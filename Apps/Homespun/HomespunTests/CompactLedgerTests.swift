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
    #expect(await reopened.entry(for: "orig")?.serverAssetID == "asset-1")
    #expect(await reopened.serverBacked().map(\.original) == ["orig"])
}

/// A ledger that can't be read is set aside, not replaced by the next record.
@Test func unreadableLedgerIsSetAside() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent("ledger.json")
    try Data("not json".utf8).write(to: url)
    let ledger = CompactLedger(url: url)
    #expect(await ledger.snapshot().isEmpty)
    let aside = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.contains("unreadable") }
    #expect(aside.count == 1)
    #expect(try String(contentsOf: folder.appendingPathComponent(aside[0]), encoding: .utf8) == "not json")
}

/// Recording appends to a journal (a library's worth of entries isn't rewritten per item); a
/// relaunch replays it, removals included, skipping a line torn by a crash, and every
/// `compactEvery` changes the snapshot is rewritten and the journal emptied.
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
    // A crash mid-write leaves half a line.
    let handle = try FileHandle(forWritingTo: journal)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(#"{"set":{"o99":{"compactIdent"#.utf8))
    try handle.close()
    let reopened = CompactLedger(url: url)
    let entries = await reopened.snapshot()
    #expect(entries.count == 10 && entries["o3"] == nil && entries["o10"]?.compactIdentifier == "c10" && entries["o99"] == nil)
    // The next change after the torn line is kept too (it starts a line of its own).
    try await reopened.record(original: "o11", compact: "c11", originalBytes: 1, compactBytes: 1)
    #expect(await CompactLedger(url: url).entry(for: "o11")?.compactIdentifier == "c11")
    let isCopy = await reopened.isCompactCopy("c7"), wasCopy = await reopened.isCompactCopy("c3")
    #expect(isCopy && !wasCopy)
    // Compaction: the snapshot holds everything and the journal starts again.
    try await reopened.compact()
    #expect(!FileManager.default.fileExists(atPath: journal.path))
    #expect(await CompactLedger(url: url).snapshot().count == 11)
    for index in 0..<CompactLedger.compactEvery {
        try await reopened.record(original: "n\(index)", compact: "m\(index)", originalBytes: 1, compactBytes: 1)
    }
    #expect(!FileManager.default.fileExists(atPath: journal.path), "the journal wasn't compacted")
    #expect(await CompactLedger(url: url).snapshot().count == 11 + CompactLedger.compactEvery)
}
