// SPDX-License-Identifier: Apache-2.0
import XCTest

/// A library of thousands of items (`EXTRA=3000 ci/ui.sh` adds them): opening an item
/// and swiping between items stays quick. 0.1.0 froze here on a real library (33,593 items).
final class LargeLibraryUITests: XCTestCase {
    @MainActor func testOpeningAnItemInALargeLibrary() throws {
        guard let expected = ProcessInfo.processInfo.environment["HOMESPUN_LIBRARY_SIZE"].flatMap(Int.init) else {
            throw XCTSkip("Run with EXTRA=3000 ci/ui.sh.")
        }
        let app = XCUIApplication()
        app.launchArguments += ["-onboardingComplete", "YES", "-hideTips"]
        app.launch()
        let items = app.gridItems()
        XCTAssertTrue(items.firstMatch.waitForExistence(timeout: 60), "the grid didn't load \(expected) items")
        attach(app, "Grid")

        // The newest item (the grid opens at the newest).
        let item = items.allElementsBoundByIndex.last { app.isOnScreen($0) } ?? items.firstMatch
        let opened = Date()
        item.tap()
        let state = app.staticTexts["item.state"]
        XCTAssertTrue(state.waitForExistence(timeout: 10), "the item didn't open within 10 s")
        let seconds = Date().timeIntervalSince(opened)
        print("opened in \(String(format: "%.1f", seconds)) s")
        XCTAssertLessThan(seconds, 5, "opening an item took \(seconds) s")
        attach(app, "Item")

        // Swipe back through older items.
        let viewer = app.descendants(matching: .any)["item.viewer"]
        let swiped = Date()
        for _ in 0..<12 { app.pageItem(older: true) }
        XCTAssertTrue(state.waitForExistence(timeout: 5), "the viewer stopped answering")
        print("12 swipes in \(String(format: "%.1f", Date().timeIntervalSince(swiped))) s")
        XCTAssertLessThan(Date().timeIntervalSince(swiped), 40)
        attach(app, "After 12 swipes")
        app.goBack()
        XCTAssertTrue(items.firstMatch.waitForExistence(timeout: 10), "not back in the grid")
    }

    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
