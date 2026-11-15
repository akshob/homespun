// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import Homespun

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
