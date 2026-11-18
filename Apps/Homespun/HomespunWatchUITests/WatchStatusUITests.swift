// SPDX-License-Identifier: Apache-2.0
import XCTest

final class WatchStatusUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testFreshScroll() { scroll(["-watchDemo", "fresh"], stale: false) }
    func testStaleScroll() { scroll(["-watchDemo", "stale"], stale: true) }
    func testArrivingStatusScroll() { scroll(["-watchDemo", "fresh", "-watchDemoLater"], stale: false) }

    private func scroll(_ arguments: [String], stale: Bool) {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        defer { app.terminate() }

        let prompt = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Open Homespun on your iPhone")).firstMatch
        let ready = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Ready to free up")).firstMatch
        if stale {
            XCTAssertTrue(prompt.waitForExistence(timeout: 20))
        } else {
            XCTAssertTrue(ready.waitForExistence(timeout: 20))
        }

        // Existence alone passes after XCUITest gives up waiting for a spinning app to idle.
        // Include that idle wait in every step's budget, across at least one minute refresh.
        func step(_ gesture: () -> Void) {
            let start = ProcessInfo.processInfo.systemUptime
            gesture()
            XCTAssertTrue(app.staticTexts.firstMatch.exists, "The watch stopped answering after a scroll")
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 15, "A scroll waited for a frozen app to idle")
        }

        let end = ProcessInfo.processInfo.systemUptime + 70
        var gestures = 0
        while ProcessInfo.processInfo.systemUptime < end {
            switch gestures % 4 {
            case 0: step { XCUIDevice.shared.rotateDigitalCrown(delta: 1) }
            case 1: step { app.swipeUp() }
            case 2: step { XCUIDevice.shared.rotateDigitalCrown(delta: -1) }
            default: step { app.swipeDown() }
            }
            gestures += 1
        }
        XCTAssertGreaterThanOrEqual(gestures, 6)
        step { app.swipeUp() }
        step { app.swipeUp() }
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Updated")).firstMatch.exists)
    }
}
