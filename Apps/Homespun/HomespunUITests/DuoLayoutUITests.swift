// SPDX-License-Identifier: Apache-2.0
import XCTest

/// iPhone Duo's inner display is one screen, held wide or tall, like Settings and Photos: the Library
/// is one grid across the whole width (no gap at the fold), Activity and Server show their list
/// beside what it opens (never an empty page), an item opens full screen with Details at the side, and
/// folding or unfolding at any point keeps the place without a crash.
///
/// Needs the iPhone Duo simulator, a server (`HOMESPUN_SERVER`, `HOMESPUN_PAIRING_CODE`) and
/// `DUO_POSE_FILE`: the test writes a pose there (landscape, portrait, laptop, folded) and waits
/// until the file is gone; `run-class.sh` with `DUO_POSES=1` folds and turns the simulator to match.
/// Pass all three with a `TEST_RUNNER_` prefix.
final class DuoLayoutUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor func testOneScreenInEveryPose() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let poses = environment["DUO_POSE_FILE"], let address = environment["HOMESPUN_SERVER"],
              let code = environment["HOMESPUN_PAIRING_CODE"] else {
            throw XCTSkip("Run on the iPhone Duo with run-class.sh and DUO_POSES=1.")
        }
        let app = XCUIApplication()
        app.launchArguments += ["-onboardingComplete", "YES", "-hideTips"]
        pose("landscape", file: poses)
        app.launch()
        app.pair(address: address, code: code)
        app.openTab("Library")
        if app.gridItems("Ready to free up").count < 2 { _ = app.compactOldestOnScreen(2) }

        for (name, columns) in [("landscape", 6), ("portrait", 5)] {
            pose(name, file: poses)
            XCTAssertTrue(app.wait(wide: name == "landscape"), "the screen didn't turn \(name)")
            checkGrid(app, columns: columns, pose: name)
            checkItem(app, pose: name)
            checkFreeUp(app, pose: name)
            checkActivity(app, pose: name)
            checkServer(app, pose: name)
        }

        // Partly folded, held tall like a laptop: the grid stays where it was (content doesn't move
        // for the fold; the system moves its own bars and sheets).
        app.openTab("Library")
        let flat = app.gridRow().map(\.frame)
        pose("laptop", file: poses)
        sleep(2)
        attach(app, "laptop, Library")
        XCTAssertEqual(app.gridRow().map(\.frame), flat, "the grid moved when half folded")
        XCTAssertEqual(app.state, .runningForeground)

        // Fold and unfold with pages open in every tab (nested stacks used to crash here).
        pose("landscape", file: poses)
        XCTAssertTrue(app.wait(wide: true))
        app.openTab("Server")
        XCTAssertTrue(app.scrollSidebar(to: app.buttons["settings.help"]), "no Help and About row")
        app.buttons["settings.help"].tap()
        XCTAssertTrue(app.buttons["help.report"].waitForExistence(timeout: 10), "no Help and About")
        app.openTab("Library")
        XCTAssertTrue(app.openItem(), "no item viewer")
        pose("folded", file: poses)
        XCTAssertTrue(app.wait(width: 0..<500), "didn't fold")
        attach(app, "folded, item open")
        XCTAssertEqual(app.state, .runningForeground, "crashed when folding")
        app.closeItem()
        XCTAssertTrue(app.openItem(), "no item viewer after folding")
        attach(app, "folded, another item")
        app.closeItem()
        checkGrid(app, columns: 4, pose: "folded")
        // Folding goes back to the list, and its pages open with Back.
        app.openTab("Server")
        let check = app.buttons["settings.check"]
        XCTAssertTrue(check.waitForExistence(timeout: 10) || app.scrollSidebar(to: check, up: true), "no Server list when folded")
        attach(app, "folded, Server")
        XCTAssertTrue(app.scrollSidebar(to: app.buttons["settings.help"]), "no Help and About row when folded")
        app.buttons["settings.help"].tap()
        XCTAssertTrue(app.buttons["help.report"].waitForExistence(timeout: 10), "Help and About didn't open when folded")
        // The visible Back (in the strip on the cover); a hidden one stays in the tree from the open layout.
        sleep(1)
        let back = app.buttons.matching(identifier: "BackButton").allElementsBoundByIndex
            .first { app.isOnScreen($0) && $0.frame.width > 20 }
        XCTAssertNotNil(back, "no Back after folding")
        back?.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["help.report"].waitForNonExistence(timeout: 5), "Back didn't leave Help and About")
        XCTAssertTrue(app.scrollSidebar(to: check, up: true), "Back didn't return to the list")
        check.tap()
        XCTAssertTrue(app.descendants(matching: .any)["check.server"].waitForExistence(timeout: 10), "no Server Check when folded")
        pose("landscape", file: poses)
        XCTAssertTrue(app.wait(wide: true), "didn't unfold")
        XCTAssertEqual(app.state, .runningForeground, "crashed when unfolding")
        XCTAssertTrue(app.descendants(matching: .any)["check.server"].waitForExistence(timeout: 10),
                      "Server Check isn't beside the list after unfolding")
        XCTAssertTrue(app.buttons["settings.check"].exists, "no list after unfolding")
        attach(app, "unfolded again, Server")
    }

    @MainActor func testVideosCompareSideBySide() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let poses = environment["DUO_POSE_FILE"], let address = environment["HOMESPUN_SERVER"],
              let code = environment["HOMESPUN_PAIRING_CODE"] else {
            throw XCTSkip("Run on the open iPhone Duo with DUO_POSES=1 and a test server.")
        }
        let app = XCUIApplication()
        app.launchArguments += ["-onboardingComplete", "YES", "-hideTips"]
        pose("landscape", file: poses)
        app.launch()
        app.pair(address: address, code: code)
        app.choose("grid.filter", "Videos")
        let videos = NSPredicate(format: "label BEGINSWITH 'Video'")
        // A retry finds the video the first attempt compacted (the test server keeps it).
        if !app.gridItems("Ready to free up").matching(videos).firstMatch.waitForExistence(timeout: 10) {
            XCTAssertEqual(app.compactNewest(1, matching: videos), 1)
        }

        for name in ["landscape", "portrait"] {
            pose(name, file: poses)
            XCTAssertTrue(app.wait(wide: name == "landscape"), "didn't turn \(name)")
            let offer = app.buttons["accessory.action"]
            XCTAssertTrue(offer.waitForExistence(timeout: 10), "no Free Up offer")
            offer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            let play = app.buttons["compare.play"]
            if !play.waitForExistence(timeout: 5) {
                for thumbnail in app.buttons.matching(identifier: "remove.compare").allElementsBoundByIndex {
                    thumbnail.tap()
                    if play.waitForExistence(timeout: 3) { break }
                }
            }
            XCTAssertTrue(play.waitForExistence(timeout: 10), "no Side by Side for the video")
            let original = app.descendants(matching: .any)["compare.image.original"]
            let compact = app.descendants(matching: .any)["compare.image.compact"]
            XCTAssertTrue(app.descendants(matching: .any)["compare.original"].waitForExistence(timeout: 30))
            XCTAssertTrue(app.descendants(matching: .any)["compare.compact"].waitForExistence(timeout: 30))
            XCTAssertTrue(original.exists && compact.exists)
            attach(app, "\(name), videos side by side")
            XCTAssertTrue(original.frame.maxX <= compact.frame.minX + 1 || original.frame.maxY <= compact.frame.minY + 1,
                          "the original must come first without overlapping")
            let screen = app.windows.firstMatch.frame
            for pane in [original, compact] {
                XCTAssertTrue(pane.frame.height > screen.height * 0.4 || pane.frame.width > screen.width * 0.3,
                              "\(name): the video pane is small: \(pane.frame)")
            }
            play.tap()
            XCTAssertEqual(play.label, "Pause both")
            let position = app.sliders["compare.position"]
            let deadline = Date().addingTimeInterval(10)
            while (position.value as? String ?? "0:00").hasPrefix("0:00"), Date() < deadline { usleep(200_000) }
            // CI's videos last 2 s: on a busy machine they can end (and stop) before the second tap.
            if play.label == "Pause both" {
                play.tap()
            }
            XCTAssertTrue(play.wait(for: \.label, toEqual: "Play both", timeout: 10), "the videos didn't pause or stop")
            XCTAssertFalse((position.value as? String ?? "").hasPrefix("0:00"), "both videos stayed at the start")
            let sound = app.buttons["compare.sound"], heard = app.buttons["compare.sound"].value as? String
            sound.tap()
            XCTAssertNotEqual(sound.value as? String, heard, "Sound didn't switch sides")
            let close = app.buttons["remove.close"]
            close.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            XCTAssertTrue(app.descendants(matching: .any)["grid"].waitForExistence(timeout: 10))
            let video = app.gridItems().matching(NSPredicate(format: "label BEGINSWITH 'Video'")).firstMatch
            XCTAssertTrue(video.waitForExistence(timeout: 10))
            video.tap()
            XCTAssertTrue(app.buttons["item.play"].waitForExistence(timeout: 10))
            app.buttons["item.compare"].tap()
            XCTAssertTrue(app.buttons["compare.play"].waitForExistence(timeout: 15), "the viewer's Compare isn't side by side")
            app.goBack()
            app.goBack()
            XCTAssertTrue(app.descendants(matching: .any)["grid"].waitForExistence(timeout: 10))
        }
        app.choose("grid.filter", "Photos and Videos")
    }

    // MARK: - Checks

    /// A full row of cells runs edge to edge with only the hairline spacing between them.
    @MainActor private func checkGrid(_ app: XCUIApplication, columns: Int, pose: String,
                                      file: StaticString = #filePath, line: UInt = #line) {
        app.openTab("Library")
        let grid = app.descendants(matching: .any)["grid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 10), file: file, line: line)
        sleep(1)
        XCTAssertGreaterThan(app.gridItems().allElementsBoundByIndex.filter { app.isOnScreen($0) }.count, 0,
                             "\(pose): the grid is blank", file: file, line: line)
        // Full rows are with the newest (a month each); photos still being added can leave the grid short of them.
        for _ in 0..<4 where app.gridRow().count < columns { grid.swipeUp(); sleep(1) }
        attach(app, "\(pose), Library")
        let row = app.gridRow().map(\.frame)
        XCTAssertEqual(row.count, columns, "\(pose): \(row)", file: file, line: line)
        guard let first = row.first, let last = row.last else { return }
        XCTAssertLessThan(first.minX - grid.frame.minX, 4, "\(pose): space before the first column", file: file, line: line)
        // Up to the vertical bar strip (84 pt) when the tabs are in it, else to the edge.
        let tabs = app.tab("Library"), strip = tabs.exists && tabs.frame.midX > grid.frame.maxX * 0.8
        XCTAssertLessThan(grid.frame.maxX - last.maxX, strip ? 90 : 4, "\(pose): space after the last column",
                          file: file, line: line)
        for (left, right) in zip(row, row.dropFirst()) {
            XCTAssertLessThan(right.minX - left.maxX, 4, "\(pose): a gap between \(left) and \(right)", file: file, line: line)
            XCTAssertEqual(left.width, right.width, accuracy: 1, "\(pose): uneven columns", file: file, line: line)
        }
    }

    /// The viewer fills the screen; Details opens beside the photo and closes again.
    @MainActor private func checkItem(_ app: XCUIApplication, pose: String) {
        app.openTab("Library")
        let tabs = app.tabFrames()
        XCTAssertTrue(app.openItem(), "\(pose): no item viewer")
        let viewer = app.descendants(matching: .any)["item.viewer"], screen = app.windows.firstMatch.frame
        XCTAssertGreaterThan(viewer.frame.width, screen.width * 0.85, "\(pose): the viewer isn't full width")
        XCTAssertFalse(app.isOnScreen(app.tab("Activity")), "\(pose): the tabs show over the viewer")
        attach(app, "\(pose), item")
        app.buttons["item.details"].tap()
        let details = app.descendants(matching: .any)["details.list"]
        XCTAssertTrue(details.waitForExistence(timeout: 10), "\(pose): no Details")
        sleep(1)
        attach(app, "\(pose), item details")
        XCTAssertGreaterThan(details.frame.minX, screen.midX, "\(pose): Details isn't at the side")
        XCTAssertTrue(viewer.exists && viewer.frame.width > screen.width * 0.4, "\(pose): Details covers the photo")
        app.buttons["details.done"].tap()
        XCTAssertTrue(details.waitForNonExistence(timeout: 5), "\(pose): Details didn't close")
        app.closeItem()
        XCTAssertEqual(app.tabFrames(), tabs, "\(pose): closing the viewer changed the tabs")
        let monitor = app.descendants(matching: .any)["perf.monitor"].firstMatch
        if monitor.exists {
            XCTAssertEqual(app.behind().changes, 0, "\(pose): the app behind the viewer changed")
        }
        XCTAssertTrue(app.descendants(matching: .any)["grid"].waitForExistence(timeout: 10), "\(pose): no grid after closing")
    }

    /// Free Up Space takes the whole screen: the chosen item compared side by side (beside or
    /// stacked, whichever shows the photo larger) with the review beside it held wide and under it
    /// held tall, Keep Original under it; never a sheet over a sheet.
    @MainActor private func checkFreeUp(_ app: XCUIApplication, pose: String) {
        app.openTab("Library")
        let offer = app.buttons["accessory.action"]
        guard offer.waitForExistence(timeout: 10) else { return XCTFail("\(pose): no Free Up offer") }
        offer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let original = app.descendants(matching: .any)["compare.image.original"]
        let compact = app.descendants(matching: .any)["compare.image.compact"]
        XCTAssertTrue(original.waitForExistence(timeout: 15) && compact.waitForExistence(timeout: 15),
                      "\(pose): Free Up Space doesn't compare side by side")
        XCTAssertTrue(app.descendants(matching: .any)["compare.compact"].waitForExistence(timeout: 30), "\(pose): no compact copy")
        sleep(2)
        attach(app, "\(pose), Free Up Space")
        let screen = app.windows.firstMatch.frame
        // The original first, the copy after it: beside it or under it, whichever shows the photo larger.
        XCTAssertTrue(original.frame.maxX <= compact.frame.minX + 1 || original.frame.maxY <= compact.frame.minY + 1,
                      "\(pose): the original and the copy overlap, or the copy comes first")
        if pose == "landscape" {
            XCTAssertTrue(app.buttons["remove.compare"].firstMatch.frame.maxX < original.frame.minX + 1,
                          "\(pose): the review isn't beside the comparison")
        } else {
            XCTAssertTrue(app.buttons["remove.compare"].firstMatch.frame.minY > max(original.frame.maxY, compact.frame.maxY) - 1,
                          "\(pose): the review isn't under the comparison")
        }
        // Each photo fills its pane one way (a portrait photo its height, a landscape one its width:
        // beside the other, held wide, a quarter of the screen and more).
        for image in [original, compact] {
            XCTAssertTrue(image.frame.height > screen.height * 0.4 || image.frame.width > screen.width * 0.25,
                          "\(pose): the comparison is small: \(image.frame)")
        }
        XCTAssertTrue(app.buttons["remove.keepOriginal"].exists, "\(pose): no Keep Original")
        XCTAssertEqual(app.sheets.count, 0, "\(pose): a sheet")
        let close = app.buttons["remove.close"]
        XCTAssertTrue(close.exists, "\(pose): no Close")
        close.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.descendants(matching: .any)["grid"].waitForExistence(timeout: 10), "\(pose): Close didn't return")
    }

    /// The newest run opens by itself; held wide, the list stays beside it.
    @MainActor private func checkActivity(_ app: XCUIApplication, pose: String) {
        app.openTab("Activity")
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'status.'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 15), "\(pose): Activity doesn't show the newest run")
        sleep(1)
        attach(app, "\(pose), Activity")
        guard pose == "landscape" else {
            // Held tall the run is across the width, the list behind the sidebar button (like Settings).
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == 'Show Sidebar'")).firstMatch.exists,
                          "\(pose): the list covers the run")
            return
        }
        let run = app.descendants(matching: .any).matching(identifier: "activity.run").firstMatch
        XCTAssertTrue(run.exists, "landscape: no list beside the run")
        XCTAssertLessThan(run.frame.maxX, rows.firstMatch.frame.minX + 1, "landscape: the list isn't beside the run")
    }

    /// Server Check opens by itself; another row replaces it (no Back, no empty page).
    @MainActor private func checkServer(_ app: XCUIApplication, pose: String) {
        app.openTab("Server")
        XCTAssertTrue(app.descendants(matching: .any)["check.server"].waitForExistence(timeout: 15),
                      "\(pose): Server doesn't open Server Check")
        sleep(1)
        attach(app, "\(pose), Server")
        if pose != "landscape" {
            // Held tall the list is behind the sidebar button, as in Settings.
            let sidebar = app.buttons.matching(NSPredicate(format: "label == 'Show Sidebar'"))
                .firstMatch
            guard sidebar.waitForExistence(timeout: 5) else { return XCTFail("\(pose): no sidebar button") }
            sidebar.tap()
        }
        let help = app.buttons["settings.help"]
        XCTAssertTrue(app.scrollSidebar(to: help), "\(pose): no list")
        help.tap()
        XCTAssertTrue(app.buttons["help.report"].waitForExistence(timeout: 10), "\(pose): Help and About didn't open")
        if pose != "landscape" {
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == 'Show Sidebar'")).firstMatch
                .waitForExistence(timeout: 5), "\(pose): the list stayed over Help and About")
        }
        sleep(1)
        attach(app, "\(pose), Server, Help and About")
        if pose == "landscape" {
            XCTAssertTrue(help.exists && help.frame.maxX < app.windows.firstMatch.frame.midX, "landscape: the list went away")
            XCTAssertTrue(help.isSelected, "landscape: the open row isn't highlighted")
        }
        // Back to Server Check, ready for the next pose.
        if pose != "landscape" {
            app.buttons.matching(NSPredicate(format: "label == 'Show Sidebar'")).firstMatch.tap()
        }
        let check = app.buttons["settings.check"]
        if app.scrollSidebar(to: check, up: true) { check.tap() }
        XCTAssertTrue(app.descendants(matching: .any)["check.server"].waitForExistence(timeout: 10))
    }

    // MARK: - Poses

    /// Asks `run-class.sh` to fold or turn the simulator, then waits until it has.
    @MainActor private func pose(_ name: String, file: String) {
        XCTAssertNoThrow(try name.write(toFile: file, atomically: true, encoding: .utf8))
        let deadline = Date().addingTimeInterval(90)
        while FileManager.default.fileExists(atPath: file), Date() < deadline { usleep(250_000) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file), "nobody turned the simulator \(name)")
        sleep(3)
    }

    /// A screenshot by `run-class.sh` (duoctl): XCTest's own shows the cover, black while the Duo is open.
    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        guard let file = ProcessInfo.processInfo.environment["DUO_POSE_FILE"] else { return }
        try? "shot \(name)".write(toFile: file, atomically: true, encoding: .utf8)
        let deadline = Date().addingTimeInterval(30)
        while FileManager.default.fileExists(atPath: file), Date() < deadline { usleep(250_000) }
    }
}

private extension XCUIApplication {
    /// The fullest row of grid cells on screen, left to right: whole cells, clear of the title and of the
    /// status accessory and tab bar at the bottom (a tap there lands on them).
    @MainActor func gridRow() -> [XCUIElement] {
        let screen = windows.firstMatch.frame
        let cells = gridItems().allElementsBoundByIndex.filter {
            $0.exists && $0.frame.minY >= screen.minY + 60 && $0.frame.maxY <= screen.maxY - 140
        }
        let rows = Dictionary(grouping: cells) { Int($0.frame.minY.rounded()) }
        let fullest = rows.values.max { $0.count < $1.count || ($0.count == $1.count && $0[0].frame.minY < $1[0].frame.minY) }
        return (fullest ?? []).sorted { $0.frame.minX < $1.frame.minX }
    }

    /// Opens a cell in the middle of the screen.
    /// A few tries, like ItemViewerUITests: a tap while the grid is still settling only stops it.
    @MainActor func openItem() -> Bool {
        for _ in 0..<3 {
            let row = gridRow()
            guard !row.isEmpty else { return false }
            row[row.count / 2].tap()
            if descendants(matching: .any)["item.viewer"].waitForExistence(timeout: 8) { return true }
        }
        return false
    }

    /// Back to the grid: Back, or swiping the viewer down.
    @MainActor func closeItem() {
        let viewer = descendants(matching: .any)["item.viewer"]
        guard viewer.exists else { return }
        goBack()
        if !viewer.waitForNonExistence(timeout: 3) { viewer.swipeDown(velocity: .fast) }
        _ = viewer.waitForNonExistence(timeout: 5)
    }

    /// Scrolls the sidebar (the list beside the detail, or the only one) until `element` is whole on
    /// screen, clear of the status accessory at the bottom.
    @MainActor func scrollSidebar(to element: XCUIElement, up: Bool = false) -> Bool {
        let screen = windows.firstMatch.frame
        let lists = collectionViews.allElementsBoundByIndex.filter { $0.exists && $0.frame.height > 200 }
        guard let list = lists.min(by: { $0.frame.width < $1.frame.width }) else { return false }
        for _ in 0..<10 {
            if element.exists, element.frame.minY > screen.minY + 60, element.frame.maxY < screen.maxY - 90 { return true }
            let from = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.3 : 0.7))
            from.press(forDuration: 0.05, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.7 : 0.3)))
            sleep(1)
        }
        return element.exists
    }

    /// Waits until the window is wide (or tall).
    @MainActor func wait(wide: Bool) -> Bool {
        let deadline = Date().addingTimeInterval(30)
        repeat {
            let frame = windows.firstMatch.frame
            if frame.width > 500, (frame.width > frame.height) == wide { return true }
            usleep(500_000)
        } while Date() < deadline
        return false
    }

    /// Waits until the window's width is in `range`.
    @MainActor func wait(width range: Range<CGFloat>) -> Bool {
        let deadline = Date().addingTimeInterval(15)
        repeat {
            if range.contains(windows.firstMatch.frame.width) { return true }
            usleep(500_000)
        } while Date() < deadline
        return false
    }
}
