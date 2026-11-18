// SPDX-License-Identifier: Apache-2.0
import XCTest

/// Select mode on any library, no server needed: every cell must show it's selected, not only the title.
final class LibraryUITests: XCTestCase {
    @MainActor func testSelectAllMarksEveryCell() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-onboardingComplete", "YES", "-hideTips"]
        app.launch()
        let cells = app.gridItems()
        XCTAssertTrue(cells.firstMatch.waitForExistence(timeout: 20), "no photos in the Library")
        app.buttons["select.start"].tap()
        let selectable = app.gridItems("Not backed up").count
        XCTAssertGreaterThan(selectable, 0)

        // One tap selects one cell, and the cell itself says so.
        guard let first = app.gridItems("Not backed up").allElementsBoundByIndex.last(where: { app.isOnScreen($0) }) else {
            return XCTFail("no item on screen to select")
        }
        first.tap()
        XCTAssertTrue(app.hasScreen("1 Selected", timeout: 5))
        XCTAssertEqual(selectedCells(app).count, 1, "the tapped cell doesn't show it's selected")

        // Select All selects every selectable item, including those the lazy grid hasn't loaded
        // (more of them on a smaller screen), and every cell on screen shows it.
        app.buttons["select.all"].tap()
        let title = app.descendants(matching: .any).matching(NSPredicate(format: "label MATCHES '^[0-9]+ Selected$'")).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5), "no selection count")
        XCTAssertGreaterThanOrEqual(Int(title.label.split(separator: " ")[0]) ?? 0, selectable)
        let shown = app.gridItems("Not backed up").allElementsBoundByIndex.filter { app.isOnScreen($0) }
        XCTAssertFalse(shown.isEmpty)
        XCTAssertTrue(shown.allSatisfy(\.isSelected), "Select All didn't mark every cell")
        attach(app, "Selected all")

        // Deselect All clears the cells too.
        app.buttons["select.all"].tap()
        XCTAssertTrue(app.hasScreen("Select Items", timeout: 5))
        XCTAssertEqual(selectedCells(app).count, 0, "cells still look selected")
        app.buttons["select.done"].tap()
        XCTAssertTrue(app.buttons["select.start"].waitForExistence(timeout: 5))
    }

    /// A short filter, then a new grid size (the thumbnail preheater reloads with the short list),
    /// then All: the newest cells, far past the short list's end, used to trap the app (reports
    /// HS-UHJXHW, HS-5MX4AG: filtering and the Library tab; opening iPhone Duo, which changes the size too).
    @MainActor func testFilterThenGridSizeThenAllKeepsRunning() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-onboardingComplete", "YES", "-hideTips"]
        app.launch()
        XCTAssertTrue(app.gridItems().firstMatch.waitForExistence(timeout: 20), "no photos in the Library")
        for (filter, size) in [("Live Photos", "Small"), ("Videos", "Large"), ("Live Photos", "Medium")] {
            app.choose("grid.filter", filter)
            app.choose("grid.menu", "Grid Size")
            let sizeItem = app.buttons[size].firstMatch
            XCTAssertTrue(sizeItem.waitForExistence(timeout: 5), "no grid size \(size)")
            sizeItem.tap()
            sleep(1)
            app.choose("grid.filter", "Photos and Videos")
            app.choose("grid.filter", "All Items")
            app.openTab("Library")
            app.openTab("Library")
            sleep(2)
            XCTAssertEqual(app.state, .runningForeground, "crashed after \(filter), \(size), then All")
            XCTAssertTrue(app.gridItems().firstMatch.waitForExistence(timeout: 10), "no grid after \(filter), \(size), then All")
        }
        app.choose("grid.menu", "Grid Size")
        let medium = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Medium")).firstMatch
        if medium.waitForExistence(timeout: 3) { medium.tap() }
    }

    @MainActor private func selectedCells(_ app: XCUIApplication) -> [XCUIElement] {
        app.gridItems().allElementsBoundByIndex.filter(\.isSelected)
    }

    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
