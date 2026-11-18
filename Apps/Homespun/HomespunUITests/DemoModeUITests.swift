// SPDX-License-Identifier: Apache-2.0
import XCTest

/// Try the Demo, from a fresh install and with no server: Welcome's Try the Demo,
/// the pretend server found and paired, a few samples backed up and their compact copies, one opened and
/// compared, Free Up Space (compare, keep one original, free the rest, with the demo's own question),
/// Restore Original, Activity's runs, Automatic Mode turned on, then Leave the Demo back to Welcome, and
/// the demo starting afresh.
/// iOS never asks for anything (no Photos access, no Local Network). And without the purchase, turning on
/// Automatic Mode or Cloud Copies in the demo asks for the real one. Screenshots are attached.
final class DemoModeUITests: XCTestCase {
    private var app: XCUIApplication!
    @MainActor private var springboard: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.springboard") }

    @MainActor func testDemoFromWelcomeToLeaving() throws {
        app = XCUIApplication()
        app.launchArguments += ["-hideTips", "-resetDemo"]
        app.launch()

        // Welcome: Try the Demo, beside the ways to set up a real server.
        let demo = app.buttons["setup.demo"]
        XCTAssertTrue(demo.waitForExistence(timeout: 20), "no Try the Demo on Welcome")
        XCTAssertTrue(app.buttons["setup.find"].exists, "no Find My Home Computer beside it")
        attach("Welcome")
        demo.tap()
        waitForPreparing()

        // The pretend server appears as if found on the Wi‑Fi, and pairs by itself.
        pairWithDemo()
        let choose = app.buttons["estimate.choose"]
        XCTAssertTrue(choose.waitForExistence(timeout: 30), "no estimate of the sample photos")
        nothingAsked("setup")
        attach("Estimate")
        choose.tap()

        // The Library, in Select mode on what isn't backed up: the samples only (never this iPhone's photos).
        XCTAssertTrue(app.buttons["select.done"].waitForExistence(timeout: 20), "the Library didn't open in Select mode")
        let notBackedUp = app.gridItems("Not backed up")
        XCTAssertTrue(notBackedUp.firstMatch.waitForExistence(timeout: 20), "no samples")
        attach("Library")
        let chosen = notBackedUp.allElementsBoundByIndex.filter { app.isOnScreen($0) }.suffix(5)
        XCTAssertEqual(chosen.count, 5, "fewer than 5 samples on screen")
        for item in chosen { item.tap() }
        XCTAssertTrue(app.hasScreen("5 Selected", timeout: 5), "selection count")
        app.buttons["compact.selected"].tap()
        attach("Backing up")
        waitForBackups()
        // The Library was showing what isn't backed up: all of it now, compact copies in their originals' places.
        showAllItems()
        let ready = app.gridItems("Ready to free up")
        let copies = Date().addingTimeInterval(20)
        while ready.count < 5, Date() < copies { sleep(1) }
        XCTAssertEqual(ready.count, 5, "not every sample got its compact copy")
        attach("Compact copies")

        // A compact copy, open, and compared with its original from the pretend server.
        guard let copy = ready.allElementsBoundByIndex.last(where: { app.isOnScreen($0) }) else { return XCTFail("no copy on screen") }
        copy.tap()
        let compare = app.buttons["item.compare"]
        XCTAssertTrue(compare.waitForExistence(timeout: 10), "no Compare in the viewer")
        attach("Viewer")
        app.buttons["item.details"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["details.list"].waitForExistence(timeout: 10), "no Details")
        attach("Details")
        app.buttons["details.done"].tap()
        compare.tap()
        XCTAssertTrue(app.descendants(matching: .any)["compare.compact"].firstMatch.waitForExistence(timeout: 30), "no Compare")
        XCTAssertTrue(app.descendants(matching: .any)["compare.original"].firstMatch.waitForExistence(timeout: 30),
                      "no original to compare with")
        attach("Compare")
        app.goBack()
        app.goBack()
        XCTAssertTrue(app.descendants(matching: .any)["grid"].waitForExistence(timeout: 10), "didn't return to the grid")

        // Free Up Space: it says nothing is deleted; compare, keep one original, free the rest.
        let offer = app.descendants(matching: .any)["offer.free"]
        XCTAssertTrue(offer.waitForExistence(timeout: 20), "no offer to free up space")
        offer.tap()
        let proceed = app.buttons["remove.confirm"]
        XCTAssertTrue(proceed.waitForExistence(timeout: 10), "no Free Up Space")
        XCTAssertTrue(app.descendants(matching: .any)["remove.demo"].firstMatch.exists, "Free Up Space doesn't say it's pretend")
        attach("Free Up Space")
        let pairCompare = app.buttons["remove.compare"].firstMatch
        XCTAssertTrue(pairCompare.waitForExistence(timeout: 5), "no compact copies to compare")
        let before = proceed.label
        var lifts = 4
        while pairCompare.frame.maxY > app.frame.maxY - 200, lifts > 0 { app.swipeUpInContent(); lifts -= 1 }
        pairCompare.tap()
        let keep = app.buttons["remove.keepOriginal"]
        XCTAssertTrue(keep.waitForExistence(timeout: 30), "no Keep Original under Compare")
        attach("Compare before freeing up")
        keep.tap()
        answerDemoQuestion("keep original")
        XCTAssertTrue(proceed.waitForExistence(timeout: 20), "didn't go back to the review after Keep Original")
        let kept = Date().addingTimeInterval(15)
        while proceed.label == before, Date() < kept { sleep(1) }
        XCTAssertNotEqual(proceed.label, before, "the kept original is still offered")
        proceed.tap()
        answerDemoQuestion("free up")
        let summary = app.staticTexts["remove.summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 60), "no result")
        XCTAssertTrue(summary.label.contains("Freed"), summary.label)
        attach("Freed")
        app.buttons["remove.dismiss"].tap()
        let atHome = app.gridItems("Original at home")
        XCTAssertTrue(atHome.firstMatch.waitForExistence(timeout: 15), "no originals at home")
        XCTAssertEqual(atHome.count, 4, "the freed originals")
        XCTAssertTrue(app.gridItems("Backed up").firstMatch.exists, "the kept original isn't Backed up")

        // A freed original compares from the pretend server, and comes back with Restore Original.
        guard let freed = atHome.allElementsBoundByIndex.last(where: { app.isOnScreen($0) }) else { return XCTFail("none on screen") }
        freed.tap()
        XCTAssertTrue(compare.waitForExistence(timeout: 10), "no Compare for a freed original")
        compare.tap()
        let fromServer = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'compare.original' AND label CONTAINS 'Homespun Demo'")).firstMatch
        XCTAssertTrue(fromServer.waitForExistence(timeout: 30), "the original didn't come from the pretend server")
        attach("Compare with the original at home")
        app.goBack()
        let action = app.buttons["item.action"]
        XCTAssertTrue(action.waitForExistence(timeout: 10) && action.label.contains("Restore Original"), action.label)
        action.tap()
        let restore = app.buttons["restore.confirm"]
        XCTAssertTrue(restore.waitForExistence(timeout: 20), "no Restore Original")
        attach("Restore Original")
        restore.tap()
        answerDemoQuestion("restore")
        let restored = app.descendants(matching: .any)["restore.summary"]
        XCTAssertTrue(restored.waitForExistence(timeout: 60), "no restore result")
        XCTAssertTrue(restored.label.hasPrefix("Restored"), restored.label)
        attach("Restored")
        app.buttons["restore.done"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["grid"].waitForExistence(timeout: 10), "didn't return to the grid")
        let back = Date().addingTimeInterval(15)
        while atHome.count != 3, Date() < back { sleep(1) }
        XCTAssertEqual(atHome.count, 3, "the restored original is still at home only")

        // Activity: the backup run, and the space freed.
        app.openTab("Activity")
        let runs = app.descendants(matching: .any).matching(identifier: "activity.run")
        XCTAssertTrue(runs.firstMatch.waitForExistence(timeout: 20), "no runs in Activity")
        XCTAssertGreaterThanOrEqual(runs.count, 2, "Activity doesn't show the backup and the space freed")
        attach("Activity")

        app.openTab("Server")
        let card = app.descendants(matching: .any)["demo.card"]
        XCTAssertTrue(card.waitForExistence(timeout: 15), "the Server tab doesn't say it's the demo")
        attach("Server")

        // Automatic Mode (unlocked in a build from Xcode): on for everything not backed up, and it starts
        // at once, asking iOS nothing (no notifications, no background tasks in the demo).
        app.openAutomaticMode()
        app.tapSwitch(app.automaticToggle)
        let everything = app.buttons["Everything not backed up yet"].firstMatch
        XCTAssertTrue(everything.waitForExistence(timeout: 10), "turning on Automatic Mode didn't ask what to back up")
        everything.tap()
        let on = Date().addingTimeInterval(10)
        while app.automaticToggle.value as? String != "1", Date() < on { usleep(250_000) }
        XCTAssertEqual(app.automaticToggle.value as? String, "1", "Automatic Mode didn't turn on")
        attach("Automatic Mode")
        nothingAsked("tabs")
        app.goBack(from: "Automatic Mode")

        // Leave the Demo, perhaps while Automatic Mode is backing up: back to Welcome.
        let leaveButton = app.buttons["demo.leave"].firstMatch
        XCTAssertTrue(app.reveal(leaveButton), "no Leave the Demo in the Server tab")
        leave(leaveButton)
        XCTAssertTrue(app.buttons["setup.demo"].waitForExistence(timeout: 20), "Leave the Demo didn't return to Welcome")
        attach("Left")

        // Nothing was left: the demo starts afresh (its pretend server isn't paired), and leaving from setup works.
        let again = app.buttons["setup.demo"]
        XCTAssertTrue(again.wait(for: \.isEnabled, toEqual: true, timeout: 15), "Try the Demo stays off after leaving")
        again.tap()
        XCTAssertFalse(app.descendants(matching: .any)["demo.prepare"].waitForExistence(timeout: 2), "drawn again after leaving")
        XCTAssertTrue(app.buttons["found.use"].waitForExistence(timeout: 30), "the demo didn't start afresh")
        let menu = app.buttons["demo.menu"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "no Demo mark in setup")
        menu.tap()
        leave(app.buttons["demo.leave"].firstMatch)
        XCTAssertTrue(app.buttons["setup.demo"].waitForExistence(timeout: 20), "leaving from setup didn't return to Welcome")

        // And it stays left when Homespun opens again.
        app.terminate()
        app.launchArguments = ["-hideTips"]
        app.launch()
        XCTAssertTrue(app.buttons["setup.find"].waitForExistence(timeout: 20), "not at Welcome after leaving")
        XCTAssertFalse(app.buttons["demo.menu"].exists, "still in the demo")
    }

    /// The purchase in the demo is the real one: without it (`-premiumLocked YES`), turning on Automatic
    /// Mode or signing in to a cloud service asks for it, as in the person's own Homespun; Close leaves it off.
    @MainActor func testTurningOnAsksForThePurchaseInTheDemo() throws {
        app = XCUIApplication()
        app.launchArguments += ["-hideTips", "-resetDemo", "-premiumLocked", "YES"]
        app.launch()
        let demo = app.buttons["setup.demo"]
        XCTAssertTrue(demo.waitForExistence(timeout: 20), "no Try the Demo on Welcome")
        demo.tap()
        waitForPreparing()
        pairWithDemo()
        let notNow = app.buttons["estimate.notNow"]
        XCTAssertTrue(notNow.waitForExistence(timeout: 30), "no estimate of the sample photos")
        notNow.tap()

        app.openAutomaticMode()
        let toggle = app.automaticToggle
        XCTAssertEqual(toggle.value as? String, "0")
        app.tapSwitch(toggle)
        expectUnlockSheet("Turn On Automatic Mode")
        XCTAssertEqual(toggle.value as? String, "0", "on without the purchase")
        app.goBack(from: "Automatic Mode")

        let cloud = app.buttons["settings.connectors"]
        XCTAssertTrue(app.reveal(cloud), "no Cloud Copies row")
        cloud.tap()
        let oneDrive = app.buttons["connector.onedrive"]
        XCTAssertTrue(oneDrive.waitForExistence(timeout: 15), "no OneDrive on the Cloud Copies page")
        oneDrive.tap()
        let signIn = app.buttons["connector.signIn"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 10), "no Sign In")
        signIn.tap()
        expectUnlockSheet("Turn On Cloud Copies")
        nothingAsked("unlock")

        app.goBack(from: "OneDrive")
        app.goBack(from: "Cloud Copies")
        let leaveButton = app.buttons["demo.leave"].firstMatch
        XCTAssertTrue(app.reveal(leaveButton), "no Leave the Demo in the Server tab")
        leave(leaveButton)
        XCTAssertTrue(app.buttons["setup.demo"].waitForExistence(timeout: 20), "Leave the Demo didn't return to Welcome")
    }

    @MainActor func testPreparingTheDemoKeepsItsPhotos() throws {
        app = XCUIApplication()
        app.launchArguments = ["-hideTips", "-resetDemo", "-demoPrepareMinimum", "3"]
        app.launch()
        let demo = app.buttons["setup.demo"], preparing = app.descendants(matching: .any)["demo.prepare"]
        XCTAssertTrue(demo.waitForExistence(timeout: 20))
        demo.tap()
        XCTAssertTrue(preparing.waitForExistence(timeout: 5), "no loading screen")
        let progress = app.progressIndicators["demo.prepare.progress"]
        XCTAssertTrue(progress.exists)
        XCTAssertNotNil(progress.value, "the progress bar has no accessible value")
        XCTAssertEqual(app.buttons["demo.prepare.cancel"].label, "Cancel")
        attach("Preparing")
        app.buttons["demo.prepare.cancel"].tap()
        XCTAssertTrue(preparing.waitForNonExistence(timeout: 10))
        XCTAssertTrue(demo.exists && demo.isEnabled, "Cancel didn't return to Welcome")
        XCTAssertFalse(app.buttons["demo.menu"].exists, "Cancel started the demo")

        demo.tap()
        waitForPreparing()
        pairWithDemo()
        let estimate = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "demo's 30 sample")).firstMatch
        XCTAssertTrue(estimate.waitForExistence(timeout: 30), "the estimate isn't for 30 samples")
        app.buttons["estimate.notNow"].tap()
        app.openTab("Library")
        let subtitle = app.staticTexts.containing(NSPredicate(format: "label CONTAINS '30 not backed up'")).firstMatch
        XCTAssertTrue(subtitle.waitForExistence(timeout: 20))
        XCTAssertTrue(app.gridItems().firstMatch.waitForExistence(timeout: 20))

        XCUIDevice.shared.press(.home)
        sleep(3)
        app.activate()
        XCTAssertFalse(preparing.waitForExistence(timeout: 3), "backgrounding discarded the media")
        XCTAssertTrue(subtitle.exists && app.gridItems().firstMatch.exists, "backgrounding lost the sample library")
        attach("Back from the background")

        app.openTab("Server")
        let leaveButton = app.buttons["demo.leave"].firstMatch
        XCTAssertTrue(app.reveal(leaveButton))
        leave(leaveButton)
        XCTAssertTrue(demo.waitForExistence(timeout: 20))
        XCTAssertTrue(demo.wait(for: \.isEnabled, toEqual: true, timeout: 15))
        demo.tap()
        XCTAssertFalse(preparing.waitForExistence(timeout: 2), "leaving discarded the media")
        XCTAssertTrue(app.buttons["found.use"].waitForExistence(timeout: 30))

        app.terminate()
        app.launchArguments = ["-hideTips", "-demoPrepareMinimum", "3"]
        app.launch()
        XCTAssertTrue(preparing.waitForExistence(timeout: 10), "a cold launch didn't draw the media again")
        XCTAssertEqual(app.buttons["demo.prepare.cancel"].label, "Leave the Demo")
        waitForPreparing()
        let menu = app.buttons["demo.menu"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 30), "the demo didn't resume")
        menu.tap()
        leave(app.buttons["demo.leave"].firstMatch)
        XCTAssertTrue(demo.waitForExistence(timeout: 20), "leaving the resumed demo didn't return to Welcome")
    }

    // MARK: Steps

    /// The launch's first demo draws its photos before setup continues.
    @MainActor private func waitForPreparing(timeout: TimeInterval = 180) {
        let preparing = app.descendants(matching: .any)["demo.prepare"]
        if preparing.waitForExistence(timeout: 3) {
            XCTAssertTrue(preparing.waitForNonExistence(timeout: timeout), "the demo's photos weren't drawn in \(Int(timeout)) s")
        }
    }

    /// The purchase sheet (the real StoreKit product): buy, restore, that one purchase unlocks both; then Close.
    @MainActor private func expectUnlockSheet(_ title: String, file: StaticString = #filePath, line: UInt = #line) {
        let buy = app.buttons["unlock.buy"]
        XCTAssertTrue(buy.waitForExistence(timeout: 10), "turning it on didn't ask for the purchase", file: file, line: line)
        XCTAssertTrue(app.staticTexts[title].exists, "no \(title)", file: file, line: line)
        XCTAssertTrue(app.staticTexts["unlock.both"].exists, file: file, line: line)
        XCTAssertTrue(app.buttons["unlock.restore"].exists, "no Restore Purchase", file: file, line: line)
        attach(title)
        app.buttons["unlock.close"].tap()
        XCTAssertTrue(buy.waitForNonExistence(timeout: 10), "the sheet didn't close", file: file, line: line)
    }

    @MainActor private func pairWithDemo() {
        let use = app.buttons["found.use"]
        XCTAssertTrue(use.waitForExistence(timeout: 30), "Homespun Demo wasn't found")
        attach("Found")
        use.tap()
        XCTAssertTrue(app.staticTexts["pair.demo"].waitForExistence(timeout: 15), "the pairing page doesn't say it's pretend")
        attach("Pairing")
        let ready = app.buttons["ready.continue"]
        XCTAssertTrue(ready.waitForExistence(timeout: 30), "not paired with Homespun Demo")
        attach("Paired")
        ready.tap()
    }

    /// Waits until no sample is waiting or backing up.
    @MainActor private func waitForBackups() {
        let busy = app.gridItems().matching(NSPredicate(format: "value IN {'Waiting', 'Backing up'}"))
        let progress = app.descendants(matching: .any)["job.progress"]
        let deadline = Date().addingTimeInterval(300)
        repeat { sleep(2) } while (busy.count > 0 || progress.exists) && Date() < deadline
        XCTAssertEqual(busy.count, 0, "samples still backing up after 5 minutes")
    }

    @MainActor private func showAllItems() {
        app.descendants(matching: .any)["grid.filter"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let all = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "All Items")).firstMatch
        XCTAssertTrue(all.waitForExistence(timeout: 5), "no All Items in the filter")
        all.tap()
        let closed = Date().addingTimeInterval(10)
        while all.exists, Date() < closed { sleep(1) }
    }

    /// The demo's stand-in for iOS's question before deleting: it says nothing is deleted. Delete.
    @MainActor private func answerDemoQuestion(_ what: String) {
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 60), "\(what): no question before deleting")
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS 'nothing is deleted'")).firstMatch.exists,
                      "\(what): the question doesn't say it's pretend")
        attach("Question: \(what)")
        alert.buttons["Delete"].tap()
    }

    @MainActor private func leave(_ button: XCUIElement) {
        XCTAssertTrue(button.waitForExistence(timeout: 10), "no Leave the Demo")
        button.tap()
        let confirm = app.buttons["demo.leave.confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "no confirmation to leave")
        confirm.tap()
    }

    /// iOS asked nothing (Photos, Local Network, notifications): the demo needs none of it.
    @MainActor private func nothingAsked(_ when: String) {
        XCTAssertFalse(springboard.alerts.firstMatch.exists, "iOS asked something in the demo (\(when))")
    }

    @MainActor private func attach(_ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
