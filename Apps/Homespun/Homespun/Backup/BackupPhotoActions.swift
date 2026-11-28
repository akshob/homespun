// SPDX-License-Identifier: Apache-2.0
import Foundation
import HomespunCore
import Photos

struct DurableOriginalRemover: RemovingOriginals {
    let context: BackupBindingContext
    let ledger: CompactLedger
    let photos: any PhotoSource
    var batchLimit = 10
    var maximumProofAge: TimeInterval = 30
    var current: @MainActor @Sendable () -> Bool = { true }

    func candidates(only: Set<String>?) async throws -> [(original: String, entry: CompactLedger.Entry)] {
        guard await current(), photos.authorization().allowsReading else { throw BackupStore.Failure.retiredBinding }
        let all = try await ledger.snapshot().filter {
            $0.value.origin == context.binding.origin && $0.value.verifiedCompact && (only?.contains($0.key) ?? true)
                && (context.binding.mode == .files ? $0.value.retention == .permanent
                    : $0.value.retention == .external && context.information.capabilities.externalVerification == .fullResourceScrub)
        }
        let kept = try await ledger.decisions()
        let originals = photos.existing(Array(all.keys), includeHidden: false)
        let compacts = photos.existing(all.values.map(\.compactIdentifier), includeHidden: true)
        var result: [(original: String, entry: CompactLedger.Entry)] = []
        for (original, entry) in all where originals.contains(original) && compacts.contains(entry.compactIdentifier) && !kept.contains(original) {
            do {
                let generation = try photos.sourceGeneration(entry.compactIdentifier)
                guard let expected = entry.compactResources, generation.resources.count == expected.count,
                      expected.allSatisfy({ resource in generation.resources.contains {
                          $0.role == resource.role && $0.bytes == resource.size && resource.size > 0
                      } }) else { continue }
                result.append((original, entry))
            } catch PhotoLibrary.Failure.notFound {
                continue
            }
        }
        return result.sorted { $0.entry.savedAt < $1.entry.savedAt }
    }

    private struct Checked: Sendable {
        var mapping: BackupStore.SavedMapping
        var approval: PhotosRemovalApproval
        var manifest: BackupAPI.Manifest
        var version: BackupAPI.Version
        var epoch: Int64
        var operationID: UUID
        var name: String
        var checkedAt: Date
    }

    func removeEligible(limit: Int?, only: Set<String>?,
                        progress: @escaping @Sendable (String) -> Void) async throws -> OriginalRemover.Report {
        let selected = Array(try await candidates(only: only).prefix(limit ?? .max))
        var report = OriginalRemover.Report()
        guard !selected.isEmpty else { return report }
        try await reconcileRemovals()
        for start in stride(from: 0, to: selected.count, by: max(1, batchLimit)) {
            try Task.checkCancellation()
            guard await current(), try await ledger.store.binding(context.binding.id)?.retired == false else {
                throw BackupStore.Failure.retiredBinding
            }
            let group = selected[start..<min(start + max(1, batchLimit), selected.count)]
            var checked: [Checked] = []
            let mappings = try await ledger.store.mappings(namespace: ledger.namespace)
            for candidate in group {
                progress("Checking original \(checked.count + 1) of \(group.count)")
                do {
                    guard var mapping = mappings[candidate.original], let operationID = candidate.entry.operationID,
                          let operation = try await ledger.store.operation(operationID),
                          let version = candidate.entry.version, let manifest = operation.manifest,
                          mapping.origin == context.binding.origin, mapping.proof?.version == version,
                          operation.receipt?.version == version,
                          let expectedCompact = candidate.entry.compactResources else { throw BackupStore.Failure.invalidImport }
                    mapping.entry = candidate.entry
                    let original = try photos.sourceGeneration(candidate.original)
                    let device = try await photos.resourceFingerprints(candidate.original)
                    guard try photos.sourceGeneration(candidate.original) == original,
                          BackupValidation.matches(manifest.resources, device) else { throw BackupStore.Failure.invalidImport }
                    let compact = try photos.sourceGeneration(candidate.entry.compactIdentifier)
                    let compactFiles = try await photos.resourceFingerprints(candidate.entry.compactIdentifier)
                    guard try photos.sourceGeneration(candidate.entry.compactIdentifier) == compact,
                          BackupValidation.matches(expectedCompact, compactFiles) else { throw BackupStore.Failure.invalidImport }
                    let proof = try await freshProof(version, manifest: manifest)
                    let gate = DeletionGate().evaluate(
                        deviceResources: device.map { .init(role: $0.role.rawValue, sha256: $0.sha256, size: $0.size) },
                        serverVerified: proof.resources.map { .init(role: $0.role.rawValue, sha256: $0.sha256, size: $0.size) },
                        compactImported: true)
                    guard case .allowed = gate else { throw BackupStore.Failure.invalidImport }
                    checked.append(.init(mapping: mapping, approval: .init(original: original, compact: compact), manifest: manifest,
                                         version: version, epoch: operation.epoch, operationID: operation.id,
                                         name: photos.describe(candidate.original)?.name ?? "Item", checkedAt: Date()))
                } catch {
                    report.blocked.append(error.localizedDescription)
                }
            }
            for index in checked.indices where Date().timeIntervalSince(checked[index].checkedAt) > maximumProofAge {
                _ = try await freshProof(checked[index].version, manifest: checked[index].manifest)
                checked[index].checkedAt = Date()
            }
            let fresh = checked.filter { Date().timeIntervalSince($0.checkedAt) <= maximumProofAge }
            report.blocked += checked.filter { Date().timeIntervalSince($0.checkedAt) > maximumProofAge }
                .map { "\($0.name): its proof expired before confirmation. Try a smaller selection." }
            guard !fresh.isEmpty else { continue }
            let id = UUID()
            let effect = BackupStore.PhotoEffect(id: id, namespace: ledger.namespace, item: id.uuidString,
                kind: .removeOriginal, bindingID: context.binding.id, version: fresh[0].version,
                epochs: Dictionary(uniqueKeysWithValues: fresh.map { ($0.operationID, $0.epoch) }),
                mappings: fresh.map(\.mapping), approvals: fresh.map(\.approval))
            _ = try await ledger.store.planEffect(effect)
            guard await current() else { try await ledger.store.cancelEffect(id); throw BackupStore.Failure.retiredBinding }
            try Task.checkCancellation()
            progress("Waiting for your confirmation")
            try await ledger.store.startEffect(id)
            do {
                let result = try await photos.removeApproved(fresh.map(\.approval))
                try await ledger.store.effectCreated(id, submitted: result.submitted)
                try await ledger.store.completeRemoval(id)
                for item in fresh where result.submitted.contains(item.approval.original.identifier) {
                    report.removed.append(item.name)
                    report.freedBytes += item.manifest.resources.reduce(0) { $0 + $1.size }
                }
                report.blocked += fresh.filter { result.invalidated.contains($0.approval.original.identifier) }
                    .map { "\($0.name): the original or its complete compact copy changed before confirmation." }
            } catch let error as PHPhotosError where error.code == .userCancelled {
                try await ledger.store.cancelEffect(id)
                report.cancelled = true
                return report
            } catch {
                try await ledger.store.effectUncertain(id, message: error.localizedDescription)
                throw error
            }
        }
        return report
    }

    private func freshProof(_ version: BackupAPI.Version, manifest: BackupAPI.Manifest) async throws -> BackupAPI.OriginalProof {
        var captured = context
        if context.binding.mode == .immich {
            let capabilities = try await context.remote.capabilities()
            guard capabilities.origin == context.binding.origin, capabilities.externalVerification == .fullResourceScrub else {
                throw BackupStageFailure.blocked("This Immich server hasn't negotiated fresh complete-resource verification.")
            }
            captured.information.capabilities = capabilities
        }
        let proof = try await captured.remote.verify(version)
        guard proof.version == version, BackupValidation.retained(proof, manifest: manifest, context: captured, policy: .permanent) else {
            throw BackupStageFailure.blocked("The exact original lacks a fresh non-purge-eligible retained proof.")
        }
        return proof
    }

    private func reconcileRemovals() async throws {
        for effect in try await ledger.store.effects(namespace: ledger.namespace) where effect.kind == .removeOriginal {
            if effect.phase == .planned { try await ledger.store.cancelEffect(effect.id); continue }
            if effect.phase == .created { try await ledger.store.completeRemoval(effect.id); continue }
            guard photos.authorization() == .authorized else {
                throw BackupStageFailure.blocked("Full Photos access is needed to reconcile the earlier removal.")
            }
            let originals = effect.originals
            let present = photos.existing(Array(originals), includeHidden: true)
            if present.isEmpty {
                try await ledger.store.effectCreated(effect.id, submitted: originals,
                    problem: "The original IDs are no longer in Photos; no additional removal was requested.")
                try await ledger.store.completeRemoval(effect.id)
            } else {
                throw BackupStageFailure.blocked("An earlier removal has an uncertain outcome. No new deletion was submitted; check the originals in Photos.")
            }
        }
    }
}

struct BackupKeeper: Sendable {
    let ledger: CompactLedger
    let photos: any PhotoSource

    func keep(_ ids: [String]) async throws -> Bool {
        try await reconcile()
        let entries = try await ledger.snapshot(), mappings = try await ledger.store.mappings(namespace: ledger.namespace)
        var held: [BackupStore.SavedMapping] = [], approvals: [PhotosRemovalApproval] = []
        var epochs: [UUID: Int64] = [:]
        for id in ids {
            guard let entry = entries[id], var mapping = mappings[id] else { continue }
            guard entry.verifiedCompact else {
                throw BackupStageFailure.blocked("This earlier compact mapping lacks complete versioned proof. Both items were kept; review the mapping before deleting a copy.")
            }
            guard photos.item(entry.compactIdentifier)?.isEdited == false else {
                throw BackupStageFailure.blocked("The compact copy has edits or cannot be read. It has been kept alongside the original.")
            }
            let before = try photos.sourceGeneration(id)
            let originals = try await photos.resourceFingerprints(id)
            guard try photos.sourceGeneration(id) == before, !originals.isEmpty, originals.allSatisfy({ $0.size > 0 }) else {
                throw BackupStore.Failure.invalidImport
            }
            if let operationID = entry.operationID, let operation = try await ledger.store.operation(operationID) {
                guard let manifest = operation.manifest, BackupValidation.matches(manifest.resources, originals) else {
                    throw BackupStore.Failure.invalidImport
                }
                epochs[operationID] = operation.epoch
            }
            mapping.entry = entry
            let compact = try photos.sourceGeneration(entry.compactIdentifier)
            if let expected = entry.compactResources {
                let actual = try await photos.resourceFingerprints(entry.compactIdentifier)
                guard try photos.sourceGeneration(entry.compactIdentifier) == compact,
                      BackupValidation.matches(expected, actual) else {
                    throw BackupStageFailure.blocked("The compact copy changed after import. Its current version has not been deleted.")
                }
            }
            held.append(mapping)
            approvals.append(.init(original: before, compact: compact))
        }
        guard !held.isEmpty else { return false }
        let id = UUID()
        let effect = BackupStore.PhotoEffect(id: id, namespace: ledger.namespace, item: id.uuidString,
            kind: .keepOriginal, epochs: epochs, mappings: held, approvals: approvals)
        _ = try await ledger.store.planEffect(effect)
        try Task.checkCancellation()
        try await ledger.store.startEffect(id)
        do {
            let result = try await photos.keepApproved(approvals)
            try await ledger.store.effectCreated(id, submitted: result.submitted)
            try await ledger.store.completeKeep(id)
            if !result.invalidated.isEmpty {
                throw BackupStageFailure.blocked("Some originals changed before the compact-copy deletion. They still need review.")
            }
            return !result.submitted.isEmpty
        } catch let error as PHPhotosError where error.code == .userCancelled {
            try await ledger.store.cancelEffect(id)
            return false
        } catch {
            try await ledger.store.effectUncertain(id, message: error.localizedDescription)
            throw error
        }
    }

    func reconcile() async throws {
        for effect in try await ledger.store.effects(namespace: ledger.namespace) where effect.kind == .keepOriginal {
            if effect.phase == .planned { try await ledger.store.cancelEffect(effect.id); continue }
            if effect.phase == .created { try await ledger.store.completeKeep(effect.id); continue }
            guard photos.authorization() == .authorized else {
                throw BackupStageFailure.blocked("Full Photos access is needed to reconcile Keep Original.")
            }
            let originals = photos.existing(effect.mappings.map(\.originalID), includeHidden: true)
            let compacts = photos.existing(effect.mappings.map(\.entry.compactIdentifier), includeHidden: true)
            guard originals.count == effect.mappings.count, compacts.isEmpty,
                  effect.approvals.allSatisfy({ (try? photos.sourceGeneration($0.original.identifier)) == $0.original }) else {
                throw BackupStageFailure.blocked("The earlier Keep Original action needs review. No additional copy was deleted.")
            }
            try await ledger.store.effectCreated(effect.id, submitted: Set(effect.mappings.map(\.entry.compactIdentifier)))
            try await ledger.store.completeKeep(effect.id)
        }
    }
}

struct DurableOriginalRestorer: RestoringOriginals {
    let context: BackupBindingContext
    let ledger: CompactLedger
    let photos: any PhotoSource
    let workspace: BackupWorkspace

    @MainActor func restore(_ items: [OriginalRestorer.Item],
                           progress: @escaping @Sendable (OriginalRestorer.Progress) -> Void) async -> OriginalRestorer.Report {
        var bound = context
        bound.session = .init(id: UUID(), bindingID: context.binding.id, identifier: "foreground.restore." + UUID().uuidString,
                              installationID: context.session.installationID)
        do {
            try await ledger.store.registerSession(bound.session)
            BackupExecutionSessions.claim(bound.session.id)
            defer { BackupExecutionSessions.release(bound.session.id) }
            return await DurableOriginalRestorer(context: bound, ledger: ledger, photos: photos, workspace: workspace)
                .performRestore(items, progress: progress)
        } catch { return .init(problems: [error.localizedDescription]) }
    }

    private func performRestore(_ items: [OriginalRestorer.Item],
                 progress: @escaping @Sendable (OriginalRestorer.Progress) -> Void) async -> OriginalRestorer.Report {
        var report = OriginalRestorer.Report()
        for (index, item) in items.enumerated() {
            if Task.isCancelled { break }
            progress(.init(done: index, total: items.count, message: "Getting original \(index + 1) of \(items.count)"))
            do {
                let restored = try await restoreOne(item)
                report.restored.append(restored)
                report.bytes += item.originalBytes
            } catch let failure as PhotosCreationFailure {
                report.copiesKept = true
                report.problems.append("Photos created an item, but its final metadata or byte verification needs recovery. Its creation is saved; no duplicate is imported. \(failure.localizedDescription)")
            } catch { report.problems.append(error.localizedDescription) }
        }
        if !report.restored.isEmpty {
            if Task.isCancelled { report.copiesKept = true }
            else {
                progress(.init(done: report.restored.count, total: items.count, message: "Waiting for your confirmation"))
                do {
                    report.copiesKept = !(try await BackupKeeper(ledger: ledger, photos: photos).keep(report.restored))
                } catch {
                    report.copiesKept = true
                    report.problems.append("The originals are restored, but recording compact-copy cleanup needs attention: \(error.localizedDescription)")
                }
            }
        }
        return report
    }

    private func restoreOne(_ item: OriginalRestorer.Item) async throws -> String {
        let entries = try await ledger.snapshot(), mappings = try await ledger.store.mappings(namespace: ledger.namespace)
        guard context.binding.mode == .files, let entry = entries[item.key], var mapping = mappings[item.key],
              entry.origin == context.binding.origin, let version = entry.version, let requestID = entry.requestID,
              let operationID = entry.operationID, let operation = try await ledger.store.operation(operationID),
              let manifest = operation.manifest, mapping.proof?.version == version,
              try await ledger.store.binding(context.binding.id)?.retired == false else {
            throw BackupStageFailure.blocked("Before restoring this earlier backup, run Server › Existing Library › Find Compact Copies on the server holding its original. Homespun needs a versioned backup record and a fresh check; a Homespun 1.0 catalog check isn't enough.")
        }
        mapping.entry = entry
        for old in try await ledger.store.effects(namespace: ledger.namespace) where old.kind == .restore && old.originals.contains(item.key) {
            if old.phase == .planned { try await ledger.store.cancelEffect(old.id); continue }
            guard let observation = old.observation, let metadata = old.metadata else { throw BackupStore.Failure.importNeedsReconciliation }
            let result = try await photos.reconcilePhotosEffect(expected: old.expected, observation: observation,
                                                                createdIdentifier: old.createdIdentifier)
            guard case .unique(let identifier, let actual) = result else {
                throw BackupStageFailure.blocked("The earlier restore may already exist. No duplicate original was imported.")
            }
            let attributes = try photos.backupMetadata(identifier)
            guard attributes.creationDate == metadata.creationDate, attributes.favorite == metadata.favorite,
                  attributes.hidden == metadata.hidden else {
                throw BackupStageFailure.blocked("The earlier restored original exists, but its library metadata needs review.")
            }
            try await ledger.store.effectCreated(old.id, identifier: identifier)
            let proof = try await context.remote.verify(version)
            guard BackupValidation.retained(proof, manifest: manifest, context: context, policy: .permanent) else { throw BackupStore.Failure.invalidImport }
            _ = try await ledger.store.completeRestore(old.id, actual: actual, proof: proof)
            return identifier
        }
        let proof = try await context.remote.verify(version)
        guard BackupValidation.retained(proof, manifest: manifest, context: context, policy: .permanent) else {
            throw BackupStore.Failure.invalidReceipt
        }
        var metadata = try photos.backupMetadata(item.compact)
        metadata.sourceID = item.key
        let observation = try photos.observePhotosEffect(restoring: true)
        let id = UUID()
        let effect = BackupStore.PhotoEffect(id: id, namespace: ledger.namespace, item: item.key, kind: .restore,
            bindingID: context.binding.id, version: version, epochs: [operationID: operation.epoch], mappings: [mapping],
            metadata: metadata, observation: observation, expected: manifest.resources)
        _ = try await ledger.store.planEffect(effect)
        let (space, overflow) = manifest.resources.reduce(0, { $0 + $1.size }).multipliedReportingOverflow(by: 2)
        guard !overflow else { throw BackupSpaceFailure.workingSpaceRequired }
        var permit = try await workspace.finalize(operation, bytes: space)
        do {
            var files: [PreparedPhotoResource] = []
            var resources: [BackupStore.Resource] = []
            for expected in manifest.resources {
                try Task.checkCancellation()
                let transfer = BackupStore.Transfer(id: UUID(), operationID: operationID, epoch: operation.epoch,
                    sessionID: context.session.id, kind: .originalDownload, version: version, expected: expected)
                let resource = try await workspace.downloadOriginal(transfer, requestID: requestID, remote: context.remote, preReserved: true)
                resources.append(resource)
                files.append(.init(fileID: resource.fileID,
                    url: ledger.store.files.stagedFile(operationID: operationID, fileID: resource.fileID), descriptor: expected))
                permit = try await workspace.consume(permit, bytes: expected.size)
            }
            try Task.checkCancellation()
            try await ledger.store.effectResources(id, resources: resources)
            metadata = try photos.backupMetadata(item.compact)
            metadata.sourceID = item.key
            try await ledger.store.effectMetadata(id, metadata: metadata)
            try await ledger.store.startEffect(id)
            let identifier: String
            do {
                identifier = try await photos.restoreResources(files, metadata: metadata)
            } catch PhotoLibrary.Failure.restoreMetadata(let identifier, let message) {
                try await ledger.store.effectCreated(id, identifier: identifier, problem: message)
                throw PhotosCreationFailure(identifier: identifier, message: message)
            } catch let failure as PhotosCreationFailure {
                try await ledger.store.effectCreated(id, identifier: failure.identifier, problem: failure.localizedDescription)
                throw failure
            } catch {
                try await ledger.store.effectUncertain(id, message: error.localizedDescription)
                throw error
            }
            try await ledger.store.effectCreated(id, identifier: identifier)
            try await workspace.release(permit)
            let tail = Task {
                let actual = try await photos.resourceFingerprints(identifier)
                let fresh = try await context.remote.verify(version)
                guard BackupValidation.retained(fresh, manifest: manifest, context: context, policy: .permanent) else {
                    throw BackupStore.Failure.invalidImport
                }
                _ = try await ledger.store.completeRestore(id, actual: actual, proof: fresh)
                return identifier
            }
            let result = try await tail.value
            try await workspace.collectReleasedFiles()
            return result
        } catch {
            try await workspace.release(permit)
            throw error
        }
    }
}
