// SPDX-License-Identifier: Apache-2.0
import XCTest

/// Selects the newest items in the library grid and waits for their compact copies.
/// Run on a fresh simulator (its library holds only Apple's sample photos, plus any synthetic
/// media you add) with photo access granted:
/// `xcrun simctl privacy <id> grant photos photos.homespun.app.dev`.
final class OnPhoneWorkflowUITests: XCTestCase {
    @MainActor func testPickedItemsGetCompactCopies() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-onboardingComplete", "YES", "-compactMode", "device"]
        app.launch()
        let count = app.compactNewest(4)

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Results"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        // Copies made on the phone: the originals stay, and nothing is backed up.
        XCTAssertGreaterThan(app.gridItems("Original still on this iPhone").count, 0, "no compact copies marked")
        XCTAssertEqual(app.gridItems("Backed up").count, 0)
        let statuses = app.checkActivity()
        XCTAssertEqual(statuses.count, count)
        XCTAssertTrue(statuses.contains("status.saved"))
    }
}
