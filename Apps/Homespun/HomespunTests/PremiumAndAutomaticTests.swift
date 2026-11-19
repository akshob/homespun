// SPDX-License-Identifier: Apache-2.0
import Foundation
import BackgroundTasks
import Testing
import UserNotifications
@testable import Homespun

@Test func premiumRowsAndPurchaseCopyExcludeUnavailableFeatures() {
    #expect(PremiumFeature.available == [.automatic, .cloudCopies, .widgets])
    #expect(PremiumFeature.backupFeatures == [.automatic, .cloudCopies])
    #expect(PremiumFeature.cloudCopies.isAvailable)
    #expect(PremiumFeature.purchaseDescription == "Automatic Mode, Cloud Copies and widgets")
}

@Test func releaseFeaturesDefaultOffAndDebugOverrideIsExplicit() {
    #expect(!ReleaseFeatures.resolve(shipping: false, arguments: [], environment: [:]))
    #expect(ReleaseFeatures.resolve(shipping: true, arguments: [], environment: [:]))
    #if DEBUG
    #expect(ReleaseFeatures.resolve(shipping: false, arguments: [], environment: ["HOMESPUN_RELEASE_FEATURES": "1"]))
    #expect(!ReleaseFeatures.resolve(shipping: true, arguments: ["-releaseFeatures", "NO"],
                                     environment: ["HOMESPUN_RELEASE_FEATURES": "1"]))
    #expect(ReleaseFeatures.resolve(shipping: false, arguments: ["-releaseFeatures", "YES"], environment: [:]))
    #else
    #expect(!ReleaseFeatures.resolve(shipping: false, arguments: ["-releaseFeatures", "YES"],
                                     environment: ["HOMESPUN_RELEASE_FEATURES": "1"]))
    #endif
}

@MainActor @Test(.enabled(if: !ReleaseFeatures.enabled))
func releaseScopeDisablesRuntimeEntryPoints() async throws {
    let premium = Premium(ownBuild: true, owned: { Issue.record("Queried the App Store"); return true },
                          testFlightWithoutProduct: { Issue.record("Queried TestFlight"); return true })
    await premium.load()
    await premium.refresh()
    #expect(!premium.isUnlocked && premium.product == nil)
    await #expect(throws: Premium.PurchaseError.self) { try await premium.purchase() }
    await #expect(throws: Premium.PurchaseError.self) { try await premium.restore() }
    let folder = URL.applicationSupportDirectory.appendingPathComponent("ReleaseScope-\(UUID())")
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var previous = AutomaticMode.State()
    previous.enabled = true
    let stateURL = folder.appendingPathComponent("automatic.json")
    try JSONEncoder().encode(previous).write(to: stateURL)
    let automatic = AutomaticMode(url: stateURL)
    await automatic.enable(existing: true)
    #expect(!automatic.enabled && automatic.state.enabled)
    automatic.schedule()
    let requests = await withCheckedContinuation { continuation in
        BGTaskScheduler.shared.getPendingTaskRequests { requests in
            continuation.resume(returning: requests.map(\.identifier))
        }
    }
    #expect(!requests.contains(AutomaticMode.taskID))
    await AutomaticMode.notify(.init(removable: 10, newlyRemovable: 10))
    let notifications = await UNUserNotificationCenter.current().pendingNotificationRequests()
    #expect(!notifications.contains { $0.identifier == "homespun.removable" })
    #expect(automatic.state.lastRun == nil)
    #expect(AppModel.shared.status == nil)
    #expect(PremiumFeature.available.isEmpty && PremiumFeature.backupFeatures.isEmpty)
    #expect(!ServerTab.Route.automatic.isAvailable && !ServerTab.Route.premium.isAvailable
            && !ServerTab.Route.connectors.isAvailable)
    #expect(!Journey.premiumMomentDue(owned: false, freedBytes: 2_000_000_000,
                                    manualBackupDays: [.now, .now.addingTimeInterval(-86_400)], dismissed: false))
    for link in [AppLink.freeUp, .activity, .server, .automatic, .unlock(feature: "widgets")] {
        #expect(!link.isAvailable)
    }
    let defaults = try #require(UserDefaults(suiteName: "release-scope-\(UUID())"))
    defaults.set("sharing", forKey: "telemetry.consent")
    let queueURL = folder.appendingPathComponent("telemetry.json")
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode([Telemetry.Event.premium("purchase"), .featureUsed("compare")]).write(to: queueURL)
    let telemetry = Telemetry(defaults: defaults, queueURL: queueURL, endpoint: nil)
    telemetry.record(.premium("shown"))
    #expect(telemetry.queued.map(\.name) == ["feature.used"])
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
