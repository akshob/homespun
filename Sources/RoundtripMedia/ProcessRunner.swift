import Foundation

struct ProcessFailure: Error, CustomStringConvertible {
    let command: [String]
    let status: Int32
    let stderr: String
    var description: String { "\(command.first ?? "?") exited \(status): \(stderr.suffix(400))" }
}

enum ProcessRunner {
    /// Runs a tool found on PATH and returns stdout; throws with stderr on failure.
    @discardableResult
    static func run(_ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ProcessFailure(command: arguments, status: process.terminationStatus,
                                 stderr: String(decoding: stderr, as: UTF8.self))
        }
        return stdout
    }

    static func available(_ tool: String) -> Bool {
        (try? run(["which", tool])) != nil
    }
}
