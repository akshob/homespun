// SPDX-License-Identifier: Apache-2.0
import XCTest

/// Without Premium, automatic mode and cloud copies explain themselves, then lead to the Premium screen.
final class PremiumUITests: XCTestCase {
    @MainActor func testLockedFeaturesOfferPremium() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-onboardingComplete", "YES", "-premiumLocked", "YES", "-hideTips"]
        app.launch()
        app.openTab("Server")
        XCTAssertFalse(app.automaticToggle.waitForExistence(timeout: 3))
        let server = XCTAttachment(screenshot: app.screenshot())
        server.name = "Server"
        server.lifetime = .keepAlways
        add(server)
        let link = app.buttons["automatic.premium"]
        _ = link.waitForExistence(timeout: 5)
        XCTAssertTrue(app.reveal(link), "automatic mode isn't offered")
        link.tap()
        let seeAll = app.buttons["premium.seeAll"]
        // A busy simulator can drop the first tap.
        if !seeAll.waitForExistence(timeout: 10), link.exists { link.tap() }
        XCTAssertTrue(seeAll.waitForExistence(timeout: 20), "no sheet about the locked feature")
        XCTAssertTrue(app.buttons["premium.feature.buy"].exists)
        let sheet = XCTAttachment(screenshot: app.screenshot())
        sheet.name = "Locked feature"
        sheet.lifetime = .keepAlways
        add(sheet)
        seeAll.tap()
        XCTAssertTrue(app.buttons["premium.restore"].waitForExistence(timeout: 10), "no Premium screen")
        XCTAssertTrue(app.buttons["premium.buy"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Premium"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
