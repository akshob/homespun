// SPDX-License-Identifier: Apache-2.0
import XCTest

/// Without Premium, automatic mode and cloud copies explain themselves, then lead to the Premium screen; widgets'
/// links lead to their places, or to unlocking widgets.
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

    /// A locked widget's tap (homespun://unlock?feature=widgets) asks to unlock widgets.
    @MainActor func testWidgetUnlockLinkOffersPremium() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-onboardingComplete", "YES", "-premiumLocked", "YES", "-hideTips"]
        app.launch()
        XCTAssertTrue(app.hasTab("Library"))
        app.open(URL(string: "homespun://unlock?feature=widgets")!)
        let title = app.staticTexts["premium.feature.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 20), "no sheet about widgets")
        XCTAssertEqual(title.label, "Unlock widgets")
        XCTAssertTrue(app.buttons["premium.feature.buy"].exists)
        let sheet = XCTAttachment(screenshot: app.screenshot())
        sheet.name = "Unlock widgets"
        sheet.lifetime = .keepAlways
        add(sheet)
    }

    /// An unlocked widget's taps open their places: Activity, and Automatic Mode in the Server tab.
    @MainActor func testWidgetLinksOpenTheirPlaces() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-onboardingComplete", "YES", "-hideTips"]
        app.launch()
        XCTAssertTrue(app.hasTab("Library"))
        app.open(URL(string: "homespun://activity")!)
        let activity = app.tab("Activity")
        XCTAssertTrue(activity.waitForExistence(timeout: 20))
        let selected = expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: activity)
        wait(for: [selected], timeout: 20)
        app.open(URL(string: "homespun://automatic")!)
        XCTAssertTrue(app.descendants(matching: .any)["automatic.page.toggle"].waitForExistence(timeout: 20),
                      "Automatic Mode didn't open")
    }
}
