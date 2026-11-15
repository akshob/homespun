// SPDX-License-Identifier: Apache-2.0
import XCTest

/// Pairs with a running Homespun Server, compacts the newest items in the library grid through
/// it, checks their badges, and optionally removes the originals. Needs a fresh simulator with synthetic media and these variables
/// (pass them to `xcodebuild test` with a `TEST_RUNNER_` prefix):
/// `HOMESPUN_SERVER` (address), `HOMESPUN_PAIRING_CODE` (from `homespun-server pair`),
/// optional `HOMESPUN_PICK` (number of newest items, default 3) and `HOMESPUN_REMOVE=1`.
final class ServerModeUITests: XCTestCase {
    // Numbered: the first pairs and compacts a selection; the second relies on that pairing.
    @MainActor func test1CompactThroughServerAndRemoveOriginals() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let address = environment["HOMESPUN_SERVER"], let code = environment["HOMESPUN_PAIRING_CODE"] else {
            throw XCTSkip("Set HOMESPUN_SERVER and HOMESPUN_PAIRING_CODE to run against a server.")
        }
        let app = XCUIApplication()
        app.launchArguments += ["-onboardingComplete", "YES"]
        app.launch()

        app.pair(address: address, code: code)
        attach(app, "Paired")

        // A paired iPhone can make a code for another device.
        app.openTab("Server")
        app.buttons["server.more"].tap()
        app.buttons["Add Device"].tap()
        XCTAssertTrue(app.staticTexts["addDevice.code"].waitForExistence(timeout: 15), "no code for another device")
        attach(app, "Add another device")
        app.navigationBars["Add Device"].buttons.firstMatch.tap()
        // It shows where this iPhone's originals go on the server.
        app.buttons["settings.originals"].tap()
        XCTAssertTrue(app.staticTexts["originals.deviceFolder"].waitForExistence(timeout: 15), "no originals folder")
        attach(app, "Originals folder")
        app.navigationBars["Originals Folder"].buttons.firstMatch.tap()
        app.openTab("Library")

        attach(app, "Grid")
        _ = app.compactNewest(Int(environment["HOMESPUN_PICK"] ?? "") ?? 3)
        attach(app, "Compacted")
        // The originals are on the server and still on the iPhone; the grid shows their copies.
        let onPhone = app.gridItems("Ready to free up")
        XCTAssertGreaterThan(onPhone.count, 0, "no compact copies marked")
        XCTAssertTrue(app.checkActivity().contains("status.saved"))

        guard environment["HOMESPUN_REMOVE"] == "1" else { return }
        // Homespun offers to free up space for what was just backed up.
        let offer = app.descendants(matching: .any)["offer.free"]
        XCTAssertTrue(offer.waitForExistence(timeout: 20), "no offer to free up space")
        attach(app, "Before removal")
        offer.tap()
        // The first time, the sheet explains what freeing up space does.
        let proceed = app.buttons["remove.confirm"]
        XCTAssertTrue(proceed.waitForExistence(timeout: 10), "no Free Up Space sheet")
        attach(app, "Free Up Space")
        proceed.tap()
        // iOS asks for confirmation; the alert may belong to the app or to SpringBoard.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let confirmation = [app.alerts.buttons["Delete"], springboard.alerts.buttons["Delete"]]
        let confirmDeadline = Date().addingTimeInterval(300)
        while Date() < confirmDeadline, !confirmation.contains(where: \.exists) { sleep(1) }
        attach(springboard, "Confirmation")
        guard let delete = confirmation.first(where: \.exists) else { return XCTFail("no deletion confirmation appeared") }
        delete.tap()
        let summary = app.staticTexts["remove.summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 60))
        attach(app, "Removed")
        XCTAssertTrue(summary.label.contains("Freed"), summary.label)
        let looksRight = app.buttons["trial.confirm"]
        XCTAssertTrue(looksRight.waitForExistence(timeout: 5), "trial check not offered")
        looksRight.tap()
        XCTAssertFalse(looksRight.waitForExistence(timeout: 2))
        // The removed originals' copies now show their originals at home.
        XCTAssertTrue(app.gridItems("Original at home").firstMatch.waitForExistence(timeout: 10), "no items marked at home")
        attach(app, "Backed up")
    }

    /// Automatic mode (unlocked in Debug builds) backs up and compacts everything else, with
    /// nothing selected. Uses the pairing from the first test.
    @MainActor func test2AutomaticModeBacksUpTheRest() throws {
        guard ProcessInfo.processInfo.environment["HOMESPUN_SERVER"] != nil else {
            throw XCTSkip("Set HOMESPUN_SERVER and HOMESPUN_PAIRING_CODE to run against a server.")
        }
        let app = XCUIApplication()
        app.launchArguments += ["-onboardingComplete", "YES"]
        app.launch()
        XCTAssertTrue(app.isConnected(), "not paired with the server")
        let remaining = app.gridItems("Not backed up")
        XCTAssertTrue(remaining.firstMatch.waitForExistence(timeout: 20), "nothing left to compact")
        let before = app.gridItems("Ready to free up").count + app.gridItems("Original at home").count

        app.openTab("Server")
        let toggle = app.switches["automatic.toggle"]
        XCTAssertTrue(app.scrollTo(toggle), "automatic mode isn't offered")
        toggle.switches.firstMatch.tap()
        app.buttons["Everything not backed up yet"].firstMatch.tap()
        // iOS asks once whether Homespun may send notifications.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 10) { allow.tap() }
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "1")
        app.openTab("Library")

        // Nothing selected, yet the rest gets compact copies.
        let busy = app.gridItems().matching(NSPredicate(format: "value IN {'Waiting', 'Backing up'}"))
        let progress = app.descendants(matching: .any)["job.progress"]
        let deadline = Date().addingTimeInterval(900)
        repeat { sleep(2) } while (busy.count > 0 || progress.exists) && Date() < deadline
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Automatic"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCTAssertGreaterThan(app.gridItems("Ready to free up").count + app.gridItems("Original at home").count, before)
        XCTAssertEqual(app.gridItems("Not backed up").count, 0, "automatic mode left items")
        XCTAssertEqual(app.gridItems("Needs attention").count, 0)
    }

    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
