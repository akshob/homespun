// SPDX-License-Identifier: Apache-2.0
import XCTest

/// Pairs with a running Homespun Server, compacts the newest items through it, and optionally
/// removes the originals. Needs a fresh simulator with synthetic media and these variables
/// (pass them to `xcodebuild test` with a `TEST_RUNNER_` prefix):
/// `HOMESPUN_SERVER` (address), `HOMESPUN_PAIRING_CODE` (from `homespun-server pair`),
/// optional `HOMESPUN_PICK` (number of newest items, default 3) and `HOMESPUN_REMOVE=1`.
final class ServerModeUITests: XCTestCase {
    @MainActor func testCompactThroughServerAndRemoveOriginals() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let address = environment["HOMESPUN_SERVER"], let code = environment["HOMESPUN_PAIRING_CODE"] else {
            throw XCTSkip("Set HOMESPUN_SERVER and HOMESPUN_PAIRING_CODE to run against a server.")
        }
        let app = XCUIApplication()
        app.launchArguments += ["-onboardingComplete", "YES"]
        app.launch()

        let connect = app.buttons["connect.open"]
        if connect.waitForExistence(timeout: 5) {
            connect.tap()
            let addressField = app.textFields["server.address"]
            XCTAssertTrue(addressField.waitForExistence(timeout: 10))
            addressField.tap()
            addressField.typeText(address)
            let codeField = app.textFields["server.code"]
            codeField.tap()
            codeField.typeText(code)
            app.buttons["server.pair"].tap()
        }
        if !app.buttons["server.card"].waitForExistence(timeout: 20) {
            XCTFail("pairing failed: \(app.staticTexts["server.error"].label)")
        }
        XCTAssertTrue(app.staticTexts["Connected"].waitForExistence(timeout: 15), "server not reachable")
        attach(app, "Paired")

        app.buttons["Choose photos and videos"].tap()
        let grid = app.images.matching(identifier: "PXGGridLayout-Info")
        XCTAssertTrue(grid.firstMatch.waitForExistence(timeout: 20), "photo picker did not show any items")
        let count = min(Int(environment["HOMESPUN_PICK"] ?? "") ?? 3, grid.count)
        for index in 0..<count { grid.element(boundBy: index).tap() }
        app.buttons["Done"].tap()

        let rows = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH 'status.'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10), "no items were queued")
        let busy = app.staticTexts.matching(NSPredicate(format: "identifier IN {'status.waiting', 'status.working'}"))
        let deadline = Date().addingTimeInterval(900)
        while busy.count > 0 && Date() < deadline { sleep(2) }
        attach(app, "Results")
        XCTAssertEqual(busy.count, 0, "items still working after 15 minutes")
        let failed = app.staticTexts.matching(identifier: "status.failed")
        XCTAssertEqual(failed.count, 0, failed.allElementsBoundByIndex.map(\.label).joined(separator: "; "))
        XCTAssertGreaterThan(app.staticTexts.matching(identifier: "status.saved").count, 0)

        guard environment["HOMESPUN_REMOVE"] == "1" else { return }
        let remove = app.buttons["remove.originals"]
        XCTAssertTrue(remove.waitForExistence(timeout: 20), "no originals offered for removal")
        for _ in 0..<4 where !remove.isHittable { app.swipeUp() }
        attach(app, "Before removal")
        remove.tap()
        // The first time, Homespun explains what removal does.
        let proceed = app.buttons["removal.continue"]
        if proceed.waitForExistence(timeout: 5) {
            attach(app, "Explanation")
            proceed.tap()
        }
        // iOS asks for confirmation; the alert may belong to the app or to SpringBoard.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let confirmation = [app.alerts.buttons["Delete"], springboard.alerts.buttons["Delete"]]
        let confirmDeadline = Date().addingTimeInterval(300)
        while Date() < confirmDeadline, !confirmation.contains(where: \.exists) { sleep(1) }
        attach(springboard, "Confirmation")
        guard let delete = confirmation.first(where: \.exists) else { return XCTFail("no deletion confirmation appeared") }
        delete.tap()
        let summary = app.staticTexts["remove.summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 60))
        attach(app, "Removed")
        XCTAssertTrue(summary.label.contains("Removed"), summary.label)
        let looksRight = app.buttons["trial.confirm"]
        XCTAssertTrue(looksRight.waitForExistence(timeout: 5), "trial check not offered")
        looksRight.tap()
        XCTAssertFalse(looksRight.waitForExistence(timeout: 2))
    }

    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
