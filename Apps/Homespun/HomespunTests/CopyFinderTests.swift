// SPDX-License-Identifier: Apache-2.0
import CryptoKit
import Foundation
import HomespunCore
import HomespunTestSupport
import Photos
import Testing
@testable import Homespun

/// Finds compact copies made elsewhere on a simulator library of synthetic media, with the
/// server's answers stood in for. Grant access first: `xcrun simctl privacy <device> grant photos photos.homespun.app.dev`.
@MainActor @Suite(.serialized) struct CopyFinderTests {
    private final class Box: @unchecked Sendable { var value: String? }

    /// Not on the main actor: PhotoKit runs the change block on its own queue.
    private nonisolated static func create(_ resources: [(PHAssetResourceType, URL)]) async throws -> String {
        let box = Box()
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            for (type, url) in resources { request.addResource(with: type, fileURL: url, options: nil) }
            request.creationDate = Date(timeIntervalSince1970: 1_636_061_270)
            box.value = request.placeholderForCreatedAsset?.localIdentifier
        }
        return try #require(box.value)
    }

    private func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    @Test(.enabled(if: PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized,
                   "Photo library access was not granted to the test host"))
    func findsCopiesMadeElsewhereAndPairsOriginals() async throws {
        let directory = try Synthetic.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        func file(_ name: String) -> URL { directory.appendingPathComponent(name) }
        let pairing = UUID().uuidString, other = UUID().uuidString
        try Synthetic.photo(at: file("copy.jpg"), .init(width: 1024, height: 768, quality: 0.6))
        try Synthetic.photo(at: file("live.jpg"), .init(width: 1024, height: 768, quality: 0.61, contentIdentifier: pairing))
        try await Synthetic.video(at: file("live.mov"), .init(width: 640, height: 480, frames: 30, bitrate: 1_000_000,
                                                              audioChannels: 1, liveIdentifier: pairing))
        try Synthetic.photo(at: file("original.jpg"), .init(width: 1600, height: 1200, quality: 0.9))
        try Synthetic.photo(at: file("its-copy.jpg"), .init(width: 1024, height: 768, quality: 0.62))
        try Synthetic.photo(at: file("partial.jpg"), .init(width: 1024, height: 768, quality: 0.63, contentIdentifier: other))
        try await Synthetic.video(at: file("partial.mov"), .init(width: 640, height: 480, frames: 30, bitrate: 900_000,
                                                                 audioChannels: 1, liveIdentifier: other))
        // Pairs found across two runs: a copy now and its original later, and the other way round.
        for (index, name) in ["e-copy.jpg", "e-original.jpg", "f-copy.jpg", "f-original.jpg"].enumerated() {
            try Synthetic.photo(at: file(name), .init(width: 800, height: 600, quality: 0.7 + Double(index) / 100))
        }
        let eCopy = try await Self.create([(.photo, file("e-copy.jpg"))])
        let fOriginal = try await Self.create([(.photo, file("f-original.jpg"))])

        let copy = try await Self.create([(.photo, file("copy.jpg"))])
        let live = try await Self.create([(.photo, file("live.jpg")), (.pairedVideo, file("live.mov"))])
        let itsCopy = try await Self.create([(.photo, file("its-copy.jpg"))])
        let original = try await Self.create([(.photo, file("original.jpg"))])
        let partial = try await Self.create([(.photo, file("partial.jpg")), (.pairedVideo, file("partial.mov"))])

        typealias Match = ServerAPI.CopyLookupResponse.Match
        func match(_ name: String, _ asset: String, _ role: ServerAPI.ResourceRole, original: Bool = false) throws -> Match {
            Match(sha256: try sha256(file(name)), assetID: String(repeating: asset, count: 64), role: role,
                  isOriginal: original, originalsVerified: true, originalBytes: 5_000_000)
        }
        let known = [try match("copy.jpg", "a", .photo), try match("live.jpg", "b", .photo),
                     try match("live.mov", "b", .pairedVideo), try match("its-copy.jpg", "c", .photo),
                     try match("original.jpg", "c", .photo, original: true), try match("partial.jpg", "d", .photo),
                     try match("e-copy.jpg", "e", .photo), try match("e-original.jpg", "e", .photo, original: true),
                     try match("f-copy.jpg", "f", .photo), try match("f-original.jpg", "f", .photo, original: true)]
        let asked = Box()
        let lookup: CopyFinder.Lookup = { hashes in
            #expect(hashes.count <= ServerAPI.CopyLookupRequest.maximumCount)
            asked.value = "yes"
            return known.filter { hashes.contains($0.sha256) }
        }

        let ledger = CompactLedger(url: directory.appendingPathComponent("ledger.json"))
        let finder = CopyFinder(url: directory.appendingPathComponent("finder.json"))
        await finder.run(lookup: lookup, ledger: ledger, batch: 3)
        let summary = try #require(finder.summary)
        #expect(asked.value != nil && !summary.stopped && finder.error == nil)
        #expect(summary.found >= 3 && summary.readyToFree >= 1 && summary.needsAttention >= 1)

        let entries = try await ledger.snapshot()
        #expect(entries[CompactLedger.elsewhere(copy)]?.serverAssetID == String(repeating: "a", count: 64))
        #expect(entries[CompactLedger.elsewhere(live)]?.serverAssetID == String(repeating: "b", count: 64))
        // The original still here is paired with its copy: ready to free up, not a second record.
        #expect(entries[original]?.compactIdentifier == itsCopy && entries[original]?.serverAssetID == String(repeating: "c", count: 64))
        #expect(entries[CompactLedger.elsewhere(itsCopy)] == nil)
        #expect(!entries.keys.contains { $0.contains(partial) } && !entries.values.contains { $0.compactIdentifier == partial })
        let album = PhotoLibrary.albumMembers()
        #expect(album.isSuperset(of: [copy, live, itsCopy]) && !album.contains(partial) && !album.contains(original))

        // Legacy lookup finds relationships, not versioned proof or a trustworthy historical origin.
        let state = LibraryState(library: [copy, live, itsCopy, original, partial], ledger: entries, album: album, job: [:])
        let badges = Dictionary(uniqueKeysWithValues: state.cells(.all).map { ($0.id, $0.badge) })
        #expect(badges[copy] == .recovery && badges[live] == .recovery && badges[itsCopy] == .recovery)
        #expect(badges[original] == nil && badges[partial] == Badge.none)

        #expect(entries[CompactLedger.elsewhere(eCopy)] != nil && entries[fOriginal] == nil)

        // Checking again skips what already has an answer (the partial one is checked again), and
        // pairs what arrived since with what was found before.
        let first = finder.total
        let eOriginal = try await Self.create([(.photo, file("e-original.jpg"))])
        let fCopy = try await Self.create([(.photo, file("f-copy.jpg"))])
        await finder.run(lookup: lookup, ledger: ledger)
        #expect(finder.total < first && (finder.summary?.needsAttention ?? 0) >= 1)
        #expect(finder.summary?.readyToFree == 2 && finder.summary?.alreadyAtHome == 0)
        let later = try await ledger.snapshot()
        #expect(later[eOriginal]?.compactIdentifier == eCopy && later[CompactLedger.elsewhere(eCopy)] == nil)
        #expect(later[fOriginal]?.compactIdentifier == fCopy && later[CompactLedger.elsewhere(fCopy)] == nil)
        let reloaded = CopyFinder(url: directory.appendingPathComponent("finder.json"))
        var saved = try #require(reloaded.summary), current = try #require(finder.summary)
        #expect(abs((saved.finishedAt ?? .distantPast).timeIntervalSince(current.finishedAt ?? .distantFuture)) < 1)
        saved.finishedAt = nil
        current.finishedAt = nil
        #expect(saved == current)
    }
}
