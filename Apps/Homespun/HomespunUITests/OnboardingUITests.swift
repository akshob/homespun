// SPDX-License-Identifier: Apache-2.0
import XCTest

/// Walks the first run on a fresh simulator: welcome, connect, server check, Photos access, and
/// the main screen. With `HOMESPUN_PAIR_LINK` it pairs through the deep link `homespun-server pair`
/// prints; with `HOMESPUN_DISCOVER` (comma-separated names) it also expects those servers on the
/// network. Without a link it skips pairing. Screenshots of every step are attached.
final class OnboardingUITests: XCTestCase {
    @MainActor func testFirstRun() throws {
        let environment = ProcessInfo.processInfo.environment
        let app = XCUIApplication()
        app.launch()

        let start = app.buttons["onboarding.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10), "no welcome screen on first launch")
        attach(app, "1 Welcome")
        start.tap()

        XCTAssertTrue(app.textFields["server.address"].waitForExistence(timeout: 10), "no connect screen")
        let discover = (environment["HOMESPUN_DISCOVER"] ?? "").split(separator: ",")
        for name in discover {
            XCTAssertTrue(app.buttons["discovered.\(name)"].waitForExistence(timeout: 20), "server \(name) not discovered")
        }
        attach(app, "2 Connect")
        // Tapping a server asks a Mac to allow this iPhone (its screen and this one show a number),
        // or shows the command that prints a code. Cancelling withdraws the question.
        for name in discover {
            let server = app.buttons["discovered.\(name)"]
            let resolved = NSPredicate(format: "isEnabled == true")
            expectation(for: resolved, evaluatedWith: server)
            waitForExpectations(timeout: 15)
            server.tap()
            let outcome = app.descendants(matching: .any).matching(
                NSPredicate(format: "identifier IN {'pair.match', 'pair.command'}")).firstMatch
            XCTAssertTrue(outcome.waitForExistence(timeout: 15), "no way to pair with \(name)")
            attach(app, "2 Pair with \(name)")
            app.buttons["Cancel"].firstMatch.tap()
            XCTAssertTrue(app.textFields["server.address"].waitForExistence(timeout: 10))
        }
        if let link = environment["HOMESPUN_PAIR_LINK"].flatMap(URL.init(string:)) {
            app.open(link)
            let confirm = app.buttons["pair.confirm"]
            XCTAssertTrue(confirm.waitForExistence(timeout: 10), "pairing link not handled")
            attach(app, "3 Pair")
            confirm.tap()
            let outcome = app.descendants(matching: .any).matching(
                NSPredicate(format: "identifier IN {'check.ready', 'check.attention'}")).firstMatch
            XCTAssertTrue(outcome.waitForExistence(timeout: 30), "no server check after pairing")
            attach(app, "4 Server check")
            app.swipeUp()
            attach(app, "4b Server check")
            app.buttons["onboarding.continue"].tap()
        } else {
            app.buttons["onboarding.skip"].tap()
        }

        let allow = app.buttons["photos.allow"]
        if allow.waitForExistence(timeout: 5) {
            attach(app, "5 Photos access")
            allow.tap()
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            let full = springboard.buttons["Allow Full Access"].firstMatch
            if full.waitForExistence(timeout: 10) { full.tap() }
        } else {
            app.buttons["photos.done"].tap()
        }

        let paired = environment["HOMESPUN_PAIR_LINK"] != nil
        XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 15), "main screen")
        if paired { XCTAssertTrue(app.isConnected()) } else { XCTAssertTrue(app.buttons["connect.open"].exists) }
        attach(app, "6 Main")

        // A link to another server (from any app or page) warns before replacing this one.
        if let link = environment["HOMESPUN_PAIR_LINK"].flatMap({ URLComponents(string: $0) }) {
            var other = link
            other.queryItems = link.queryItems?.map { $0.name == "server" ? URLQueryItem(name: "server", value: "192.0.2.1:8787") : $0 }
            app.open(other.url!)
            XCTAssertTrue(app.descendants(matching: .any)["pair.replaces"].waitForExistence(timeout: 10), "no replace warning")
            XCTAssertTrue(app.buttons["pair.confirm"].label.hasPrefix("Replace"))
            attach(app, "7 Replace warning")
            app.buttons["Cancel"].tap()
            XCTAssertTrue(app.isConnected(timeout: 10), "pairing changed after cancel")
        }
    }

    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
