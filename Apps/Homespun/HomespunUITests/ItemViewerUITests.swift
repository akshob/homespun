// SPDX-License-Identifier: Apache-2.0
import XCTest

/// Opens items from the Library: the viewer's state line, Details, Compare (from this iPhone, and
/// downloaded from the server once the original has been freed), and swiping between items.
/// Needs a fresh simulator with synthetic media and a server (pass with a `TEST_RUNNER_` prefix):
/// `HOMESPUN_SERVER` and `HOMESPUN_PAIRING_CODE`. The tests run in order and share the pairing.
final class ItemViewerUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private var server: String? { ProcessInfo.processInfo.environment["HOMESPUN_SERVER"] }

    @MainActor private func launch(_ arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-onboardingComplete", "YES"] + arguments
        app.launch()
        return app
    }

    @MainActor func test1ViewerDetailsAndCompare() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let address = server, let code = environment["HOMESPUN_PAIRING_CODE"] else {
            throw XCTSkip("Set HOMESPUN_SERVER and HOMESPUN_PAIRING_CODE to run against a server.")
        }
        let app = launch()
        app.pair(address: address, code: code)
        if app.gridItems("Ready to free up").count < 2 { _ = app.compactNewest(2) }

        // The older of the two opens; the item before it isn't backed up.
        let ready = app.gridItems("Ready to free up")
        XCTAssertTrue(ready.firstMatch.waitForExistence(timeout: 20), "nothing ready to free up")
        ready.element(boundBy: 0).tap()
        let state = app.staticTexts["item.state"]
        XCTAssertTrue(state.waitForExistence(timeout: 10), "no state line")
        XCTAssertTrue(state.label.hasPrefix("Ready to free up · original on"), state.label)
        XCTAssertTrue(app.buttons["item.action"].label.contains("Free Up Space"))
        XCTAssertTrue(app.buttons["item.compare"].exists, "no Compare for a copy whose original is here")
        XCTAssertFalse(app.tabBars.buttons["Library"].isHittable, "the tab bar shows over the viewer")
        attach(app, "Viewer")

        // Details: where it is, and the sizes.
        app.buttons["item.details"].tap()
        XCTAssertTrue(row(app, "Original still on this iPhone").waitForExistence(timeout: 10))
        XCTAssertTrue(row(app, "Compact copy in Photos").exists)
        XCTAssertTrue(row(app, "Original on ").exists)
        XCTAssertTrue(row(app, "Original, ").waitForExistence(timeout: 10), "no sizes")
        attach(app, "Details")
        app.buttons["details.done"].tap()

        // Compare: both versions, from this iPhone; the split line moves.
        app.buttons["item.compare"].tap()
        let original = app.staticTexts["compare.original"], compact = app.staticTexts["compare.compact"]
        XCTAssertTrue(original.waitForExistence(timeout: 30), "the original didn't load")
        XCTAssertTrue(compact.waitForExistence(timeout: 30), "the compact copy didn't load")
        XCTAssertTrue(original.label.contains("on this iPhone"), original.label)
        let split = app.descendants(matching: .any)["compare.split"]
        XCTAssertEqual(split.value as? String, "Split at 50 percent")
        attach(app, "Compare")
        let start = split.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: -120, dy: 0)))
        let moved = split.value as? String ?? ""
        XCTAssertNotEqual(moved, "Split at 50 percent")
        app.descendants(matching: .any)["compare.image"].pinch(withScale: 2.5, velocity: 2)
        attach(app, "Compare, split moved and zoomed (\(moved))")
        app.buttons["Compact Copy"].tap()
        XCTAssertFalse(original.exists)
        attach(app, "Compare, compact copy")
        app.navigationBars["Compare"].buttons.firstMatch.tap()

        // Swipe back to the item before it: not backed up, with Back Up.
        XCTAssertTrue(state.waitForExistence(timeout: 5))
        let viewer = app.scrollViews["item.viewer"]
        viewer.swipeRight()
        XCTAssertTrue(waitFor(state, label: "Not backed up · only on this iPhone"), state.label)
        XCTAssertTrue(app.buttons["item.action"].label.contains("Back Up"))
        XCTAssertFalse(app.buttons["item.compare"].exists)
        attach(app, "Swiped to an item not backed up")
        viewer.swipeLeft()
        XCTAssertTrue(waitFor(state, prefix: "Ready to free up"), state.label)
        // Double-tap zooms; the state line steps aside while zoomed.
        viewer.doubleTap()
        XCTAssertTrue(state.waitForNonExistence(timeout: 5), "the state line stayed over a zoomed photo")
        attach(app, "Zoomed")
    }

    /// Frees one original from the viewer, then Compare downloads it from the server.
    @MainActor func test2CompareDownloadsAFreedOriginal() throws {
        guard server != nil else { throw XCTSkip("Set HOMESPUN_SERVER and HOMESPUN_PAIRING_CODE to run against a server.") }
        let app = launch()
        XCTAssertTrue(app.isConnected(), "not paired with the server")
        let ready = app.gridItems("Ready to free up").matching(NSPredicate(format: "label BEGINSWITH 'Photo'"))
        XCTAssertTrue(ready.firstMatch.waitForExistence(timeout: 20), "no photo ready to free up")
        ready.element(boundBy: ready.count - 1).tap()
        let state = app.staticTexts["item.state"]
        XCTAssertTrue(state.waitForExistence(timeout: 10))

        app.buttons["item.action"].tap()
        let proceed = app.buttons["remove.confirm"]
        XCTAssertTrue(proceed.waitForExistence(timeout: 10), "no Free Up Space sheet")
        XCTAssertEqual(proceed.label, "Free Up 1 Original")
        proceed.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let confirmation = [app.alerts.buttons["Delete"], springboard.alerts.buttons["Delete"]]
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline, !confirmation.contains(where: \.exists) { sleep(1) }
        guard let delete = confirmation.first(where: \.exists) else { return XCTFail("no deletion confirmation appeared") }
        delete.tap()
        XCTAssertTrue(app.staticTexts["remove.summary"].waitForExistence(timeout: 60))
        let done = [app.buttons["trial.confirm"], app.buttons["remove.dismiss"]]
        XCTAssertTrue(done[0].waitForExistence(timeout: 5) || done[1].exists)
        done.first(where: \.exists)?.tap()

        // The same item now has its original only at home.
        XCTAssertTrue(waitFor(state, prefix: "Original at home · on"), state.label)
        XCTAssertFalse(app.buttons["item.action"].exists, "an action for an item already freed")
        attach(app, "Viewer, original at home")
        app.buttons["item.details"].tap()
        XCTAssertTrue(row(app, "Not on this iPhone").waitForExistence(timeout: 10))
        attach(app, "Details, original at home")
        app.buttons["details.done"].tap()

        app.buttons["item.compare"].tap()
        let original = app.staticTexts["compare.original"]
        XCTAssertTrue(original.waitForExistence(timeout: 60), "the original didn't download")
        XCTAssertTrue(original.label.contains("from "), original.label)
        XCTAssertTrue(app.staticTexts["compare.compact"].exists)
        let facts = app.staticTexts["compare.originalFacts"]
        XCTAssertTrue(facts.label.contains("MB") || facts.label.contains("KB"), facts.label)
        attach(app, "Compare, original from the server")
        app.navigationBars["Compare"].buttons.firstMatch.tap()
        XCTAssertTrue(state.waitForExistence(timeout: 5))
    }

    /// The viewer, Details and Compare in whatever appearance the simulator has, for review; and
    /// Details' Couldn't back up and Kept as is variants (Debug's `-itemDemoState`).
    @MainActor func test3ScreensForReview() throws {
        guard server != nil else { throw XCTSkip("Set HOMESPUN_SERVER and HOMESPUN_PAIRING_CODE to run against a server.") }
        var app = launch()
        let atHome = app.gridItems("Original at home")
        XCTAssertTrue(atHome.firstMatch.waitForExistence(timeout: 20), "nothing at home; run test2 first")
        // Each item at home (a photo and a video after test2), its Details, and Compare.
        for index in 0..<min(atHome.count, 2) {
            atHome.element(boundBy: index).tap()
            XCTAssertTrue(app.staticTexts["item.state"].waitForExistence(timeout: 10))
            sleep(1)
            attach(app, "Review: viewer \(index)")
            app.buttons["item.details"].tap()
            XCTAssertTrue(row(app, "Compact copy in Photos").waitForExistence(timeout: 10))
            sleep(1)
            attach(app, "Review: details \(index)")
            app.buttons["details.done"].tap()
            app.buttons["item.compare"].tap()
            let facts = app.staticTexts["compare.originalFacts"]
            XCTAssertTrue(facts.waitForExistence(timeout: 10))
            let downloaded = NSPredicate(format: "label CONTAINS 'MB' OR label CONTAINS 'kB'")
            expectation(for: downloaded, evaluatedWith: facts)
            waitForExpectations(timeout: 60)
            sleep(1)
            attach(app, "Review: compare \(index)")
            app.navigationBars["Compare"].buttons.firstMatch.tap()
            app.navigationBars.buttons.firstMatch.tap()
        }
        for demo in ["failed", "kept"] {
            app.terminate()
            app = launch(["-itemDemoState", demo])
            // The demo state shows in the viewer only; the grid still says Not backed up.
            let item = app.gridItems("Not backed up")
            XCTAssertTrue(item.firstMatch.waitForExistence(timeout: 20), "no \(demo) item")
            item.firstMatch.tap()
            XCTAssertTrue(app.staticTexts["item.state"].waitForExistence(timeout: 10))
            attach(app, "Review: viewer, \(demo)")
            app.buttons["item.details"].tap()
            XCTAssertTrue(app.descendants(matching: .any)["details.problem"].waitForExistence(timeout: 10))
            if demo == "failed" {
                XCTAssertTrue(app.buttons["details.tryAgain"].exists)
                XCTAssertTrue(app.buttons["details.keep"].exists)
            }
            attach(app, "Review: details, \(demo)")
        }
    }

    /// A Details row, read as one element: its title, then its detail.
    @MainActor private func row(_ app: XCUIApplication, _ start: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", start)).firstMatch
    }

    @MainActor private func waitFor(_ element: XCUIElement, label: String? = nil, prefix: String? = nil,
                                    timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists, label.map({ element.label == $0 }) ?? true, prefix.map({ element.label.hasPrefix($0) }) ?? true {
                return true
            }
            usleep(250_000)
        }
        return false
    }

    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
