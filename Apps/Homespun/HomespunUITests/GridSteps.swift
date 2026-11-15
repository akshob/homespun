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
    /// Scrolling down minimises the tab bar (the Library opens at the newest items), so a tab
    /// may need a scroll up before it can be tapped; tries a few times until it's selected.
    /// A tab: in the tab bar (iPhone), or in iPhone Duo's vertical bar strip, where it's a radio
    /// button on the inner display and a plain button on the cover.
    @MainActor func tab(_ title: String) -> XCUIElement {
        let strip = buttons.matching(NSPredicate(format: "identifier == %@ OR (label == %@ AND identifier BEGINSWITH 'tab.')",
                                                 "tab." + title.lowercased(), title)).firstMatch
        for candidate in [tabBars.buttons[title], radioButtons[title], strip] where candidate.exists { return candidate }
        return tabBars.buttons[title]
    }

    /// Waits for a tab, wherever the device puts tabs.
    @MainActor func hasTab(_ title: String, timeout: TimeInterval = 15) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if tab(title).exists { return true }
            usleep(250_000)
        } while Date() < deadline
        return false
    }

    /// A screen's title: a navigation bar on an iPhone; on iPhone Duo, where bar items move to the
    /// strip, a header with the title as its label.
    @MainActor func screenTitle(_ title: String) -> XCUIElement {
        let bar = navigationBars.matching(NSPredicate(format: "identifier ==[c] %@", title)).firstMatch
        if bar.exists { return bar }
        let header = descendants(matching: .any).matching(NSPredicate(format: "label ==[c] %@ AND elementType != %d",
                                                                      title, XCUIElement.ElementType.button.rawValue)).firstMatch
        return header.exists ? header : bar
    }

    /// Waits for a screen's title, wherever the device shows it.
    @MainActor func hasScreen(_ title: String, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if screenTitle(title).exists { return true }
            usleep(250_000)
        } while Date() < deadline
        return false
    }

    /// Goes back one screen: the navigation bar's Back on an iPhone, the strip's on iPhone Duo. On the
    /// open Duo's right page a page opened from the left has no Back (the left page is still there),
    /// so this does nothing.
    @MainActor func goBack(from title: String? = nil) {
        let bar = title.map { screenTitle($0) }.flatMap { $0.elementType == .navigationBar ? $0 : nil }
            ?? navigationBars.firstMatch
        let inBar = bar.buttons.firstMatch
        let strip = descendants(matching: .any)["BackButton"]
        if strip.exists, strip.isHittable { strip.tap() } else if inBar.exists, inBar.isHittable { inBar.tap() }
    }

    /// The automatic mode control: a switch on an iPhone, a checkbox on iPhone Duo's inner display.
    @MainActor var automaticToggle: XCUIElement { descendants(matching: .any)["automatic.toggle"] }

    /// The open Duo shows the Library as a book: what you open goes to the right page.
    @MainActor var isBook: Bool { descendants(matching: .any)["library.page"].exists }

    /// On iPhone Duo the tabs are in the vertical bar strip, where they're radio buttons.
    @MainActor func openTab(_ title: String) {
        _ = hasTab(title, timeout: 10)
        let tab = tab(title)
        for _ in 0..<3 where !(tab.exists && tab.isSelected) {
            if !(tab.exists && tab.isHittable) { swipeDown() }
            if tab.exists, tab.isHittable { tab.tap() }
            _ = tab.waitForExistence(timeout: 2)
        }
    }

    /// Swipes up in the left quarter of the screen: the content on an iPhone, the left page on the
    /// open iPhone Duo (the middle is the fold).
    @MainActor func swipeUpOnLeft() {
        let start = coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.75))
        start.press(forDuration: 0.05, thenDragTo: coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.3)))
    }

    /// Scrolls the current screen until the element exists (lists load rows lazily).
    @MainActor @discardableResult func scrollTo(_ element: XCUIElement, swipes: Int = 8) -> Bool {
        var left = swipes
        while !element.exists, left > 0 {
            swipeUpOnLeft()
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
        XCTAssertTrue(hasScreen("\(chosen.count) Selected", timeout: 5), "selection count",
                      file: file, line: line)
        buttons["compact.selected"].tap()

        let busy = gridItems().matching(NSPredicate(format: "value IN {'Waiting', 'Backing up'}"))
        let progress = descendants(matching: .any)["job.progress"]
        let deadline = Date().addingTimeInterval(900)
        repeat { sleep(2) } while (busy.count > 0 || progress.exists) && Date() < deadline
        XCTAssertEqual(busy.count, 0, "items still working after 15 minutes", file: file, line: line)
        return chosen.count
    }

    /// Opens Activity's latest run and checks every item finished without failing. Returns the
    /// statuses, back on Library.
    @MainActor func checkActivity(file: StaticString = #filePath, line: UInt = #line) -> [String] {
        // The grid opens scrolled to the newest items, which minimises the tab bar; scrolling up
        // brings its tabs back.
        for _ in 0..<3 where !screenTitle("Activity").exists {
            if !(tabBars.buttons["Activity"].exists && tabBars.buttons["Activity"].isHittable) { swipeDown() }
            openTab("Activity")
            _ = hasScreen("Activity", timeout: 3)
        }
        let run = descendants(matching: .any).matching(identifier: "activity.run").firstMatch
        XCTAssertTrue(run.waitForExistence(timeout: 20), "no run in Activity", file: file, line: line)
        run.tap()
        let rows = descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'status.'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10), "no items in the run", file: file, line: line)
        let failed = descendants(matching: .any).matching(identifier: "status.failed")
        XCTAssertEqual(failed.count, 0, failed.allElementsBoundByIndex.map(\.label).joined(separator: "; "),
                       file: file, line: line)
        let statuses = rows.allElementsBoundByIndex.map(\.identifier)
        goBack()
        openTab("Library")
        return statuses
    }
}
