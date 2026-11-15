// SPDX-License-Identifier: Apache-2.0
import XCTest

/// Steps shared by the workflow tests: pair, select in the Library, back up, and check Activity.
extension XCUIApplication {
    /// Pairs with the server at `address` using a code from `homespun-server pair`, unless
    /// already paired, and waits until it's connected. Goes through setup from the Library's Set Up
    /// notice: Connect Another Way › Enter Address and Code, then Ready, and Not Now on the estimate.
    @MainActor func pair(address: String, code: String, file: StaticString = #filePath, line: UInt = #line) {
        let connect = buttons["connect.open"]
        if connect.waitForExistence(timeout: 5) {
            connect.tap()
            // The Local Network promises come once, then setup looks on the Wi‑Fi. Every page after
            // that (still looking, a server found, the question) offers Connect Another Way.
            let promises = buttons["network.continue"]
            if promises.waitForExistence(timeout: 5) { promises.tap() }
            let other = buttons["setup.otherWays"].firstMatch
            let enter = buttons["other.address"]
            let deadline = Date().addingTimeInterval(30)
            while !enter.exists, Date() < deadline {
                if other.exists, other.isHittable { other.tap() }
                _ = enter.waitForExistence(timeout: 2)
            }
            XCTAssertTrue(enter.exists, "no way to enter an address", file: file, line: line)
            enter.tap()
            let addressField = textFields["server.address"]
            XCTAssertTrue(addressField.waitForExistence(timeout: 10), file: file, line: line)
            // Both fields are kept from an earlier try (L6); empty ones show their placeholders.
            func replace(_ field: XCUIElement, placeholder: String, with text: String) {
                // At the end of what's there, so deleting removes all of it.
                field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
                if let kept = field.value as? String, !kept.isEmpty, kept != placeholder {
                    field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: kept.count))
                }
                field.typeText(text)
            }
            replace(addressField, placeholder: "192.168.1.20:8787", with: address)
            replace(textFields["pair.code"], placeholder: "XXXX-XXXX", with: code)
            buttons["pair.submit"].tap()
            let ready = buttons["ready.continue"]
            XCTAssertTrue(ready.waitForExistence(timeout: 30), "not paired with \(address)", file: file, line: line)
            ready.tap()
            let photos = buttons["photos.continue"]
            if photos.waitForExistence(timeout: 3) {
                photos.tap()
                let full = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow Full Access"].firstMatch
                if full.waitForExistence(timeout: 10) { full.tap() }
            }
            // The estimate before the first task; with nothing to back up, setup ends by itself.
            let notNow = buttons["estimate.notNow"]
            if notNow.waitForExistence(timeout: 30) { notNow.tap() }
        }
        XCTAssertTrue(isConnected(), "server not reachable", file: file, line: line)
    }

    /// Opens a tab by its title.
    @MainActor func openTab(_ title: String) {
        let tab = tabBars.buttons[title]
        if tab.waitForExistence(timeout: 10) { tab.tap() }
    }

    /// Scrolls the current screen until the element exists (lists load rows lazily).
    @MainActor @discardableResult func scrollTo(_ element: XCUIElement, swipes: Int = 8) -> Bool {
        var left = swipes
        while !element.exists, left > 0 {
            swipeUp()
            left -= 1
        }
        return element.waitForExistence(timeout: 2)
    }

    /// Whether the Server tab says the server is connected (waits a little), back on Library.
    @MainActor func isConnected(timeout: TimeInterval = 20) -> Bool {
        openTab("Server")
        let status = descendants(matching: .any)["server.status"]
        let connected = NSPredicate(format: "label CONTAINS 'Connected' OR value CONTAINS 'Connected'")
        let deadline = Date().addingTimeInterval(timeout)
        var ok = false
        while Date() < deadline {
            if status.exists, connected.evaluate(with: status) { ok = true; break }
            sleep(1)
        }
        openTab("Library")
        return ok
    }

    /// Grid items, optionally only those with this badge (`Badge.label` in the app).
    func gridItems(_ badge: String? = nil) -> XCUIElementQuery {
        let predicate = badge.map { NSPredicate(format: "identifier == 'asset' AND value BEGINSWITH %@", $0) }
            ?? NSPredicate(format: "identifier == 'asset'")
        return descendants(matching: .any).matching(predicate)
    }

    /// Selects the newest `count` items that aren't backed up, compacts them, and waits until
    /// done. Returns how many were selected.
    @MainActor func compactNewest(_ count: Int, file: StaticString = #filePath, line: UInt = #line) -> Int {
        let candidates = gridItems("Not backed up")
        XCTAssertTrue(candidates.firstMatch.waitForExistence(timeout: 20), "the grid shows nothing to compact",
                      file: file, line: line)
        buttons["select.start"].tap()
        let all = candidates.allElementsBoundByIndex
        let chosen = Array(all.suffix(min(count, all.count)))
        for item in chosen { item.tap() }
        XCTAssertTrue(navigationBars["\(chosen.count) Selected"].waitForExistence(timeout: 5), "selection count",
                      file: file, line: line)
        buttons["compact.selected"].tap()

        let busy = gridItems().matching(NSPredicate(format: "value IN {'Waiting', 'Backing up'}"))
        let progress = descendants(matching: .any)["job.progress"]
        let deadline = Date().addingTimeInterval(900)
        repeat { sleep(2) } while (busy.count > 0 || progress.exists) && Date() < deadline
        XCTAssertEqual(busy.count, 0, "items still working after 15 minutes", file: file, line: line)
        return chosen.count
    }

    /// Opens Activity and checks every item finished without failing. Returns the statuses.
    @MainActor func checkActivity(file: StaticString = #filePath, line: UInt = #line) -> [String] {
        openTab("Activity")
        let rows = staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH 'status.'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10), "no items in Activity", file: file, line: line)
        let failed = staticTexts.matching(identifier: "status.failed")
        XCTAssertEqual(failed.count, 0, failed.allElementsBoundByIndex.map(\.label).joined(separator: "; "),
                       file: file, line: line)
        let statuses = rows.allElementsBoundByIndex.map(\.identifier)
        openTab("Library")
        return statuses
    }
}
