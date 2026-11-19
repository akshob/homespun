// SPDX-License-Identifier: Apache-2.0
import XCTest

extension XCUIApplication {
    /// Scrolls until `element` exists and sits clear of the bottom accessory and tab bar, which
    /// the list scrolls under (a tap there would land on the accessory).
    @MainActor @discardableResult func reveal(_ element: XCUIElement) -> Bool {
        guard scrollTo(element) else { return false }
        let limit = frame.maxY - 220
        var tries = 4
        while element.exists, element.frame.maxY > limit, tries > 0 {
            swipeUpInContent()
            tries -= 1
        }
        // Scrolled past it, above the top of the list: bring it back down.
        tries = 4
        while element.exists, element.frame.minY < 100, tries > 0 {
            swipeDownInContent(near: element)
            tries -= 1
        }
        // A swipe keeps scrolling after it ends, so on a short screen (iPhone Duo's cover) it can carry
        // the row past the window both ways and leave it under the accessory: drag the rest of the way
        // and hold, which doesn't coast. (Not on the open Duo, whose screen coordinates are turned.)
        tries = 4
        while element.exists, windows.firstMatch.frame.width < 700, tries > 0 {
            let row = element.frame
            let distance = row.maxY > limit ? row.maxY - limit + 40 : row.minY < 100 ? row.minY - 140 : 0
            guard distance != 0, let list = contentLists.last(where: { $0.frame.intersects(row) }) ?? contentLists.last
            else { break }
            let step = max(-list.frame.height * 0.4, min(list.frame.height * 0.4, distance))
            let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -step)), withVelocity: .slow,
                        thenHoldForDuration: 0.3)
            tries -= 1
        }
        return element.exists || scrollTo(element)
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
            if row == "settings.check" {
                XCTAssertTrue(app.descendants(matching: .any)["check.connection.encrypted"].waitForExistence(timeout: 10))
            }
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
                let find = app.buttons["settings.findCopies"]
                XCTAssertTrue(find.waitForExistence(timeout: 10) || app.reveal(find), "no Find Compact Copies")
                find.tap()
                XCTAssertTrue(app.buttons["copies.start"].waitForExistence(timeout: 10), "no Find Compact Copies sheet")
                attach(app, "Find Compact Copies")
                app.buttons["copies.close"].tap()
            }
            app.goBack(from: title)
        }
        let backups = [("settings.automatic", "Automatic Mode")]
            + (AppFeatures.cloudCopies ? [("settings.connectors", "Cloud Copies")] : [])
        let lower = (backups.map(\.0) + ["settings.compactCopies", "settings.devices",
                     "settings.notifications", "settings.premium", "settings.help", "server.unpair"]).map { app.buttons[$0] }
        for row in lower {
            XCTAssertTrue(app.reveal(row), "no \(row)")
        }
        // Automatic mode and cloud copies say whether they're on (their switches are on their pages).
        for (row, title) in backups {
            let element = app.buttons[row]
            XCTAssertTrue(app.reveal(element), "no \(row)")
            let status = NSPredicate(format: "label BEGINSWITH %@ AND (label CONTAINS 'Off' OR label CONTAINS 'On')", title)
            XCTAssertTrue(waitFor { status.evaluate(with: element) }, element.label)
            XCTAssertFalse(element.label.contains("Premium"), element.label)
        }
        XCTAssertFalse(app.switches["automatic.toggle"].exists, "a switch for automatic mode in the list")
        attach(app, "Server, scrolled")
        if !AppFeatures.cloudCopies { XCTAssertFalse(app.buttons["settings.connectors"].exists) }
        for (row, title) in backups + [("settings.compactCopies", "Compact Copies"), ("settings.notifications", "Notifications"),
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
        XCTAssertTrue(app.reveal(app.buttons["settings.devices"]), "no Devices row")
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

extension ServerTabUITests {
    @MainActor func test7RePairKeepsTheConfirmedNameAndOneActiveDevice() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let address = environment["HOMESPUN_SERVER"], let code = environment["HOMESPUN_PAIRING_CODE"],
              let action = environment["HOMESPUN_HOST_ACTION_FILE"],
              let output = environment["HOMESPUN_PAIRING_OUTPUT_FILE"] else { throw XCTSkip("Needs temporary pairing-code action.") }
        let app = XCUIApplication()
        app.launchArguments += ["-onboardingComplete", "YES", "-hideTips"]
        app.launch()
        app.pair(address: address, code: code)
        app.showTab("Server")
        let row = app.buttons["settings.deviceName"]
        XCTAssertTrue(app.reveal(row))
        row.tap()
        let field = app.textFields["device.name"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        XCTAssertTrue(waitFor { (field.value as? String)?.isEmpty == false })
        let current = field.value as? String ?? ""
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count) + "Family Phone")
        app.buttons["device.name.save"].tap()
        XCTAssertTrue(app.reveal(row))
        XCTAssertTrue(waitFor { row.label.contains("Family Phone") })
        try Data("pairing-code".utf8).write(to: URL(fileURLWithPath: action), options: .atomic)
        let deadline = Date().addingTimeInterval(30)
        while !FileManager.default.fileExists(atPath: output), Date() < deadline { usleep(250_000) }
        let text = try String(contentsOfFile: output, encoding: .utf8)
        let line = try XCTUnwrap(text.split(separator: "\n").first { $0.hasPrefix("Pairing code: ") })
        let newCode = try XCTUnwrap(line.split(separator: " ").dropFirst(2).first).description
        XCTAssertTrue(app.reveal(app.buttons["server.unpair"]))
        app.buttons["server.unpair"].tap()
        let confirm = app.alerts.firstMatch.buttons["server.unpair.confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        app.showTab("Library")
        app.pair(address: address, code: newCode)
        app.showTab("Server")
        XCTAssertTrue(app.reveal(row))
        XCTAssertTrue(waitFor { row.label.contains("Family Phone") })
        let devices = app.buttons["settings.devices"]
        XCTAssertTrue(app.reveal(devices))
        devices.tap()
        let count = app.staticTexts["devices.count"]
        XCTAssertTrue(count.waitForExistence(timeout: 15))
        XCTAssertEqual(count.label.lowercased(), "1 paired device")
        XCTAssertTrue(app.descendants(matching: .any)["devices.this"].label.contains("Family Phone"))
        app.goBack(from: "Devices")
    }

    @MainActor func test8ServerFollowsItsPinnedKeyToANewAddress() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let address = environment["HOMESPUN_SERVER"], let moved = environment["HOMESPUN_MOVED_SERVER"],
              let code = environment["HOMESPUN_PAIRING_CODE"], let action = environment["HOMESPUN_HOST_ACTION_FILE"],
              let rogueLog = environment["HOMESPUN_ROGUE_LOG"] else { throw XCTSkip("Needs temporary server address actions.") }
        let app = XCUIApplication()
        app.launchArguments += ["-onboardingComplete", "YES", "-hideTips"]
        let candidates = try JSONSerialization.data(withJSONObject: [
            ["url": "https://\(moved)", "serviceName": "Home Mac (test)"]
        ])
        app.launchEnvironment["HOMESPUN_SERVER_CANDIDATES"] = String(decoding: candidates, as: UTF8.self)
        app.launch()
        app.pair(address: address, code: code)
        app.showTab("Server")
        app.buttons["settings.check"].tap()
        let current = app.descendants(matching: .any)["check.connection.address"]
        XCTAssertTrue(current.waitForExistence(timeout: 15))

        func command(_ value: String) throws {
            try Data(value.utf8).write(to: URL(fileURLWithPath: action), options: .atomic)
            let deadline = Date().addingTimeInterval(30)
            while FileManager.default.fileExists(atPath: action), Date() < deadline { usleep(250_000) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: action), "host action didn't finish")
        }
        func currentAddress() -> String { current.label + " " + (current.value as? String ?? "") }
        func checkAgain() {
            let again = app.buttons["check.again"]
            XCTAssertTrue(app.reveal(again))
            again.tap()
            XCTAssertTrue(app.reveal(current))
        }

        try command("wrong-key-port")
        checkAgain()
        let refused = app.descendants(matching: .any)["check.connection.addressNotFound"]
        XCTAssertTrue(refused.waitForExistence(timeout: 40))
        XCTAssertTrue(app.reveal(current))
        XCTAssertTrue(currentAddress().contains(address), currentAddress())
        let log = try String(contentsOfFile: rogueLog, encoding: .utf8)
        XCTAssertFalse(log.contains("/api/v1/info"), "the different-key candidate received an authenticated request")

        try command("move-port")
        sleep(65) // Rediscovery is deliberately limited to once a minute.
        checkAgain()
        let found = app.descendants(matching: .any)["check.connection.addressChanged"]
        XCTAssertTrue(found.waitForExistence(timeout: 40))
        XCTAssertTrue(app.reveal(current))
        XCTAssertTrue(currentAddress().contains(moved), currentAddress())
        XCTAssertTrue(found.label.contains("at its new address"), found.label)
        XCTAssertTrue(app.descendants(matching: .any)["check.connection.encrypted"].exists)
        XCTAssertFalse(app.buttons["connect.open"].exists, "following the pinned key required pairing again")
        app.goBack(from: "Server Check")
    }

    @MainActor func test9ServerKeyChangeIsConfirmed() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let address = environment["HOMESPUN_SERVER"], let code = environment["HOMESPUN_PAIRING_CODE"],
              let action = environment["HOMESPUN_HOST_ACTION_FILE"] else { throw XCTSkip("Needs the temporary server's host-action watcher.") }
        let app = XCUIApplication()
        app.launchArguments += ["-onboardingComplete", "YES", "-hideTips"]
        app.launch()
        app.pair(address: address, code: code)
        app.showTab("Server")
        app.buttons["settings.check"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["check.connection.encrypted"].waitForExistence(timeout: 15))
        try Data("rotate-key".utf8).write(to: URL(fileURLWithPath: action), options: .atomic)
        sleep(15)
        let again = app.buttons["check.again"]
        XCTAssertTrue(app.reveal(again))
        again.tap()
        app.goBack(from: "Server Check")
        let notice = app.descendants(matching: .any)["server.keyChanged.confirmed"]
        XCTAssertTrue(notice.waitForExistence(timeout: 20) || app.reveal(notice), "the new key wasn't confirmed with the pairing")
        app.buttons["settings.check"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["check.connection.encrypted"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["check.connection.key"].exists)
    }

    /// Server › This iPhone › Name renames this iPhone and its originals folder on the server.
    @MainActor func testRenameThisIPhone() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let address = environment["HOMESPUN_SERVER"], let code = environment["HOMESPUN_PAIRING_CODE"] else {
            throw XCTSkip("Set HOMESPUN_SERVER and HOMESPUN_PAIRING_CODE to run against a server.")
        }
        let app = XCUIApplication()
        app.launchArguments += ["-onboardingComplete", "YES", "-hideTips"]
        app.launch()
        app.pair(address: address, code: code)
        app.showTab("Server")
        let row = app.buttons["settings.deviceName"]
        XCTAssertTrue(app.reveal(row), "no Name row")
        row.tap()
        let field = app.textFields["device.name"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        XCTAssertTrue(waitFor { (field.value as? String)?.isEmpty == false }, "the current name didn't load")
        let current = field.value as? String ?? ""
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count) + "Akshob’s iPhone")
        attach(app, "Rename")
        app.buttons["device.name.save"].tap()
        XCTAssertTrue(app.reveal(row), "didn't go back to the Server tab")
        XCTAssertTrue(waitFor { row.label.contains("Akshob’s iPhone") }, row.label)
        // Its folder on the server has the new name too.
        let originals = app.buttons["settings.originals"]
        XCTAssertTrue(app.reveal(originals))
        originals.tap()
        let folder = app.descendants(matching: .any)["originals.deviceFolder"]
        XCTAssertTrue(folder.waitForExistence(timeout: 15))
        XCTAssertTrue(folder.label.contains("Akshob’s iPhone"), folder.label)
        attach(app, "Originals folder after renaming")
    }

    private func waitFor(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(15)
        while !condition(), Date() < deadline { usleep(250_000) }
        return condition()
    }
}
