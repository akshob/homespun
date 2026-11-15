// SPDX-License-Identifier: Apache-2.0
import XCTest

/// Finds compact copies made elsewhere through Settings, against a server that imported their
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
        app.launchArguments += ["-onboardingComplete", "YES"]
        app.launch()
        app.pair(address: address, code: code)
        XCTAssertEqual(app.gridItems("Backed up").count, 0)

        app.buttons["server.card"].tap()
        app.buttons["settings.findCopies"].tap()
        app.buttons["copies.start"].tap()
        let found = app.descendants(matching: .any)["copies.found"]
        XCTAssertTrue(found.waitForExistence(timeout: 120), "the check didn't finish")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Result"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertTrue(found.label.contains("Compact copies found, \(expected)") || found.label.contains("\(expected)"),
                      "found: \(found.label)")

        // Checking again finds nothing new to look at.
        app.buttons["copies.start"].tap()
        XCTAssertTrue(found.waitForExistence(timeout: 60))
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["Done"].tap()
        let backedUp = app.gridItems("Backed up")
        XCTAssertTrue(backedUp.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(backedUp.count, expected, "grid doesn't show the copies as backed up")
    }
}
