// SPDX-License-Identifier: Apache-2.0
import XCTest

/// Without Premium, automatic mode and cloud copies lead to the Premium screen.
final class PremiumUITests: XCTestCase {
    @MainActor func testLockedFeaturesOfferPremium() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-onboardingComplete", "YES", "-premiumLocked", "YES"]
        app.launch()
        app.buttons["settings"].tap()
        XCTAssertFalse(app.switches["automatic.toggle"].waitForExistence(timeout: 3))
        let link = app.buttons["automatic.premium"]
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        link.tap()
        XCTAssertTrue(app.buttons["premium.restore"].waitForExistence(timeout: 10), "no Premium screen")
        XCTAssertTrue(app.buttons["premium.buy"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Premium"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
