// SPDX-License-Identifier: Apache-2.0
import XCTest

@MainActor @discardableResult
func requestDuoHostAction(_ action: String, requestFile: String, timeout: TimeInterval,
                          file: StaticString = #filePath, line: UInt = #line) -> Bool {
    let token = UUID().uuidString
    let reply = requestFile + "." + token + ".result"
    do {
        try (token + "\n" + action).write(toFile: requestFile, atomically: true, encoding: .utf8)
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !FileManager.default.fileExists(atPath: reply), ProcessInfo.processInfo.systemUptime < deadline {
            usleep(250_000)
        }
        guard FileManager.default.fileExists(atPath: reply) else {
            XCTFail("The host didn't complete simulator action \(action).", file: file, line: line)
            return false
        }
        let outcome = try String(contentsOfFile: reply, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        try FileManager.default.removeItem(atPath: reply)
        guard outcome == "ok" else {
            XCTFail("Simulator action \(action) failed on the host; see the poses log.", file: file, line: line)
            return false
        }
        return true
    } catch {
        XCTFail("Simulator action \(action) could not be exchanged: \(error.localizedDescription)", file: file, line: line)
        return false
    }
}
