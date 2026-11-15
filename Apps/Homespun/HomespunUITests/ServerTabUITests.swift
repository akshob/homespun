// SPDX-License-Identifier: Apache-2.0
import XCTest

extension XCUIApplication {
    /// Scrolls until `element` exists and sits clear of the bottom accessory and tab bar, which
    /// the list scrolls under (a tap there would land on the accessory).
    @MainActor @discardableResult func reveal(_ element: XCUIElement) -> Bool {
        guard scrollTo(element) else { return false }
        let limit = frame.maxY - 220
        var tries = 4
        while element.frame.maxY > limit, tries > 0 {
            swipeUpInContent()
            tries -= 1
        }
        return element.exists
    }

    /// Opens a tab (`openTab` scrolls up first if the tab bar was minimised).
    @MainActor func showTab(_ title: String) { openTab(title) }
}

/// The Server tab's rows, the devices list, the unpair confirmation, and a finished run in
/// Activity with its details. Pairs with a running server: pass `HOMESPUN_SERVER` and
/// `HOMESPUN_PAIRING_CODE` to `xcodebuild test` with a `TEST_RUNNER_` prefix.
final class ServerTabUITests: XCTestCase {
    @MainActor func testServerTabAndActivityHistory() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let address = environment["HOMESPUN_SERVER"], let code = environment["HOMESPUN_PAIRING_CODE"] else {
            throw XCTSkip("Set HOMESPUN_SERVER and HOMESPUN_PAIRING_CODE to run against a server.")
        }
        let app = XCUIApplication()
        app.launchArguments += ["-onboardingComplete", "YES", "-hideTips"]
        app.launch()
        app.pair(address: address, code: code)

        // The status card and the rows, top to bottom.
        app.showTab("Server")
        XCTAssertTrue(app.descendants(matching: .any)["server.status"].waitForExistence(timeout: 10))
        for row in ["settings.check", "settings.originals", "settings.existingLibrary", "settings.immich"] {
            XCTAssertTrue(app.buttons[row].waitForExistence(timeout: 5), "no \(row)")
        }
        attach(app, "Server")
        // Each page opens (and is attached, for comparing with the design).
        for (row, title) in [("settings.check", "Server Check"), ("settings.originals", "Originals Folder"),
                             ("settings.existingLibrary", "Existing Library"), ("settings.immich", "Immich")] {
            app.buttons[row].tap()
            // Case-insensitive: Server Check's page belongs to setup.
            XCTAssertTrue(app.hasScreen(title), "no \(title) page")
            sleep(2)
            attach(app, title)
            if row == "settings.originals", app.buttons["originals.change"].waitForExistence(timeout: 10) {
                app.buttons["originals.change"].tap()
                XCTAssertTrue(app.hasScreen("Change Folder"))
                sleep(2)
                attach(app, "Change Folder")
                app.goBack(from: "Change Folder")
            }
            if row == "settings.existingLibrary" {
                app.buttons["settings.findCopies"].tap()
                XCTAssertTrue(app.buttons["copies.start"].waitForExistence(timeout: 10), "no Find Compact Copies sheet")
                attach(app, "Find Compact Copies")
                app.buttons["copies.close"].tap()
            }
            app.goBack(from: title)
        }
        // Debug builds have Premium, so automatic mode is a switch.
        let lower = [app.automaticToggle] + ["settings.connectors", "settings.compactCopies",
                     "settings.devices", "settings.notifications", "settings.premium", "settings.help",
                     "server.unpair"].map { app.buttons[$0] }
        for row in lower {
            XCTAssertTrue(app.reveal(row), "no \(row)")
        }
        attach(app, "Server, scrolled")
        for (row, title) in [("settings.automatic", "Automatic Mode"), ("settings.connectors", "Cloud Copies"),
                             ("settings.compactCopies", "Compact Copies"), ("settings.notifications", "Notifications"),
                             ("settings.help", "Help and About")] {
            XCTAssertTrue(app.reveal(app.buttons[row]), "no \(row)")
            app.buttons[row].tap()
            XCTAssertTrue(app.hasScreen(title), "no \(title) page")
            sleep(2)
            attach(app, title)
            app.goBack(from: title)
        }
        XCTAssertTrue(app.reveal(app.buttons["settings.premium"]))
        app.buttons["settings.premium"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["premium.unlocked"].waitForExistence(timeout: 10), "no Premium page")
        attach(app, "Premium")
        app.goBack()

        // Devices lists this iPhone.
        app.buttons["settings.devices"].tap()
        let this = app.descendants(matching: .any)["devices.this"]
        XCTAssertTrue(this.waitForExistence(timeout: 15), "this iPhone isn't listed")
        XCTAssertTrue(this.label.contains("This iPhone"), this.label)
        XCTAssertTrue(app.buttons["settings.addDevice"].exists)
        attach(app, "Devices")
        app.goBack(from: "Devices")

        // Unpairing asks first; Cancel keeps the pairing.
        XCTAssertTrue(app.reveal(app.buttons["server.unpair"]))
        app.buttons["server.unpair"].tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "no confirmation")
        XCTAssertTrue(alert.label.hasPrefix("Unpair from"), alert.label)
        attach(app, "Unpair")
        alert.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["server.unpair"].waitForExistence(timeout: 5), "unpaired after Cancel")
        // Scrolling down minimised the tab bar; scrolling back up brings its tabs back.
        for _ in 0..<4 { app.swipeDown() }

        // While a backup runs, Activity's Now card has Pause and Stop; Stop asks first.
        app.showTab("Library")
        let notBackedUp = app.gridItems("Not backed up")
        // (Only without an offer to free up space in the accessory, which can sit over the Back Up button.)
        if notBackedUp.firstMatch.waitForExistence(timeout: 15), notBackedUp.count > 2,
           !app.buttons["accessory.action"].exists {
            app.buttons["select.start"].tap()
            notBackedUp.allElementsBoundByIndex.last?.tap()
            app.buttons["compact.selected"].tap()
            app.showTab("Activity")
            let now = app.descendants(matching: .any)["activity.now"]
            if now.waitForExistence(timeout: 20) {
                attach(app, "Activity, backing up")
                app.buttons["activity.stop"].tap()
                let stop = app.alerts.firstMatch
                XCTAssertTrue(stop.waitForExistence(timeout: 5), "Stop doesn't ask")
                XCTAssertEqual(stop.label, "Stop backing up?")
                attach(app, "Stop backing up")
                stop.buttons["Keep Going"].tap()
                let deadline = Date().addingTimeInterval(300)
                while now.exists, Date() < deadline { sleep(2) }
            }
        }

        // Back up two items (unless an earlier test backed everything up), then Activity shows the run.
        app.showTab("Library")
        if app.gridItems("Not backed up").firstMatch.waitForExistence(timeout: 15) {
            _ = app.compactNewest(2)
        }
        app.showTab("Activity")
        let run = app.descendants(matching: .any).matching(identifier: "activity.run").firstMatch
        XCTAssertTrue(run.waitForExistence(timeout: 20), "no finished run in Activity")
        attach(app, "Activity")
        run.tap()
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'status.'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10), "no items in the run")
        XCTAssertGreaterThan(app.descendants(matching: .any).matching(identifier: "status.saved").count, 0)
        attach(app, "Run details")
        app.goBack()
        XCTAssertTrue(run.waitForExistence(timeout: 5))
    }

    /// The server doesn't answer: the status says so, with what to check and Try Again. Run with
    /// the server stopped and `HOMESPUN_UNREACHABLE=1`, after a test that paired.
    @MainActor func testCantReachTheServer() throws {
        guard ProcessInfo.processInfo.environment["HOMESPUN_UNREACHABLE"] == "1" else {
            throw XCTSkip("Stop the server and set HOMESPUN_UNREACHABLE=1 to run this.")
        }
        let app = XCUIApplication()
        app.launchArguments += ["-onboardingComplete", "YES", "-hideTips"]
        app.launch()
        app.showTab("Server")
        let status = app.descendants(matching: .any)["server.status"]
        let unreachable = NSPredicate(format: "label CONTAINS[c] \"Can't reach\"")
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline, !(status.exists && unreachable.evaluate(with: status)) { sleep(1) }
        XCTAssertTrue(unreachable.evaluate(with: status), status.label)
        XCTAssertTrue(app.buttons["server.retry"].waitForExistence(timeout: 5))
        attach(app, "Can't reach")
        app.showTab("Activity")
        attach(app, "Activity, can't reach")
    }

    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
