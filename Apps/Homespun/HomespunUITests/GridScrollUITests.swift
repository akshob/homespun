// SPDX-License-Identifier: Apache-2.0
import XCTest

/// The grid moves with the finger and nothing else, like Photos. The old grid (SwiftUI) estimated
/// the rows it hadn't built, so a short drag from the newest end teleported it to a far month for
/// half a second, with empty cells, then snapped back. Needs a library spread over many months
/// (`ui.sh` with `DATED=`); the app reports where its grid is with `-perfMonitor`.
final class GridScrollUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
    }

    /// On iPhone Duo with poses (`ci/ui.sh` with `DUO_POSES=1`): the file `ui.sh` watches to fold and turn it.
    private let poses = ProcessInfo.processInfo.environment["DUO_POSE_FILE"]

    @MainActor private func launch() throws {
        // Folded, where XCTest's gestures reach the app.
        pose("folded")
        app = XCUIApplication()
        app.launchArguments += ["-onboardingComplete", "YES", "-hideTips", "YES", "-perfMonitor", "YES"]
        app.launch()
        XCTAssertTrue(app.gridItems().firstMatch.waitForExistence(timeout: 30), "no photos in the Library")
        XCTAssertTrue(app.descendants(matching: .any)["perf.monitor"].waitForExistence(timeout: 10), "no grid report")
    }

    /// From the newest end: a short drag moves the grid by the drag, a small swipe a little further,
    /// and neither ever shows another part of the library, even for a frame.
    @MainActor func testShortDragsFromTheNewestMoveOnlyWithTheFinger() throws {
        try launch()
        let start = try settled()
        guard start.value("grid.bottom") - start.value("grid.top") > 400 else { throw XCTSkip("The library fits on the screen.") }
        XCTAssertEqual(start.value("grid.offset"), start.value("grid.bottom"), accuracy: 1, "the Library didn't open at the newest")
        XCTAssertEqual(start.value("grid.blank"), 0, "cells without their picture at the newest")
        // The months whose headers are on screen (none when the newest month fills the screen), and the
        // item in the middle: a jump would show another part of the library.
        let newest = months()
        let columns = start.value("grid.columns")

        // A short, slow drag toward older items, held at the end so it doesn't fling.
        drag(by: 100)
        let dragged = try settled(changedFrom: start)
        XCTAssertEqual(dragged.value("grid.jumps"), start.value("grid.jumps"), "the grid jumped while following the finger")
        XCTAssertEqual(start.value("grid.offset") - dragged.value("grid.offset"), 100, accuracy: 35,
                       "a 100-point drag moved the grid \(start.value("grid.offset") - dragged.value("grid.offset")) points")
        check(months(), near: newest, within: 1, "after a 100-point drag")
        XCTAssertLessThanOrEqual(abs(dragged.value("grid.anchor") - start.value("grid.anchor")), columns * 3,
                                 "a 100-point drag moved from item \(start.value("grid.anchor")) to \(dragged.value("grid.anchor"))")
        XCTAssertEqual(dragged.value("grid.blank"), 0, "cells without their picture after a short drag")

        // Back to the newest by a drag the other way.
        drag(by: -100)
        let back = try settled(changedFrom: dragged)
        XCTAssertEqual(back.value("grid.offset") - dragged.value("grid.offset"), 100, accuracy: 35, "dragging back didn't follow the finger")
        XCTAssertEqual(back.value("grid.jumps"), start.value("grid.jumps"), "the grid jumped dragging back")

        // A small swipe flings it a little further, never somewhere else.
        let before = months()
        swipe(by: 120)
        let swiped = try settled(changedFrom: back)
        XCTAssertEqual(swiped.value("grid.jumps"), start.value("grid.jumps"), "the grid jumped during a swipe")
        let travelled = back.value("grid.offset") - swiped.value("grid.offset")
        XCTAssertGreaterThan(travelled, 60, "a swipe toward older items didn't scroll")
        XCTAssertLessThan(travelled, 5_000, "a small swipe went \(travelled) points")
        check(months(), near: before, within: Int(travelled / 200) + 2, "after a small swipe of \(Int(travelled)) points")
        XCTAssertLessThanOrEqual(abs(swiped.value("grid.anchor") - back.value("grid.anchor")), columns * (travelled / 60 + 3),
                                 "a swipe of \(Int(travelled)) points moved from item \(back.value("grid.anchor")) to \(swiped.value("grid.anchor"))")
        XCTAssertEqual(swiped.value("grid.blank"), 0, "cells without their picture after a swipe")

        // The Library tab tapped again brings the newest, exactly (not the oldest, the system's scroll to
        // the top). Minimised (scrolling toward the newest minimises it), the tab bar's first tap expands it.
        for _ in 0..<2 where report().value("grid.offset") == swiped.value("grid.offset") {
            app.tab("Library").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            sleep(2)
        }
        let newestAgain = try settled(changedFrom: swiped)
        XCTAssertEqual(newestAgain.value("grid.offset"), newestAgain.value("grid.bottom"), accuracy: 1,
                       "the Library tab didn't bring the newest")
        XCTAssertFalse(app.isOnScreen(app.buttons["connect.open"]), "the Library tab went to the oldest")
    }

    /// Turning the iPhone keeps the item that was in the middle of the screen in view.
    @MainActor func testTurningKeepsTheItemInView() throws {
        try launch()
        let start = try settled()
        guard start.value("grid.bottom") - start.value("grid.top") > 2_000 else { throw XCTSkip("The library is short.") }
        for _ in 0..<3 { swipe(by: 250) }
        let middle = try settled(changedFrom: start)
        let anchor = middle.value("grid.anchor")
        defer { XCUIDevice.shared.orientation = .portrait }
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            sleep(2)
            XCTAssertEqual(app.state, .runningForeground, "crashed turning \(orientation.rawValue)")
            let now = report()
            XCTAssertTrue(now.value("grid.first") <= anchor && anchor <= now.value("grid.last"),
                          "turned \(orientation.rawValue): item \(anchor) isn't in view (\(now.value("grid.first"))–\(now.value("grid.last")))")
            XCTAssertEqual(now.value("grid.jumps"), start.value("grid.jumps"))
        }
    }

    /// iPhone Duo, scrolled to the middle of the library: unfolding, turning and folding keep the item
    /// in the middle of the screen in view, without a crash (one was reported unfolding on the grid).
    /// It scrolls folded: XCTest's gestures don't reach the open Duo.
    @MainActor func testFoldingMidLibraryKeepsTheItemInView() throws {
        guard poses != nil else { throw XCTSkip("Folds iPhone Duo (ci/ui.sh with DUO_POSES=1).") }
        try launch()
        let start = try settled()
        guard start.value("grid.bottom") - start.value("grid.top") > 2_000 else { throw XCTSkip("The library is short.") }
        for _ in 0..<3 { swipe(by: 250) }
        let middle = try settled(changedFrom: start)
        let anchor = middle.value("grid.anchor"), columns = middle.value("grid.columns")
        shot("mid-library, folded")
        // Unfolded, turned, folded again: the grid fills the screen it's on (beside the tabs' strip, if
        // any), with more columns open.
        let nonStrict = XCTExpectedFailure.Options()
        nonStrict.isStrict = false
        for (name, wide) in [("landscape", true), ("portrait", false), ("folded", false)] {
            pose(name)
            XCTAssertTrue(waitForWindow { name == "folded" ? $0.width < 500 : $0.width > 500 && ($0.width > $0.height) == wide },
                          "the screen didn't turn \(name)")
            XCTAssertEqual(app.state, .runningForeground, "crashed: \(name)")
            let window = app.windows.firstMatch.frame.width
            // The grid takes all the room it's given (its safe area); that room is the screen, less a strip.
            func follows(_ report: Report) -> Bool { abs(report.value("grid.width") - report.value("grid.span")) < 1 }
            func fills(_ report: Report) -> Bool {
                report.value("grid.width") > window - 120 && (name == "folded") == (report.value("grid.columns") == columns)
            }
            let deadline = Date().addingTimeInterval(20)
            var now = report()
            while !(follows(now) && fills(now)), Date() < deadline {
                sleep(1)
                now = report()
            }
            XCTAssertTrue(follows(now), "\(name): the grid is \(now.value("grid.width")) wide, given \(now.value("grid.span"))")
            XCTExpectFailure("Unfolding on a slow machine, SwiftUI's inspector container can keep its old safe area: the Library's title and grid stay narrow until the next turn",
                             options: nonStrict) {
                XCTAssertTrue(fills(now), "\(name): the grid is \(now.value("grid.width")) wide in \(now.value("grid.columns")) columns, the screen \(window)")
            }
            sleep(2)
            now = report()
            XCTAssertTrue(now.value("grid.first") <= anchor && anchor <= now.value("grid.last"),
                          "\(name): item \(anchor) isn't in view (\(now.value("grid.first"))–\(now.value("grid.last")))")
            XCTAssertEqual(now.value("grid.jumps"), middle.value("grid.jumps"), "\(name): the grid jumped")
            XCTAssertFalse(app.gridItems().allElementsBoundByIndex.filter { app.isOnScreen($0) }.isEmpty, "\(name): the grid is blank")
            shot("mid-library, \(name)")
        }
    }

    /// Closing an item at the newest end leaves the grid where it was, not even a few frames elsewhere
    /// (on the open Duo the tab bar the viewer hid comes back a moment after the grid, and its insets
    /// differ until then). In every pose on iPhone Duo: taps reach the open Duo, swipes don't.
    @MainActor func testClosingTheViewerAtTheNewestStaysPut() throws {
        try launch()
        _ = try settled()
        for name in poses == nil ? ["iPhone"] : ["landscape", "portrait", "folded"] {
            if poses != nil {
                pose(name)
                XCTAssertTrue(waitForWindow { name == "folded" ? $0.width < 500 : $0.width > 500 && ($0.width > $0.height) == (name == "landscape") },
                              "the screen didn't turn \(name)")
                sleep(3)
            }
            let before = report()
            XCTAssertEqual(before.value("grid.offset"), before.value("grid.bottom"), accuracy: 1, "\(name): not at the newest")
            // A cell in the last row clear of the bars at the bottom.
            let screen = app.windows.firstMatch.frame
            let cells = app.gridItems().allElementsBoundByIndex.filter {
                $0.frame.minY > screen.minY + 100 && $0.frame.maxY < screen.maxY - 140 && app.isOnScreen($0)
            }
            guard let cell = cells.max(by: { ($0.frame.minY, -$0.frame.minX) < ($1.frame.minY, -$1.frame.minX) }) else {
                return XCTFail("\(name): no cell to open")
            }
            cell.tap()
            let viewer = app.descendants(matching: .any)["item.viewer"].firstMatch
            XCTAssertTrue(viewer.waitForExistence(timeout: 8), "\(name): the item didn't open")
            sleep(1)
            app.goBack()
            XCTAssertTrue(viewer.waitForNonExistence(timeout: 8), "\(name): the item didn't close")
            sleep(2)
            let after = report()
            XCTAssertEqual(after.value("grid.bounces"), before.value("grid.bounces"),
                           "\(name): closing the item moved the grid and back")
            XCTAssertEqual(after.value("grid.offset"), after.value("grid.bottom"), accuracy: 1, "\(name): not at the newest after closing")
            XCTAssertEqual(after.value("grid.jumps"), before.value("grid.jumps"))
        }
    }

    /// Paging the viewer to items that weren't in view: the grid behind it follows (like Photos), so
    /// closing zooms into the item shown, in view, not into the one tapped.
    @MainActor func testClosingTheViewerShowsTheItemItCameTo() throws {
        try launch()
        let start = try settled()
        guard start.value("grid.bottom") - start.value("grid.top") > 2_000 else { throw XCTSkip("The library is short.") }
        for _ in 0..<2 { swipe(by: 250) }
        let middle = try settled(changedFrom: start)
        let screen = app.windows.firstMatch.frame
        let top = app.navigationBars.firstMatch.exists ? app.navigationBars.firstMatch.frame.maxY : screen.minY + 120
        let cells = app.gridItems().allElementsBoundByIndex.filter { $0.frame.minY > top && app.isOnScreen($0) }
        guard let first = cells.min(by: { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }) else {
            return XCTFail("no cells on screen")
        }
        first.tap()
        let viewer = app.descendants(matching: .any)["item.viewer"].firstMatch
        XCTAssertTrue(viewer.waitForExistence(timeout: 8), "the item didn't open")
        // Older items, past the top row: out of the grid's view.
        for _ in 0..<Int(middle.value("grid.columns")) * 2 + 1 { viewer.swipeRight() }
        sleep(2)
        let paged = report()
        let shown = paged.value("grid.shown")
        XCTAssertGreaterThanOrEqual(shown, 0, "the grid didn't hear which item the viewer shows")
        XCTAssertLessThan(shown, middle.value("grid.first"), "paging didn't reach the items above the screen")
        XCTAssertEqual(paged.value("grid.zoom"), shown, "closing would zoom into another item than the one shown")
        XCTAssertTrue(paged.value("grid.first") <= shown && shown <= paged.value("grid.last"),
                      "item \(shown) isn't in view behind the viewer (\(paged.value("grid.first"))–\(paged.value("grid.last")))")

        app.goBack()
        XCTAssertTrue(viewer.waitForNonExistence(timeout: 8), "the viewer didn't close")
        sleep(2)
        let back = report()
        XCTAssertTrue(back.value("grid.first") <= shown && shown <= back.value("grid.last"),
                      "closed: item \(shown) isn't in view (\(back.value("grid.first"))–\(back.value("grid.last")))")
        XCTAssertEqual(back.value("grid.jumps"), start.value("grid.jumps"))
    }

    /// Pinching changes the columns (like Grid Size), keeping the item under the fingers in view.
    @MainActor func testPinchingChangesTheColumnsAndKeepsTheItem() throws {
        try launch()
        // On iPhone Duo the grid runs under the tabs' strip, and XCTest's pinch (across the grid's frame)
        // puts a finger on the strip: pinching is checked on the iPhone.
        guard app.tabBars.firstMatch.exists else { throw XCTSkip("XCTest's pinch lands on iPhone Duo's tab strip.") }
        let start = try settled()
        guard start.value("grid.bottom") - start.value("grid.top") > 2_000 else { throw XCTSkip("The library is short.") }
        for _ in 0..<2 { swipe(by: 250) }
        let middle = try settled(changedFrom: start)
        let columns = middle.value("grid.columns"), anchor = middle.value("grid.anchor")
        grid.pinch(withScale: 0.4, velocity: -1)
        sleep(2)
        let smaller = report()
        // Back to the size it had, whatever happens (the size is kept for the next launch).
        defer { if report().value("grid.columns") != columns { grid.pinch(withScale: 2.5, velocity: 1) } }
        XCTAssertGreaterThan(smaller.value("grid.columns"), columns, "pinching in didn't make the cells smaller")
        XCTAssertTrue(smaller.value("grid.first") <= anchor && anchor <= smaller.value("grid.last"),
                      "item \(anchor) left the screen (\(smaller.value("grid.first"))–\(smaller.value("grid.last")))")
        grid.pinch(withScale: 2.5, velocity: 1)
        sleep(2)
        let back = report()
        XCTAssertEqual(back.value("grid.columns"), columns, "pinching out didn't bring the size back")
        XCTAssertTrue(back.value("grid.first") <= anchor && anchor <= back.value("grid.last"), "item \(anchor) left the screen")
        XCTAssertEqual(back.value("grid.jumps"), start.value("grid.jumps"))
    }

    /// Select mode: a sideways drag along a row selects it, like Photos; touching and holding, then
    /// dragging to the top edge, scrolls the grid and selects everything it passes.
    @MainActor func testDragToSelect() throws {
        try launch()
        let start = try settled()
        app.buttons["select.start"].tap()
        XCTAssertTrue(app.hasScreen("Select Items", timeout: 5))
        sleep(1)
        // Select mode's bars differ from the tab bar: the newest end stays in view.
        let selecting = report()
        let screen = app.windows.firstMatch.frame
        let cells = app.gridItems().allElementsBoundByIndex.filter {
            $0.frame.minY > screen.minY + 150 && $0.frame.maxY < screen.maxY - 150 && app.isOnScreen($0)
        }
        let rows = Dictionary(grouping: cells) { Int($0.frame.minY.rounded()) }
        guard let row = rows.values.max(by: { $0.count < $1.count })?.sorted(by: { $0.frame.minX < $1.frame.minX }), row.count > 1 else {
            return XCTFail("no row of cells on screen")
        }
        row[0].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: row[row.count - 1].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)),
                   withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertTrue(app.hasScreen("\(row.count) Selected", timeout: 5), "a sideways drag along a row didn't select it")
        XCTAssertEqual(report().value("grid.offset"), selecting.value("grid.offset"), accuracy: 1, "the grid scrolled during the drag")
        guard start.value("grid.bottom") - start.value("grid.top") > 1_500 else { return app.buttons["select.done"].tap() }

        // Hold on a cell that isn't selected (from a selected one the drag deselects), then drag up to
        // the top edge and stay there: the grid scrolls toward older items, selecting all it passes.
        guard let other = cells.first(where: { abs($0.frame.minY - row[0].frame.minY) > 1 }) else {
            return app.buttons["select.done"].tap()
        }
        let top = app.navigationBars.firstMatch.exists ? app.navigationBars.firstMatch.frame.maxY : screen.minY + 120
        other.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.6, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: screen.midX, dy: top + 25)), withVelocity: .default, thenHoldForDuration: 2.5)
        let scrolled = try settled(changedFrom: selecting)
        XCTAssertLessThan(scrolled.value("grid.offset"), selecting.value("grid.offset") - 150, "the grid didn't scroll at the top edge")
        let title = app.descendants(matching: .any).matching(NSPredicate(format: "label MATCHES '^[0-9]+ Selected$'")).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(Int(title.label.split(separator: " ")[0]) ?? 0, row.count * 3, "the run didn't grow while scrolling")
        app.buttons["select.done"].tap()
    }

    // MARK: Gestures

    private var grid: XCUIElement { app.descendants(matching: .any)["grid"].firstMatch }

    /// Drags slowly by `points` (positive: down, toward older items) and holds, so it doesn't fling.
    @MainActor private func drag(by points: CGFloat) {
        let from = grid.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: points > 0 ? 0.35 : 0.6))
        from.press(forDuration: 0.1, thenDragTo: from.withOffset(CGVector(dx: 0, dy: points)), withVelocity: .slow,
                   thenHoldForDuration: 0.5)
    }

    /// A quick swipe of `points`, let go while moving.
    @MainActor private func swipe(by points: CGFloat) {
        let from = grid.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: 0, dy: points)), withVelocity: .fast,
                   thenHoldForDuration: 0)
    }

    // MARK: iPhone Duo's poses

    /// Asks `ui.sh` to fold or turn iPhone Duo (nothing elsewhere), then waits until it has.
    @MainActor private func pose(_ name: String) {
        guard let poses else { return }
        XCTAssertNoThrow(try name.write(toFile: poses, atomically: true, encoding: .utf8))
        let deadline = Date().addingTimeInterval(90)
        while FileManager.default.fileExists(atPath: poses), Date() < deadline { usleep(250_000) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: poses), "nobody turned the simulator \(name)")
        sleep(3)
    }

    /// A screenshot by `ui.sh` (XCTest's own shows the cover, black while the Duo is open).
    @MainActor private func shot(_ name: String) {
        guard let poses else { return }
        try? "shot \(name)".write(toFile: poses, atomically: true, encoding: .utf8)
        let deadline = Date().addingTimeInterval(30)
        while FileManager.default.fileExists(atPath: poses), Date() < deadline { usleep(250_000) }
    }

    /// Waits until the window's frame is as wanted (a slow machine takes a while to fold or turn).
    @MainActor private func waitForWindow(_ wanted: (CGRect) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(30)
        repeat {
            if wanted(app.windows.firstMatch.frame) { return true }
            usleep(500_000)
        } while Date() < deadline
        return false
    }

    // MARK: Reading the grid

    struct Report {
        let values: [String: Double]
        func value(_ name: String) -> Double { values[name] ?? .nan }
    }

    /// The grid's report (`perf.monitor`): where it is, its ends, the items in view, jumps, cells without pictures.
    @MainActor private func report() -> Report {
        var values: [String: Double] = [:]
        for part in app.descendants(matching: .any)["perf.monitor"].label.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1)
            if pair.count == 2, let value = Double(pair[1]) { values[String(pair[0])] = value }
        }
        return Report(values: values)
    }

    /// Waits until the grid has stopped (its offset differs from `earlier`'s, then holds), and a moment
    /// more for pictures.
    @MainActor private func settled(changedFrom earlier: Report? = nil, file: StaticString = #filePath,
                                    line: UInt = #line) throws -> Report {
        let deadline = Date().addingTimeInterval(15)
        var last = report()
        while Date() < deadline {
            sleep(1)
            let now = report()
            let moved = earlier.map { now.value("grid.offset") != $0.value("grid.offset") } ?? true
            if moved, now.value("grid.offset") == last.value("grid.offset"), !now.value("grid.offset").isNaN {
                sleep(1)
                return report()
            }
            last = now
        }
        XCTFail("the grid didn't settle", file: file, line: line)
        return last
    }

    /// The months whose headers are on screen (year × 12 + month).
    @MainActor private func months() -> [Int] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMMM yyyy"
        let calendar = Calendar(identifier: .gregorian)
        return app.staticTexts.allElementsBoundByIndex.compactMap { text in
            guard let date = formatter.date(from: text.label), app.isOnScreen(text) else { return nil }
            let parts = calendar.dateComponents([.year, .month], from: date)
            return (parts.year ?? 0) * 12 + (parts.month ?? 0)
        }
    }

    /// The months on screen now are close to the ones before (a jump shows a far one, a year or more away).
    private func check(_ now: [Int], near before: [Int], within: Int, _ what: String, file: StaticString = #filePath,
                       line: UInt = #line) {
        guard let newest = before.max(), let oldest = before.min() else { return }
        for month in now where month > newest + within || month < oldest - within {
            XCTFail("\(what): a month \(abs(month - newest)) months away is on screen (\(now) after \(before))", file: file, line: line)
        }
    }
}
