// SPDX-License-Identifier: Apache-2.0
import XCTest

/// Screenshots of the real widgets for review, not part of any CI run: with
/// `TEST_RUNNER_HOMESPUN_WIDGET_SHOTS=<folder>` it adds Homespun's medium and small widgets to the Home
/// Screen from the widget gallery, then shows them with made-up facts (`-widgetDemo`): ready to free
/// up, the server out of reach, and locked. The screenshots are attachments, and PNGs in the folder.
/// For dark ones, set the simulator's appearance first (`xcrun simctl ui <id> appearance dark`) and
/// give another folder.
final class WidgetGalleryUITests: XCTestCase {
    @MainActor private var springboard: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.springboard") }

    @MainActor func testWidgetsOnTheHomeScreen() throws {
        try XCTSkipUnless(folder != nil, "Set TEST_RUNNER_HOMESPUN_WIDGET_SHOTS=<folder> for widget screenshots.")
        continueAfterFailure = false
        show("ready")
        addWidget(page: 1, shots: true)
        addWidget(page: 0, shots: false)
        for state in ["ready", "away", "locked"] {
            show(state)
            attach("Home Screen, \(state)")
        }
    }

    /// Opens the app with made-up facts for the widgets, then goes to the Home Screen.
    @MainActor private func show(_ state: String) {
        // Launching again ends the running app first.
        let app = XCUIApplication()
        app.launchArguments = ["-onboardingComplete", "YES", "-hideTips", "-widgetDemo", state]
        app.launch()
        XCTAssertTrue(app.hasTab("Library"))
        // The widgets get the facts once the main screen has loaded.
        sleep(6)
        XCUIDevice.shared.press(.home)
        sleep(4)
    }

    /// Edit Home Screen › Edit › Add Widget › Homespun, the size on `page`, Add Widget, Done.
    @MainActor private func addWidget(page: Int, shots: Bool) {
        // Still editing the Home Screen (an earlier run): stop first.
        if springboard.buttons["Done"].waitForExistence(timeout: 2) {
            springboard.buttons["Done"].tap()
            sleep(2)
        }
        // Homespun's own icon (not its widget) is on the page the Home button leads back to.
        let icon = springboard.icons.matching(NSPredicate(format: "identifier == 'Homespun' AND value != 'Widget'")).firstMatch
        XCTAssertTrue(icon.waitForExistence(timeout: 10), "no Home Screen")
        icon.press(forDuration: 2)
        tap(springboard.buttons["Edit Home Screen"], "Edit Home Screen")
        tap(springboard.buttons["Edit"], "Edit")
        tap(springboard.buttons["Add Widget"], "Add Widget")
        let search = springboard.searchFields.firstMatch
        tap(search, "the gallery's search field")
        search.typeText("Homespun")
        sleep(2)
        let named = NSPredicate(format: "label == 'Homespun'")
        let result = [springboard.cells.containing(named), springboard.buttons.matching(named),
                      springboard.staticTexts.matching(named)]
            .lazy.flatMap { $0.allElementsBoundByIndex }.first { $0.isHittable && $0.elementType != .icon }
        tap(result ?? springboard.cells.containing(named).firstMatch, "Homespun in the gallery")
        sleep(2)
        if shots { attach("Gallery, small") }
        for _ in 0..<page {
            springboard.swipeLeft()
            sleep(2)
        }
        if shots, page > 0 { attach("Gallery, medium") }
        // The gallery's own page is drawn by another process, out of the test's reach: its Add Widget
        // button is the wide one at the bottom.
        let add = springboard.buttons["Add Widget"]
        if add.waitForExistence(timeout: 3) {
            add.tap()
        } else {
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.905)).tap()
        }
        sleep(3)
        tap(springboard.buttons["Done"], "Done")
        sleep(3)
        // A busy simulator can miss the first tap.
        if springboard.buttons["Done"].exists { springboard.buttons["Done"].tap() }
        sleep(2)
    }

    @MainActor private func tap(_ element: XCUIElement, _ name: String) {
        guard element.waitForExistence(timeout: 15) else {
            let tree = XCTAttachment(string: springboard.debugDescription)
            tree.name = "Home Screen without \(name)"
            tree.lifetime = .keepAlways
            add(tree)
            attach("Without \(name)")
            XCTFail("no \(name)")
            return
        }
        element.tap()
    }

    private var folder: String? { ProcessInfo.processInfo.environment["HOMESPUN_WIDGET_SHOTS"] }

    @MainActor private func attach(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let shot = XCTAttachment(screenshot: screenshot)
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder else { return }
        let file = name.lowercased().replacingOccurrences(of: ", ", with: "-").replacingOccurrences(of: " ", with: "-")
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(file).png"))
    }
}
