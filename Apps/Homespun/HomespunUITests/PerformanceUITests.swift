// SPDX-License-Identifier: Apache-2.0
import XCTest

/// Smoothness on a library the size of a real one (35,000 photos on the HS Perf simulator, built
/// for profiling: `ci/perf.sh`). The app measures itself (`-perfMonitor`): frames
/// while something scrolls, and how long each interaction takes. Budgets follow Apple's guidance
/// ("Improving app responsiveness", "Understanding hitches in your app"): scrolling at most
/// 10 ms of hitches per second (Apple's "good"), no frame longer than a few refreshes, and a tap
/// answered well within 100–250 ms.
final class PerformanceUITests: XCTestCase {
    /// Hitch time per second of scrolling, in ms (Apple: ≤ 10 good, ≤ 25 warning), for the app
    /// scrolling by itself (`test10`), and with the test runner's gestures, which make the app walk
    /// its accessibility tree on the main thread at every gesture (so "warning" is the line there).
    static let hitchBudget = 10.0
    static let gestureHitchBudget = 25.0
    /// Frames longer than 50 ms (a visible stutter) allowed in one scrolling check, by itself and
    /// with gestures.
    static let slowFrameBudget = 0.0
    static let gestureSlowFrameBudget = 4.0
    /// A screen shown for the first time since launch (an item, a tab) also sets up its types and
    /// views, which the simulator makes slower than a phone; after that, a tap's 200–250 ms.
    static let firstTimeBudget = 600.0

    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = true
    }

    @MainActor private func launch(_ extra: [String] = []) throws {
        guard ProcessInfo.processInfo.environment["HOMESPUN_PERF"] != nil else {
            throw XCTSkip("Run with ci/perf.sh (a 35,000-photo simulator, Profile build).")
        }
        app = XCUIApplication()
        app.launchArguments += ["-onboardingComplete", "YES", "-hideTips", "YES", "-perfMonitor", "YES",
                                "-session.foreground", "NO"] + extra
        app.launch()
        XCTAssertTrue(app.gridItems().firstMatch.waitForExistence(timeout: 60), "the grid didn't show")
        XCTAssertTrue(monitorElement.waitForExistence(timeout: 10), "no performance monitor")
    }

    // MARK: Reading the monitor

    private var monitorElement: XCUIElement { app.descendants(matching: .any)["perf.monitor"].firstMatch }

    @MainActor private func monitor() -> [String: Double] {
        var values: [String: Double] = [:]
        for part in monitorElement.label.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1)
            if pair.count == 2, let value = Double(pair[1]) { values[String(pair[0])] = value }
        }
        return values
    }

    /// The span `name` after `action`, waiting until it's recorded (a newer value than before).
    @MainActor private func span(_ name: String, timeout: TimeInterval = 10, _ action: () -> Void) -> Double? {
        let before = monitor()["\(name).n"] ?? 0
        action()
        // Reading the monitor makes the app walk its accessibility tree on the main thread, so it
        // isn't read while the interaction being timed is still going on.
        usleep(800_000)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let now = monitor()
            if let value = now[name], (now["\(name).n"] ?? 0) > before { return value }
            usleep(400_000)
        }
        return nil
    }

    /// Runs `gestures` and checks the frames counted while things scrolled.
    @MainActor private func checkSmooth(_ what: String, hitchBudget: Double = gestureHitchBudget,
                                        file: StaticString = #filePath, line: UInt = #line, _ gestures: () -> Void) {
        let before = monitor()
        gestures()
        sleep(1)
        let after = monitor()
        let frames = (after["frames"] ?? 0) - (before["frames"] ?? 0)
        let hitchMs = (after["hitchMs"] ?? 0) - (before["hitchMs"] ?? 0)
        let scrollMs = (after["scrollMs"] ?? 0) - (before["scrollMs"] ?? 0)
        let ratio = scrollMs > 0 ? hitchMs / (scrollMs / 1000) : 0
        let slow = (after["slowFrames"] ?? 0) - (before["slowFrames"] ?? 0)
        // Grid cells on screen still without their picture, over the frames counted.
        let shown = (after["shownCells"] ?? 0) - (before["shownCells"] ?? 0)
        let blank = shown > 0 ? ((after["blankCells"] ?? 0) - (before["blankCells"] ?? 0)) * 100 / shown : 0
        print(String(format: "PERF %@: %.0f frames over %.0f ms, hitches %.1f ms/s, %.0f frames over 50 ms (longest so far %.1f ms), blank cells %.1f%%",
                     what, frames, scrollMs, ratio, slow, after["longestMs"] ?? 0, blank))
        XCTAssertGreaterThan(frames, 30, "\(what): nothing scrolled", file: file, line: line)
        XCTAssertLessThanOrEqual(ratio, hitchBudget, "\(what): \(ratio) ms of hitches per second", file: file, line: line)
        XCTAssertLessThanOrEqual(slow, Self.gestureSlowFrameBudget, "\(what): \(slow) frames over 50 ms", file: file, line: line)
    }

    // MARK: Controls

    /// A bar button by identifier, wherever the device puts it: on iPhone Duo's cover it's in the
    /// vertical strip, where buttons say they can't be hit (tapped by coordinate).
    @MainActor private func tapBarButton(_ identifier: String, file: StaticString = #filePath, line: UInt = #line) {
        let button = app.descendants(matching: .any)[identifier].firstMatch
        guard button.waitForExistence(timeout: 5) else { return XCTFail("no \(identifier)", file: file, line: line) }
        button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    /// A menu's item by the start of its label (menu items don't carry identifiers).
    @MainActor private func menuItem(_ label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch
    }

    /// Grid items in the middle of the screen (clear of the bars and the strip).
    @MainActor private func middleItems() -> [XCUIElement] {
        let screen = app.windows.firstMatch.frame
        return app.gridItems().allElementsBoundByIndex.filter { item in
            let frame = item.frame
            return !frame.isEmpty && frame.midY > screen.height * 0.25 && frame.midY < screen.height * 0.75
                && frame.midX < screen.width * 0.8
        }
    }

    // MARK: Gestures

    private var grid: XCUIElement { app.descendants(matching: .any)["grid"].firstMatch }

    /// Where gestures go, read once: finding an element makes the app walk its accessibility tree
    /// on the main thread (XCTest's snapshot; even the app's own root takes the whole tree), and
    /// between gestures that lands in the middle of the scrolling being measured. Points are taken
    /// from SpringBoard's origin instead: it's snapshotted in its own process, and touches go to
    /// the app in front.
    struct Area {
        let origin: XCUICoordinate
        let frame: CGRect

        func point(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
            origin.withOffset(CGVector(dx: frame.minX + frame.width * x, dy: frame.minY + frame.height * y))
        }
    }

    @MainActor private func area(_ element: XCUIElement) -> Area {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "nothing to scroll")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        return Area(origin: springboard.coordinate(withNormalizedOffset: .zero), frame: element.frame)
    }

    /// A fast flick (up: toward older items, the top).
    @MainActor private func flick(_ area: Area, up: Bool, distance: CGFloat = 0.6) {
        let from = area.point(0.5, up ? 0.2 : 0.8), to = area.point(0.5, up ? 0.2 + distance : 0.8 - distance)
        from.press(forDuration: 0.01, thenDragTo: to, withVelocity: .fast, thenHoldForDuration: 0)
    }

    @MainActor private func flicks(_ count: Int, up: Bool) {
        let area = area(grid)
        for _ in 0..<count { flick(area, up: up) }
    }

    // MARK: Tests

    /// The same budget with the grid still: per-item imports must not reload 35,000 thumbnails.
    @MainActor func test11BackUpTwentyItemsWhileGridIsStill() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let address = environment["HOMESPUN_SERVER"], let code = environment["HOMESPUN_PAIRING_CODE"] else {
            throw XCTSkip("Needs perf.sh's isolated server.")
        }
        try launch()
        app.pair(address: address, code: code)
        app.openTab("Library")
        tapBarButton("grid.menu")
        let sizes = menuItem("Grid Size")
        if sizes.waitForExistence(timeout: 5) { sizes.tap() }
        app.buttons["Small"].firstMatch.tap()
        sleep(2)
        tapBarButton("select.start")
        let screen = app.windows.firstMatch.frame
        let items = app.gridItems("Not backed up").allElementsBoundByIndex.filter {
            $0.isHittable && $0.frame.midY > screen.minY + 120 && $0.frame.midY < screen.maxY - 180
        }.suffix(20)
        XCTAssertEqual(items.count, 20)
        for item in items { item.tap() }
        XCTAssertTrue(app.hasScreen("20 Selected", timeout: 5))
        sleep(2)
        let before = monitor()
        tapBarButton("compact.selected")
        let progress = app.descendants(matching: .any)["job.progress"].firstMatch
        let deadline = Date().addingTimeInterval(600)
        var after = before
        repeat {
            sleep(5)
            after = monitor()
        } while (after["job.finished"] ?? 0) - (before["job.finished"] ?? 0) < 20 && Date() < deadline
        sleep(2)
        after = monitor()
        XCTAssertFalse(progress.exists, "local work still running after item completion")
        func delta(_ key: String) -> Double { (after[key] ?? 0) - (before[key] ?? 0) }
        let n = delta("job.finished")
        print("PERF backup: \(after)")
        XCTAssertEqual(n, 20)
        XCTAssertEqual(after["backup.slowFrames"] ?? .infinity, 0)
        XCTAssertLessThanOrEqual(after["backup.hitchMsPerS"] ?? .infinity, 5)
        XCTAssertLessThanOrEqual(after["GridApply.p95"] ?? .infinity, 2)
        XCTAssertLessThanOrEqual(delta("library.buildState"), n)
        XCTAssertEqual(delta("grid.reloads"), 0)
    }

    @MainActor func test01LaunchToGrid() throws {
        try launch()
        let launchMs = monitor()["launch"] ?? .infinity, fromMain = monitor()["launchFromMain"] ?? .infinity
        print(String(format: "PERF launch to grid: %.0f ms from the process's start, %.0f ms from the app's code", launchMs, fromMain))
        // Loading before the app's code (dyld) takes seconds in the simulator and a fraction of
        // that on a phone, so the budget is from the app's code to the grid with its items. The
        // test runner adds about a second (the app builds its accessibility tree from the start);
        // `perf-launch.sh` checks launches without it (budget 1.2 s).
        XCTAssertLessThan(fromMain, 2_500, "from the app's code to the grid took \(fromMain) ms")
    }

    @MainActor func test02ScrollTheWholeLibrary() throws {
        try launch()
        // Flick back through the years, then forward again, without stopping.
        checkSmooth("flick toward older") { flicks(15, up: true) }
        checkSmooth("flick toward newer") { flicks(15, up: false) }
        // Slow drags (cells appear one row at a time).
        let area = area(grid)
        // Slow drags are the most gestures per second of scrolling, and each gesture brings XCTest's
        // snapshot onto the main thread (22–31 ms/s across runs, nearly all XCTest in traces); the
        // app alone at this speed is test10's "slow" phase, held to 10 ms/s.
        checkSmooth("slow drags", hitchBudget: 40) {
            for _ in 0..<6 {
                area.point(0.5, 0.3).press(forDuration: 0.05, thenDragTo: area.point(0.5, 0.7), withVelocity: .slow,
                                           thenHoldForDuration: 0)
            }
        }
    }

    @MainActor func test03OpenItemsAndPage() throws {
        try launch()
        for attempt in 0..<5 {
            let items = middleItems()
            guard let item = items.dropFirst(attempt * 3).first else { return XCTFail("no items to open") }
            let ms = span("open") { item.tap() }
            XCTAssertTrue(app.descendants(matching: .any)["item.viewer"].waitForExistence(timeout: 5), "the item didn't open")
            print(String(format: "PERF open item%@: %.0f ms", attempt == 0 ? " (first)" : "", ms ?? -1))
            XCTAssertNotNil(ms)
            // The first time also sets up the viewer's types and views (once per launch).
            let budget: Double = attempt == 0 ? Self.firstTimeBudget : 250
            XCTAssertLessThan(ms ?? .infinity, budget, "opening an item took \(ms ?? -1) ms")
            if attempt == 0 {
                let pager = area(app.descendants(matching: .any)["item.viewer"])
                checkSmooth("paging items") {
                    for _ in 0..<12 {
                        app.pageItem(older: true) {
                            pager.point(0.15, 0.5).press(forDuration: 0.01, thenDragTo: pager.point(0.9, 0.5), withVelocity: .fast,
                                                       thenHoldForDuration: 0)
                        }
                    }
                }
            }
            app.goBack()
            XCTAssertTrue(grid.waitForExistence(timeout: 5))
        }
    }

    @MainActor func test04SwitchFilters() throws {
        try launch()
        for filter in ["Not Backed Up", "Ready to Free Up", "Original at Home", "Needs Attention", "Compact Copy Later",
                       "All Items", "Videos", "Live Photos", "Photos and Videos"] {
            tapBarButton("grid.filter")
            let option = menuItem(filter)
            guard option.waitForExistence(timeout: 5) else {
                XCTFail("no filter \(filter)")
                continue
            }
            let ms = span("filter") { option.tap() }
            print(String(format: "PERF filter %@: %.0f ms", filter, ms ?? -1))
            XCTAssertLessThan(ms ?? .infinity, 250, "switching to \(filter) took \(ms ?? -1) ms")
        }
        checkSmooth("scroll after filters") { flicks(6, up: true) }
    }

    @MainActor func test05SelectEverything() throws {
        try launch()
        tapBarButton("select.start")
        let all = app.descendants(matching: .any)["select.all"].firstMatch
        XCTAssertTrue(all.waitForExistence(timeout: 5))
        let ms = span("selectAll") { all.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        print(String(format: "PERF select all: %.0f ms", ms ?? -1))
        XCTAssertLessThan(ms ?? .infinity, 300, "Select All took \(ms ?? -1) ms")
        XCTAssertTrue(app.descendants(matching: .any)["compact.selected"].waitForExistence(timeout: 5))
        checkSmooth("scroll with everything selected") { flicks(8, up: true) }
        let deselect = span("selectAll") { all.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        XCTAssertLessThan(deselect ?? .infinity, 300, "Deselect All took \(deselect ?? -1) ms")
        tapBarButton("select.done")
    }

    @MainActor func test06SwitchTabs() throws {
        try launch()
        var seen: Set<String> = ["Library"]
        for tab in ["Activity", "Server", "Library", "Server", "Activity", "Library"] {
            let first = seen.insert(tab).inserted
            let ms = span("tab") { app.openTab(tab) }
            print(String(format: "PERF tab %@%@: %.0f ms", tab, first ? " (first)" : "", ms ?? -1))
            XCTAssertLessThan(ms ?? .infinity, first ? Self.firstTimeBudget : 200, "switching to \(tab) took \(ms ?? -1) ms")
        }
    }

    @MainActor func test07GridSizes() throws {
        try launch()
        // From Medium (the size is kept between launches; choosing the size already shown changes nothing).
        for (index, size) in ["Medium", "Small", "Large", "Medium"].enumerated() {
            let timed = index > 0
            tapBarButton("grid.menu")
            let sizes = menuItem("Grid Size")
            if sizes.waitForExistence(timeout: 5) { sizes.tap() }
            let option = app.buttons[size].firstMatch
            guard option.waitForExistence(timeout: 5) else {
                XCTFail("no grid size \(size)")
                continue
            }
            guard timed else {
                option.tap()
                sleep(2)
                continue
            }
            let ms = span("gridSize") { option.tap() }
            print(String(format: "PERF grid size %@: %.0f ms", size, ms ?? -1))
            XCTAssertLessThan(ms ?? .infinity, Self.firstTimeBudget, "changing to \(size) took \(ms ?? -1) ms")
            checkSmooth("scroll at \(size)") { flicks(6, up: true) }
        }
    }

    @MainActor func test08ListsScroll() throws {
        try launch()
        app.openTab("Server")
        let server = app.descendants(matching: .any).matching(identifier: "settings.help").firstMatch
        _ = server.waitForExistence(timeout: 5)
        let list = area(app.collectionViews.firstMatch)
        checkSmooth("Server list") {
            for _ in 0..<3 {
                list.point(0.5, 0.8).press(forDuration: 0.01, thenDragTo: list.point(0.5, 0.3), withVelocity: .fast,
                                           thenHoldForDuration: 0)
                list.point(0.5, 0.3).press(forDuration: 0.01, thenDragTo: list.point(0.5, 0.8), withVelocity: .fast,
                                           thenHoldForDuration: 0)
            }
        }
        app.openTab("Library")
    }

    /// The grid scrolling by itself (`-perfAutoscroll`): slowly (cells appear a row at a time),
    /// fast, very fast and back, with nothing but the app on the main thread. Apple's "good" budget.
    @MainActor func test10AutoscrollTheLibrary() throws {
        try launch(["-perfAutoscroll"])
        // Not read while it runs: reading makes the app walk its accessibility tree.
        let total = PerformanceUITestsPhases.seconds + 6
        sleep(UInt32(total))
        var values = monitor()
        let deadline = Date().addingTimeInterval(20)
        while values["autoscroll"] == nil, Date() < deadline {
            sleep(2)
            values = monitor()
        }
        XCTAssertEqual(values["autoscroll"], 1, "the autoscroll didn't finish")
        for phase in PerformanceUITestsPhases.names {
            let frames = values["auto.\(phase).frames"] ?? 0, ratio = values["auto.\(phase).hitchMsPerS"] ?? .infinity
            let slow = values["auto.\(phase).slowFrames"] ?? .infinity, longest = values["auto.\(phase).longestMs"] ?? 0
            let blank = values["auto.\(phase).blankPct"] ?? 0
            print(String(format: "PERF autoscroll %@: %.0f frames, hitches %.1f ms/s, %.0f frames over 50 ms, longest %.1f ms, blank cells %.1f%%",
                         phase, frames, ratio, slow, longest, blank))
            XCTAssertGreaterThan(frames, 30, "autoscroll \(phase): nothing scrolled")
            XCTAssertLessThanOrEqual(ratio, Self.hitchBudget, "autoscroll \(phase): \(ratio) ms of hitches per second")
            XCTAssertLessThanOrEqual(slow, Self.slowFrameBudget, "autoscroll \(phase): \(slow) frames over 50 ms")
        }
    }

    /// Swiping down closes an item (like Photos); a sideways swipe still pages.
    @MainActor func test11SwipeDownClosesAnItem() throws {
        try launch()
        guard let item = middleItems().first else { return XCTFail("no items to open") }
        item.tap()
        let viewer = app.descendants(matching: .any)["item.viewer"]
        XCTAssertTrue(viewer.waitForExistence(timeout: 5), "the item didn't open")
        let pager = area(viewer)
        app.pageItem(older: false) {
            pager.point(0.85, 0.5).press(forDuration: 0.01, thenDragTo: pager.point(0.15, 0.5), withVelocity: .fast,
                                       thenHoldForDuration: 0)
        }
        sleep(1)
        XCTAssertTrue(viewer.exists, "a sideways swipe closed the item")
        pager.point(0.5, 0.3).press(forDuration: 0.05, thenDragTo: pager.point(0.5, 0.85), withVelocity: .default,
                                    thenHoldForDuration: 0)
        XCTAssertTrue(viewer.waitForNonExistence(timeout: 5), "swiping down didn't close the item")
        XCTAssertTrue(grid.waitForExistence(timeout: 5))
    }

    /// A second tap on the Library tab brings the newest items (the system's own second tap went to
    /// the top, the oldest).
    @MainActor func test12LibraryTabBringsTheNewest() throws {
        try launch()
        // The grid lays out only around what's on screen: its last item is on screen only at the newest.
        func atNewest() -> Bool {
            guard let last = app.gridItems().allElementsBoundByIndex.last else { return false }
            return app.isOnScreen(last)
        }
        func waitForNewest() -> Bool {
            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline {
                if atNewest() { return true }
                sleep(1)
            }
            return false
        }
        XCTAssertTrue(atNewest(), "the Library didn't open at the newest")
        flicks(6, up: true)
        XCTAssertFalse(atNewest(), "the grid didn't scroll away from the newest")
        app.tab("Library").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(waitForNewest(), "tapping Library again didn't bring the newest")
        XCTAssertFalse(app.isOnScreen(app.buttons["connect.open"]), "tapping Library again went to the oldest")

        // In Select mode (no tab bar), the bar's Newest does it.
        tapBarButton("select.start")
        flicks(6, up: true)
        XCTAssertFalse(atNewest())
        tapBarButton("select.newest")
        XCTAssertTrue(waitForNewest(), "Newest in Select mode didn't bring the newest")
        tapBarButton("select.done")
    }

    /// Xcode's own hitch metric, for the result bundle (reported, not a pass/fail budget).
    @MainActor func test09HitchMetricReport() throws {
        try launch()
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        let area = area(grid)
        measure(metrics: [XCTHitchMetric(application: app)], options: options) {
            for _ in 0..<4 { flick(area, up: true) }
            for _ in 0..<4 { flick(area, up: false) }
        }
    }
}

/// The app's autoscroll phases (`PerfMonitor.autoscrollPhases`): their names and total length.
enum PerformanceUITestsPhases {
    static let names = ["slow", "fast", "faster", "back"]
    static let seconds = 6 + 6 + 4 + 5 + 4
}
