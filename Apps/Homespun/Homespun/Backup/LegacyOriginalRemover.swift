// SPDX-License-Identifier: Apache-2.0
import Foundation
import HomespunCore
import Photos

/// The v1 catalog cache selects items only. Every Photos mutation needs a new byte proof.
struct LegacyOriginalProof: Sendable {
    var status: ServerAPI.AssetStatus
    var resources: [ServerAPI.ResourceDescriptor]
    var requestedAt: Date

    static func safe(_ status: ServerAPI.AssetStatus, asset: String) -> Bool {
        status.assetID.lowercased() == asset.lowercased() && status.trashedUntil == nil
            && [.imported, .ready, .stored].contains(status.state)
    }

    static func fresh(asset: String, client: ServerClient, now: @Sendable () -> Date,
                      current: @MainActor @Sendable () -> Bool) async throws -> Self {
        guard await current() else { throw CancellationError() }
        let before = try await client.status(asset)
        guard safe(before, asset: asset) else { throw blocked("Its original is incomplete or in the server's trash. Nothing was removed.") }
        let started = now()
        let proof = try await client.verify(asset)
        let after = try await client.status(asset)
        guard await current(), safe(after, asset: asset), before.state == after.state, before.kind == after.kind,
              before.compact == after.compact,
              before.resources.map({ ($0.role.rawValue, $0.sha256, $0.size) }).elementsEqual(
                after.resources.map { ($0.role.rawValue, $0.sha256, $0.size) }, by: { $0 == $1 }),
              proof.assetID.lowercased() == asset.lowercased(),
              !proof.resources.isEmpty, Set(proof.resources.map(\.role)).count == proof.resources.count,
              proof.resources.count == after.resources.count else {
            throw blocked("The server's original changed during its check. Nothing was removed.")
        }
        let resources = try proof.resources.map { resource -> ServerAPI.ResourceDescriptor in
            guard resource.verified, let hash = resource.sha256, let bytes = resource.size, bytes > 0,
                  hash.count == 64, after.resources.contains(where: {
                      $0.role == resource.role && $0.sha256.lowercased() == hash.lowercased()
                          && $0.size == bytes && $0.state == .verified
                  }) else { throw blocked("Its original isn't complete and verified on the server.") }
            return .init(role: resource.role, filename: resource.role.rawValue, size: bytes, sha256: hash.lowercased())
        }
        guard try BackupAPI.Manifest(kind: after.kind, resources: resources).assetID() == asset.lowercased() else {
            throw blocked("The complete original no longer matches this backup's identity.")
        }
        return .init(status: after, resources: resources, requestedAt: started)
    }

    static func compact(_ id: String, asset: String, originalBytes: Int, photos: any PhotoSource,
                        client: ServerClient) async throws -> PhotoGeneration {
        let generation = try photos.sourceGeneration(id)
        let resources = try await photos.resourceFingerprints(id)
        guard try photos.sourceGeneration(id) == generation, !resources.isEmpty,
              Set(resources.map(\.role)).count == resources.count, resources.allSatisfy({ $0.size > 0 }),
              generation.resources.count == resources.count else {
            throw blocked("Its compact copy changed or is incomplete. It was kept.")
        }
        let hashes = Array(Set(resources.map(\.sha256))).sorted()
        var matches: [ServerAPI.CopyLookupResponse.Match] = []
        for start in stride(from: 0, to: hashes.count, by: ServerAPI.CopyLookupRequest.maximumCount) {
            matches += try await client.lookupCopies(Array(hashes[start..<min(start + ServerAPI.CopyLookupRequest.maximumCount, hashes.count)]))
        }
        guard resources.allSatisfy({ resource in
            matches.contains {
                !$0.isOriginal && $0.originalsVerified && $0.sha256.lowercased() == resource.sha256.lowercased()
                    && $0.assetID.lowercased() == asset.lowercased() && $0.role == resource.role
                    && $0.originalBytes == originalBytes
            }
        }) else {
            throw blocked("Its compact copy can't be confirmed. Run Find Compact Copies after updating the server.")
        }
        return generation
    }

    static func blocked(_ message: String) -> BackupStageFailure { .blocked(message) }
}

struct LegacyOriginalRemover: RemovingOriginals {
    let client: ServerClient
    let ledger: CompactLedger
    let photos: any PhotoSource
    let scope: String
    let mode: ServerAPI.StorageMode
    var origin: BackupAPI.Origin?
    var current: @MainActor @Sendable () -> Bool
    var now: @Sendable () -> Date = { Date() }
    var maximumProofAge: TimeInterval = 30
    var batchLimit = 10

    func candidates(only: Set<String>?) async throws -> [(original: String, entry: CompactLedger.Entry)] {
        guard mode == .files, await current(), photos.authorization().allowsReading else { return [] }
        let projection = try await ledger.projection()
        let confirmed = projection.legacyConfirmed(scope: scope, origin: origin, now: now())
        let photos = photos
        let (originals, compacts) = await PhotoKitReads.run {
            (photos.existing(Array(projection.entries.keys), includeHidden: false),
             photos.existing(projection.entries.values.map(\.compactIdentifier), includeHidden: true))
        }
        return projection.entries.compactMap { id, entry in
            guard entry.origin == nil, entry.serverAssetID != nil, confirmed[id] != nil,
                  originals.contains(id), compacts.contains(entry.compactIdentifier),
                  !projection.kept.contains(id), only?.contains(id) ?? true else { return nil }
            return (original: id, entry: entry)
        }.sorted { $0.entry.savedAt < $1.entry.savedAt }
    }

    private struct Checked: Sendable {
        var original: String
        var entry: CompactLedger.Entry
        var approval: PhotosRemovalApproval
        var device: [ServerAPI.ResourceDescriptor]
        var proof: LegacyOriginalProof
        var name: String
    }

    private func check(_ original: String, entry: CompactLedger.Entry) async throws -> Checked {
        guard await current(), mode == .files, entry.origin == nil, let asset = entry.serverAssetID,
              try await ledger.entry(for: original) == entry, !(try await ledger.decisions()).contains(original) else {
            throw LegacyOriginalProof.blocked("This backup changed or belongs to another server. Nothing was removed.")
        }
        let generation = try photos.sourceGeneration(original)
        let device = try await photos.resourceFingerprints(original)
        guard try photos.sourceGeneration(original) == generation else { throw BackupStore.Failure.invalidImport }
        let compact = try await LegacyOriginalProof.compact(entry.compactIdentifier, asset: asset,
            originalBytes: entry.originalBytes, photos: photos, client: client)
        let proof = try await LegacyOriginalProof.fresh(asset: asset, client: client, now: now, current: current)
        let bytes = proof.resources.reduce(0) { $0 + $1.size }
        let gate = DeletionGate().evaluate(
            deviceResources: device.map { .init(role: $0.role.rawValue, sha256: $0.sha256, size: $0.size) },
            serverVerified: proof.resources.map { .init(role: $0.role.rawValue, sha256: $0.sha256, size: $0.size) },
            compactImported: true)
        guard case .allowed = gate, bytes == entry.originalBytes,
              try photos.sourceGeneration(original) == generation,
              try photos.sourceGeneration(entry.compactIdentifier) == compact, await current() else {
            throw LegacyOriginalProof.blocked("The original or its complete compact copy didn't match. Nothing was removed.")
        }
        return .init(original: original, entry: entry, approval: .init(original: generation, compact: compact),
                     device: device, proof: proof, name: photos.describe(original)?.name ?? "Item")
    }

    func removeEligible(limit: Int?, only: Set<String>?,
                        progress: @escaping @Sendable (String) -> Void) async throws -> OriginalRemover.Report {
        let selected = Array(try await candidates(only: only).prefix(limit ?? .max))
        var report = OriginalRemover.Report()
        for start in stride(from: 0, to: selected.count, by: max(1, batchLimit)) {
            var checked: [Checked] = []
            for candidate in selected[start..<min(start + max(1, batchLimit), selected.count)] {
                try Task.checkCancellation()
                progress("Checking with your server")
                do { checked.append(try await check(candidate.original, entry: candidate.entry)) }
                catch { report.blocked.append(error.localizedDescription) }
            }
            for index in checked.indices where now().timeIntervalSince(checked[index].proof.requestedAt) > min(30, maximumProofAge) {
                do { checked[index] = try await check(checked[index].original, entry: checked[index].entry) }
                catch { report.blocked.append(error.localizedDescription); checked[index].proof.requestedAt = .distantPast }
            }
            var fresh: [Checked] = []
            for item in checked {
                let age = now().timeIntervalSince(item.proof.requestedAt)
                guard age >= 0, age <= min(30, maximumProofAge),
                      try await ledger.entry(for: item.original) == item.entry,
                      !(try await ledger.decisions()).contains(item.original) else {
                    report.blocked.append("\(item.name): the proof expired or the mapping changed. Try a smaller selection.")
                    continue
                }
                fresh.append(item)
            }
            guard !fresh.isEmpty else { continue }
            guard mode == .files, await current() else { throw CancellationError() }
            try Task.checkCancellation()
            // Check every age together immediately before submitting the generation-fenced iOS request.
            guard fresh.allSatisfy({
                let age = now().timeIntervalSince($0.proof.requestedAt)
                return age >= 0 && age <= min(30, maximumProofAge)
            }) else {
                report.blocked.append("The proof expired before confirmation. Try a smaller selection.")
                continue
            }
            progress("Waiting for your confirmation")
            do {
                let result = try await photos.removeApproved(fresh.map(\.approval))
                for item in fresh where result.submitted.contains(item.original) {
                    report.removed.append(item.name)
                    report.freedBytes += item.entry.originalBytes
                }
                report.blocked += fresh.filter { result.invalidated.contains($0.original) }
                    .map { "\($0.name): the original or compact copy changed before confirmation." }
            } catch let error as PHPhotosError where error.code == .userCancelled {
                report.cancelled = true
                return report
            }
        }
        return report
    }
}
