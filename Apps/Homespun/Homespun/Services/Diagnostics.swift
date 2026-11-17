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
    static let shared = MetricsReceiver()

    func start() { MXMetricManager.shared.add(self) }

    func didReceive(_ payloads: [MXMetricPayload]) {
        let payloads = payloads.map { $0.jsonRepresentation() }
        Task { @MainActor in
            for payload in payloads { await Telemetry.shared.upload(payload: payload, kind: "metrics") }
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let payloads = payloads.map { $0.jsonRepresentation() }
        Task { @MainActor in
            for payload in payloads {
                DiagnosticsStore.shared.keep(payload)
                await Telemetry.shared.upload(payload: payload, kind: "diagnostics")
            }
        }
    }
}

/// The last few MetricKit diagnostic payloads, for problem reports.
@MainActor
final class DiagnosticsStore {
    static let shared = DiagnosticsStore()
    static let kept = 3

    private let folder: URL

    init(folder: URL = URL.applicationSupportDirectory.appendingPathComponent("Homespun/diagnostics")) {
        self.folder = folder
    }

    func keep(_ payload: Data) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "\(Int(Date().timeIntervalSince1970 * 1000)).json"
        try? payload.write(to: folder.appendingPathComponent(name), options: .atomic)
        for old in files().dropFirst(Self.kept) { try? FileManager.default.removeItem(at: old) }
    }

    /// The newest payload, decoded (nil if there is none).
    func latest() -> [String: Any]? {
        guard let file = files().first, let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        endedUnexpectedly = defaults.bool(forKey: "session.foreground") || Self.simulated(defaults)
        defaults.set(false, forKey: "session.foreground")
        if endedUnexpectedly {
            Telemetry.shared.record(.crashMarker())
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

    func active() { defaults.set(true, forKey: "session.foreground") }
    func background() { defaults.set(false, forKey: "session.foreground") }
}
