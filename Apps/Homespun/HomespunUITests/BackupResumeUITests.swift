// SPDX-License-Identifier: Apache-2.0
import XCTest

/// Needs the `resume` run in ci/lane.sh: its isolated server, seed size, request log and host-action files.
final class BackupResumeUITests: XCTestCase {
    private struct Request {
        var method: String
        var path: String

        var uploadID: UUID? {
            let parts = path.split(separator: "/")
            guard parts.count == 4 || parts.count == 5 && parts[4] == "complete",
                  parts[0] == "api", parts[1] == "v2", parts[2] == "uploads",
                  method == "HEAD" || method == "PATCH" || method == "POST" && path.hasSuffix("/complete") else { return nil }
            return UUID(uuidString: String(parts[3]))
        }

        var isCompletion: Bool { method == "POST" && uploadID != nil && path.hasSuffix("/complete") }
        var isDerivative: Bool { method == "GET" && path.hasPrefix("/api/v2/derivatives/") }
        var isAcknowledgement: Bool {
            method == "POST" && path.hasPrefix("/api/v2/deliveries/") && path.hasSuffix("/ack")
        }
    }

    private enum Failure: Error { case timedOut(String) }

    private func requests(_ data: Data) -> [Request] {
        String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            guard line.contains("[Hummingbird] Request") else { return nil }
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard let method = fields.first(where: { $0.hasPrefix("hb.request.method=") }),
                  let path = fields.first(where: { $0.hasPrefix("hb.request.path=") }) else { return nil }
            return Request(method: String(method.dropFirst("hb.request.method=".count)),
                           path: String(path.dropFirst("hb.request.path=".count)))
        }
    }

    private func waitFor(_ message: String, timeout: TimeInterval, _ condition: () throws -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if try condition() { return }
            usleep(250_000)
        } while Date() < deadline
        XCTFail(message)
        throw Failure.timedOut(message)
    }

    @MainActor private func attach(_ screenshot: XCUIScreenshot, name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor func testQuitMidUploadAndAfterServerProcessingResumesWithoutReselecting() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let address = environment["HOMESPUN_SERVER"], let code = environment["HOMESPUN_PAIRING_CODE"] else {
            throw XCTSkip("Set HOMESPUN_SERVER and HOMESPUN_PAIRING_CODE with the resume CI run.")
        }
        guard let log = environment["HOMESPUN_SERVER_LOG"],
              let text = environment["HOMESPUN_SEED_VIDEO_BYTES"], let bytes = Int(text), bytes > 0,
              let action = environment["HOMESPUN_HOST_ACTION_FILE"],
              let settled = environment["HOMESPUN_COMPACT_SETTLED_FILE"] else {
            throw XCTSkip("Needs a server. Use the resume run's request log, seed size and host actions.")
        }
        let logURL = URL(fileURLWithPath: log)
        func readLog() throws -> Data { try Data(contentsOf: logURL) }
        let video = NSPredicate(format: "label BEGINSWITH 'Video'")
        let chunks = (bytes + 65_535) / 65_536
        let app = XCUIApplication()
        app.launchArguments += ["-onboardingComplete", "YES", "-hideTips"]
        app.launchEnvironment["HOMESPUN_TEST_UPLOAD_PACING"] = "65536,250"
        app.launch()
        app.pair(address: address, code: code)
        XCTAssertEqual(app.startCompacting(1, matching: video), 1)
        let midUpload = app.screenshot()
        var uploading: UUID?
        try waitFor("No upload reached four chunks", timeout: 90) {
            let patches = requests(try readLog()).filter { $0.method == "PATCH" && $0.uploadID != nil }
            let counts = Dictionary(grouping: patches, by: { $0.uploadID! })
            uploading = counts.first { $0.value.count >= 4 }?.key
            return uploading != nil
        }
        app.terminate()
        attach(midUpload, name: "Mid-upload")
        sleep(1)
        let killedLog = try readLog(), killOffset = killedLog.count
        let uploadID = try XCTUnwrap(uploading)
        let beforeRequests = requests(killedLog)
        XCTAssertEqual(Set(beforeRequests.compactMap(\.uploadID)), [uploadID])
        let before = beforeRequests.filter { $0.method == "PATCH" && $0.uploadID == uploadID }.count
        XCTAssertLessThan(before, chunks, "The first quit did not interrupt an upload")
        XCTAssertFalse(beforeRequests.contains { $0.isCompletion }, "The upload completed before the first quit")

        app.launch()
        let firstRelaunch = app.screenshot()
        // No taps, re-selection or retry: launch must recover the persisted upload itself.
        try waitFor("The relaunched app never completed its original upload", timeout: 120) {
            requests(try readLog()).contains { $0.isCompletion && $0.uploadID == uploadID }
        }
        app.terminate()
        let completedLog = try readLog(), completeOffset = completedLog.count
        attach(firstRelaunch, name: "After first relaunch")
        let resumed = requests(Data(completedLog.dropFirst(killOffset)))
        XCTAssertEqual(Set(resumed.compactMap(\.uploadID)), [uploadID], "Relaunch created a different upload")
        XCTAssertTrue(resumed.contains { $0.method == "HEAD" && $0.uploadID == uploadID }, "Relaunch did not re-read the server's offset")
        let after = resumed.filter { $0.method == "PATCH" && $0.uploadID == uploadID }.count
        XCTAssertLessThanOrEqual(before + after, chunks + 1, "The upload restarted instead of resuming at its durable offset")
        XCTAssertFalse(requests(completedLog).contains(where: \.isDerivative),
                       "The compact copy downloaded before the app quit; the closed-app case was not exercised")

        try Data("compact-settled".utf8).write(to: URL(fileURLWithPath: action), options: .atomic)
        try waitFor("The host did not finish waiting for server processing", timeout: 200) {
            !FileManager.default.fileExists(atPath: action)
        }
        XCTAssertEqual(try String(contentsOfFile: settled, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "ready")

        app.launch()
        XCTAssertTrue(app.gridItems("Ready to free up").matching(video).firstMatch.waitForExistence(timeout: 120),
                      "Launch did not save and verify the completed server result without user action")
        attach(app.screenshot(), name: "After final relaunch")
        try waitFor("The saved delivery was not acknowledged", timeout: 30) {
            requests(Data(try readLog().dropFirst(completeOffset))).contains(where: \.isAcknowledgement)
        }
        let delivered = requests(Data(try readLog().dropFirst(completeOffset)))
        XCTAssertTrue(delivered.contains(where: \.isDerivative), "The final launch never fetched the server's result")
        XCTAssertFalse(delivered.contains { $0.method == "PATCH" }, "The final launch re-uploaded an original")
        XCTAssertTrue(Set(delivered.compactMap(\.uploadID)).isSubset(of: [uploadID]), "The final launch created a new upload")
        let statuses = app.checkActivity()
        XCTAssertTrue(statuses.contains("status.saved"))
        XCTAssertFalse(statuses.contains("status.failed"))
    }
}
