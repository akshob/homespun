// SPDX-License-Identifier: Apache-2.0
import Foundation
import HomespunCore
import Photos

extension BackupStore {
    struct LegacyRestoreIntent: Codable, Sendable {
        var item: String
        var scope: String
        var startedAt: Date
        var expected: [ServerAPI.ResourceDescriptor]
    }

    func beginLegacyRestore(_ intent: LegacyRestoreIntent, namespace: String) throws {
        try mutateState { connection in
            guard try connection.rows("SELECT item FROM legacy_restores WHERE namespace = ? AND item = ?",
                [.text(namespace), .text(intent.item)]).isEmpty else {
                throw BackupStageFailure.blocked("A restored original may already be in Recents. Check it before trying again.")
            }
            try connection.execute("INSERT INTO legacy_restores(namespace,item,body) VALUES(?,?,?)",
                [.text(namespace), .text(intent.item), .blob(try Self.encode(intent))])
        }
    }

    func hasLegacyRestore(_ item: String, namespace: String) throws -> Bool {
        try readState { connection in
            try !connection.rows("SELECT item FROM legacy_restores WHERE namespace = ? AND item = ?",
                [.text(namespace), .text(item)]).isEmpty
        }
    }

    func finishLegacyRestore(_ item: String, namespace: String) throws {
        try mutateState { connection in
            _ = try connection.execute("DELETE FROM legacy_restores WHERE namespace = ? AND item = ?",
                [.text(namespace), .text(item)])
        }
    }
}

struct LegacyOriginalRestorer: RestoringOriginals {
    let client: ServerClient
    let ledger: CompactLedger
    let photos: any PhotoSource
    let scope: String
    let mode: ServerAPI.StorageMode
    var origin: BackupAPI.Origin?
    var current: @MainActor @Sendable () -> Bool
    var now: @Sendable () -> Date = { Date() }

    func restore(_ items: [OriginalRestorer.Item],
                 progress: @escaping @Sendable (OriginalRestorer.Progress) -> Void) async -> OriginalRestorer.Report {
        var report = OriginalRestorer.Report()
        for (index, item) in items.enumerated() {
            guard !Task.isCancelled else { break }
            progress(.init(done: index, total: items.count, message: "Getting original \(index + 1) of \(items.count)"))
            do {
                let result = try await restoreOne(item, progress: progress)
                report.restored.append(result.identifier)
                report.bytes += item.originalBytes
                report.copiesKept = report.copiesKept || result.copyKept
            } catch { report.problems.append(error.localizedDescription) }
        }
        return report
    }

    private func restoreOne(_ item: OriginalRestorer.Item,
                            progress: @escaping @Sendable (OriginalRestorer.Progress) -> Void) async throws
        -> (identifier: String, copyKept: Bool) {
        guard mode == .files, await current() else { throw CancellationError() }
        guard !(try await ledger.store.hasLegacyRestore(item.key, namespace: ledger.namespace)) else {
            throw LegacyOriginalProof.blocked("A restored original may already be in Recents. Check it before trying again.")
        }
        let projection = try await ledger.projection()
        guard let entry = projection.entries[item.key], entry.origin == nil,
              entry.compactIdentifier == item.compact, entry.serverAssetID == item.serverAssetID,
              entry.originalBytes == item.originalBytes,
              projection.legacyConfirmed(scope: scope, origin: origin, now: now())[item.key] != nil,
              photos.existing([item.key], includeHidden: true).isEmpty else {
            throw LegacyOriginalProof.blocked("This earlier backup isn't confirmed, or its original is already on this iPhone.")
        }
        let compact = try await LegacyOriginalProof.compact(item.compact, asset: item.serverAssetID,
            originalBytes: item.originalBytes, photos: photos, client: client)
        let proof = try await LegacyOriginalProof.fresh(asset: item.serverAssetID, client: client, now: now, current: current)
        guard proof.resources.reduce(0, { $0 + $1.size }) == item.originalBytes else { throw BackupStore.Failure.invalidImport }
        // Validate the complete set before Photos: unsupported resources must never be silently dropped.
        _ = try BackupAPI.Manifest(kind: proof.status.kind, resources: proof.resources).validated()
        let (_, overflow) = item.originalBytes.addingReportingOverflow(1 << 30)
        guard !overflow, OriginalRestorer.room(for: item.originalBytes).enough else {
            throw LegacyOriginalProof.blocked("This iPhone needs more space to restore the complete original.")
        }
        let work = ledger.store.files.root.appendingPathComponent("legacy-restore-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        var files: [PreparedPhotoResource] = []
        for expected in proof.resources {
            try Task.checkCancellation()
            let file = try await client.downloadOriginalFile(assetID: item.serverAssetID, role: expected.role,
                to: work.appendingPathComponent(expected.role.rawValue, isDirectory: true), fallback: expected.role.rawValue)
            let digest = try await Task.detached { try Fingerprint.digests(of: file) }.value
            guard digest.size == expected.size, digest.sha256 == expected.sha256 else {
                throw LegacyOriginalProof.blocked("The original changed on the way. Its compact copy was kept.")
            }
            var received = expected
            received.filename = file.lastPathComponent
            files.append(.init(fileID: UUID(), url: file, descriptor: received))
        }
        let fresh = try await LegacyOriginalProof.fresh(asset: item.serverAssetID, client: client, now: now, current: current)
        guard BackupValidation.matches(proof.resources, fresh.resources),
              try photos.sourceGeneration(item.compact) == compact,
              try await ledger.entry(for: item.key) == entry, await current() else { throw BackupStore.Failure.invalidImport }
        var metadata = try photos.backupMetadata(item.compact)
        metadata.sourceID = item.key
        metadata.kind = proof.status.kind
        try Task.checkCancellation()
        try await ledger.store.beginLegacyRestore(.init(item: item.key, scope: scope, startedAt: now(),
            expected: proof.resources), namespace: ledger.namespace)
        guard await current() else { throw CancellationError() }
        let identifier = try await photos.restoreResources(files, metadata: metadata)
        let generation = try photos.sourceGeneration(identifier)
        let actual = try await photos.resourceFingerprints(identifier)
        guard try photos.sourceGeneration(identifier) == generation,
              BackupValidation.matches(proof.resources, actual) else {
            throw LegacyOriginalProof.blocked("Photos may have restored the original, but its bytes need review. No duplicate will be imported; the compact copy stays.")
        }
        var copyKept = true
        do {
            guard await current(), !Task.isCancelled else { throw CancellationError() }
            let compactNow = try await LegacyOriginalProof.compact(item.compact, asset: item.serverAssetID,
                originalBytes: item.originalBytes, photos: photos, client: client)
            guard compactNow == compact else { throw BackupStore.Failure.invalidImport }
            let last = try await LegacyOriginalProof.fresh(asset: item.serverAssetID, client: client, now: now, current: current)
            let age = now().timeIntervalSince(last.requestedAt)
            guard BackupValidation.matches(proof.resources, last.resources),
                  try await ledger.entry(for: item.key) == entry, await current(), age >= 0, age <= 30 else {
                throw BackupStore.Failure.invalidImport
            }
            progress(.init(done: 0, total: 1, message: "Waiting for your confirmation"))
            let result = try await photos.keepApproved([.init(original: generation, compact: compact)])
            copyKept = !result.submitted.contains(item.compact)
        } catch {
            // The verified restored original stays. Cancellation or uncertainty can only keep more copies.
        }
        try await ledger.restored([(key: item.key, restored: identifier, entry: entry)], copiesDeleted: !copyKept)
        try await ledger.store.finishLegacyRestore(item.key, namespace: ledger.namespace)
        let candidate = LegacyCheck.Candidate(item: identifier, asset: item.serverAssetID.lowercased(),
            bytes: item.originalBytes, role: proof.status.kind == .video ? .video : .photo,
            compact: copyKept ? item.compact : nil)
        try? await ledger.store.recordLegacyChecks([.init(candidate: candidate, scope: scope, origin: origin,
            verified: true, checkedAt: now())], scope: scope, namespace: ledger.namespace, current: current)
        return (identifier, copyKept)
    }
}
