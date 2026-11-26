// SPDX-License-Identifier: Apache-2.0
import Foundation
import HomespunCore
import HomespunMedia

enum BackupStageFailure: Error, LocalizedError, Sendable {
    case blocked(String)
    case sourceChanged(String)
    var errorDescription: String? { switch self { case .blocked(let message), .sourceChanged(let message): message } }
}

enum BackupValidation {
    static func matches(_ left: [ServerAPI.ResourceDescriptor], _ right: [ServerAPI.ResourceDescriptor]) -> Bool {
        PhotoKitSource.sameResources(left, right)
    }

    static func retained(_ proof: BackupAPI.OriginalProof, manifest: BackupAPI.Manifest,
                         context: BackupBindingContext, policy: BackupAPI.RetentionPolicy) -> Bool {
        guard proof.version.origin == context.binding.origin, proof.resources.count == manifest.resources.count,
              proof.resources.allSatisfy({ $0.state == .verified && $0.size > 0 && $0.receivedBytes == $0.size && $0.verifiedAt != nil }),
              matches(manifest.resources, proof.resources.map {
                  .init(role: $0.role, filename: "", size: $0.size, sha256: $0.sha256)
              }) else { return false }
        switch context.binding.mode {
        case .files:
            if policy == .permanent { return proof.retention == .permanent && proof.claimID != nil }
            return proof.retention == .permanent && proof.claimID != nil || proof.retention == .deferred
        case .immich:
            return context.information.capabilities.externalVerification == .fullResourceScrub && proof.retention == .external
        }
    }
}

struct BackupFinalizer: Sendable {
    let store: BackupStore
    let photos: any PhotoSource
    let workspace: BackupWorkspace

    func run(_ operation: BackupStore.Operation, lease: BackupStore.Lease, context: BackupBindingContext,
             progress: @escaping @Sendable (String) -> Void) async throws -> BackupStore.SavedMapping {
        guard let manifest = operation.manifest, let request = operation.request,
              let receipt = operation.receipt, let derivative = receipt.derivative,
              receipt.compact == .ready, derivative.version == receipt.version,
              operation.origin == context.binding.origin, operation.bindingID == context.binding.id,
              let metadataData = operation.metadata else { throw BackupStore.Failure.invalidImport }
        let originalMetadata = try BackupStore.decode(BackupPhotoMetadata.self, metadataData)
        if let intent = try await store.importIntent(operation.id), intent.phase != .planned {
            return try await reconcile(intent, operation: operation, manifest: manifest, policy: request.retention,
                                       context: context, progress: progress)
        }
        guard photos.authorization().allowsReading else {
            throw BackupStageFailure.blocked("Allow Photos access before saving compact copies. The originals remain on the server.")
        }
        var metadata = originalMetadata
        if photos.existing([operation.itemID], includeHidden: true).contains(operation.itemID) {
            metadata = try photos.backupMetadata(operation.itemID)
            if metadata.generation != originalMetadata.generation {
                let current = try await photos.resourceFingerprints(operation.itemID)
                guard BackupValidation.matches(manifest.resources, current) else {
                    throw BackupStageFailure.sourceChanged("The original changed after preparation. Its earlier backup is preserved; select the current version again.")
                }
            }
        }
        let originals = try await store.resources(operation.id)
        let transfers = try await store.transfers(operationID: operation.id)
        let cached = originals
        func existing(_ compact: ServerAPI.CompactResource) -> BackupStore.Resource? {
            for transfer in transfers where transfer.kind == .download && transfer.generationID == derivative.generationID
                && transfer.expected.role == compact.role && transfer.state == .completed {
                if let id = transfer.capturedResourceID, let resource = cached.first(where: { $0.fileID == id && $0.availability == .present }),
                   FileManager.default.fileExists(atPath: store.files.stagedFile(operationID: operation.id, fileID: id).path) {
                    return resource
                }
            }
            return nil
        }
        let cachedMotion = cached.first { $0.kind == .motion && $0.descriptor.role == .pairedVideo && $0.availability == .present
            && FileManager.default.fileExists(atPath: store.files.stagedFile(operationID: operation.id, fileID: $0.fileID).path) }
        let motion = originals.first { $0.kind == .original && $0.availability == .present && $0.descriptor.role == .fullSizePairedVideo }
            ?? originals.first { $0.kind == .original && $0.availability == .present && $0.descriptor.role == .pairedVideo }
        // Existing staged files are already counted by the Store. Reserve missing downloads plus
        // Photos' new copy. Linux delegates motion: reserve the retained motion's encoding overlap
        // (output, partial and Photos' copy), conservatively 4x its size.
        var needed = try sum(derivative.resources.filter { existing($0) == nil }.map(\.size)
                             + derivative.resources.map(\.size) + [cachedMotion?.descriptor.size ?? 0])
        if derivative.deviceCompresses.contains(.pairedVideo), cachedMotion == nil {
            guard let motion else {
                throw BackupStageFailure.blocked("The exact retained Live Photo motion is needed before this copy can be saved.")
            }
            let (growth, overflow) = motion.descriptor.size.multipliedReportingOverflow(by: 4)
            guard !overflow else { throw BackupSpaceFailure.workingSpaceRequired }
            needed = try sum([needed, growth])
        }
        var permit = try await workspace.finalize(operation, bytes: needed)
        do {
            var files: [PreparedPhotoResource] = []
            for compact in derivative.resources {
                try Task.checkCancellation()
                let descriptor = ServerAPI.ResourceDescriptor(role: compact.role, filename: compact.filename,
                                                               size: compact.size, sha256: compact.sha256)
                let resource: BackupStore.Resource
                let downloaded: Bool
                if let stored = existing(compact) {
                    resource = stored
                    downloaded = false
                } else {
                    progress("Downloading compact copy")
                    let transfer = BackupStore.Transfer(id: UUID(), operationID: operation.id, epoch: lease.epoch,
                        sessionID: context.session.id, kind: .download, version: receipt.version,
                        expected: descriptor, generationID: derivative.generationID)
                    resource = try await workspace.download(transfer, resource: compact, remote: context.remote, preReserved: true)
                    downloaded = true
                }
                let file = store.files.stagedFile(operationID: operation.id, fileID: resource.fileID)
                try await validate(file, expected: descriptor)
                files.append(.init(fileID: resource.fileID, url: file, descriptor: descriptor))
                if downloaded { permit = try await workspace.consume(permit, bytes: compact.size) }
            }
            if derivative.deviceCompresses.contains(.pairedVideo) {
                guard let motion, let photo = files.first(where: { $0.descriptor.role == .photo }) else {
                    throw BackupStore.Failure.invalidImport
                }
                let oldMotion = cachedMotion
                let made: PreparedPhotoResource
                if let oldMotion {
                    let file = store.files.stagedFile(operationID: operation.id, fileID: oldMotion.fileID)
                    try await validate(file, expected: oldMotion.descriptor)
                    made = .init(fileID: oldMotion.fileID, url: file, descriptor: oldMotion.descriptor)
                    progress("Checking Live Photo")
                    if case .invalid(let reason) = try await PhotoResourceHandoff.validateLivePhoto([photo, made]) {
                        throw PhotoLibrary.Failure.livePhotoInvalid(reason)
                    }
                } else {
                    progress("Compressing motion")
                    let input = store.files.stagedFile(operationID: operation.id, fileID: motion.fileID)
                    try await validate(input, expected: motion.descriptor)
                    let pendingKey = "delegated-motion-output:" + operation.id.uuidString
                    if let abandoned = try await store.metadata(pendingKey, as: UUID.self),
                       try await !store.resources(operation.id).contains(where: { $0.fileID == abandoned }) {
                        let output = store.files.stagedFile(operationID: operation.id, fileID: abandoned)
                        for url in LivePhotoMotionCompressor.workingFiles(for: output) {
                            do { try FileManager.default.removeItem(at: url) }
                            catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {}
                        }
                    }
                    let fileID = UUID(), output = store.files.stagedFile(operationID: operation.id, fileID: fileID)
                    try await store.saveMetadata(pendingKey, value: fileID)
                    do {
                        _ = try await LivePhotoMotionCompressor(profile: operation.profile).compress(input: input, output: output)
                        try BackupFiles.protect(output)
                        let digest = try await Task.detached { try Fingerprint.digests(of: output) }.value
                        guard digest.size > 0, digest.size <= permit.maximumBytes else { throw BackupSpaceFailure.workingSpaceRequired }
                        let descriptor = ServerAPI.ResourceDescriptor(role: .pairedVideo, filename: "motion.mov",
                                                                      size: digest.size, sha256: digest.sha256, sha1: digest.sha1)
                        let candidate = PreparedPhotoResource(fileID: fileID, url: output, descriptor: descriptor)
                        progress("Checking Live Photo")
                        if case .invalid(let reason) = try await PhotoResourceHandoff.validateLivePhoto([photo, candidate]) {
                            throw PhotoLibrary.Failure.livePhotoInvalid(reason)
                        }
                        try await store.recordResource(.init(fileID: fileID, operationID: operation.id, kind: .motion, descriptor: descriptor))
                        made = candidate
                    } catch {
                        // Only our own never-recorded output; a recorded resource is never deleted here.
                        if let recorded = try? await store.resources(operation.id),
                           !recorded.contains(where: { $0.fileID == fileID }) {
                            for url in LivePhotoMotionCompressor.workingFiles(for: output) {
                                try? FileManager.default.removeItem(at: url)
                            }
                        }
                        throw error
                    }
                }
                files.append(made)
            } else if manifest.kind == .livePhoto {
                guard let photo = files.first(where: { $0.descriptor.role == .photo }),
                      let motion = files.first(where: { $0.descriptor.role == .pairedVideo }) else {
                    throw BackupStore.Failure.invalidImport
                }
                progress("Checking Live Photo")
                if case .invalid(let reason) = try await PhotoResourceHandoff.validateLivePhoto([photo, motion]) {
                    throw PhotoLibrary.Failure.livePhotoInvalid(reason)
                }
            }
            permit = try await workspace.remaining(permit, bytes: try sum(files.map(\.descriptor.size)))
            try Task.checkCancellation()
            let proof = try await context.remote.verify(receipt.version)
            guard BackupValidation.retained(proof, manifest: manifest, context: context, policy: request.retention) else {
                throw BackupStageFailure.blocked("The exact original resource set lacks the required retained-origin proof.")
            }
            if photos.existing([operation.itemID], includeHidden: true).contains(operation.itemID) {
                let latest = try photos.backupMetadata(operation.itemID)
                if latest.generation != metadata.generation {
                    let actual = try await photos.resourceFingerprints(operation.itemID)
                    guard BackupValidation.matches(manifest.resources, actual) else {
                        throw BackupStageFailure.sourceChanged("The original changed before its compact copy could be saved. The earlier backup is preserved.")
                    }
                }
                metadata = latest
            }
            let observation = try photos.observePhotosEffect(restoring: false)
            let intent = try await store.planImport(lease, expected: files.map(\.descriptor))
            _ = try await store.prepareImportContext(intent, metadata: metadata, observation: observation)
            try Task.checkCancellation()
            progress("Saving")
            try await store.startImport(intent.id, lease: lease)
            let identifier: String
            do {
                identifier = try await photos.importCompact(files, metadata: metadata)
            } catch let failure as PhotosCreationFailure {
                try await store.importCreated(intent.id, identifier: failure.identifier)
                throw failure
            } catch {
                try await store.importUncertain(intent.id)
                throw error
            }
            // A committed Photos mutation is a fact even if the caller was cancelled meanwhile.
            try await store.importCreated(intent.id, identifier: identifier)
            try await store.importMetadataApplied(intent.id)
            try await workspace.release(permit)
            let tail = Task {
                progress("Verifying saved copy")
                let actual = try await photos.resourceFingerprints(identifier)
                guard BackupValidation.matches(intent.expected, actual) else {
                    throw BackupStageFailure.blocked("Photos' complete saved resources did not verify. No original can be removed.")
                }
                let fresh = try await context.remote.verify(intent.version)
                guard BackupValidation.retained(fresh, manifest: manifest, context: context, policy: request.retention) else {
                    throw BackupStore.Failure.invalidImport
                }
                return try await store.finishImport(intent.id, actual: actual, proof: fresh)
            }
            let mapping = try await tail.value
            return mapping
        } catch {
            try await workspace.release(permit)
            throw error
        }
    }

    private func reconcile(_ intent: BackupStore.ImportIntent, operation: BackupStore.Operation,
                           manifest: BackupAPI.Manifest, policy: BackupAPI.RetentionPolicy,
                           context: BackupBindingContext, progress: @escaping @Sendable (String) -> Void) async throws -> BackupStore.SavedMapping {
        guard let saved = try await store.importContext(intent.id) else {
            throw BackupStageFailure.blocked("The earlier Photos action needs guided recovery. Its intent has been preserved.")
        }
        progress("Checking previous Photos action")
        let result = try await photos.reconcilePhotosEffect(expected: intent.expected, observation: saved.observation,
                                                           createdIdentifier: intent.createdIdentifier)
        guard case .unique(let id, let actual) = result else {
            if case .blocked(let message) = result { throw BackupStageFailure.blocked(message) }
            throw BackupStore.Failure.importNeedsReconciliation
        }
        if intent.createdIdentifier == nil || saved.metadataApplied != true {
            let metadata = try photos.backupMetadata(id)
            guard attributes(saved.metadata, metadata) else {
                throw BackupStageFailure.blocked("The matching resource candidate is not uniquely associated with this import's library attributes.")
            }
        }
        try await store.importCreated(intent.id, identifier: id)
        try await store.importMetadataApplied(intent.id)
        let proof = try await context.remote.verify(intent.version)
        guard BackupValidation.retained(proof, manifest: manifest, context: context, policy: policy) else {
            throw BackupStore.Failure.invalidImport
        }
        return try await store.finishImport(intent.id, actual: actual, proof: proof)
    }

    private func attributes(_ expected: BackupPhotoMetadata, _ actual: BackupPhotoMetadata) -> Bool {
        guard expected.creationDate == actual.creationDate, expected.favorite == actual.favorite,
              expected.hidden == actual.hidden, Set(expected.albums).isSubset(of: Set(actual.albums)) else { return false }
        do {
            switch (try expected.location(), try actual.location()) {
            case (nil, nil): return true
            case (let first?, let second?): return first.distance(from: second) < 0.1
            default: return false
            }
        } catch { return false }
    }

    private func validate(_ file: URL, expected: ServerAPI.ResourceDescriptor) async throws {
        let digest = try await Task.detached { try Fingerprint.digests(of: file) }.value
        guard digest.size > 0, digest.size == expected.size, digest.sha256 == expected.sha256.lowercased() else {
            throw BackupStore.Failure.invalidImport
        }
        if expected.role == .photo {
            let data = try Data(contentsOf: file, options: .mappedIfSafe)
            if JPEGIntegrity.isJPEG(data), !JPEGIntegrity.isComplete(data) {
                throw PhotoLibrary.Failure.verificationFailed("the compact JPEG is structurally incomplete")
            }
        }
    }

    private func sum(_ values: [Int]) throws -> Int {
        try values.reduce(0) {
            let (result, overflow) = $0.addingReportingOverflow($1)
            guard $1 >= 0, !overflow else { throw BackupSpaceFailure.workingSpaceRequired }
            return result
        }
    }
}
