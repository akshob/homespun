// SPDX-License-Identifier: Apache-2.0
import XCTest

/// Without the purchase (`-premiumLocked YES`), automatic mode and cloud copies look the same: their
/// rows say whether they're on and their pages open. Turning one on asks for the purchase (with the
/// price and Restore Purchase); closing that leaves it off. Pairs with a running server: pass
/// `HOMESPUN_SERVER` and `HOMESPUN_PAIRING_CODE` to `xcodebuild test` with a `TEST_RUNNER_` prefix.
/// Widgets' links need no server: a locked widget asks for the purchase, an unlocked one opens its place.
final class PremiumUITests: XCTestCase {
    @MainActor func testReleaseScopeHidesPremiumAndAutomaticSurfaces() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-onboardingComplete", "YES", "-hideTips", "-releaseFeatures", "NO",
                               "-freedBytes", "0", "-journey.sessions", "3", "-journey.setupSession", "1",
                               "-journey.getStartedClosed", "NO"]
        app.launch()
        XCTAssertTrue(app.hasTab("Library"))
        app.openTab("Library")

        for link in ["unlock?feature=widgets", "unlock?feature=automatic", "automatic", "activity", "server", "free-up"] {
            app.open(URL(string: "homespun://\(link)")!)
            XCTAssertFalse(app.buttons["unlock.buy"].waitForExistence(timeout: 1), link)
            XCTAssertFalse(app.switches["automatic.toggle"].exists, link)
            XCTAssertFalse(app.buttons["premium.restore"].exists, link)
            XCTAssertTrue(app.tab("Library").isSelected, link)
            XCTAssertFalse(app.buttons["remove.confirm"].exists, link)
        }
        app.openTab("Activity")
        XCTAssertTrue(app.descendants(matching: .any)["activity.getStarted"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["activity.premiumMoment"].exists)
        XCTAssertFalse(app.buttons["activity.automatic"].exists)
        assertReleaseCopy(app)

        app.openTab("Server")
        app.swipeUpInContent()
        for id in ["settings.premium", "settings.automatic", "settings.connectors"] {
            XCTAssertFalse(app.buttons[id].exists, id)
        }
        XCTAssertTrue(app.reveal(app.buttons["settings.notifications"]), "Manual completion alerts stay free")
        assertReleaseCopy(app)
        let help = app.buttons["settings.help"]
        XCTAssertTrue(app.reveal(help))
        help.tap()
        XCTAssertTrue(app.buttons["settings.onboarding"].waitForExistence(timeout: 10))
        assertReleaseCopy(app)
        app.buttons["settings.onboarding"].tap()
        XCTAssertTrue(app.buttons["setup.find"].waitForExistence(timeout: 10))
        assertReleaseCopy(app)
    }

    @MainActor private func assertReleaseCopy(_ app: XCUIApplication, file: StaticString = #filePath,
                                              line: UInt = #line) {
        let forbidden = NSPredicate(format: "label CONTAINS[c] 'Premium' OR label CONTAINS[c] 'Automatic Mode' "
                                    + "OR label CONTAINS[c] 'widgets' OR label CONTAINS[c] 'Apple Watch' "
                                    + "OR label CONTAINS[c] 'Cloud Copies' OR label CONTAINS[c] 'Restore Purchase'")
        XCTAssertEqual(app.staticTexts.matching(forbidden).count, 0, file: file, line: line)
        XCTAssertEqual(app.buttons.matching(forbidden).count, 0, file: file, line: line)
    }

    @MainActor func testTurningOnAsksForThePurchase() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let address = environment["HOMESPUN_SERVER"], let code = environment["HOMESPUN_PAIRING_CODE"] else {
            throw XCTSkip("Set HOMESPUN_SERVER and HOMESPUN_PAIRING_CODE to run against a server.")
        }
        let app = XCUIApplication()
        app.launchArguments += ["-onboardingComplete", "YES", "-premiumLocked", "YES", "-hideTips"]
        app.launchWithFeatures()
        app.pair(address: address, code: code)

        // The rows: what's on, never "Premium".
        app.openTab("Server")
        let automatic = app.buttons["settings.automatic"], cloud = app.buttons["settings.connectors"]
        if ReleaseFeatures.cloudCopies { XCTAssertTrue(app.reveal(cloud), "no Cloud Copies row") }
        XCTAssertTrue(app.reveal(automatic), "no Automatic Mode row")
        let rows = [(automatic, "Automatic Mode")] + (ReleaseFeatures.cloudCopies ? [(cloud, "Cloud Copies")] : [])
        for (row, title) in rows {
            // Cloud copies' status comes from the server.
            let off = NSPredicate(format: "label BEGINSWITH %@ AND label ENDSWITH 'Off'", title)
            let deadline = Date().addingTimeInterval(15)
            while !off.evaluate(with: row), Date() < deadline { usleep(250_000) }
            XCTAssertTrue(off.evaluate(with: row), row.label)
            XCTAssertFalse(row.label.contains("Premium"), row.label)
        }
        attach(app, "Server")

        // Automatic Mode: its switch asks for the purchase before anything else; Close leaves it off.
        app.openAutomaticMode()
        let toggle = app.automaticToggle
        XCTAssertEqual(toggle.value as? String, "0")
        attach(app, "Automatic Mode")
        app.tapSwitch(toggle)
        expectUnlockSheet(app, title: "Turn On Automatic Mode")
        XCTAssertEqual(toggle.value as? String, "0", "on without the purchase")
        XCTAssertFalse(app.buttons["Everything not backed up yet"].exists, "asked what to back up without the purchase")
        app.goBack(from: "Automatic Mode")

        guard ReleaseFeatures.cloudCopies else {
            XCTAssertFalse(cloud.exists, "Cloud Copies is hidden in this release")
            return
        }
        // Cloud Copies: signing in to a service asks for the purchase; Close doesn't start signing in.
        XCTAssertTrue(app.reveal(cloud), "no Cloud Copies row")
        cloud.tap()
        let oneDrive = app.buttons["connector.onedrive"]
        XCTAssertTrue(oneDrive.waitForExistence(timeout: 15), "no OneDrive on the Cloud Copies page")
        attach(app, "Cloud Copies")
        oneDrive.tap()
        let signIn = app.buttons["connector.signIn"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 10), "no Sign In")
        signIn.tap()
        expectUnlockSheet(app, title: "Turn On Cloud Copies")
        XCTAssertFalse(app.descendants(matching: .any)["signIn.code"].waitForExistence(timeout: 3),
                       "signing in started without the purchase")
        XCTAssertTrue(signIn.exists)
    }

    /// A locked widget's tap (homespun://unlock?feature=widgets) asks for the purchase.
    @MainActor func testWidgetUnlockLinkAsksForThePurchase() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-onboardingComplete", "YES", "-premiumLocked", "YES", "-hideTips"]
        app.launchWithFeatures()
        XCTAssertTrue(app.hasTab("Library"))
        app.open(URL(string: "homespun://unlock?feature=widgets")!)
        expectUnlockSheet(app, title: "Unlock Widgets")
    }

    /// An unlocked widget's taps open their places: Activity, and Automatic Mode in the Server tab.
    @MainActor func testWidgetLinksOpenTheirPlaces() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-onboardingComplete", "YES", "-hideTips"]
        app.launchWithFeatures()
        XCTAssertTrue(app.hasTab("Library"))
        app.open(URL(string: "homespun://activity")!)
        let activity = app.tab("Activity")
        XCTAssertTrue(activity.waitForExistence(timeout: 20))
        let selected = expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: activity)
        wait(for: [selected], timeout: 20)
        app.open(URL(string: "homespun://automatic")!)
        XCTAssertTrue(app.automaticToggle.waitForExistence(timeout: 20), "Automatic Mode didn't open")
    }

    /// The sheet: the feature, that one purchase unlocks them all, buy and restore; then Close.
    @MainActor private func expectUnlockSheet(_ app: XCUIApplication, title: String,
                                              file: StaticString = #filePath, line: UInt = #line) {
        let buy = app.buttons["unlock.buy"]
        XCTAssertTrue(buy.waitForExistence(timeout: 10), "turning it on didn't ask for the purchase", file: file, line: line)
        XCTAssertTrue(app.staticTexts[title].exists, "no \(title)", file: file, line: line)
        XCTAssertTrue(app.staticTexts["unlock.both"].exists, file: file, line: line)
        XCTAssertTrue(app.buttons["unlock.restore"].exists, "no Restore Purchase", file: file, line: line)
        attach(app, title)
        app.buttons["unlock.close"].tap()
        XCTAssertTrue(buy.waitForNonExistence(timeout: 10), "the sheet didn't close", file: file, line: line)
    }

    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
