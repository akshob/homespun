// SPDX-License-Identifier: Apache-2.0
import Foundation
import MetricKit
import os

/// MetricKit: iOS's daily performance metrics (launch time, hangs, memory, battery) and its crash
/// and hang diagnostics, delivered the next time Homespun starts on iPhones whose owner allows
/// Share With App Developers (Settings › Privacy & Security › Analytics & Improvements). They go to
/// the developer only if the person shares analytics; the latest diagnostics also stay on this
/// iPhone for a problem report.
final class MetricsReceiver: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    @MainActor static let shared = MetricsReceiver()
    private let telemetry: Telemetry
    private let store: DiagnosticsStore

    @MainActor init(telemetry: Telemetry = .shared, store: DiagnosticsStore = .shared) {
        self.telemetry = telemetry
        self.store = store
        super.init()
    }

    func start() { MXMetricManager.shared.add(self) }

    func didReceive(_ payloads: [MXMetricPayload]) {
        let payloads = payloads.map { ($0.jsonRepresentation(), $0.timeStampBegin, $0.timeStampEnd) }
        Task { @MainActor in
            for (data, begin, end) in payloads {
                await receive(data, begin: begin, end: end, kind: "metrics")
            }
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let payloads = payloads.map { ($0.jsonRepresentation(), $0.timeStampBegin, $0.timeStampEnd) }
        Task { @MainActor in
            for (data, begin, end) in payloads {
                await receive(data, begin: begin, end: end, kind: "diagnostics")
            }
        }
    }

    /// Also used by tests without manufacturing system-owned MetricKit payloads.
    @MainActor func receive(_ data: Data, begin: Date, end: Date, kind: String) async {
        guard !telemetry.paused, telemetry.diagnosticPolicy.allows(begin: begin, end: end) else { return }
        if kind == "diagnostics" { store.keep(data, begin: begin, end: end) }
        await telemetry.upload(payload: data, kind: kind, begin: begin, end: end)
    }
}

/// MetricKit aggregates can arrive days later and cover both namespaces. Drop the *whole*
/// overlapping payload, even its real-use portion. Intervals survive relaunch; an interrupted
/// demo stays open until a real launch/leave resolves it. Before this policy existed attribution
/// was unknown, so historical payloads are conservatively excluded too.
@MainActor
final class DiagnosticPolicy {
    private struct Interval: Codable {
        var begin: Date
        var end: Date?
    }
    private struct History: Codable {
        var since: Date
        var intervals: [Interval]
    }
    private let defaults: UserDefaults
    private let now: () -> Date
    private var history: History
    private static let key = "diagnostics.demoIntervals"

    init(defaults: UserDefaults, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
        if let data = defaults.data(forKey: Self.key) {
            // Corrupt attribution history is not permission to collect.
            history = (try? JSONDecoder().decode(History.self, from: data))
                ?? History(since: .distantFuture, intervals: [])
        } else {
            history = History(since: now(), intervals: [])
            persist()
        }
    }

    func setDemo(_ on: Bool) {
        if on {
            if history.intervals.last?.end != nil || history.intervals.isEmpty {
                history.intervals.append(Interval(begin: now()))
            }
        } else if let last = history.intervals.indices.last, history.intervals[last].end == nil {
            history.intervals[last].end = now()
        }
        persist()
    }

    func allows(begin: Date, end: Date) -> Bool {
        guard begin >= history.since, begin <= end, end <= now() else { return false }
        return !history.intervals.contains { begin <= ($0.end ?? .distantFuture) && end >= $0.begin }
    }

    private func persist() {
        // History contains only finite Dates and is always JSON encodable.
        do { defaults.set(try JSONEncoder().encode(history), forKey: Self.key) }
        catch {
            history.since = .distantFuture
            Logger(subsystem: "photos.homespun.app", category: "Diagnostics").error("Diagnostic attribution unavailable.")
        }
    }
}

/// The last few MetricKit diagnostic payloads, for problem reports.
@MainActor
final class DiagnosticsStore {
    static let shared = DiagnosticsStore()
    static let kept = 3

    private let folder: URL
    private let isPaused: () -> Bool
    private struct Stored: Codable {
        var begin: Date
        var end: Date
        var payload: Data
    }

    init(folder: URL = URL.applicationSupportDirectory.appendingPathComponent("Homespun/diagnostics"),
         isPaused: @escaping () -> Bool = { Telemetry.shared.paused }) {
        self.folder = folder
        self.isPaused = isPaused
    }

    func keep(_ payload: Data, begin: Date, end: Date) {
        guard !isPaused() else { return }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let name = "\(Int(Date().timeIntervalSince1970 * 1000)).json"
            let stored = Stored(begin: begin, end: end, payload: payload)
            try JSONEncoder().encode(stored).write(to: folder.appendingPathComponent(name), options: .atomic)
            for old in files().dropFirst(Self.kept) { try FileManager.default.removeItem(at: old) }
        } catch {
            Logger(subsystem: "photos.homespun.app", category: "Diagnostics").error("Could not retain diagnostics on this device.")
        }
    }

    /// The newest payload, decoded (nil if there is none).
    func latest() -> [String: Any]? {
        guard !isPaused() else { return nil }
        for file in files() {
            // Old raw caches predate trustworthy demo attribution and must not enter a report.
            guard let data = try? Data(contentsOf: file),
                  let stored = try? JSONDecoder().decode(Stored.self, from: data),
                  stored.begin <= stored.end,
                  let payload = try? JSONSerialization.jsonObject(with: stored.payload) as? [String: Any] else { continue }
            return payload
        }
        return nil
    }

    /// Newest first (names are millisecond timestamps).
    private func files() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return names.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
}

/// Intervals MetricKit measures (its daily metrics report their counts and durations).
enum Signposts {
    static let backUp = MXMetricManager.makeLogHandle(category: "BackUp")
    static let freeUp = MXMetricManager.makeLogHandle(category: "FreeUp")
    static let library = MXMetricManager.makeLogHandle(category: "Library")

    /// Runs `body` where the caller runs (its actor), between a begin and an end signpost.
    static func measure<T>(_ log: OSLog, _ name: StaticString, isolation: isolated (any Actor)? = #isolation,
                           _ body: () async throws -> T) async rethrows -> T {
        let id = OSSignpostID(log: log)
        mxSignpost(.begin, log: log, name: name, signpostID: id)
        defer { mxSignpost(.end, log: log, name: name, signpostID: id) }
        return try await body()
    }
}

/// Notices when Homespun quit while it was on screen (a crash, or iOS ending it for using too much
/// memory or hanging): set while active, cleared in the background. iOS itself shows nothing when
/// an app crashes, so Homespun offers a problem report once.
@MainActor @Observable
final class SessionMarker {
    static let shared = SessionMarker()

    /// The last session ended while Homespun was on screen.
    private(set) var endedUnexpectedly: Bool
    /// Show the "quit unexpectedly" question (once per such ending).
    var offersReport = false
    private let defaults: UserDefaults
    private let telemetry: Telemetry

    init(defaults: UserDefaults = .standard, telemetry: Telemetry = .shared) {
        self.defaults = defaults
        self.telemetry = telemetry
        endedUnexpectedly = !telemetry.paused && (defaults.bool(forKey: "session.foreground") || Self.simulated(defaults))
        defaults.set(false, forKey: "session.foreground")
        if endedUnexpectedly {
            telemetry.record(.crashMarker())
            offersReport = Self.asks(defaults)
        }
    }

    /// UI tests: `-simulateUncleanExit YES` (Debug builds only).
    private static func simulated(_ defaults: UserDefaults) -> Bool {
        #if DEBUG
        defaults.bool(forKey: "simulateUncleanExit")
        #else
        false
        #endif
    }

    /// Debug builds are stopped from Xcode and by UI tests while on screen: they ask only with
    /// `-crashPrompt YES`.
    private static func asks(_ defaults: UserDefaults) -> Bool {
        #if DEBUG
        defaults.bool(forKey: "crashPrompt")
        #else
        true
        #endif
    }

    func active() { defaults.set(!telemetry.paused, forKey: "session.foreground") }
    func background() { defaults.set(false, forKey: "session.foreground") }
}
