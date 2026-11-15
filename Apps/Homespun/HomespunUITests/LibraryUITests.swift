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
        let first = app.gridItems("Not backed up").firstMatch
        first.tap()
        XCTAssertTrue(app.hasScreen("1 Selected", timeout: 5))
        XCTAssertEqual(selectedCells(app).count, 1, "the tapped cell doesn't show it's selected")

        // Select All selects every selectable item, including those the lazy grid hasn't loaded
        // (more of them on a smaller screen), and every cell on screen shows it.
        app.buttons["select.all"].tap()
        let title = app.descendants(matching: .any).matching(NSPredicate(format: "label MATCHES '^[0-9]+ Selected$'")).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5), "no selection count")
        XCTAssertGreaterThanOrEqual(Int(title.label.split(separator: " ")[0]) ?? 0, selectable)
        let shown = app.gridItems("Not backed up").allElementsBoundByIndex.filter(\.isHittable)
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
