// SPDX-License-Identifier: Apache-2.0
import Foundation
import HomespunCore

extension DemoLibrary {
    func preparationBytes(_ id: String, mode: ServerAPI.StorageMode) throws -> Int {
        guard !isRetired, let item = demoItem(id), !isCopy(id) else { throw PhotoLibrary.Failure.notFound }
        return try item.files.values.reduce(0) { total, file in
            let size = try PhotoLibrary.size(of: file)
            let (next, overflow) = total.addingReportingOverflow(size)
            guard size > 0, !overflow else { throw BackupAPI.ValidationError.invalidManifest }
            return next
        }
    }

    func prepareBackup(_ id: String, mode: ServerAPI.StorageMode, directory: URL, maximumBytes: Int,
                       progress: @escaping @Sendable (String) -> Void) async throws -> PreparedPhoto {
        try Task.checkCancellation()
        guard !isRetired, let item = demoItem(id), !isCopy(id) else { throw PhotoLibrary.Failure.notFound }
        guard try preparationBytes(id, mode: mode) <= maximumBytes else {
            throw PhotoLibrary.Failure.unsupported("The demo item is waiting for protected staging space.")
        }
        let before = try sourceGeneration(id)
        var files: [PreparedPhotoResource] = []
        do {
            for (role, source) in item.files.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                try Task.checkCancellation()
                let fileID = UUID(), digest = try Fingerprint.digests(of: source)
                let file = directory.appendingPathComponent(fileID.uuidString)
                try whileActive { try FileManager.default.copyItem(at: source, to: file) }
                try BackupFiles.protect(file)
                files.append(.init(fileID: fileID, url: file, descriptor: .init(
                    role: role, filename: source.lastPathComponent, size: digest.size, sha256: digest.sha256, sha1: digest.sha1)))
            }
            guard try sourceGeneration(id) == before else { throw BackupAPI.ValidationError.invalidManifest }
            let metadata = BackupPhotoMetadata(sourceID: id, kind: item.kind.api, creationDate: item.creationDate,
                                               locationArchive: nil, favorite: item.isFavorite, hidden: false,
                                               albums: [], generation: before)
            let prepared = PreparedPhoto(metadata: metadata, resources: files)
            _ = try prepared.manifest.validated()
            return prepared
        } catch {
            for file in files { try? FileManager.default.removeItem(at: file.url) }
            throw error
        }
    }

    func resourceFingerprints(_ id: String) async throws -> [ServerAPI.ResourceDescriptor] {
        guard !isRetired, let item = demoItem(id) else { throw PhotoLibrary.Failure.notFound }
        return try item.files.sorted(by: { $0.key.rawValue < $1.key.rawValue }).map { role, url in
            let digest = try Fingerprint.digests(of: url)
            return .init(role: role, filename: url.lastPathComponent, size: digest.size, sha256: digest.sha256, sha1: digest.sha1)
        }
    }

    func sourceGeneration(_ id: String) throws -> PhotoGeneration {
        guard !isRetired, let item = demoItem(id) else { throw PhotoLibrary.Failure.notFound }
        let modified = try item.files.values.compactMap {
            try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }.max()
        return .init(identifier: id, modified: modified, width: item.pixelWidth, height: item.pixelHeight,
                     resources: try item.files.map { role, file in
                         .init(role: role, name: file.lastPathComponent, bytes: try PhotoLibrary.size(of: file))
                     }.sorted { $0.role.rawValue < $1.role.rawValue })
    }

    func observePhotosEffect(restoring: Bool) throws -> PhotosObservation {
        guard !isRetired else { throw CancellationError() }
        return .init(token: nil, baseline: restoring ? Set(allIdentifiers()) : albumMembers(), restoring: restoring)
    }

    func reconcilePhotosEffect(expected: [ServerAPI.ResourceDescriptor], observation: PhotosObservation,
                               createdIdentifier: String?) async throws -> PhotosReconciliation {
        guard !isRetired else { throw CancellationError() }
        let candidates: Set<String>
        if let createdIdentifier {
            guard demoItem(createdIdentifier) != nil else {
                return .blocked("The demo's previous creation isn't visible; no duplicate was made.")
            }
            candidates = [createdIdentifier]
        } else {
            candidates = (observation.restoring ? Set(allIdentifiers()) : albumMembers()).subtracting(observation.baseline)
        }
        var matches: [(String, [ServerAPI.ResourceDescriptor])] = []
        for id in candidates.sorted() {
            let actual = try await resourceFingerprints(id)
            if PhotoKitSource.sameResources(expected, actual) { matches.append((id, actual)) }
            if matches.count > 1 { return .blocked("More than one complete demo copy matches. No copy was removed or imported.") }
        }
        guard let match = matches.first else {
            return .blocked("The earlier demo creation needs review. No duplicate was imported.")
        }
        return .unique(identifier: match.0, resources: match.1)
    }

    func importCompact(_ files: [PreparedPhotoResource], metadata: BackupPhotoMetadata) async throws -> String {
        guard !isRetired else { throw CancellationError() }
        return try await addCompactCopy(of: metadata.sourceID,
                                       files: Dictionary(uniqueKeysWithValues: files.map { ($0.descriptor.role, $0.url) }))
    }

    func restoreResources(_ files: [PreparedPhotoResource], metadata: BackupPhotoMetadata) async throws -> String {
        guard !isRetired, let id = restore(metadata.sourceID) else { throw PhotoLibrary.Failure.notFound }
        return id
    }

    func removeApproved(_ approvals: [PhotosRemovalApproval]) async throws -> PhotosRemovalResult {
        guard !isRetired else { throw CancellationError() }
        var valid = Set<String>(), invalid = Set<String>()
        for approval in approvals {
            if (try? sourceGeneration(approval.original.identifier)) == approval.original,
               (try? sourceGeneration(approval.compact.identifier)) == approval.compact {
                valid.insert(approval.original.identifier)
            } else {
                invalid.insert(approval.original.identifier)
            }
        }
        if !valid.isEmpty { try await delete(valid.sorted()) }
        return .init(submitted: valid, invalidated: invalid)
    }
}
