// SPDX-License-Identifier: Apache-2.0
import XCTest

/// Picks the newest items in the system photo picker and waits for their compact copies.
/// Run on a fresh simulator (its library holds only Apple's sample photos, plus any synthetic
/// media you add) with photo access granted:
/// `xcrun simctl privacy <id> grant photos photos.homespun.app.dev`.
final class OnPhoneWorkflowUITests: XCTestCase {
    @MainActor func testPickedItemsGetCompactCopies() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-useServer", "NO"]
        app.launch()
        app.buttons["Choose photos and videos"].tap()

        let grid = app.images.matching(identifier: "PXGGridLayout-Info")
        XCTAssertTrue(grid.firstMatch.waitForExistence(timeout: 20), "photo picker did not show any items")
        let count = min(4, grid.count)
        for index in 0..<count { grid.element(boundBy: index).tap() }
        app.buttons["Done"].tap()

        let rows = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH 'status.'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10), "no items were queued")
        let busy = app.staticTexts.matching(NSPredicate(format: "identifier IN {'status.waiting', 'status.working'}"))
        let deadline = Date().addingTimeInterval(900)
        while busy.count > 0 && Date() < deadline { sleep(2) }

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Results"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        XCTAssertEqual(busy.count, 0, "items still working after 15 minutes")
        XCTAssertEqual(rows.count, count)
        let failed = app.staticTexts.matching(identifier: "status.failed")
        XCTAssertEqual(failed.count, 0, failed.allElementsBoundByIndex.map(\.label).joined(separator: "; "))
        XCTAssertGreaterThan(app.staticTexts.matching(identifier: "status.saved").count, 0)
    }
}
