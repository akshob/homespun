// SPDX-License-Identifier: Apache-2.0
import BackgroundTasks
import Foundation
import XCTest
@testable import Homespun

final class ReleaseScopeTests: XCTestCase {
    @MainActor func testReleaseDisablesEntryPoints() async throws {
        try XCTSkipIf(ReleaseFeatures.enabled, "Run with the HomespunReleaseScope scheme.")
        let premium = Premium(ownBuild: true, owned: { XCTFail("Queried purchase entitlements"); return true },
                              testFlightWithoutProduct: { XCTFail("Queried purchase products"); return true })
        await premium.load()
        await premium.refresh()
        XCTAssertFalse(premium.isUnlocked)
        XCTAssertNil(premium.product)
        do {
            _ = try await premium.purchase()
            XCTFail("Purchase was allowed")
        } catch { XCTAssertTrue(error is Premium.PurchaseError) }
        do {
            try await premium.restore()
            XCTFail("Restore was allowed")
        } catch { XCTAssertTrue(error is Premium.PurchaseError) }

        let folder = URL.applicationSupportDirectory.appendingPathComponent("ReleaseScope-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var previous = AutomaticMode.State()
        previous.enabled = true
        let stateURL = folder.appendingPathComponent("automatic.json")
        try JSONEncoder().encode(previous).write(to: stateURL)
        let automatic = AutomaticMode(url: stateURL)
        await automatic.enable(existing: true)
        XCTAssertFalse(automatic.enabled)
        XCTAssertTrue(automatic.state.enabled, "Keep settings for a later feature-enabled release")
        automatic.schedule()
        let requests = await withCheckedContinuation { continuation in
            BGTaskScheduler.shared.getPendingTaskRequests { requests in
                continuation.resume(returning: requests.map(\.identifier))
            }
        }
        XCTAssertFalse(requests.contains(AutomaticMode.taskID))
        await AutomaticMode.notify(.init(removable: 10, newlyRemovable: 10)) { _ in
            XCTFail("Delivered an automatic-run notification")
        }
        let model = AppModel.shared
        _ = await automatic.run(settings: model.settings, job: model.job, premium: premium, notify: true)
        XCTAssertNil(automatic.state.lastRun)
        XCTAssertNil(model.status)
        let diagnostics = await ReportDiagnostics.make(model: model, checks: nil)
        XCTAssertNil(diagnostics["premium"])
        XCTAssertNil(diagnostics["automatic"])
        XCTAssertTrue(PremiumFeature.available.isEmpty && PremiumFeature.backupFeatures.isEmpty)
        XCTAssertTrue(ServerTab.Route.notifications.isAvailable, "Manual completion alerts stay free")
        XCTAssertFalse(ServerTab.Route.automatic.isAvailable || ServerTab.Route.premium.isAvailable
                       || ServerTab.Route.connectors.isAvailable)
        XCTAssertFalse(Journey.premiumMomentDue(owned: false, freedBytes: 2_000_000_000,
                                               manualBackupDays: [.now, .now.addingTimeInterval(-86_400)],
                                               dismissed: false))
        for link in [AppLink.freeUp, .activity, .server, .automatic, .unlock(feature: "widgets")] {
            XCTAssertFalse(link.isAvailable)
        }

        let suite = "release-scope-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("sharing", forKey: "telemetry.consent")
        let queueURL = folder.appendingPathComponent("telemetry.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([Telemetry.Event.premium("purchase"), .featureUsed("compare")]).write(to: queueURL)
        let telemetry = Telemetry(defaults: defaults, queueURL: queueURL, endpoint: nil)
        telemetry.record(.premium("shown"))
        XCTAssertEqual(telemetry.queued.map(\.name), ["feature.used"])
    }
}
