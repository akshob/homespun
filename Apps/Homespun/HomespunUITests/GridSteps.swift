// SPDX-License-Identifier: Apache-2.0
import XCTest

/// Steps shared by the workflow tests: select in Homespun's library grid, compact, and check.
extension XCUIApplication {
    /// Pairs with the server at `address` using a code from `homespun-server pair`, unless
    /// already paired, and waits until it's connected.
    @MainActor func pair(address: String, code: String, file: StaticString = #filePath, line: UInt = #line) {
        let connect = buttons["connect.open"]
        if connect.waitForExistence(timeout: 5) {
            connect.tap()
            let addressField = textFields["server.address"]
            XCTAssertTrue(addressField.waitForExistence(timeout: 10), file: file, line: line)
            addressField.tap()
            addressField.typeText(address)
            buttons["server.continue"].tap()
            let codeField = textFields["pair.code"]
            XCTAssertTrue(codeField.waitForExistence(timeout: 15), "no pairing screen for \(address)", file: file, line: line)
            codeField.tap()
            codeField.typeText(code)
            buttons["pair.submit"].tap()
        }
        if !buttons["server.card"].waitForExistence(timeout: 20) {
            XCTFail("pairing failed: \(staticTexts["pair.error"].label)", file: file, line: line)
        }
        XCTAssertTrue(staticTexts["Connected"].waitForExistence(timeout: 15), "server not reachable", file: file, line: line)
    }

    /// Grid items, optionally only those with this badge (`Badge.label` in the app).
    func gridItems(_ badge: String? = nil) -> XCUIElementQuery {
        let predicate = badge.map { NSPredicate(format: "identifier == 'asset' AND value == %@", $0) }
            ?? NSPredicate(format: "identifier == 'asset'")
        return descendants(matching: .any).matching(predicate)
    }

    /// Selects the newest `count` items that aren't backed up, compacts them, and waits until
    /// done. Returns how many were selected.
    @MainActor func compactNewest(_ count: Int, file: StaticString = #filePath, line: UInt = #line) -> Int {
        let candidates = gridItems("Not backed up")
        XCTAssertTrue(candidates.firstMatch.waitForExistence(timeout: 20), "the grid shows nothing to compact",
                      file: file, line: line)
        let all = candidates.allElementsBoundByIndex
        let chosen = Array(all.suffix(min(count, all.count)))
        for item in chosen { item.tap() }
        XCTAssertEqual(staticTexts["selection.count"].label, "\(chosen.count) selected", file: file, line: line)
        buttons["compact.selected"].tap()

        let busy = gridItems().matching(NSPredicate(format: "value IN {'Waiting', 'Working'}"))
        let deadline = Date().addingTimeInterval(900)
        repeat { sleep(2) } while (busy.count > 0 || buttons["job.progress"].exists) && Date() < deadline
        XCTAssertEqual(busy.count, 0, "items still working after 15 minutes", file: file, line: line)
        return chosen.count
    }

    /// Opens Activity and checks every item finished without failing. Returns the statuses.
    @MainActor func checkActivity(file: StaticString = #filePath, line: UInt = #line) -> [String] {
        buttons["activity.open"].tap()
        let rows = staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH 'status.'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10), "no items in Activity", file: file, line: line)
        let failed = staticTexts.matching(identifier: "status.failed")
        XCTAssertEqual(failed.count, 0, failed.allElementsBoundByIndex.map(\.label).joined(separator: "; "),
                       file: file, line: line)
        let statuses = rows.allElementsBoundByIndex.map(\.identifier)
        buttons["Done"].tap()
        return statuses
    }
}
