// SPDX-License-Identifier: Apache-2.0
import XCTest

/// The extended oldserver run starts b35fc19, then upgrades the same TLS identity and catalog.
final class OldServerUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor private func launch(seed: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-onboardingComplete", "YES", "-hideTips", "-releaseFeatures", "YES"]
        if seed { app.launchArguments += ["-legacyBackUp", "3"] }
        app.launch()
        return app
    }

    @MainActor func test1EarlierBackupsAndUpdateAlert() throws {
        let env = ProcessInfo.processInfo.environment
        guard let address = env["HOMESPUN_SERVER"], let code = env["HOMESPUN_PAIRING_CODE"] else {
            throw XCTSkip("Set HOMESPUN_SERVER and HOMESPUN_PAIRING_CODE with the oldserver run.")
        }
        let app = launch(seed: true)
        app.pair(address: address, code: code)
        app.openTab("Library")
        try wait("Three earlier compact copies must have their 1.0 badges") {
            app.gridItems("Ready to free up").count == 3
        }
        XCTAssertEqual(app.gridItems("Backup not confirmed").count, 0)
        app.openTab("Activity")
        let notice = app.descendants(matching: .any)["server.updateNotice"].firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 20))
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '404'")).firstMatch.exists)
        app.openTab("Library")
        XCTAssertEqual(app.startCompacting(1), 1)
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        XCTAssertTrue(alert.label.contains("needs an update"))
        XCTAssertTrue(alert.staticTexts.containing(NSPredicate(format: "label CONTAINS 'existing backups'")).firstMatch.exists)
        alert.buttons["OK"].tap()
    }

    @MainActor func test2FreeUpAndRestoreOverV1() throws {
        guard ProcessInfo.processInfo.environment["HOMESPUN_SERVER"] != nil else {
            throw XCTSkip("Set HOMESPUN_SERVER with the oldserver run.")
        }
        let app = launch()
        app.openTab("Library")
        let ready = app.gridItems("Ready to free up").firstMatch
        XCTAssertTrue(ready.waitForExistence(timeout: 20))
        let readyBefore = app.gridItems("Ready to free up").count
        let backedBefore = app.gridItems("Backed up").count
        app.reveal(ready)
        ready.tap()
        XCTAssertTrue(app.buttons["item.action"].waitForExistence(timeout: 10))
        app.buttons["item.action"].tap()
        XCTAssertTrue(app.buttons["remove.confirm"].waitForExistence(timeout: 20))
        app.buttons["remove.confirm"].tap()
        try confirmDeletion(app)
        XCTAssertTrue(app.staticTexts["remove.summary"].waitForExistence(timeout: 60))
        app.buttons["remove.dismiss"].tap()
        try wait("The freed original must be at home") {
            app.staticTexts["item.state"].label.hasPrefix("Original at home")
        }
        XCTAssertTrue(app.buttons["item.action"].label.contains("Restore Original"))
        try restoreOriginal(app)
        // Restore keeps the original full size after its fresh server/device hash check.
        try wait("Restoring must keep one more original full size") {
            app.gridItems("Backed up").count == backedBefore + 1
                && app.gridItems("Ready to free up").count == readyBefore - 1
        }
        XCTAssertEqual(app.gridItems("Backup not confirmed").count, 0)
    }

    @MainActor func test3UpgradeKeepsLegacyActionsAndAdmitsNewV2Work() throws {
        let env = ProcessInfo.processInfo.environment
        guard let action = env["HOMESPUN_HOST_ACTION_FILE"], let upgraded = env["HOMESPUN_SERVER_UPGRADED_FILE"],
              let log = env["HOMESPUN_SERVER_LOG"] else {
            throw XCTSkip("Needs a server. Use the oldserver host-action watcher.")
        }
        let app = launch()
        app.openTab("Library")
        let legacyFilter = NSPredicate(format: "value CONTAINS 'Homespun 1.0'")
        try wait("An earlier backup must remain available") {
            app.gridItems("Ready to free up").matching(legacyFilter).count
                + app.gridItems("Original at home").matching(legacyFilter).count > 0
        }
        let before = app.gridItems().count
        let readyBefore = app.gridItems("Ready to free up").count
        let homeBefore = app.gridItems("Original at home").count
        let keptBefore = app.gridItems("Kept as is").count
        app.terminate()
        if !FileManager.default.fileExists(atPath: upgraded) {
            try Data("upgrade-server".utf8).write(to: URL(fileURLWithPath: action), options: .atomic)
            try wait("The 1.1 server must start on the same catalog and port") {
                FileManager.default.fileExists(atPath: upgraded)
            }
        }
        let offset = (try Data(contentsOf: URL(fileURLWithPath: log))).count
        app.launch()
        app.openTab("Library")
        try wait("The existing grid must remain unchanged after the server upgrade") {
            app.gridItems().count == before && app.gridItems("Ready to free up").count == readyBefore
                && app.gridItems("Original at home").count == homeBefore
        }
        XCTAssertEqual(app.gridItems("Backup not confirmed").count, 0)
        app.openTab("Activity")
        XCTAssertFalse(app.descendants(matching: .any)["server.updateNotice"].firstMatch.exists)
        app.openTab("Library")
        XCTAssertEqual(app.startCompacting(1), 1)
        try wait("New work must use v2, without duplicating the earlier copies") {
            let text = String(decoding: try Data(contentsOf: URL(fileURLWithPath: log)).dropFirst(offset), as: UTF8.self)
            return text.contains("/api/v2/backup-requests") && (app.gridItems("Ready to free up").count == readyBefore + 1
                || app.gridItems("Kept as is").count > keptBefore)
        }
        XCTAssertEqual(app.gridItems().count, before)
        // A still-legacy mapping continues through the v1 fresh-proof path on the updated server.
        let legacy = app.gridItems("Ready to free up").matching(legacyFilter).firstMatch
        if !legacy.exists {
            // A previous attempt may already have freed the last legacy original.
            let freed = app.gridItems("Original at home").matching(legacyFilter).firstMatch
            XCTAssertTrue(freed.exists)
            app.reveal(freed)
            freed.tap()
            XCTAssertTrue(app.buttons["item.action"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.buttons["item.action"].label.contains("Restore Original"))
            try restoreOriginal(app)
            return
        }
        app.reveal(legacy)
        legacy.tap()
        app.buttons["item.action"].tap()
        XCTAssertTrue(app.buttons["remove.confirm"].waitForExistence(timeout: 20))
        app.buttons["remove.confirm"].tap()
        try confirmDeletion(app)
        XCTAssertTrue(app.staticTexts["remove.summary"].waitForExistence(timeout: 60))
        app.buttons["remove.dismiss"].tap()
        try wait("Legacy Free Up must still work after updating") {
            app.staticTexts["item.state"].label.hasPrefix("Original at home")
        }
    }

    @MainActor private func restoreOriginal(_ app: XCUIApplication) throws {
        app.buttons["item.action"].tap()
        XCTAssertTrue(app.buttons["restore.confirm"].waitForExistence(timeout: 60))
        app.buttons["restore.confirm"].tap()
        try confirmDeletion(app)
        let summary = app.descendants(matching: .any)["restore.summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 60))
        XCTAssertTrue(summary.label.hasPrefix("Restored"), summary.label)
        app.buttons["restore.done"].tap()
    }

    @MainActor private func confirmDeletion(_ app: XCUIApplication) throws {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let buttons = [app.alerts.buttons["Delete"], springboard.alerts.buttons["Delete"]]
        try wait("iOS must ask before any original or compact deletion") { buttons.contains(where: \.exists) }
        try XCTUnwrap(buttons.first(where: \.exists)).tap()
    }

    @MainActor private func wait(_ message: String, _ condition: () throws -> Bool) throws {
        let deadline = Date().addingTimeInterval(180)
        repeat {
            if try condition() { return }
            usleep(250_000)
        } while Date() < deadline
        XCTFail(message)
        throw Failure.timeout
    }

    private enum Failure: Error { case timeout }
}
