// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import Homespun

private let day: TimeInterval = 86_400
private let now = Date(timeIntervalSince1970: 1_800_000_000)

/// The slider's five stops, and when an item's compact copy is due: a month after the later of
/// when it was taken and when this iPhone first had it; favorites never, while they're kept.
@Test func compactCopiesAreDueOnceAnItemIsOldEnough() {
    var schedule = CompactSchedule()
    #expect(schedule.days == 30 && schedule.stop == 2 && schedule.label == "After 1 month")
    #expect(CompactSchedule.stops.map { CompactSchedule.label(days: $0) }
            == ["Right away", "After 1 week", "After 1 month", "After 2 months", "After 3 months"])
    schedule.stop = 4
    #expect(schedule.days == 90)
    schedule.stop = 9
    #expect(schedule.days == 90)
    schedule.days = 45 // between stops: the nearest one shows
    #expect(schedule.stop == 2 || schedule.stop == 3)

    let month = CompactSchedule()
    let taken = now.addingTimeInterval(-40 * day)
    #expect(month.due(created: taken, firstSeen: nil, favorite: false) == taken.addingTimeInterval(30 * day))
    // An old photo saved yesterday counts from yesterday.
    let saved = now.addingTimeInterval(-1 * day)
    #expect(month.due(created: taken, firstSeen: saved, favorite: false) == saved.addingTimeInterval(30 * day))
    #expect(month.due(created: taken, firstSeen: nil, favorite: true) == nil)
    var favorites = month
    favorites.keepFavorites = false
    #expect(favorites.due(created: taken, firstSeen: nil, favorite: true) != nil)
    // No dates at all: due now. Right away: due as soon as it's taken.
    #expect(month.due(created: nil, firstSeen: nil, favorite: false)! <= now)
    var rightAway = month
    rightAway.days = 0
    #expect(rightAway.due(created: saved, firstSeen: nil, favorite: false) == saved)
}

/// A run compacts what's due (backed up already or not) and backs up recent items without a
/// compact copy; items already backed up and not due are left alone; Immich mode only compacts.
@Test func automaticRunsCompactWhatsDueAndBackUpWhatsRecent() {
    let old = AutomaticCandidate(id: "old", created: now.addingTimeInterval(-60 * day))
    let recent = AutomaticCandidate(id: "recent", created: now.addingTimeInterval(-3 * day))
    let waited = AutomaticCandidate(id: "waited", created: now.addingTimeInterval(-31 * day))
    let waiting = AutomaticCandidate(id: "waiting", created: now.addingTimeInterval(-10 * day))
    let favorite = AutomaticCandidate(id: "favorite", created: now.addingTimeInterval(-100 * day), favorite: true)
    let airdropped = AutomaticCandidate(id: "airdropped", created: now.addingTimeInterval(-400 * day))
    let all = [recent, old, waited, waiting, favorite, airdropped]
    let plan = AutomaticPlan.make(all, backedUp: ["waited", "waiting"], firstSeen: ["airdropped": now.addingTimeInterval(-2 * day)],
                                  schedule: .standard, now: now, backsUp: true, limit: 200)
    #expect(plan.compact == ["old", "waited"])
    #expect(plan.backUp == ["airdropped", "favorite", "recent"])

    let immich = AutomaticPlan.make(all, backedUp: [], firstSeen: [:], schedule: .standard, now: now, backsUp: false, limit: 200)
    #expect(immich.compact == ["airdropped", "old", "waited"] && immich.backUp.isEmpty)

    // The batch fills with compact copies first.
    let small = AutomaticPlan.make(all, backedUp: [], firstSeen: [:], schedule: .standard, now: now, backsUp: true, limit: 2)
    #expect(small.compact == ["airdropped", "old"] && small.backUp.isEmpty)
}

/// Items backed up without a compact copy are kept apart from the ledger (whose file is unchanged),
/// survive a relaunch, and leave once their compact copy is recorded or they're forgotten.
@Test func backedUpItemsAreRememberedUntilTheirCompactCopy() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("ledger.json")
    let ledger = CompactLedger(url: url)
    try await ledger.recordBackedUp(original: "a", serverAssetID: "sha-a", originalBytes: 100)
    try await ledger.recordBackedUp(original: "b", serverAssetID: "sha-b", originalBytes: 200)
    let reopened = CompactLedger(url: url)
    #expect(Set(await reopened.backedUpSnapshot().keys) == ["a", "b"])
    #expect(await reopened.snapshot().isEmpty)
    try await reopened.record(original: "a", compact: "copy-a", originalBytes: 100, compactBytes: 20, serverAssetID: "sha-a")
    try await reopened.forgetBackedUp(["b"])
    #expect(await CompactLedger(url: url).backedUpSnapshot().isEmpty)
    // Something with a compact copy isn't recorded as waiting for one.
    try await reopened.recordBackedUp(original: "a", serverAssetID: "sha-a", originalBytes: 100)
    #expect(await reopened.backedUpSnapshot().isEmpty)
}

/// The grid shows "Backed up" for them: not in Not Backed Up, not free-able, but Back Up can make
/// the compact copy now.
@Test func backedUpItemsShowTheirOwnBadge() {
    let due = now.addingTimeInterval(10 * day)
    let state = LibraryState(library: ["recent", "plain", "favorite"], ledger: [:], album: [], job: [:],
                             backedUp: ["recent": due, "favorite": nil])
    let cells = Dictionary(uniqueKeysWithValues: state.cells.map { ($0.id, $0) })
    #expect(cells["recent"]?.badge == .copyLater && cells["recent"]?.compactAfter == due)
    #expect(cells["favorite"]?.badge == .copyLater && cells["favorite"]?.compactAfter == nil)
    #expect(cells["plain"]?.badge == Badge.none)
    #expect(state.cells(.copyLater).map(\.id) == ["recent", "favorite"])
    #expect(state.cells(.notBackedUp).map(\.id) == ["plain"])
    #expect(cells["recent"].map { $0.canCompact && !$0.canFree && !$0.isNotBackedUp } == true)
    #expect(Badge.copyLater.spoken(server: "polonium", compactAfter: nil)
            == "Backed up. Original on polonium; favorites keep their original.")
}
