// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import Homespun

/// The ledger survives a relaunch: what's saved is read back, dates included.
@Test func ledgerIsReadBackAfterARelaunch() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("ledger.json")
    try await CompactLedger(url: url).record(original: "orig", compact: "copy", originalBytes: 100, compactBytes: 20,
                                             serverAssetID: "asset-1")
    let reopened = CompactLedger(url: url)
    #expect(try await reopened.entry(for: "orig")?.serverAssetID == "asset-1")
    #expect(try await reopened.serverBacked().isEmpty, "A legacy server ID is not a versioned removal proof")
}

/// A corrupt migration source is preserved and blocks reads rather than becoming an empty ledger.
@Test func unreadableLedgerIsSetAside() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent("ledger.json")
    try Data("not json".utf8).write(to: url)
    let ledger = CompactLedger(url: url)
    await #expect(throws: BackupStore.Failure.legacyUnreadable) { try await ledger.snapshot() }
    #expect(try String(contentsOf: url, encoding: .utf8) == "not json")
}

/// The facade writes only the canonical database, not another JSON snapshot or journal.
@Test func ledgerJournalReplaysAndCompacts() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("ledger.json")
    let journal = folder.appendingPathComponent("ledger.journal")
    let ledger = CompactLedger(url: url)
    for index in 0..<10 {
        try await ledger.record(original: "o\(index)", compact: "c\(index)", originalBytes: 1, compactBytes: 1, serverAssetID: "s")
    }
    try await ledger.record(["o10": .init(compactIdentifier: "c10", originalBytes: 1, compactBytes: 1, savedAt: Date())],
                            removing: ["o3"])
    #expect(!FileManager.default.fileExists(atPath: url.path), "the snapshot was rewritten for a single item")
    let reopened = CompactLedger(url: url)
    let entries = try await reopened.snapshot()
    #expect(entries.count == 10 && entries["o3"] == nil && entries["o10"]?.compactIdentifier == "c10" && entries["o99"] == nil)
    try await reopened.record(original: "o11", compact: "c11", originalBytes: 1, compactBytes: 1)
    #expect(try await CompactLedger(url: url).entry(for: "o11")?.compactIdentifier == "c11")
    let isCopy = try await reopened.isCompactCopy("c7"), wasCopy = try await reopened.isCompactCopy("c3")
    #expect(isCopy && !wasCopy)
    try await reopened.compact()
    #expect(!FileManager.default.fileExists(atPath: journal.path))
    #expect(try await CompactLedger(url: url).snapshot().count == 11)
    #expect(!FileManager.default.fileExists(atPath: url.path))
}

/// Keep Original and Restore Original: an original kept full size is backed up and never compacted
/// automatically; a restore whose copies iOS didn't delete leaves an ordinary pair.
@Test func keptAndRestoredOriginalsChangeTheLedger() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-\(UUID().uuidString)/ledger.json")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let ledger = CompactLedger(url: url)
    try await ledger.record(original: "a", compact: "copy-a", originalBytes: 100, compactBytes: 20, serverAssetID: "sa")
    try await ledger.record(original: "b", compact: "copy-b", originalBytes: 200, compactBytes: 30, serverAssetID: "sb")
    try await ledger.record(original: "c", compact: "copy-c", originalBytes: 300, compactBytes: 40, serverAssetID: "sc")

    try await ledger.keepOriginals([(original: "a", serverAssetID: "sa", originalBytes: 100)])
    let entryA = try await ledger.entry(for: "a"), backedA = try await ledger.backedUpSnapshot()["a"]
    #expect(entryA == nil && backedA?.kept == true)

    let b = try #require(try await ledger.entry(for: "b")), c = try #require(try await ledger.entry(for: "c"))
    try await ledger.restored([(key: "b", restored: "b2", entry: b)], copiesDeleted: true)
    let afterB = try await ledger.entry(for: "b"), keptB = try await ledger.backedUpSnapshot()["b2"]
    #expect(afterB == nil && keptB?.kept == true && keptB?.serverAssetID == "sb")
    try await ledger.restored([(key: "c", restored: "c2", entry: c)], copiesDeleted: false)
    let afterC = try await ledger.entry(for: "c"), pairC = try await ledger.entry(for: "c2"), backedC = try await ledger.backedUpSnapshot()["c2"]
    #expect(afterC == nil && pairC?.compactIdentifier == "copy-c" && backedC == nil)

    // Read back after a relaunch, older backed-up records (without `kept`) too.
    let reopened = CompactLedger(url: url)
    let keptA = try await reopened.backedUpSnapshot()["a"], pair = try await reopened.entry(for: "c2")
    #expect(keptA?.kept == true && pair != nil)
    let old = try JSONDecoder().decode(CompactLedger.BackedUp.self, from: Data(#"{"serverAssetID":"x","originalBytes":1,"backedUpAt":0}"#.utf8))
    #expect(old.kept == nil)
}
