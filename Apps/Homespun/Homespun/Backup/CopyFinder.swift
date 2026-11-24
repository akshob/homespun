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
    private var task: Task<Void, Never>?
    private var retired = false
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
    }

    func start(lookup: @escaping Lookup, ledger: CompactLedger, again: Bool = false,
               finished: @escaping @MainActor () async -> Void = {}) {
        guard !retired, !isRunning, task == nil else { return }
        task = Task {
            await run(lookup: lookup, ledger: ledger, again: again)
            await finished()
            task = nil
        }
    }

    func stop() { task?.cancel() }

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
    func run(lookup: Lookup, ledger: CompactLedger, again: Bool = false, batch: Int = 100) async {
        guard !retired, !isRunning else { return }
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
        if again {
            settled = []
            atHome = [:]
        }
        let snapshot: [String: CompactLedger.Entry]
        do { snapshot = try await ledger.snapshot() }
        catch { self.error = error.localizedDescription; return }
        let known = Self.known(snapshot)
        let todo = photos.allIdentifiers().filter { !known.contains($0) && !settled.contains($0) }
        total = todo.count
        checked = 0
        found = 0
        var result = Summary()
        // A copy and its original may turn up in different batches, or different runs: start from
        // the copies recorded before and the originals still waiting for theirs.
        var copies: [String: (id: String, bytes: Int, originalBytes: Int)] = [:]
        for (key, entry) in snapshot where key == CompactLedger.elsewhere(entry.compactIdentifier) {
            if let asset = entry.serverAssetID { copies[asset] = (entry.compactIdentifier, entry.compactBytes, entry.originalBytes) }
        }
        let present = photos.existing(Array(atHome.keys), includeHidden: false)
        atHome = atHome.filter { present.contains($0.key) }
        var originals: [String: (id: String, bytes: Int)] = [:]
        for (id, original) in atHome { originals[original.assetID] = (id, original.bytes) }
        var countedAtHome = Set<String>()
        do {
            for start in stride(from: 0, to: todo.count, by: batch) {
                try Task.checkCancellation()
                let ids = Array(todo[start..<min(start + batch, todo.count)])
                let hashed = await photos.copyHashes(ids)
                let hashes = Array(Set(hashed.values.flatMap { $0.hashes.values }))
                var matches: [String: ServerAPI.CopyLookupResponse.Match] = [:]
                for first in stride(from: 0, to: hashes.count, by: ServerAPI.CopyLookupRequest.maximumCount) {
                    let chunk = Array(hashes[first..<min(first + ServerAPI.CopyLookupRequest.maximumCount, hashes.count)])
                    for match in try await lookup(chunk) { matches[match.sha256.lowercased()] = match }
                }

                var entries: [String: CompactLedger.Entry] = [:], removing: [String] = [], album: [String] = []
                for id in ids {
                    guard let item = hashed[id] else {
                        result.skipped += 1
                        continue
                    }
                    switch CopyMatching.classify(item.hashes, matches: matches) {
                    case .copy(let asset, let originalBytes):
                        result.found += 1
                        album.append(id)
                        if let original = originals.removeValue(forKey: asset) {
                            if countedAtHome.remove(original.id) != nil { result.alreadyAtHome -= 1 }
                            atHome[original.id] = nil
                            result.readyToFree += 1
                            entries[original.id] = .init(compactIdentifier: id, originalBytes: original.bytes,
                                                         compactBytes: item.bytes, savedAt: Date(), serverAssetID: asset)
                        } else {
                            copies[asset] = (id, item.bytes, originalBytes)
                            entries[CompactLedger.elsewhere(id)] = .init(
                                compactIdentifier: id, originalBytes: originalBytes, compactBytes: item.bytes,
                                savedAt: Date(), serverAssetID: asset)
                        }
                        settled.insert(id)
                    case .original(let asset):
                        if let copy = copies.removeValue(forKey: asset) {
                            result.readyToFree += 1
                            entries[CompactLedger.elsewhere(copy.id)] = nil
                            removing.append(CompactLedger.elsewhere(copy.id))
                            entries[id] = .init(compactIdentifier: copy.id, originalBytes: item.bytes,
                                                compactBytes: copy.bytes, savedAt: Date(), serverAssetID: asset)
                        } else {
                            result.alreadyAtHome += 1
                            countedAtHome.insert(id)
                            originals[asset] = (id, item.bytes)
                            atHome[id] = AtHome(assetID: asset, bytes: item.bytes)
                        }
                        settled.insert(id)
                    case .partial:
                        result.needsAttention += 1
                    case .unknown:
                        result.notFound += 1
                        settled.insert(id)
                    }
                }
                try await ledger.record(entries, removing: removing)
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
    static func known(_ ledger: [String: CompactLedger.Entry]) -> Set<String> {
        var known = Set<String>()
        for (original, entry) in ledger where entry.serverAssetID != nil {
            known.insert(original)
            known.insert(entry.compactIdentifier)
        }
        return known
    }

    struct Hashed: Sendable {
        var hashes: [ServerAPI.ResourceRole: String]
        var bytes: Int
    }

    private func save(_ summary: Summary) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(Saved(summary: summary, settled: settled, atHome: atHome)) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
