// SPDX-License-Identifier: Apache-2.0
import XCTest

/// Finds compact copies made elsewhere through Server › Existing Library, against a server that imported their
/// originals (`homespun-test/e2e-copies.sh` sets it up). Needs `HOMESPUN_SERVER`,
/// `HOMESPUN_PAIRING_CODE` and `HOMESPUN_COPIES` (how many copies the library holds), passed
/// to `xcodebuild test` with a `TEST_RUNNER_` prefix.
final class CopyFinderUITests: XCTestCase {
    @MainActor func testFindsCompactCopiesMadeElsewhere() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let address = environment["HOMESPUN_SERVER"], let code = environment["HOMESPUN_PAIRING_CODE"],
              let expected = environment["HOMESPUN_COPIES"].flatMap(Int.init) else {
            throw XCTSkip("Set HOMESPUN_SERVER, HOMESPUN_PAIRING_CODE and HOMESPUN_COPIES to run against a server.")
        }
        let app = XCUIApplication()
        app.launchArguments += ["-onboardingComplete", "YES", "-hideTips"]
        app.launch()
        app.pair(address: address, code: code)
        XCTAssertEqual(app.gridItems("Original at home").count, 0)

        app.openTab("Server")
        app.buttons["settings.existingLibrary"].tap()
        app.buttons["settings.findCopies"].tap()
        // The sheet explains first, then finds.
        XCTAssertTrue(app.buttons["copies.start"].waitForExistence(timeout: 10), "no explanation")
        app.buttons["copies.start"].tap()
        let found = app.descendants(matching: .any)["copies.found"]
        XCTAssertTrue(found.waitForExistence(timeout: 120), "the check didn't finish")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Result"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertTrue(found.label.contains("Compact copies found, \(expected)") || found.label.contains("\(expected)"),
                      "found: \(found.label)")

        // Running it again checks only what changed.
        app.buttons["copies.start"].tap()
        XCTAssertTrue(found.waitForExistence(timeout: 60))
        app.buttons["copies.done"].tap()
        XCTAssertTrue(app.buttons["settings.findCopies"].waitForExistence(timeout: 5))
        app.goBack()
        app.openTab("Library")
        let library = XCTAttachment(screenshot: app.screenshot())
        library.name = "Library"
        library.lifetime = .keepAlways
        add(library)
        let backedUp = app.gridItems("Original at home")
        XCTAssertTrue(backedUp.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(backedUp.count, expected, "grid doesn't show the copies as backed up")
    }
}
