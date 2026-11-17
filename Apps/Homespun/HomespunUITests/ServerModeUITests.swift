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
        app.launchArguments += ["-onboardingComplete", "YES", "-hideTips"]
        app.launch()

        app.pair(address: address, code: code)
        attach(app, "Paired")

        // A paired iPhone can make a code for another device.
        app.openTab("Server")
        app.buttons["server.more"].tap()
        app.buttons["Add Device"].tap()
        XCTAssertTrue(app.staticTexts["addDevice.code"].waitForExistence(timeout: 15), "no code for another device")
        attach(app, "Add another device")
        app.goBack(from: "Add Device")
        // It shows where this iPhone's originals go on the server.
        app.buttons["settings.originals"].tap()
        XCTAssertTrue(app.staticTexts["originals.deviceFolder"].waitForExistence(timeout: 15), "no originals folder")
        attach(app, "Originals folder")
        app.goBack(from: "Originals Folder")
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
        // iOS asks for confirmation; the alert may belong to the app or to SpringBoard.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        func confirmDeletion(_ what: String) -> Bool {
            let confirmation = [app.alerts.buttons["Delete"], springboard.alerts.buttons["Delete"]]
            let deadline = Date().addingTimeInterval(300)
            while Date() < deadline, !confirmation.contains(where: \.exists) { sleep(1) }
            attach(springboard, "Confirmation: \(what)")
            guard let delete = confirmation.first(where: \.exists) else { return false }
            delete.tap()
            return true
        }
        // The compact copies can be compared with their originals before anything goes, inside the
        // same sheet (no second sheet); one keeps its original instead (its compact copy goes).
        let before = proceed.label
        let compare = app.buttons["remove.compare"].firstMatch
        XCTAssertTrue(compare.waitForExistence(timeout: 5), "no compact copies to compare")
        // On a small screen (iPhone Duo's cover) the sheet opens at half height, the photos under its
        // buttons: bring them up first.
        var lifts = 4
        while compare.frame.maxY > app.frame.maxY - 200, lifts > 0 { app.swipeUpInContent(); lifts -= 1 }
        compare.tap()
        XCTAssertTrue(app.staticTexts["compare.compact"].waitForExistence(timeout: 30), "no Compare")
        attach(app, "Compare before freeing up")
        let keep = app.buttons["remove.keepOriginal"]
        XCTAssertTrue(keep.waitForExistence(timeout: 5), "no Keep Original under Compare")
        keep.tap()
        XCTAssertTrue(confirmDeletion("keep original"), "no confirmation to delete the compact copy")
        XCTAssertTrue(proceed.waitForExistence(timeout: 20), "didn't go back to the review after Keep Original")
        let deadline = Date().addingTimeInterval(15)
        while proceed.label == before, Date() < deadline { sleep(1) }
        XCTAssertNotEqual(proceed.label, before, "the kept original is still offered: \(proceed.label)")
        attach(app, "After Keep Original")
        proceed.tap()
        guard confirmDeletion("free up") else { return XCTFail("no deletion confirmation appeared") }
        let summary = app.staticTexts["remove.summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 60))
        attach(app, "Removed")
        XCTAssertTrue(summary.label.contains("Freed"), summary.label)
        // The copies were compared before (the first time); the result just has Done.
        let done = app.buttons["remove.dismiss"]
        XCTAssertTrue(done.waitForExistence(timeout: 10), "no Done after freeing up")
        done.tap()
        // The removed originals' copies now show their originals at home; the kept one is backed up,
        // its original still here full size.
        XCTAssertTrue(app.gridItems("Original at home").firstMatch.waitForExistence(timeout: 10), "no items marked at home")
        XCTAssertTrue(app.gridItems("Backed up").firstMatch.waitForExistence(timeout: 10), "the kept original isn't Backed up")
        attach(app, "Backed up")
    }

    /// Restore Original: an original freed up in the first test comes back from the server into
    /// Photos (from the viewer), its compact copy goes once iOS asks, and it's kept full size
    /// (Backed up); then another through Select mode under Original at Home.
    @MainActor func test3RestoreOriginals() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["HOMESPUN_SERVER"] != nil, environment["HOMESPUN_REMOVE"] == "1" else {
            throw XCTSkip("Runs after the first test freed up originals (HOMESPUN_REMOVE=1).")
        }
        let app = XCUIApplication()
        app.launchArguments += ["-onboardingComplete", "YES", "-hideTips"]
        app.launch()
        XCTAssertTrue(app.isConnected(), "not paired with the server")
        app.openTab("Library")
        let atHome = app.gridItems("Original at home")
        XCTAssertTrue(atHome.firstMatch.waitForExistence(timeout: 20), "nothing freed up to restore")
        let before = atHome.count
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        func restore(_ what: String) {
            let confirm = app.buttons["restore.confirm"]
            XCTAssertTrue(confirm.waitForExistence(timeout: 20), "\(what): no Restore Original sheet")
            attach(app, "\(what): Restore Original")
            confirm.tap()
            let delete = [app.alerts.buttons["Delete"], springboard.alerts.buttons["Delete"]]
            let deadline = Date().addingTimeInterval(180)
            while Date() < deadline, !delete.contains(where: \.exists) { sleep(1) }
            guard let button = delete.first(where: \.exists) else { return XCTFail("\(what): iOS didn't ask to delete the compact copy") }
            button.tap()
            let summary = app.descendants(matching: .any)["restore.summary"]
            XCTAssertTrue(summary.waitForExistence(timeout: 60), "\(what): no result")
            XCTAssertTrue(summary.label.hasPrefix("Restored"), "\(what): \(summary.label)")
            attach(app, "\(what): restored")
            app.buttons["restore.done"].tap()
        }

        // From the viewer.
        guard let item = atHome.allElementsBoundByIndex.last(where: { app.isOnScreen($0) }) else {
            return XCTFail("no item at home on screen")
        }
        item.tap()
        let action = app.buttons["item.action"]
        XCTAssertTrue(action.waitForExistence(timeout: 10) && action.label.contains("Restore Original"), action.label)
        action.tap()
        restore("viewer")
        XCTAssertTrue(app.descendants(matching: .any)["grid"].waitForExistence(timeout: 10), "didn't return to the grid")
        XCTAssertTrue(app.gridItems("Backed up").firstMatch.waitForExistence(timeout: 15), "the restored original isn't Backed up")
        let deadline = Date().addingTimeInterval(15)
        while atHome.count != before - 1, Date() < deadline { sleep(1) }
        XCTAssertEqual(atHome.count, before - 1, "the restored item is still at home only")
        guard before > 1 else { return }

        // Select mode, under Original at Home.
        app.descendants(matching: .any)["grid.filter"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let filter = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Original at Home")).firstMatch
        XCTAssertTrue(filter.waitForExistence(timeout: 5), "no Original at Home filter")
        filter.tap()
        app.buttons["select.start"].tap()
        guard let pick = atHome.allElementsBoundByIndex.last(where: { app.isOnScreen($0) }) else { return XCTFail("nothing to select") }
        pick.tap()
        let selected = app.buttons["restore.selected"]
        XCTAssertTrue(selected.waitForExistence(timeout: 5) && selected.label.contains("1"), selected.label)
        selected.tap()
        restore("selection")
        XCTAssertTrue(waitForCount(atHome, before - 2), "the selection wasn't restored")
    }

    @MainActor private func waitForCount(_ query: XCUIElementQuery, _ count: Int) -> Bool {
        let deadline = Date().addingTimeInterval(15)
        while query.count != count, Date() < deadline { sleep(1) }
        return query.count == count
    }

    /// Automatic mode (unlocked in Debug builds) backs up and compacts everything else, with
    /// nothing selected. Uses the pairing from the first test.
    @MainActor func test2AutomaticModeBacksUpTheRest() throws {
        guard ProcessInfo.processInfo.environment["HOMESPUN_SERVER"] != nil else {
            throw XCTSkip("Set HOMESPUN_SERVER and HOMESPUN_PAIRING_CODE to run against a server.")
        }
        let app = XCUIApplication()
        app.launchArguments += ["-onboardingComplete", "YES", "-hideTips"]
        app.launch()
        XCTAssertTrue(app.isConnected(), "not paired with the server")
        let remaining = app.gridItems("Not backed up")
        XCTAssertTrue(remaining.firstMatch.waitForExistence(timeout: 20), "nothing left to compact")
        let before = app.gridItems("Ready to free up").count + app.gridItems("Original at home").count

        app.openTab("Server")
        let toggle = app.automaticToggle
        // Clear of the status bar at the bottom (iPhone Duo's cover is short).
        XCTAssertTrue(app.reveal(toggle), "automatic mode isn't offered")
        // A switch's knob on an iPhone; the checkbox itself on iPhone Duo's inner display.
        if toggle.switches.firstMatch.exists { toggle.switches.firstMatch.tap() } else { toggle.tap() }
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
