// SPDX-License-Identifier: Apache-2.0
import Foundation

#if os(Linux) || os(macOS)
#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// Bridges cancellation into synchronous media backends dispatched off the Swift executor.
/// The scope is thread-local; each scope owns at most one running tool.
public final class MediaProcessCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var process: Process?
    private static let key = "photos.homespun.media.processCancellation"

    public init() {}

    public func run<T>(_ body: () throws -> T) throws -> T {
        let previous = Thread.current.threadDictionary[Self.key]
        Thread.current.threadDictionary[Self.key] = self
        defer { Thread.current.threadDictionary[Self.key] = previous }
        try check()
        let value = try body()
        try check()
        return value
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        let running = process
        lock.unlock()
        if let running { terminate(running) }
    }

    private func terminate(_ running: Process) {
        if running.isRunning { running.terminate() }
        // Escalation is only for cancellation, not a time limit on a legitimate long encode.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [self] in
            lock.lock()
            defer { lock.unlock() }
            if process === running, running.isRunning { _ = kill(running.processIdentifier, SIGKILL) }
        }
    }

    fileprivate static var current: MediaProcessCancellation? {
        Thread.current.threadDictionary[key] as? MediaProcessCancellation
    }

    var processID: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return process?.processIdentifier
    }

    fileprivate func start(_ process: Process) throws {
        try check()
        // Foundation's launch path can block. Cancellation must never wait for it while
        // occupying a cooperative executor thread; a raced cancellation is applied below.
        try process.run()
        lock.lock()
        self.process = process
        let stop = cancelled
        lock.unlock()
        if stop { terminate(process) }
    }

    fileprivate func finish() {
        lock.lock()
        process = nil
        lock.unlock()
    }

    fileprivate func check() throws {
        lock.lock()
        let cancelled = cancelled
        lock.unlock()
        if cancelled { throw CancellationError() }
    }
}

struct ProcessFailure: Error, CustomStringConvertible {
    let command: [String]
    let status: Int32
    let stderr: String
    var description: String { "\(command.first ?? "?") exited \(status): \(stderr.suffix(400))" }
}

enum ProcessRunner {
    /// Stdout is structured probe output, never media. Bound it separately from diagnostics.
    static let maximumOutputBytes = 64 << 20
    static let maximumDiagnosticBytes = 256 << 10

    /// One writer per drain; the caller reads only after joining its DispatchGroup.
    private final class Drain: @unchecked Sendable {
        private(set) var data = Data()
        private(set) var overflow = false
        private(set) var error: (any Error)?

        func read(_ handle: FileHandle, limit: Int, tail: Bool, onOverflow: (@Sendable () -> Void)? = nil) {
            defer { try? handle.close() }
            do {
                while let chunk = try handle.read(upToCount: 64 << 10), !chunk.isEmpty {
                    if tail {
                        data.append(chunk)
                        if data.count > limit { data.removeFirst(data.count - limit) }
                    } else {
                        let room = max(0, limit - data.count)
                        data.append(chunk.prefix(room))
                        if chunk.count > room, !overflow {
                            overflow = true
                            onOverflow?()
                        }
                    }
                }
            } catch { self.error = error }
        }
    }

    /// Runs a tool found on PATH and returns stdout; throws with stderr on failure.
    @discardableResult
    static func run(_ arguments: [String], outputLimit: Int = maximumOutputBytes) throws -> Data {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let cancellation = MediaProcessCancellation.current ?? MediaProcessCancellation()
        let stdout = Drain(), stderr = Drain(), drains = DispatchGroup()
        do { try cancellation.start(process) }
        catch {
            try? output.fileHandleForReading.close()
            try? errors.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
            try? errors.fileHandleForWriting.close()
            throw error
        }
        // The parent must not keep an extra write end open while waiting for EOF.
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
        drains.enter()
        DispatchQueue.global(qos: .utility).async {
            stdout.read(output.fileHandleForReading, limit: max(0, outputLimit), tail: false,
                        onOverflow: { cancellation.cancel() })
            drains.leave()
        }
        drains.enter()
        DispatchQueue.global(qos: .utility).async {
            stderr.read(errors.fileHandleForReading, limit: maximumDiagnosticBytes, tail: true)
            drains.leave()
        }
        process.waitUntilExit()
        cancellation.finish()
        drains.wait()
        guard !stdout.overflow else {
            throw ProcessFailure(command: arguments, status: process.terminationStatus,
                                 stderr: "Tool output exceeded \(outputLimit) bytes.")
        }
        try cancellation.check()
        try Task.checkCancellation()
        if let error = stdout.error ?? stderr.error { throw error }
        guard process.terminationStatus == 0 else {
            throw ProcessFailure(command: arguments, status: process.terminationStatus,
                                 stderr: String(decoding: stderr.data, as: UTF8.self))
        }
        return stdout.data
    }

    static func available(_ tool: String) -> Bool {
        (try? run(["which", tool])) != nil
    }
}
#endif
