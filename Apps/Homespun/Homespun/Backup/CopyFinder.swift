// SPDX-License-Identifier: Apache-2.0
import Foundation
import HomespunCore
import UIKit

/// Finds compact copies Homespun didn't make on this iPhone: made with other tools from
/// originals the server already holds (`homespun-server import`), or Homespun's own after a
/// reinstall or on a new phone. It hashes the items Homespun doesn't know yet and asks the
/// server which hashes belong to items it holds. Found copies count as backed up and join the
/// Homespun album, so they're never backed up as originals; an original found together with its
/// copy becomes ready to free up. Only hashes leave the phone, and only to the paired server.
@MainActor @Observable
final class CopyFinder {
    struct Summary: Codable, Equatable, Sendable {
        var checked = 0
        /// Compact copies whose originals are on the server.
        var found = 0
        /// Of those, copies whose original is also still on this iPhone: ready to free up.
        var readyToFree = 0
        /// Items that are the originals themselves (on the server too), with no copy here.
        var alreadyAtHome = 0
        /// Only some files matched, or the server hasn't checked all of the item's originals.
        var needsAttention = 0
        /// Not on the server.
        var notFound = 0
        /// Only in iCloud, or unreadable.
        var skipped = 0
        var finishedAt: Date?
        var stopped = false
    }

    typealias Lookup = @Sendable ([String]) async throws -> [ServerAPI.CopyLookupResponse.Match]

    /// An original on this iPhone that the server holds too, waiting for its compact copy to turn up.
    struct AtHome: Codable, Equatable, Sendable {
        var assetID: String
        var bytes: Int
    }

    private struct Saved: Codable {
        var summary: Summary?
        /// Items checked with a final answer, skipped next time unless checking everything again.
        var settled: Set<String> = []
        var atHome: [String: AtHome]? = nil
        var bindingID: UUID?
    }

    private(set) var isRunning = false
    private(set) var checked = 0
    private(set) var total = 0
    /// Copies found so far in this run.
    private(set) var found = 0
    private(set) var summary: Summary?
    private(set) var error: String?
    private var settled: Set<String>
    private var atHome: [String: AtHome]
    private var bindingID: UUID?
    private var task: Task<Void, Never>?
    private var retired = false
    private var suspended = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let url: URL
    private let photos: any PhotoSource

    static var defaultURL: URL {
        URL.applicationSupportDirectory.appendingPathComponent("Homespun/copy-finder.json")
    }

    init(url: URL = CopyFinder.defaultURL, photos: any PhotoSource = PhotoKitSource()) {
        self.url = url
        self.photos = photos
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let saved = (try? decoder.decode(Saved.self, from: Data(contentsOf: url))) ?? Saved()
        summary = saved.summary
        settled = saved.settled
        atHome = saved.atHome ?? [:]
        bindingID = saved.bindingID
    }

    func start(lookup: @escaping Lookup, ledger: CompactLedger, context: BackupBindingContext? = nil,
               current: @escaping @MainActor @Sendable () -> Bool = { true }, again: Bool = false,
               finished: @escaping @MainActor () async -> Void = {}) {
        guard !retired, !suspended, !isRunning, task == nil else { return }
        task = Task {
            await run(lookup: lookup, ledger: ledger, context: context, current: current, again: again)
            await finished()
            task = nil
        }
    }

    func stop() { task?.cancel() }

    func unavailable() {
        guard !isRunning else { return }
        error = "Update Homespun Server and reconnect the original archive, then try again. No items have been changed."
    }

    func suspendAndWait() async {
        suspended = true
        stop()
        await task?.value
        if isRunning { await withCheckedContinuation { waiters.append($0) } }
    }

    func resume() { if !retired { suspended = false } }

    func retire() {
        retired = true
        stop()
    }

    func stopAndWait() async {
        retire()
        await task?.value
        if isRunning { await withCheckedContinuation { waiters.append($0) } }
    }

    /// Checks every item not known yet (`again`: also those checked before), `batch` at a time.
    func run(lookup: Lookup, ledger: CompactLedger, context: BackupBindingContext? = nil,
             current: @MainActor @Sendable () -> Bool = { true }, again: Bool = false, batch: Int = 100) async {
        guard !retired, !suspended, !isRunning, batch > 0 else { return }
        isRunning = true
        error = nil
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            isRunning = false
            UIApplication.shared.isIdleTimerDisabled = false
            let pending = waiters
            waiters = []
            pending.forEach { $0.resume() }
        }
        if again || bindingID != context?.binding.id {
            settled = []
            atHome = [:]
        }
        bindingID = context?.binding.id
        let snapshot: [String: CompactLedger.Entry]
        do { snapshot = try await ledger.snapshot() }
        catch { self.error = error.localizedDescription; return }
        let known = Self.known(snapshot, origin: context?.binding.origin, bindingID: context?.binding.id)
        let todo = photos.allIdentifiers().filter { !known.contains($0) && !settled.contains($0) }
        total = todo.count
        checked = 0
        found = 0
        var result = Summary()
        // A copy and its original may turn up in different batches, or different runs: start from
        // the copies recorded before and the originals still waiting for theirs.
        var copies: [String: String] = [:]
        for (key, entry) in snapshot where key == CompactLedger.elsewhere(entry.compactIdentifier)
            && entry.verifiedCompact && entry.origin == context?.binding.origin && entry.bindingID == context?.binding.id {
            if let asset = entry.serverAssetID { copies[asset] = entry.compactIdentifier }
        }
        let present = photos.existing(Array(atHome.keys), includeHidden: false)
        atHome = atHome.filter { present.contains($0.key) }
        var originals: [String: String] = [:]
        for (id, original) in atHome { originals[original.assetID] = id }
        var countedAtHome = Set<String>()
        do {
            // The canonical mapping commits before album membership. Repair a crash in between
            // without re-admitting the backup, importing a copy or exporting any original.
            let members = photos.albumMembers()
            let missingAlbum = Array(Set(snapshot.values.filter {
                $0.verifiedCompact && $0.origin == context?.binding.origin && $0.bindingID == context?.binding.id
                    && !members.contains($0.compactIdentifier)
            }.map(\.compactIdentifier)))
            for start in stride(from: 0, to: missingAlbum.count, by: batch) {
                try Task.checkCancellation()
                guard !retired, !suspended, current() else { throw CancellationError() }
                try await photos.addToAlbum(Array(missingAlbum[start..<min(start + batch, missingAlbum.count)]))
            }
            for start in stride(from: 0, to: todo.count, by: batch) {
                try Task.checkCancellation()
                guard !retired, !suspended, current() else { throw CancellationError() }
                let ids = Array(todo[start..<min(start + batch, todo.count)])
                let hashed = await photos.copyHashes(ids)
                let hashes = Array(Set(hashed.values.flatMap { $0.hashes.values }))
                var matches: [String: ServerAPI.CopyLookupResponse.Match] = [:]
                for first in stride(from: 0, to: hashes.count, by: ServerAPI.CopyLookupRequest.maximumCount) {
                    let chunk = Array(hashes[first..<min(first + ServerAPI.CopyLookupRequest.maximumCount, hashes.count)])
                    for match in try await lookup(chunk) { matches[match.sha256.lowercased()] = match }
                }

                var album: [String] = []
                for id in ids {
                    try Task.checkCancellation()
                    guard !retired, !suspended, current() else { throw CancellationError() }
                    guard let item = hashed[id] else {
                        result.skipped += 1
                        continue
                    }
                    // v1 is discovery only. A complete v2 association and fresh byte proof decide
                    // whether anything can become usable, even when v1's status is incomplete.
                    let hints = item.hashes.filter { CopyMatching.roles.contains($0.key) }.compactMap { role, hash in
                        matches[hash.lowercased()].map { (role, $0) }
                    }
                    let completeHint = !hints.isEmpty && hints.count == item.hashes.filter({ CopyMatching.roles.contains($0.key) }).count
                        && Set(hints.map(\.1.assetID)).count == 1
                        && hints.allSatisfy({ $0.0 == $0.1.role })
                    let outcome: CopyMatching.Outcome
                    if completeHint, hints.allSatisfy({ !$0.1.isOriginal }) {
                        outcome = .copy(assetID: hints[0].1.assetID, originalBytes: 0)
                    } else if completeHint, hints.allSatisfy({ $0.1.isOriginal }) {
                        outcome = .original(assetID: hints[0].1.assetID)
                    } else {
                        outcome = CopyMatching.classify(item.hashes, matches: matches)
                    }
                    switch outcome {
                    case .copy(let asset, _):
                        guard let context else { result.needsAttention += 1; continue }
                        do {
                            let original = try await adopt(id, asset: asset, original: originals[asset],
                                ledger: ledger, context: context, current: current)
                            result.found += 1
                            album.append(id)
                            if let original {
                                originals[asset] = nil
                                if countedAtHome.remove(original) != nil { result.alreadyAtHome -= 1 }
                                atHome[original] = nil
                                result.readyToFree += 1
                            } else {
                                copies[asset] = id
                                if let original = originals[asset] {
                                    if countedAtHome.remove(original) != nil { result.alreadyAtHome -= 1 }
                                    result.needsAttention += 1
                                    settled.remove(original)
                                }
                            }
                            settled.insert(id)
                        } catch is CancellationError { throw CancellationError() }
                        catch {
                            guard current(), !retired, !suspended else { throw CancellationError() }
                            result.needsAttention += 1
                            self.error = error.localizedDescription
                        }
                    case .original(let asset):
                        var paired = false
                        let hasCopy = copies[asset] != nil && context != nil
                        if let copy = copies[asset], let context {
                            do {
                                paired = try await adopt(copy, asset: asset, original: id, ledger: ledger,
                                    context: context, current: current) == id
                            } catch is CancellationError { throw CancellationError() }
                            catch {
                                guard current(), !retired, !suspended else { throw CancellationError() }
                                self.error = error.localizedDescription
                            }
                        }
                        if paired {
                            copies[asset] = nil
                            atHome[id] = nil
                            result.readyToFree += 1
                        } else {
                            if hasCopy { result.needsAttention += 1 }
                            else {
                                result.alreadyAtHome += 1
                                countedAtHome.insert(id)
                            }
                            originals[asset] = id
                            atHome[id] = AtHome(assetID: asset, bytes: item.bytes)
                        }
                        if paired || !hasCopy { settled.insert(id) }
                    case .partial:
                        result.needsAttention += 1
                    case .unknown:
                        result.notFound += 1
                        settled.insert(id)
                    }
                }
                guard !retired, !suspended, current() else { throw CancellationError() }
                try await photos.addToAlbum(album)
                checked += ids.count
                found = result.found
                result.checked = checked
                save(result)
            }
        } catch is CancellationError {
            result.stopped = true
        } catch {
            self.error = error.localizedDescription
            result.stopped = true
        }
        result.finishedAt = Date()
        summary = result
        save(result)
    }

    /// Items the ledger already knows: originals backed up through Homespun and their copies.
    static func known(_ ledger: [String: CompactLedger.Entry], origin: BackupAPI.Origin? = nil,
                      bindingID: UUID? = nil) -> Set<String> {
        var known = Set<String>()
        guard origin != nil, bindingID != nil else { return known }
        for (original, entry) in ledger where entry.verifiedCompact && entry.origin == origin && entry.bindingID == bindingID {
            known.insert(original)
            known.insert(entry.compactIdentifier)
        }
        return known
    }

    struct Hashed: Sendable {
        var hashes: [ServerAPI.ResourceRole: String]
        var bytes: Int
        var resources: [ServerAPI.ResourceDescriptor] = []
        var kind: ServerAPI.AssetKind = .photo
        var generation: PhotoGeneration?
    }

    private func adopt(_ id: String, asset: String, original: String?, ledger: CompactLedger,
                       context: BackupBindingContext,
                       current: @MainActor @Sendable () -> Bool) async throws -> String? {
        guard current(), !retired, !suspended, let item = await photos.copyHashes([id])[id],
              !item.resources.isEmpty, let generation = item.generation else { throw BackupStore.Failure.invalidImport }
        // Do not transmit the device's names or SHA-1 fingerprints.
        let compact = BackupAPI.Manifest(kind: item.kind, resources: item.resources.sorted { $0.role.rawValue < $1.role.rawValue }.map {
            .init(role: $0.role, filename: $0.role.rawValue, size: $0.size, sha256: $0.sha256)
        })
        let candidate = try await context.remote.resolveCopy(.init(origin: context.binding.origin, assetID: asset, compact: compact))
        guard candidate.origin == context.binding.origin, try candidate.manifest.assetID() == asset,
              candidate.manifest.kind == item.kind else { throw BackupStore.Failure.invalidReceipt }
        var paired: (id: String, generation: PhotoGeneration?)?
        if let original, original != id, let local = await photos.copyHashes([original])[original], local.generation != nil,
           local.kind == candidate.manifest.kind, BackupValidation.matches(candidate.manifest.resources, local.resources) {
            paired = (original, local.generation)
        }
        try Task.checkCancellation()
        guard current(), !retired, !suspended else { throw CancellationError() }
        let operation = try await ledger.store.planCopyAdoption(compactID: id, originalID: paired?.id,
            candidate: candidate, compact: compact, bindingID: context.binding.id,
            namespace: ledger.namespace, profile: context.information.capabilities.recipe.profile)
        guard let request = operation.request else { throw BackupStore.Failure.invalidReceipt }
        let receipt = try await context.remote.adoptCopy(.init(request: request, compact: compact))
        guard receipt.operationID == operation.id, receipt.version.origin == context.binding.origin,
              receipt.version.descriptorGeneration > 0,
              receipt.version.recipeID == (try context.information.capabilities.recipe.identifier()) else {
            throw BackupStore.Failure.invalidReceipt
        }
        let proof = try await context.remote.verify(receipt.version)
        guard proof.version == receipt.version,
              BackupValidation.retained(proof, manifest: candidate.manifest, context: context, policy: .permanent),
              let fresh = await photos.copyHashes([id])[id],
              fresh.generation == generation, BackupValidation.matches(compact.resources, fresh.resources) else {
            throw BackupStore.Failure.invalidImport
        }
        if let paired, let generation = paired.generation, try photos.sourceGeneration(paired.id) != generation {
            throw BackupStore.Failure.invalidImport
        }
        try Task.checkCancellation()
        guard current(), !retired, !suspended else { throw CancellationError() }
        try await ledger.store.finishCopyAdoption(operation.id, epoch: operation.epoch,
            receipt: receipt, proof: proof, actual: fresh.resources)
        return paired?.id
    }

    private func save(_ summary: Summary) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(Saved(summary: summary, settled: settled, atHome: atHome, bindingID: bindingID)) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
