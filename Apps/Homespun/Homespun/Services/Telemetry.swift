// SPDX-License-Identifier: Apache-2.0
import Foundation
import HomespunCore
import Observation
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
    /// The last install ID that sent anything, so its data can still be deleted after opting out.
    private(set) var sentInstallID: UUID?
    private(set) var queued: [Event] = []
    /// Setup events before the person decided: kept in memory, sent only if they choose to share.
    private var beforeConsent: [Event] = []
    private var flushing = false
    private var channel: AppInfo.Channel?
    /// Nothing is recorded while the demo is on: it isn't how the person uses Homespun.
    var paused = false

    let endpoint: URL?
    private let defaults: UserDefaults
    private let queueURL: URL
    private let send: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    init(defaults: UserDefaults = .standard,
         queueURL: URL = URL.applicationSupportDirectory.appendingPathComponent("Homespun/telemetry-queue.json"),
         endpoint: URL? = Telemetry.defaultEndpoint,
         send: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }) {
        self.defaults = defaults
        self.queueURL = queueURL
        self.endpoint = endpoint
        self.send = send
        consent = defaults.string(forKey: "telemetry.consent").flatMap(Consent.init) ?? .unasked
        installID = defaults.string(forKey: "telemetry.install").flatMap(UUID.init)
        sentInstallID = defaults.string(forKey: "telemetry.sentInstall").flatMap(UUID.init)
        if consent == .sharing {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            queued = (try? decoder.decode([Event].self, from: Data(contentsOf: queueURL))) ?? []
        }
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
            queued = beforeConsent
            beforeConsent = []
            record(.analyticsOptIn)
        } else {
            consent = .notSharing
            installID = nil
            queued = []
            beforeConsent = []
        }
        defaults.set(consent.rawValue, forKey: "telemetry.consent")
        defaults.set(installID?.uuidString.lowercased(), forKey: "telemetry.install")
        saveQueue()
    }

    // MARK: Events

    /// Queues an event if the person shares (before they've decided, setup events wait in memory).
    func record(_ event: Event) {
        guard !paused else { return }
        switch consent {
        case .sharing:
            queued.append(event)
            if queued.count > Self.maximumQueued { queued.removeFirst(queued.count - Self.maximumQueued) }
            saveQueue()
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
        if flushing {
            while flushing { try? await Task.sleep(for: .milliseconds(20)) }
            return
        }
        guard isSharing, let endpoint, let installID, !queued.isEmpty else { return }
        flushing = true
        defer { flushing = false }
        let channel = await currentChannel()
        while isSharing, !queued.isEmpty {
            let batch = Array(queued.prefix(Self.batchSize))
            let body = Batch(install: installID.uuidString.lowercased(), app: AppInfo.current(channel: channel),
                             device: DeviceInfo.current, events: batch)
            guard let request = try? Self.request(endpoint.appendingPathComponent("v1/events"), json: body),
                  let (_, response) = try? await send(request),
                  let status = (response as? HTTPURLResponse)?.statusCode else { return }
            if (200..<300).contains(status) || status == 400 {
                // 400: the service rejects this batch for good (an older app's event); don't retry it.
                queued.removeFirst(min(batch.count, queued.count))
                markSent(installID)
                saveQueue()
            } else {
                return
            }
        }
    }

    /// Flush while iOS gives the app a little time after it leaves the screen.
    func flushInBackground() {
        guard isSharing, !queued.isEmpty else { return }
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
        for id in Set([sentInstallID, installID].compactMap { $0 }) {
            var request = URLRequest(url: endpoint.appendingPathComponent("v1/installs/\(id.uuidString.lowercased())"))
            request.httpMethod = "DELETE"
            request.setValue(Self.appKey, forHTTPHeaderField: "X-Homespun-Key")
            let (_, response) = try await send(request)
            guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) || status == 404 else {
                throw TelemetryError.rejected
            }
        }
        sentInstallID = nil
        defaults.removeObject(forKey: "telemetry.sentInstall")
        queued = []
        if isSharing {
            installID = UUID()
            defaults.set(installID?.uuidString.lowercased(), forKey: "telemetry.install")
        }
        saveQueue()
    }

    var hasSharedData: Bool { sentInstallID != nil }

    // MARK: MetricKit and reports

    /// A MetricKit payload (`kind` "metrics" or "diagnostics"), sent at once if the person shares.
    func upload(payload json: Data, kind: String) async {
        guard isSharing, let endpoint, let installID,
              let payload = try? JSONSerialization.jsonObject(with: json) else { return }
        let channel = await currentChannel()
        let body: [String: Any] = ["install": installID.uuidString.lowercased(),
                                   "app": AppInfo.current(channel: channel).dictionary,
                                   "device": DeviceInfo.current.dictionary, "payload": payload]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        var request = Self.baseRequest(endpoint.appendingPathComponent("v1/\(kind)"))
        request.httpBody = data
        if let (_, response) = try? await send(request), let status = (response as? HTTPURLResponse)?.statusCode,
           (200..<300).contains(status) {
            markSent(installID)
        }
    }

    /// Sends a problem report; returns its number ("HS-…"). Reports work whether or not the person
    /// shares analytics (they're sent on purpose). A reply address must never link analytics to a person.
    func sendReport(_ report: ProblemReport) async throws -> String {
        guard let endpoint else { throw TelemetryError.unavailable }
        let channel = await currentChannel()
        let reportInstall = report.email == nil && isSharing ? installID : nil
        var body: [String: Any] = ["install": reportInstall.map { $0.uuidString.lowercased() as Any } ?? NSNull(),
                                   "app": AppInfo.current(channel: channel).dictionary,
                                   "device": DeviceInfo.current.dictionary, "message": report.message]
        if let email = report.email { body["email"] = email }
        if let diagnostics = report.diagnostics { body["diagnostics"] = diagnostics }
        var request = Self.baseRequest(endpoint.appendingPathComponent("v1/reports"))
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await send(request)
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw TelemetryError.rejected }
        guard (200..<300).contains(status),
              let id = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["id"] as? String else {
            throw status == 429 ? TelemetryError.tooMany : TelemetryError.rejected
        }
        if let reportInstall { markSent(reportInstall) }
        record(.reportSent(withDiagnostics: report.diagnostics != nil))
        return id
    }

    // MARK: Helpers

    func currentChannel() async -> AppInfo.Channel {
        if let channel { return channel }
        let found = await AppInfo.channel()
        channel = found
        return found
    }

    private func markSent(_ id: UUID) {
        guard sentInstallID != id else { return }
        sentInstallID = id
        defaults.set(id.uuidString.lowercased(), forKey: "telemetry.sentInstall")
    }

    private func saveQueue() {
        if queued.isEmpty {
            try? FileManager.default.removeItem(at: queueURL)
            return
        }
        try? FileManager.default.createDirectory(at: queueURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(queued).write(to: queueURL, options: .atomic)
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
