// SPDX-License-Identifier: Apache-2.0
import XCTest

/// Count work inside the app, not accessibility snapshots or simulator wall-clock time.
final class GridRedrawUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor func testBackUpTouchesOnlyChangedCells() throws {
        try backUp(allItems: true)
    }

    @MainActor func testBackUpUnderNotBackedUpFilter() throws {
        try backUp(allItems: false)
    }

    @MainActor func testSelectAllKeepsTheGridStill() throws {
        try backUp(allItems: true, selectAll: true)
    }

    @MainActor func testRealServerBackUpTouchesOnlyChangedCells() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let address = environment["HOMESPUN_SERVER"], let code = environment["HOMESPUN_PAIRING_CODE"],
              !code.isEmpty else { throw XCTSkip("Needs a server.") }
        let app = XCUIApplication()
        app.launchArguments = ["-onboardingComplete", "YES", "-hideTips", "-perfMonitor", "YES"]
        app.launch()
        app.pair(address: address, code: code)
        app.openTab("Library")
        let select = app.buttons["select.start"]
        XCTAssertTrue(select.waitForExistence(timeout: 20))
        select.tap()
        let screen = app.windows.firstMatch.frame
        let chosen = Array(app.gridItems("Not backed up").allElementsBoundByIndex.filter {
            $0.isHittable && $0.frame.midY > screen.minY + 120 && $0.frame.midY < screen.maxY - 180
        }.suffix(8))
        XCTAssertEqual(chosen.count, 8)
        for item in chosen { item.tap() }
        XCTAssertTrue(app.hasScreen("8 Selected", timeout: 5))
        sleep(2)
        let before = app.renderReport()
        app.buttons["compact.selected"].tap()
        let deadline = Date().addingTimeInterval(300)
        var after = before
        repeat {
            sleep(5)
            after = app.renderReport()
        } while (after["job.finished"] ?? 0) - (before["job.finished"] ?? 0) < 8 && Date() < deadline
        sleep(2)
        after = app.renderReport()
        func delta(_ key: String) -> Double { (after[key] ?? 0) - (before[key] ?? 0) }
        print("GRID REDRAW server: \(after.keys.sorted().map { "\($0)=\(delta($0))" }.joined(separator: ";"))")
        XCTAssertEqual(delta("job.finished"), 8)
        XCTAssertLessThanOrEqual(delta("render.root"), 2)
        XCTAssertLessThanOrEqual(delta("render.mainTab"), 2)
        XCTAssertLessThanOrEqual(delta("render.library"), 4)
        XCTAssertEqual(delta("grid.reloads"), 0)
        XCTAssertEqual(delta("grid.imageClears"), 0)
        XCTAssertLessThanOrEqual(delta("grid.thumbRequests"), 8)
        XCTAssertLessThanOrEqual(delta("grid.configs"), 40)
    }

    @MainActor private func backUp(allItems: Bool, selectAll: Bool = false) throws {
        let app = XCUIApplication()
        app.launchArguments = ["-hideTips", "-resetDemo", "-perfMonitor", "YES"]
        app.launch()
        func tap(_ id: String, timeout: Double = 30) throws {
            let button = app.buttons[id].firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: timeout), "no \(id)")
            button.tap()
        }
        try tap("setup.demo")
        try tap("found.use", timeout: 180)
        try tap("ready.continue")
        try tap("estimate.choose")
        if allItems {
            try tap("select.done")
            try tap("grid.filter")
            let all = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'All Items'")).firstMatch
            XCTAssertTrue(all.waitForExistence(timeout: 10))
            all.tap()
            try tap("select.start")
        }
        let items = app.gridItems("Not backed up")
        XCTAssertTrue(items.firstMatch.waitForExistence(timeout: 20))
        let expected = selectAll ? 30 : 8
        if selectAll {
            try tap("select.all")
        } else {
            let screen = app.windows.firstMatch.frame
            let chosen = Array(items.allElementsBoundByIndex.filter {
                let frame = $0.frame
                return $0.isHittable && frame.midY > screen.minY + 120 && frame.midY < screen.maxY - 180
            }.suffix(expected))
            XCTAssertEqual(chosen.count, expected)
            for item in chosen { item.tap() }
        }
        XCTAssertTrue(app.hasScreen("\(expected) Selected", timeout: 5), "not every item was selected")
        sleep(2)
        let before = app.renderReport()
        // The probe label must not cause the root to redraw while idle.
        sleep(1)
        XCTAssertEqual(app.renderReport()["render.root"], before["render.root"])
        try tap("compact.selected")
        let progress = app.descendants(matching: .any)["job.progress"].firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 15))
        let deadline = Date().addingTimeInterval(180)
        repeat { sleep(5) } while progress.exists && Date() < deadline
        XCTAssertFalse(progress.exists, "backup did not finish")
        sleep(2)
        let after = app.renderReport()
        func delta(_ key: String) -> Double { (after[key] ?? 0) - (before[key] ?? 0) }
        let n = delta("job.finished")
        let text = after.keys.sorted().map { "\($0)=\(delta($0))" }.joined(separator: ";")
        print("GRID REDRAW \(allItems ? "all" : "filtered"): \(text)")
        let attachment = XCTAttachment(string: text)
        attachment.name = "Grid redraw counters"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertEqual(n, Double(expected))
        XCTAssertLessThanOrEqual(delta("render.root"), 2)
        XCTAssertLessThanOrEqual(delta("render.mainTab"), 2)
        XCTAssertLessThanOrEqual(delta("render.library"), 4)
        XCTAssertEqual(delta("grid.reloads"), 0)
        if allItems {
            XCTAssertGreaterThanOrEqual(delta("grid.swaps"), 1)
            XCTAssertEqual(delta("grid.imageClears"), 0)
            XCTAssertLessThanOrEqual(delta("grid.thumbRequests"), n)
            XCTAssertLessThanOrEqual(delta("grid.configs"), (selectAll ? 2.5 : 4) * n + 8)
            XCTAssertLessThanOrEqual(delta("grid.layouts"), 4)
        } else {
            XCTAssertGreaterThanOrEqual(delta("grid.batches"), 1)
            XCTAssertLessThanOrEqual(delta("grid.imageClears"), 30 + n)
        }
    }
}

extension XCUIApplication {
    @MainActor func renderReport() -> [String: Double] {
        let monitor = descendants(matching: .any)["perf.monitor"].firstMatch
        XCTAssertTrue(monitor.waitForExistence(timeout: 10))
        return Dictionary(monitor.label.split(separator: ";").compactMap {
            let pair = $0.split(separator: "=", maxSplits: 1)
            guard pair.count == 2, let value = Double(pair[1]) else { return nil }
            return (String(pair[0]), value)
        }, uniquingKeysWith: { _, last in last })
    }
}
