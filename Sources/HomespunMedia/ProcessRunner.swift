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

    private final class Progress: @unchecked Sendable {
        private let lock = NSLock()
        private var pending = ""
        private var frame: Int64 = 0
        private var time: Int64 = 0
        private var advanced = ContinuousClock.now
        private(set) var timedOut = false

        func observe(_ data: Data) {
            lock.lock()
            defer { lock.unlock() }
            pending += String(decoding: data, as: UTF8.self)
            let lines = pending.split(separator: "\n", omittingEmptySubsequences: false)
            pending = String(String(lines.last ?? "").suffix(4096))
            for line in lines.dropLast() {
                let pair = line.split(separator: "=", maxSplits: 1)
                guard pair.count == 2, let value = Int64(pair[1].trimmingCharacters(in: .whitespaces)) else { continue }
                if pair[0] == "frame", value > frame { frame = value; advanced = .now }
                if pair[0] == "out_time_us", value > time { time = value; advanced = .now }
            }
        }

        func expire(after timeout: Duration) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !timedOut, ContinuousClock.now - advanced >= timeout else { return false }
            timedOut = true
            return true
        }

        func expired() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return timedOut
        }
    }

    /// One writer per drain; the caller reads only after joining its DispatchGroup.
    private final class Drain: @unchecked Sendable {
        private(set) var data = Data()
        private(set) var overflow = false
        private(set) var error: (any Error)?

        func read(_ handle: FileHandle, limit: Int, tail: Bool, onOverflow: (@Sendable () -> Void)? = nil,
                  observe: (@Sendable (Data) -> Void)? = nil) {
            defer { try? handle.close() }
            do {
                var bytes = [UInt8](repeating: 0, count: 64 << 10)
                while true {
                    let count = bytes.withUnsafeMutableBytes { buffer in
                        #if os(Linux)
                        Glibc.read(handle.fileDescriptor, buffer.baseAddress!, buffer.count)
                        #else
                        Darwin.read(handle.fileDescriptor, buffer.baseAddress!, buffer.count)
                        #endif
                    }
                    if count == 0 { break }
                    if count < 0 {
                        if errno == EINTR { continue }
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    let chunk = Data(bytes.prefix(count))
                    observe?(chunk)
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
    static func run(_ arguments: [String], outputLimit: Int = maximumOutputBytes, progressTimeout: TimeInterval? = nil) throws -> Data {
        try Task.checkCancellation()
        let process = Process()
        process.qualityOfService = .utility
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let cancellation = MediaProcessCancellation.current ?? MediaProcessCancellation()
        let progress = progressTimeout.map { _ in Progress() }
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
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        if let progress, let timeout = progressTimeout, timeout.isFinite, timeout > 0 {
            let interval = max(100, Int(min(5, timeout / 4) * 1000))
            timer.schedule(deadline: .now() + .milliseconds(interval), repeating: .milliseconds(interval))
            timer.setEventHandler {
                if progress.expire(after: .seconds(timeout)) { cancellation.cancel() }
            }
        }
        timer.resume()
        defer { timer.cancel() }
        drains.enter()
        DispatchQueue.global(qos: .utility).async {
            stdout.read(output.fileHandleForReading, limit: progress == nil ? max(0, outputLimit) : maximumDiagnosticBytes,
                        tail: progress != nil, onOverflow: { cancellation.cancel() },
                        observe: { progress?.observe($0) })
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
        if progress?.expired() == true {
            throw ProcessFailure(command: arguments, status: process.terminationStatus,
                                 stderr: "Encoding stalled: no encoded frame or output media time advanced within the progress window.")
        }
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
