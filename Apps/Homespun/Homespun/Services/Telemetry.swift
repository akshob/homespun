// SPDX-License-Identifier: Apache-2.0
import Foundation
import HomespunCore
import Observation
import os
import StoreKit
import UIKit

/// Analytics the person chose to share with Homespun's developer (asked once in setup, changed in
/// Server › Share Analytics). Only the events below, with rounded numbers and short codes: never
/// photos, file names, places, server names or addresses. Each opt-in gets a new random install ID,
/// so stopping and starting again can't be linked. Events wait in a small file and go out in
/// batches; nothing leaves the iPhone unless the person shares.
@MainActor @Observable
final class Telemetry {
    static let shared = Telemetry()

    enum Consent: String, Codable, Sendable { case unasked, sharing, notSharing }

    /// Production endpoint; Debug builds send only to an endpoint given with `-telemetryEndpoint`.
    nonisolated static let productionEndpoint = URL(string: "https://telemetry.homespun.photos")!
    /// A public key that only keeps random traffic out; the Worker checks it (services/telemetry).
    nonisolated static let appKey = "homespun-app-v1"
    static let maximumQueued = 500
    static let batchSize = 100

    private(set) var consent: Consent
    /// Random per opt-in; nil while not sharing. Shown in Settings for deleting shared data.
    private(set) var installID: UUID?
    /// Local only: never send these identities together or link consent periods on the service.
    private(set) var deletionHandles: Set<UUID> = []
    var queued: [Event] { entries.map(\.event) }
    private var entries: [Entry] = []
    private var generation = UUID()
    private var consentBegan: Date
    private var erasing: Set<UUID> = []
    /// Setup events before the person decided: kept in memory, sent only if they choose to share.
    private var beforeConsent: [Event] = []
    private var flushing: Set<UUID> = []
    private var flushWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    private var activeRequests: [UUID: Int] = [:]
    private var requestWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    private var deleting = false
    private var unreadableState = false
    private(set) var lastError: (any Error)?
    private var channel: AppInfo.Channel?
    let diagnosticPolicy: DiagnosticPolicy
    /// Demo retirement keeps this true until its last writer has stopped.
    var paused = false {
        didSet {
            diagnosticPolicy.setDemo(paused)
            if paused { defaults.set(false, forKey: "session.foreground") }
        }
    }

    let endpoint: URL?
    private let defaults: UserDefaults
    private let queueURL: URL
    private let now: () -> Date
    private let send: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    init(defaults: UserDefaults = .standard,
         queueURL: URL = URL.applicationSupportDirectory.appendingPathComponent("Homespun/telemetry-queue.json"),
         endpoint: URL? = Telemetry.defaultEndpoint,
         diagnosticPolicy: DiagnosticPolicy? = nil,
         now: @escaping () -> Date = Date.init,
         send: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }) {
        self.defaults = defaults
        self.queueURL = queueURL
        self.endpoint = endpoint
        self.send = send
        self.now = now
        self.diagnosticPolicy = diagnosticPolicy ?? DiagnosticPolicy(defaults: defaults, now: now)
        consent = defaults.string(forKey: "telemetry.consent").flatMap(Consent.init) ?? .unasked
        installID = defaults.string(forKey: "telemetry.install").flatMap(UUID.init)
        consentBegan = defaults.object(forKey: "telemetry.consentBegan") as? Date ?? now()
        do {
            let fence = try defaults.data(forKey: "telemetry.fence").map { try JSONDecoder().decode(Fence.self, from: $0) }
            if let fence {
                consent = fence.consent
                installID = fence.install
                generation = fence.generation
                consentBegan = fence.began
            }
            if FileManager.default.fileExists(atPath: queueURL.path) {
                let data = try Data(contentsOf: queueURL)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .millisecondsSince1970
                if let state = try? decoder.decode(State.self, from: data) {
                    consent = state.consent
                    installID = state.install
                    generation = state.generation
                    consentBegan = state.began
                    entries = state.entries
                    deletionHandles = state.handles
                    erasing = state.erasing
                    if let fence, fence.generation != state.generation {
                        // A consent change can outlive a failed queue-file write. Never resurrect
                        // its old consent or queue; keep its outstanding erasure handles.
                        generation = fence.generation
                        consent = fence.consent
                        installID = fence.install
                        consentBegan = fence.began
                        entries = []
                    }
                } else {
                    // Upgrade the old event-only queue without losing the legacy erasure handle.
                    decoder.dateDecodingStrategy = .iso8601
                    entries = try decoder.decode([Event].self, from: data).map { Entry(event: $0) }
                }
            }
            if let legacy = defaults.string(forKey: "telemetry.sentInstall").flatMap(UUID.init) {
                deletionHandles.insert(legacy)
            }
            if consent != .sharing { entries = [] }
            if consent == .sharing && installID == nil { installID = UUID() }
            if !ReleaseFeatures.premium { entries.removeAll { $0.event.name == "premium.event" } }
        } catch {
            // Do not overwrite an unreadable journal: it may hold the only erasure handles.
            unreadableState = true
            note(error)
        }
        if !unreadableState { saveOrNoteFailure() }
    }

    private struct Entry: Codable {
        var id = UUID()
        var event: Event
    }

    private struct State: Codable {
        var consent: Consent
        var install: UUID?
        var generation: UUID
        var began: Date
        var entries: [Entry]
        var handles: Set<UUID>
        var erasing: Set<UUID>
    }

    private struct Fence: Codable {
        var consent: Consent
        var install: UUID?
        var generation: UUID
        var began: Date
    }

    private func saveState() throws {
        guard !unreadableState else { throw TelemetryError.unavailable }
        try FileManager.default.createDirectory(at: queueURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(State(consent: consent, install: installID, generation: generation, began: consentBegan, entries: entries,
                                 handles: deletionHandles, erasing: erasing)).write(to: queueURL, options: .atomic)
        try saveConsentFence()
        defaults.removeObject(forKey: "telemetry.sentInstall")
        lastError = nil
    }

    private func saveOrNoteFailure() {
        do { try saveState() } catch { note(error) }
    }

    private func saveConsentFence() throws {
        // One value, not separately-written consent/install/generation keys.
        let fence = Fence(consent: consent, install: installID, generation: generation, began: consentBegan)
        defaults.set(try JSONEncoder().encode(fence), forKey: "telemetry.fence")
        defaults.set(consent.rawValue, forKey: "telemetry.consent")
        defaults.set(installID?.uuidString.lowercased(), forKey: "telemetry.install")
        defaults.set(consentBegan, forKey: "telemetry.consentBegan")
    }

    private func note(_ error: any Error) {
        lastError = error
        Logger(subsystem: "photos.homespun.app", category: "Telemetry").error("Telemetry operation failed; erasure state preserved.")
    }

    private func matches(_ token: UUID, _ install: UUID) -> Bool {
        isSharing && generation == token && installID == install && !erasing.contains(install)
    }

    /// Persist the attempt *before* issuing the request: a lost response may still mean stored data.
    private func transmit(_ request: URLRequest, install: UUID?, generation token: UUID) async throws -> (Data, URLResponse) {
        guard !paused, generation == token, !Task.isCancelled else { throw TelemetryError.rejected }
        if let install {
            guard matches(token, install) else { throw TelemetryError.rejected }
            deletionHandles.insert(install)
            try saveState()
            activeRequests[install, default: 0] += 1
        }
        defer {
            if let install {
                activeRequests[install, default: 1] -= 1
                if activeRequests[install] == 0 {
                    activeRequests.removeValue(forKey: install)
                    requestWaiters.removeValue(forKey: install)?.forEach { $0.resume() }
                }
            }
        }
        return try await send(request)
    }

    private func waitForRequests(_ install: UUID) async {
        if activeRequests[install, default: 0] > 0 {
            await withCheckedContinuation { requestWaiters[install, default: []].append($0) }
        }
    }

    /// Called only after DemoMode has resolved a resumed demo, before registering MetricKit.
    func resolveDiagnosticNamespace() {
        diagnosticPolicy.setDemo(paused)
    }

    nonisolated static var defaultEndpoint: URL? {
        #if DEBUG
        UserDefaults.standard.string(forKey: "telemetryEndpoint").flatMap(URL.init)
        #else
        productionEndpoint
        #endif
    }

    var isSharing: Bool { consent == .sharing }

    // MARK: Consent

    /// The person's choice (setup or Settings). Sharing starts a new install ID; stopping clears
    /// the queue and the ID (data already sent stays until deleted, see `deleteSharedData`).
    func setSharing(_ on: Bool) {
        if on {
            guard consent != .sharing else { return }
            consent = .sharing
            installID = UUID()
            generation = UUID()
            entries = beforeConsent.map { Entry(event: $0) }
            beforeConsent = []
        } else {
            consent = .notSharing
            installID = nil
            generation = UUID()
            entries = []
            beforeConsent = []
        }
        consentBegan = now()
        do {
            try saveConsentFence()
            if on { record(.analyticsOptIn) }
            try saveState()
        } catch { note(error) }
    }

    // MARK: Events

    /// Queues an event if the person shares (before they've decided, setup events wait in memory).
    func record(_ event: Event) {
        guard !paused else { return }
        guard ReleaseFeatures.premium || event.name != "premium.event" else { return }
        switch consent {
        case .sharing:
            entries.append(Entry(event: event))
            if entries.count > Self.maximumQueued { entries.removeFirst(entries.count - Self.maximumQueued) }
            saveOrNoteFailure()
            if queued.count >= Self.batchSize { Task { await flush() } }
        case .unasked:
            if event.name.hasPrefix("setup.") || event.name == "pair.result" || event.name == "server.info" {
                beforeConsent.append(event)
            }
        case .notSharing:
            break
        }
    }

    /// Sends what's queued, in batches; keeps it for next time if the network or the service fails.
    /// If a flush is already under way, waits for it instead of starting another.
    func flush() async {
        let token = generation
        if flushing.contains(token) {
            await withCheckedContinuation { flushWaiters[token, default: []].append($0) }
            return
        }
        guard !paused, isSharing, let endpoint, let installID, !entries.isEmpty else { return }
        flushing.insert(token)
        defer {
            flushing.remove(token)
            flushWaiters.removeValue(forKey: token)?.forEach { $0.resume() }
        }
        let channel = await currentChannel()
        while !paused, matches(token, installID), !entries.isEmpty, !Task.isCancelled {
            let batch = Array(entries.prefix(Self.batchSize))
            let body = Batch(install: installID.uuidString.lowercased(), app: AppInfo.current(channel: channel),
                             device: DeviceInfo.current, events: batch.map(\.event))
            do {
                let request = try Self.request(endpoint.appendingPathComponent("v1/events"), json: body)
                let (_, response) = try await transmit(request, install: installID, generation: token)
                guard let status = (response as? HTTPURLResponse)?.statusCode,
                      (200..<300).contains(status) || status == 400 || status == 410 else {
                    throw TelemetryError.rejected
                }
                guard matches(token, installID) else { return }
                // A full queue may have evicted some of this batch while the request was suspended.
                let acknowledged = Set(batch.map(\.id))
                entries.removeAll { acknowledged.contains($0.id) }
                try saveState()
            } catch {
                note(error)
                return
            }
        }
    }

    /// Flush while iOS gives the app a little time after it leaves the screen.
    func flushInBackground() {
        guard !paused, isSharing, !queued.isEmpty else { return }
        let task = UIApplication.shared.beginBackgroundTask(withName: "Analytics")
        Task {
            await flush()
            UIApplication.shared.endBackgroundTask(task)
        }
    }

    /// The server's kind and version: once a day, and when its version changes.
    func recordServerInfoDaily(_ info: ServerAPI.ServerInfo, now: Date = Date()) {
        guard !paused else { return }
        let key = "\(info.version).\(info.mode.rawValue)"
        let last = defaults.object(forKey: "telemetry.serverInfoDate") as? Date ?? .distantPast
        guard key != defaults.string(forKey: "telemetry.serverInfoKey") || now.timeIntervalSince(last) > 86_400 else { return }
        defaults.set(key, forKey: "telemetry.serverInfoKey")
        defaults.set(now, forKey: "telemetry.serverInfoDate")
        record(.serverInfo(info))
    }

    /// Asks the service to delete everything sent under this iPhone's install IDs. Sharing goes on
    /// with a new ID.
    func deleteSharedData() async throws {
        guard let endpoint else { throw TelemetryError.unavailable }
        guard !deleting else { throw TelemetryError.rejected }
        deleting = true
        defer { deleting = false }
        let targets = deletionHandles.union(erasing).union(installID.map { [$0] } ?? [])
        erasing.formUnion(targets)
        deletionHandles.formUnion(targets)
        entries = []
        generation = UUID()
        consentBegan = now()
        if isSharing { installID = UUID() }
        try saveConsentFence()
        try saveState()
        for id in targets {
            // Requests already on the wire cannot be recalled. Reconcile their completion before
            // erasing A, without blocking a new consent generation B from collecting or sending.
            await waitForRequests(id)
            var request = URLRequest(url: endpoint.appendingPathComponent("v1/installs/\(id.uuidString.lowercased())"))
            request.httpMethod = "DELETE"
            request.setValue(Self.appKey, forHTTPHeaderField: "X-Homespun-Key")
            let (_, response) = try await send(request)
            guard (response as? HTTPURLResponse)?.statusCode == 204 else {
                throw TelemetryError.rejected
            }
            erasing.remove(id)
            deletionHandles.remove(id)
            try saveState()
        }
    }

    var hasSharedData: Bool { !deletionHandles.isEmpty }

    // MARK: MetricKit and reports

    /// A MetricKit payload (`kind` "metrics" or "diagnostics"), sent at once if the person shares.
    func upload(payload json: Data, kind: String, begin: Date, end: Date) async {
        let token = generation
        guard !paused, isSharing, let endpoint, let installID,
              begin >= consentBegan, begin <= end, end <= now(),
              diagnosticPolicy.allows(begin: begin, end: end),
              let payload = try? JSONSerialization.jsonObject(with: json) else { return }
        let channel = await currentChannel()
        guard !paused, matches(token, installID) else { return }
        let body: [String: Any] = ["install": installID.uuidString.lowercased(),
                                   "app": AppInfo.current(channel: channel).dictionary,
                                   "device": DeviceInfo.current.dictionary, "payload": payload]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        var request = Self.baseRequest(endpoint.appendingPathComponent("v1/\(kind)"))
        request.httpBody = data
        do {
            let (_, response) = try await transmit(request, install: installID, generation: token)
            guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
                throw TelemetryError.rejected
            }
        } catch { note(error) }
    }

    /// Sends a problem report; returns its number ("HS-…"). Reports work whether or not the person
    /// shares analytics (they're sent on purpose). A reply address must never link analytics to a person.
    func sendReport(_ report: ProblemReport) async throws -> String {
        guard !paused, let endpoint else { throw TelemetryError.unavailable }
        let token = generation
        let reportInstall = report.email == nil && isSharing ? installID : nil
        let channel = await currentChannel()
        guard !paused, token == generation else { throw TelemetryError.rejected }
        var body: [String: Any] = ["install": reportInstall.map { $0.uuidString.lowercased() as Any } ?? NSNull(),
                                   "app": AppInfo.current(channel: channel).dictionary,
                                   "device": DeviceInfo.current.dictionary, "message": report.message]
        if let email = report.email { body["email"] = email }
        if let diagnostics = report.diagnostics { body["diagnostics"] = diagnostics }
        var request = Self.baseRequest(endpoint.appendingPathComponent("v1/reports"))
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await transmit(request, install: reportInstall, generation: token)
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw TelemetryError.rejected }
        guard (200..<300).contains(status),
              let id = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["id"] as? String else {
            throw status == 429 ? TelemetryError.tooMany : TelemetryError.rejected
        }
        if token == generation { record(.reportSent(withDiagnostics: report.diagnostics != nil)) }
        return id
    }

    // MARK: Helpers

    func currentChannel() async -> AppInfo.Channel {
        if let channel { return channel }
        let found = await AppInfo.channel()
        channel = found
        return found
    }

    nonisolated static func baseRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(appKey, forHTTPHeaderField: "X-Homespun-Key")
        return request
    }

    nonisolated static func request(_ url: URL, json: some Encodable) throws -> URLRequest {
        var request = baseRequest(url)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(json)
        return request
    }

    private struct Batch: Encodable {
        var install: String
        var app: AppInfo
        var device: DeviceInfo
        var events: [Event]
    }
}

enum TelemetryError: LocalizedError {
    case unavailable, rejected, tooMany

    var errorDescription: String? {
        switch self {
        case .unavailable: "Reports can't be sent from this build of the app."
        case .rejected: "The report couldn't be sent. Try again in a moment."
        case .tooMany: "Too many reports in a short time. Try again in a few minutes."
        }
    }
}

/// A problem report: what the person wrote, an optional reply address, and diagnostics they saw.
struct ProblemReport {
    var message: String
    var email: String?
    var diagnostics: [String: Any]?
}

// MARK: - Events

extension Telemetry {
    /// One event: a name from the catalog below and a few short properties (the Worker accepts
    /// only these names and keys).
    struct Event: Codable, Equatable, Sendable {
        enum Value: Codable, Equatable, Sendable {
            case int(Int), string(String), bool(Bool)

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let bool = try? container.decode(Bool.self) { self = .bool(bool) }
                else if let int = try? container.decode(Int.self) { self = .int(int) }
                else { self = .string(try container.decode(String.self)) }
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.singleValueContainer()
                switch self {
                case .int(let value): try container.encode(value)
                case .string(let value): try container.encode(value)
                case .bool(let value): try container.encode(value)
                }
            }
        }

        var name: String
        var time: Date
        var props: [String: Value]

        init(_ name: String, time: Date = Date(), _ props: [String: Value] = [:]) {
            self.name = name
            self.time = time
            self.props = props.mapValues { value in
                // Strings are short codes: letters, digits, dot, dash, underscore, colon.
                guard case .string(let text) = value else { return value }
                let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._:-"))
                return .string(String(text.unicodeScalars.filter { allowed.contains($0) && $0.isASCII }.prefix(64)))
            }
        }

        static func appLaunch() -> Event { Event("app.launch", ["cold": .bool(true)]) }
        static func setupStep(_ step: String) -> Event { Event("setup.step", ["step": .string(step)]) }
        static func setupChoice(_ question: String, _ answer: String) -> Event {
            Event("setup.choice", ["question": .string(question), "answer": .string(answer)])
        }
        static func setupDone(_ outcome: String) -> Event { Event("setup.done", ["outcome": .string(outcome)]) }
        static func pairResult(method: String, error: Error?) -> Event {
            var props: [String: Value] = ["method": .string(method), "outcome": .string(error == nil ? "ok" : "failed")]
            if let error { props["error"] = .string(Self.code(error)) }
            return Event("pair.result", props)
        }
        static func serverInfo(_ info: ServerAPI.ServerInfo) -> Event {
            var props: [String: Value] = ["mode": .string(info.mode.rawValue), "version": .string(info.version)]
            if let kind = info.hardware?.kind.rawValue { props["kind"] = .string(kind) }
            else if let os = info.platform?.os.rawValue { props["kind"] = .string(os) }
            if let os = info.platform?.os.rawValue, let kind = info.hardware?.kind.rawValue, kind != "container" {
                props["kind"] = .string("\(os).\(kind)")
            }
            return Event("server.info", props)
        }
        static func runFinished(_ run: RunHistory.Run) -> Event {
            let bytes = run.items.reduce(0) { $0 + ($1.originalBytes ?? 0) }
            return Event("run.finished", [
                "trigger": .string(run.trigger.rawValue), "items": .int(Bucket.count(run.items.count)),
                "bytes": .int(Bucket.megabytes(bytes)), "duration": .int(Bucket.seconds(run.end.timeIntervalSince(run.start))),
                "compacted": .int(Bucket.count(run.count(.saved))), "backedUp": .int(Bucket.count(run.count(.backedUp))),
                "failed": .int(Bucket.count(run.count(.failed))), "kept": .int(Bucket.count(run.count(.kept))),
                "notYet": .int(Bucket.count(run.count(.notYet)))])
        }
        static func freeUpFinished(items: Int, bytes: Int, first: Bool) -> Event {
            Event("freeup.finished", ["items": .int(Bucket.count(items)), "bytes": .int(Bucket.megabytes(bytes)),
                                      "first": .bool(first)])
        }
        static func featureUsed(_ feature: String, _ detail: String? = nil) -> Event {
            var props: [String: Value] = ["feature": .string(feature)]
            if let detail { props["detail"] = .string(detail) }
            return Event("feature.used", props)
        }
        static func premium(_ event: String, outcome: String? = nil) -> Event {
            var props: [String: Value] = ["event": .string(event)]
            if let outcome { props["outcome"] = .string(outcome) }
            return Event("premium.event", props)
        }
        static func error(_ error: Error, where place: String) -> Event {
            let parts = Self.code(error).split(separator: ":", maxSplits: 1).map(String.init)
            return Event("error", ["domain": .string(parts.first ?? "other"), "code": .string(parts.count > 1 ? parts[1] : "unknown"),
                                   "where": .string(place)])
        }
        static let analyticsOptIn = Event("analytics.optin")
        static func reportSent(withDiagnostics: Bool) -> Event { Event("report.sent", ["withDiagnostics": .bool(withDiagnostics)]) }
        static func crashMarker() -> Event { Event("crash.marker", ["foreground": .bool(true)]) }

        /// "domain:code" for an error, without its message (messages can hold names).
        static func code(_ error: Error) -> String {
            switch error {
            case is ServerClient.IdentityMismatch, is ServerPairing.IdentityFailure:
                return "tls_identity"
            case let failure as ServerClient.Failure:
                return "server:" + (failure.code ?? (failure.status == 0 ? "none" : String(failure.status)))
            case let failure as PhotoLibrary.Failure:
                // The case name only: associated values can hold file names.
                return "photos:" + (Mirror(reflecting: failure).children.first?.label ?? String(describing: failure))
            case let error as URLError:
                return "url:\(error.code.rawValue)"
            default:
                let error = error as NSError
                let domain = error.domain.split(separator: ".").last.map(String.init) ?? "other"
                return "\(domain.prefix(24)):\(error.code)"
            }
        }
    }

    func record(error: Error, where place: String) { record(.error(error, where: place)) }
}

/// Rounding, so numbers describe size without being exact: 0, 1, 2, 5, 10, 20, 50, 100, …
enum Bucket {
    /// The largest of 1, 2, 5, 10, 20, 50, … that isn't above `value` (0 for 0 or less).
    static func count(_ value: Int) -> Int {
        guard value > 0 else { return 0 }
        var best = 1, step = 1
        while step <= value {
            for multiple in [1, 2, 5] where step * multiple <= value { best = step * multiple }
            guard step <= Int.max / 10 else { break }
            step *= 10
        }
        return best
    }

    static func megabytes(_ bytes: Int) -> Int { count(bytes / 1_000_000) }

    static func seconds(_ interval: TimeInterval) -> Int { count(Int(interval.rounded())) }
}

// MARK: - App and device

struct AppInfo: Encodable, Sendable {
    enum Channel: String, Encodable, Sendable { case debug, testflight, appstore }

    var version: String
    var build: String
    var channel: Channel

    static func current(channel: Channel) -> AppInfo {
        let info = Bundle.main.infoDictionary
        return AppInfo(version: String((info?["CFBundleShortVersionString"] as? String ?? "?").prefix(16)),
                       build: String((info?["CFBundleVersion"] as? String ?? "?").prefix(16)), channel: channel)
    }

    /// Debug builds, TestFlight (StoreKit's sandbox), or the App Store.
    static func channel() async -> Channel {
        #if DEBUG
        return .debug
        #else
        if case .verified(let app)? = try? await AppTransaction.shared, app.environment == .sandbox { return .testflight }
        return .appstore
        #endif
    }

    var dictionary: [String: String] { ["version": version, "build": build, "channel": channel.rawValue] }
}

struct DeviceInfo: Encodable, Sendable {
    var model: String
    var os: String
    var family: String

    /// The iPhone Duo's model identifiers (the foldable).
    static let duoModels: Set<String> = ["iPhone19,4"]

    @MainActor static var current: DeviceInfo {
        let model = modelIdentifier
        return DeviceInfo(model: String(model.prefix(32)), os: String(UIDevice.current.systemVersion.prefix(16)),
                          family: duoModels.contains(model) ? "duo" : "iphone")
    }

    static var modelIdentifier: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    var dictionary: [String: String] { ["model": model, "os": os, "family": family] }
}
