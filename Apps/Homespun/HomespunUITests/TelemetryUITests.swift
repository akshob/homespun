// SPDX-License-Identifier: Apache-2.0
import XCTest

/// Analytics, problem reports and the "quit unexpectedly" question, against a telemetry stub
/// (`ci/lane.sh telemetry`, which checks what reached it) and a server to pair
/// with. The tests run in order on one simulator.
final class TelemetryUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private var stub: String? { ProcessInfo.processInfo.environment["TELEMETRY_STUB"] }

    @MainActor private func launch(_ arguments: [String] = []) throws -> XCUIApplication {
        guard let stub else { throw XCTSkip("Run with ci/lane.sh telemetry.") }
        let app = XCUIApplication()
        app.launchArguments += ["-onboardingComplete", "YES", "-hideTips", "-telemetryEndpoint", stub] + arguments
        app.launch()
        return app
    }

    @MainActor private func openServerRow(_ app: XCUIApplication, _ id: String, title: String) {
        app.openTab("Server")
        let row = app.buttons[id]
        XCTAssertTrue(app.reveal(row), "no \(id)")
        row.tap()
        XCTAssertTrue(app.hasScreen(title), "no \(title) page")
    }

    /// Setup asks after Ready; sharing sends setup steps, pairing and the server's kind.
    @MainActor func test1SetupAsksAndSharingWorks() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let address = environment["HOMESPUN_SERVER"], let code = environment["HOMESPUN_PAIRING_CODE"] else {
            throw XCTSkip("Needs a server.")
        }
        let app = try launch()
        app.pair(address: address, code: code, shareAnalytics: true)
        openServerRow(app, "settings.analytics", title: "Share Analytics")
        let toggle = app.switches["analytics.toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "1", "sharing isn't on after choosing Share")
        attach(app, "Share Analytics")
        // Leaving the app sends what's queued.
        XCUIDevice.shared.press(.home)
        sleep(4)
    }

    /// Report a Problem: write, see what's included, send, get a number.
    @MainActor func test2ReportAProblem() throws {
        let app = try launch()
        openServerRow(app, "settings.help", title: "Help and About")
        let report = app.buttons["help.report"]
        XCTAssertTrue(report.waitForExistence(timeout: 5))
        report.tap()
        let message = app.descendants(matching: .any)["report.message"]
        XCTAssertTrue(message.waitForExistence(timeout: 5), "no message field")
        let send = app.buttons["report.send"]
        XCTAssertFalse(send.isEnabled, "Send works without a message")
        message.tap()
        message.typeText("Test report from the UI tests: the backup stopped at 2 of 4 items.")
        let email = app.textFields["report.email"]
        email.tap()
        email.typeText("tester@example.com")
        attach(app, "Report a Problem")
        app.buttons["report.preview"].tap()
        let diagnostics = app.staticTexts["report.diagnostics"]
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 10))
        let text = diagnostics.label
        XCTAssertTrue(text.contains("\"library\"") && text.contains("\"server\"") && text.contains("\"recentRuns\""), text)
        XCTAssertFalse(text.contains("Home Mac") || text.contains("127.0.0.1"), "the server's name or address is included")
        attach(app, "What's Included")
        app.goBack()
        XCTAssertTrue(send.waitForExistence(timeout: 5) && send.isEnabled)
        send.tap()
        let id = app.staticTexts["report.id"]
        XCTAssertTrue(id.waitForExistence(timeout: 20), "no report number")
        // The stub answers HS-TEST01; the real service a new number.
        XCTAssertTrue(id.label.hasPrefix("Report HS-"), id.label)
        attach(app, "Report sent")
        let number = String(id.label.dropFirst("Report ".count))
        app.buttons["report.done"].tap()

        // Its number can be found again later: Help and About › Sent Reports.
        let sent = app.buttons["help.sentReports"]
        XCTAssertTrue(sent.waitForExistence(timeout: 10), "no Sent Reports")
        sent.tap()
        let row = app.descendants(matching: .any).matching(identifier: "reports.row").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no sent report listed")
        XCTAssertTrue(row.label.contains(number), "\(row.label) doesn't show \(number)")
        attach(app, "Sent reports")
        app.goBack(from: "Sent Reports")
    }

    /// After Homespun quit while on screen, it asks once and opens the report.
    @MainActor func test3QuitUnexpectedly() throws {
        let app = try launch(["-simulateUncleanExit", "YES", "-crashPrompt", "YES"])
        let alert = app.alerts["Homespun quit unexpectedly"]
        XCTAssertTrue(alert.waitForExistence(timeout: 15), "no question after an unexpected quit")
        attach(app, "Quit unexpectedly")
        alert.buttons["Report a Problem"].tap()
        let message = app.descendants(matching: .any)["report.message"]
        XCTAssertTrue(message.waitForExistence(timeout: 10), "the report didn't open")
        XCTAssertTrue(app.staticTexts["Homespun quit unexpectedly"].exists)
        attach(app, "Report after a crash")
        app.buttons["Cancel"].firstMatch.tap()
        XCUIDevice.shared.press(.home)
        sleep(4)
    }

    /// Delete Shared Data, then stop sharing.
    @MainActor func test4DeleteAndStop() throws {
        let app = try launch()
        openServerRow(app, "settings.analytics", title: "Share Analytics")
        let delete = app.buttons["analytics.delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5) && delete.isEnabled)
        delete.tap()
        // The dialog's button, not the list row with the same title.
        let confirm = app.buttons.matching(NSPredicate(format: "label == 'Delete Shared Data' AND identifier != 'analytics.delete'"))
            .firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "no confirmation")
        attach(app, "Delete shared data?")
        confirm.tap()
        XCTAssertTrue(app.descendants(matching: .any)["analytics.deleted"].waitForExistence(timeout: 15), "not deleted")
        let toggle = app.switches["analytics.toggle"]
        toggle.switches.firstMatch.exists ? toggle.switches.firstMatch.tap() : toggle.tap()
        XCTAssertEqual(toggle.value as? String, "0")
        attach(app, "Stopped sharing")
    }

    /// The launch/demo namespace is resolved before the cold-crash question or diagnostic intake.
    @MainActor func test5DemoLaunchNeverAttributesAColdCrashToTheRealSession() throws {
        let app = try launch(["-resetDemo", "-startDemo", "-holdDemoPreparation",
                              "-simulateUncleanExit", "YES", "-crashPrompt", "YES"])
        XCTAssertTrue(app.buttons["demo.prepare.cancel"].waitForExistence(timeout: 20), "demo did not prepare")
        XCTAssertFalse(app.alerts["Homespun quit unexpectedly"].exists)
        attach(app, "Demo launch without a real crash question")
        app.terminate()
    }

    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
