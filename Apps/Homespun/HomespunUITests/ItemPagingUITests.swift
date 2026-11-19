// SPDX-License-Identifier: Apache-2.0
import UIKit
import XCTest

/// Swiping between items, then turning the iPhone (folding and unfolding iPhone Duo): the item shown
/// stays the same through every size, and each page shows its photo; zoomed in, a swipe doesn't page. No server needed; at least six
/// items (`EXTRA=` in ci/ui.sh). On iPhone Duo, pass `DUO_POSE_FILE` as for DuoLayoutUITests (with a
/// `TEST_RUNNER_` prefix): the test folds and turns the simulator through it.
final class ItemPagingUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// Upright again for the next tests (XCTest calls this on the main thread).
    override func tearDown() {
        super.tearDown()
        guard poses == nil else { return }
        MainActor.assumeIsolated { XCUIDevice.shared.orientation = .portrait }
    }

    private var poses: String? { ProcessInfo.processInfo.environment["DUO_POSE_FILE"] }

    @MainActor func testAVideoPlaysInTheViewer() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-onboardingComplete", "YES", "-hideTips"]
        app.launch()
        XCTAssertTrue(app.gridItems().firstMatch.waitForExistence(timeout: 30))
        app.choose("grid.filter", "Videos")
        let video = app.gridItems().matching(NSPredicate(format: "label BEGINSWITH 'Video'")).firstMatch
        XCTAssertTrue(video.waitForExistence(timeout: 10), "no seeded video")
        video.tap()
        let play = app.buttons["item.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 10), "no video controls")
        func labeled(_ label: String) -> Bool {
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label),
                                                          object: play)], timeout: 8) == .completed
        }
        XCTAssertTrue(labeled("Pause"), "the video didn't autoplay")
        XCTAssertTrue(labeled("Play"), "the video didn't end")
        let position = app.sliders["item.position"]
        let ended = position.value as? String ?? ""
        XCTAssertTrue(ended.hasPrefix("0:03") || ended.hasPrefix("0:02"), "no progress: \(ended)")
        play.tap()
        XCTAssertTrue(labeled("Pause"), "Play didn't restart")
        app.shownPage().tap()
        XCTAssertTrue(labeled("Play"), "tapping the page didn't pause")
        XCTAssertEqual(app.shownPage().value as? String, "Paused")
        if poses == nil {
            position.adjust(toNormalizedSliderPosition: 0.5)
            XCTAssertTrue((position.value as? String ?? "").hasPrefix("0:01"), "the scrubber didn't seek")
            let picture = XCTAttachment(screenshot: app.screenshot())
            picture.name = "Video controls"
            picture.lifetime = .keepAlways
            add(picture)
        }
        app.goBack()
        app.choose("grid.filter", "Photos and Videos")
    }

    @MainActor func testSwipingAndTurningKeepTheItem() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-onboardingComplete", "YES", "-hideTips"]
        app.launch()
        let items = app.gridItems()
        XCTAssertTrue(items.firstMatch.waitForExistence(timeout: 30), "no photos in the Library")
        sleep(2)
        // The newest item clear of the bars at the bottom (the grid opens at the newest).
        let screen = app.windows.firstMatch.frame
        guard let item = items.allElementsBoundByIndex.last(where: {
            app.isOnScreen($0) && $0.frame.maxY < screen.maxY - 140 && $0.frame.minY > screen.minY + 60
        }) else { return XCTFail("no item on screen") }
        item.tap()
        let viewer = app.descendants(matching: .any)["item.viewer"]
        XCTAssertTrue(viewer.waitForExistence(timeout: 10), "the item didn't open")
        guard var opened = position(viewer) else { return XCTFail("the viewer doesn't say which item: \(viewer.value ?? "")") }
        check(app, viewer, at: opened.index, "opened")
        // On to the newest (its cell can be under the bars), the newest photos (`EXTRA=`) behind it.
        while opened.index < opened.count {
            app.pageItem(older: false)
            opened.index += 1
            check(app, viewer, at: opened.index, "to the newest, \(opened.index)")
        }
        XCTAssertGreaterThan(opened.index, 5, "needs six items")

        // Five older items, one at a time, then back to the newest.
        for step in 1...5 {
            app.pageItem(older: true)
            check(app, viewer, at: opened.index - step, "\(step) back")
        }
        for step in (0..<5).reversed() {
            app.pageItem(older: false)
            check(app, viewer, at: opened.index - step, "\(5 - step) forward")
        }
        // Another item than the one opened, then other sizes: the same item stays.
        app.pageItem(older: true)
        app.pageItem(older: true)
        let shown = opened.index - 2
        check(app, viewer, at: shown, "2 back")
        if let poses {
            for name in ["portrait", "folded", "landscape"] {
                pose(name, file: poses)
                check(app, viewer, at: shown, name)
            }
        } else {
            for (orientation, name) in [(UIDeviceOrientation.landscapeLeft, "landscape"), (.portrait, "portrait")] {
                XCUIDevice.shared.orientation = orientation
                sleep(2)
                check(app, viewer, at: shown, name)
            }
        }
        app.pageItem(older: false)
        check(app, viewer, at: shown + 1, "after turning, 1 forward")

        // Zoomed in, a swipe pans the photo instead of paging; zoomed out, it pages again.
        let state = app.staticTexts["item.state"]
        XCTAssertTrue(state.waitForExistence(timeout: 5), "no state line")
        app.shownPage().doubleTap()
        XCTAssertTrue(state.waitForNonExistence(timeout: 5), "didn't zoom in")
        viewer.swipeRight()
        sleep(1)
        XCTAssertEqual(position(viewer)?.index, shown + 1, "a swipe paged while zoomed in")
        viewer.swipeDown()
        XCTAssertTrue(viewer.exists, "a downward pan dismissed a zoomed photo")
        XCTAssertEqual(position(viewer)?.index, shown + 1)
        app.shownPage().doubleTap()
        XCTAssertTrue(state.waitForExistence(timeout: 5), "didn't zoom out")
        let start = viewer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 35)),
                    withVelocity: .slow, thenHoldForDuration: 0.4)
        XCTAssertTrue(viewer.exists, "a short downward drag didn't cancel")
        app.pageItem(older: true)
        check(app, viewer, at: shown, "zoomed out, 1 back")
    }

    // MARK: - Checks

    /// Which item the viewer shows ("Item 3 of 40", one-based).
    @MainActor private func position(_ viewer: XCUIElement) -> (index: Int, count: Int)? {
        let words = (viewer.value as? String ?? "").split(separator: " ")
        guard words.count == 4, let index = Int(words[1]), let count = Int(words[3]) else { return nil }
        return (index, count)
    }

    /// The viewer settles on item `index`, with its photo on screen (not loading).
    @MainActor private func check(_ app: XCUIApplication, _ viewer: XCUIElement, at index: Int, _ when: String,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(10)
        while position(viewer)?.index != index, Date() < deadline { usleep(200_000) }
        XCTAssertEqual(position(viewer)?.index, index, "\(when): another item is shown", file: file, line: line)
        // Paging has stopped.
        sleep(1)
        let pages = app.descendants(matching: .any).matching(identifier: "item.page").allElementsBoundByIndex
            .filter { app.isOnScreen($0) }
        XCTAssertFalse(pages.isEmpty, "\(when): no page on screen", file: file, line: line)
        for page in pages {
            XCTAssertNotEqual(page.value as? String, "Loading", "\(when): the page has no photo", file: file, line: line)
        }
        // XCTest's screenshots of the open iPhone Duo show its cover; elsewhere, the photo is on screen.
        if poses == nil {
            let screenshot = app.screenshot()
            XCTAssertGreaterThan(Self.colourful(screenshot.image), 0.12, "\(when): the screen is blank", file: file, line: line)
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = when
            add(attachment)
        }
    }

    /// The share of the screen that isn't near black (the viewer's background).
    private static func colourful(_ image: UIImage) -> Double {
        guard let cgImage = image.cgImage else { return 0 }
        let width = 60, height = 120
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return 0 }
        let bright = stride(from: 0, to: pixels.count, by: 4).filter { max(pixels[$0], pixels[$0 + 1], pixels[$0 + 2]) > 48 }
        return Double(bright.count) / Double(width * height)
    }

    /// Asks `ui.sh` to fold or turn the simulator, then waits until it has (as DuoLayoutUITests does).
    @MainActor private func pose(_ name: String, file: String) {
        XCTAssertNoThrow(try name.write(toFile: file, atomically: true, encoding: .utf8))
        let deadline = Date().addingTimeInterval(90)
        while FileManager.default.fileExists(atPath: file), Date() < deadline { usleep(250_000) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file), "nobody turned the simulator \(name)")
        sleep(3)
    }
}
