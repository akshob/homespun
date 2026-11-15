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
