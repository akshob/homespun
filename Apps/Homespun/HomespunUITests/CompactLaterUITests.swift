// SPDX-License-Identifier: Apache-2.0
import XCTest

/// Automatic mode backs recent items up at once and makes their compact copies only once they're
/// old enough (Server › Automatic Mode, the slider). A recent item deleted on the iPhone meanwhile
/// goes to the server's trash. Needs a fresh simulator whose library holds old synthetic media plus
/// `HOMESPUN_RECENT` items added today, and a server (`HOMESPUN_SERVER`, `HOMESPUN_PAIRING_CODE`);
/// `homespun-test/e2e-later.sh` sets this up. The tests run in order.
final class CompactLaterUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private var recent: Int? { ProcessInfo.processInfo.environment["HOMESPUN_RECENT"].flatMap(Int.init) }

    @MainActor private func launch(_ arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-onboardingComplete", "YES", "-hideTips"] + arguments
        app.launch()
        return app
    }

    @MainActor private func waitForAutomatic(_ app: XCUIApplication, until done: () -> Bool) {
        let busy = app.gridItems().matching(NSPredicate(format: "value BEGINSWITH 'Waiting' OR value BEGINSWITH 'Backing up'"))
        let progress = app.descendants(matching: .any)["job.progress"]
        let deadline = Date().addingTimeInterval(900)
        repeat { sleep(3) } while (busy.count > 0 || progress.exists || !done()) && Date() < deadline
    }

    @MainActor private func openAutomaticMode(_ app: XCUIApplication) {
        app.openTab("Server")
        let row = app.buttons["settings.automatic"]
        XCTAssertTrue(app.reveal(row), "no Automatic Mode row")
        row.tap()
        XCTAssertTrue(app.sliders["automatic.cutoff"].waitForExistence(timeout: 10), "no compact copies slider")
    }

    @MainActor func test1RecentItemsAreBackedUpAndCompactedLater() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let address = environment["HOMESPUN_SERVER"], let code = environment["HOMESPUN_PAIRING_CODE"],
              let recent else { throw XCTSkip("Run with homespun-test/e2e-later.sh.") }
        let app = launch()
        app.pair(address: address, code: code)

        // The default: compact copies after a month, with a live count.
        openAutomaticMode(app)
        let slider = app.sliders["automatic.cutoff"]
        XCTAssertEqual(slider.value as? String, "After 1 month")
        attach(app, "Automatic Mode, before")

        // Its switch is on the same page.
        app.turnOnAutomaticMode()
        app.openTab("Library")

        // Old items get compact copies; the recent ones are backed up and wait.
        let later = app.gridItems("Backed up")
        waitForAutomatic(app) { app.gridItems("Not backed up").count == 0 && later.count == recent }
        attach(app, "Library after the run")
        XCTAssertEqual(later.count, recent, "recent items not waiting for their compact copy")
        XCTAssertGreaterThan(app.gridItems("Ready to free up").count, 0, "nothing old was compacted")
        XCTAssertEqual(app.gridItems("Not backed up").count, 0)

        // The item says when its compact copy comes.
        let item = later.allElementsBoundByIndex.last { app.isOnScreen($0) } ?? later.firstMatch
        app.reveal(item)
        item.tap()
        let state = app.staticTexts["item.state"]
        XCTAssertTrue(state.waitForExistence(timeout: 10), "the item didn't open")
        XCTAssertTrue(state.label.hasPrefix("Backed up · compact copy after"), state.label)
        XCTAssertTrue(app.buttons["item.action"].label.contains("Make Compact Copy"))
        attach(app, "Backed up item")
    }

    /// Deleted on the iPhone before its compact copy: the server moves the original to its trash.
    @MainActor func test2ACleanedUpItemGoesToTheServersTrash() throws {
        guard ProcessInfo.processInfo.environment["HOMESPUN_SERVER"] != nil, let recent else {
            throw XCTSkip("Run with homespun-test/e2e-later.sh.")
        }
        let app = launch(["-deleteNewestBackedUp"])
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let confirmation = [app.alerts.buttons["Delete"], springboard.alerts.buttons["Delete"]]
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline, !confirmation.contains(where: \.exists) { sleep(1) }
        guard let delete = confirmation.first(where: \.exists) else { return XCTFail("iOS didn't ask to delete") }
        delete.tap()
        let later = app.gridItems("Backed up")
        let gone = Date().addingTimeInterval(30)
        while later.count != recent - 1, Date() < gone { sleep(1) }
        XCTAssertEqual(later.count, recent - 1)

        app.openTab("Server")
        let originals = app.buttons["settings.originals"]
        XCTAssertTrue(app.reveal(originals))
        originals.tap()
        let trash = app.descendants(matching: .any)["originals.trash"]
        XCTAssertTrue(app.scrollTo(trash), "no trash on the server")
        XCTAssertTrue(trash.label.contains("1"), trash.label)
        attach(app, "Server trash")
    }

    /// The slider moved to Right Away: the next run compacts what was waiting.
    @MainActor func test3RightAwayCompactsWhatWaited() throws {
        guard ProcessInfo.processInfo.environment["HOMESPUN_SERVER"] != nil else {
            throw XCTSkip("Run with homespun-test/e2e-later.sh.")
        }
        var app = launch()
        openAutomaticMode(app)
        let slider = app.sliders["automatic.cutoff"]
        slider.adjust(toNormalizedSliderPosition: 0)
        // The open Duo's screen coordinates are turned: drag the thumb in the slider's own
        // coordinates instead (five stops, so the thumb sits at stop / 4).
        let stops = ["Right away", "After 1 week", "After 1 month", "After 2 months", "After 3 months"]
        if let current = slider.value as? String, current != stops[0] {
            let thumb = Double(stops.firstIndex(of: current) ?? 2) / 4
            slider.coordinate(withNormalizedOffset: CGVector(dx: thumb, dy: 0.5))
                .press(forDuration: 0.2, thenDragTo: slider.coordinate(withNormalizedOffset: CGVector(dx: -0.1, dy: 0.5)))
        }
        let value = NSPredicate(format: "value == 'Right away'")
        expectation(for: value, evaluatedWith: slider)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(app.descendants(matching: .any)["automatic.cutoff.preview"].waitForExistence(timeout: 10))
        attach(app, "Automatic Mode, right away")

        // Automatic mode catches up when the app opens.
        app.terminate()
        app = launch()
        let later = app.gridItems("Backed up")
        waitForAutomatic(app) { later.count == 0 }
        attach(app, "Library, everything compacted")
        XCTAssertEqual(later.count, 0, "items still waiting for their compact copy")
        XCTAssertEqual(app.gridItems("Not backed up").count, 0)
    }

    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
