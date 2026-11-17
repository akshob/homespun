// SPDX-License-Identifier: Apache-2.0
import XCTest

/// Without the purchase (`-premiumLocked YES`), automatic mode and cloud copies look the same: their
/// rows say whether they're on and their pages open. Turning one on asks for the purchase (with the
/// price and Restore Purchase); closing that leaves it off. Pairs with a running server: pass
/// `HOMESPUN_SERVER` and `HOMESPUN_PAIRING_CODE` to `xcodebuild test` with a `TEST_RUNNER_` prefix.
final class PremiumUITests: XCTestCase {
    @MainActor func testTurningOnAsksForThePurchase() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let address = environment["HOMESPUN_SERVER"], let code = environment["HOMESPUN_PAIRING_CODE"] else {
            throw XCTSkip("Set HOMESPUN_SERVER and HOMESPUN_PAIRING_CODE to run against a server.")
        }
        let app = XCUIApplication()
        app.launchArguments += ["-onboardingComplete", "YES", "-premiumLocked", "YES", "-hideTips"]
        app.launch()
        app.pair(address: address, code: code)

        // The rows: what's on, never "Premium".
        app.openTab("Server")
        let automatic = app.buttons["settings.automatic"], cloud = app.buttons["settings.connectors"]
        XCTAssertTrue(app.reveal(cloud), "no Cloud Copies row")
        XCTAssertTrue(app.reveal(automatic), "no Automatic Mode row")
        for (row, title) in [(automatic, "Automatic Mode"), (cloud, "Cloud Copies")] {
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

    /// The sheet: the feature, that one purchase unlocks both, buy and restore; then Close.
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
