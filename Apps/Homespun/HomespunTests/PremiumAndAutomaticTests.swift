// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import Homespun

@Test func premiumRowsAndPurchaseCopyExcludeUnavailableFeatures() {
    #expect(PremiumFeature.available == [.automatic, .widgets])
    #expect(PremiumFeature.backupFeatures == [.automatic])
    #expect(!PremiumFeature.cloudCopies.isAvailable)
    #expect(PremiumFeature.purchaseDescription == "Automatic Mode and widgets")
}

@Test func automaticModePicksNewItemsNotYetBackedUp() {
    let day: TimeInterval = 86_400
    let enabled = Date(timeIntervalSince1970: 1_800_000_000)
    let entry = CompactLedger.Entry(compactIdentifier: "copy-a", originalBytes: 10, compactBytes: 1, savedAt: enabled,
                                    serverAssetID: "sha")
    let assets: [(id: String, created: Date?)] = [
        ("old", enabled - 10 * day),            // before automatic mode was turned on
        ("synced-late", enabled - 30 * day),     // old date, but added to the library since
        ("a", enabled + day), ("copy-a", enabled + day), ("album", enabled + day),
        ("kept", enabled + 2 * day), ("failing", enabled + 3 * day), ("new", enabled + 4 * day),
        ("newer", enabled + 5 * day), ("undated", nil),
        ("phone-copy-only", enabled + 6 * day),  // compacted by the old on-phone mode, never backed up
    ]
    var onPhone = entry
    onPhone.compactIdentifier = "phone-copy"
    onPhone.serverAssetID = nil
    let picked = AutomaticMode.pick(assets, since: enabled, added: ["synced-late"],
                                    ledger: ["a": entry, "phone-copy-only": onPhone], album: ["album"],
                                    attempts: ["failing": AutomaticMode.maximumAttempts, "new": 1], settled: ["kept"])
    // Oldest first: the late arrival has the oldest date.
    #expect(picked == ["synced-late", "new", "newer", "phone-copy-only"])
    #expect(AutomaticMode.pick(assets, since: enabled, added: [], ledger: [:], album: [], attempts: [:], settled: [],
                               limit: 2) == ["a", "copy-a"])
    #expect(AutomaticMode.describe(.init(compacted: 3, kept: 1)) == "3 backed up and compacted, 1 kept as is.")
    #expect(AutomaticMode.describe(.init(skipped: "The server wasn't reachable.")) == "Skipped: The server wasn't reachable.")
}

/// The Server tab's Automatic Mode value: off, on, or when it last ran.
@Test func automaticModeStatusSaysOffOnAndWhenItRan() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
    let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 10)))
    func at(day: Int, hour: Int, year: Int = 2026) throws -> Date {
        try #require(calendar.date(from: DateComponents(year: year, month: 11, day: day, hour: hour)))
    }
    #expect(AutomaticMode.status(on: false, lastRun: now, now: now, calendar: calendar) == "Off")
    #expect(AutomaticMode.status(on: true, lastRun: nil, now: now, calendar: calendar) == "On")
    #expect(AutomaticMode.status(on: true, lastRun: try at(day: 17, hour: 9), now: now, calendar: calendar) == "On · ran today")
    #expect(AutomaticMode.status(on: true, lastRun: try at(day: 17, hour: 2), now: now, calendar: calendar)
        == "On · ran last night")
    #expect(AutomaticMode.status(on: true, lastRun: try at(day: 16, hour: 23), now: now, calendar: calendar)
        == "On · ran last night")
    #expect(AutomaticMode.status(on: true, lastRun: try at(day: 16, hour: 14), now: now, calendar: calendar)
        == "On · ran yesterday")
    let older = AutomaticMode.status(on: true, lastRun: try at(day: 11, hour: 14), now: now, calendar: calendar)
    #expect(older.hasPrefix("On · ran ") && older.contains("11") && !older.contains("2026"), "\(older)")
    let lastYear = AutomaticMode.status(on: true, lastRun: try at(day: 11, hour: 14, year: 2025), now: now, calendar: calendar)
    #expect(lastYear.contains("2025"), "\(lastYear)")
}

/// Stands in for the App Store's answer to "does this account own Premium?".
private final class Ownership: @unchecked Sendable {
    let lock = NSLock()
    var owned = false
}

@MainActor @Test func premiumFollowsWhatTheAccountOwns() async {
    #expect(Premium(ownBuild: true, owned: { false }, listens: false).isUnlocked)
    let store = Ownership()
    let premium = Premium(ownBuild: false, owned: { store.lock.withLock { store.owned } },
                          testFlightWithoutProduct: { false }, listens: false)
    await premium.refresh()
    #expect(!premium.isUnlocked)
    store.lock.withLock { store.owned = true }    // bought, restored, or shared by the family
    await premium.refresh()
    #expect(premium.isUnlocked && premium.purchased)
    store.lock.withLock { store.owned = false }   // refunded, or Family Sharing ended
    await premium.refresh()
    #expect(!premium.isUnlocked)
}

@MainActor @Test func testFlightUnlocksPremiumUntilTheProductExists() async {
    let beta = Premium(ownBuild: false, owned: { false }, testFlightWithoutProduct: { true }, listens: false)
    await beta.refresh()
    #expect(beta.isUnlocked && beta.beta && !beta.purchased)
    // Debug builds are already unlocked and never ask the App Store.
    let own = Premium(ownBuild: true, owned: { false }, testFlightWithoutProduct: { Issue.record("asked"); return true },
                      listens: false)
    await own.refresh()
    #expect(own.isUnlocked && !own.beta)
}
