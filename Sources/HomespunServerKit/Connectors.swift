// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import HomespunCore

/// A destination the server copies originals to after it has stored and checked them, for
/// example OneDrive. Connectors add copies; they never count toward removing an original from
/// the iPhone (only this server's own verified copy does).
///
/// Built-in connectors ship with the server. Others can be added by building a server binary
/// that passes them to `ServerCommand.run(connectors:)`.
public protocol Connector: Sendable {
    /// Stable identifier: lowercase letters, digits, and hyphens.
    var id: String { get }
    var name: String { get }
    var summary: String { get }
    /// Settings the app asks for. Secret values are never sent back to the app.
    var fields: [ServerAPI.ConnectorField] { get }
    /// Signs in with a code the app shows (`beginSignIn` / `pollSignIn`).
    var signsIn: Bool { get }

    /// Checks that the settings work (called when the connector is turned on or changed).
    /// Returns the account or place copies go, to show in the app.
    func check(_ context: ConnectorContext) async throws -> String?
    func beginSignIn(_ context: ConnectorContext) async throws -> ServerAPI.ConnectorSignIn
    func pollSignIn(_ context: ConnectorContext) async throws -> ServerAPI.ConnectorSignInStatus
    /// Copies one item's originals and confirms the copy. Returns where it went.
    func copy(_ item: ConnectorItem, context: ConnectorContext) async throws -> String?
}

extension Connector {
    public var signsIn: Bool { false }
    public func beginSignIn(_ context: ConnectorContext) async throws -> ServerAPI.ConnectorSignIn {
        throw ConnectorError.failed("\(name) doesn't sign in.")
    }
    public func pollSignIn(_ context: ConnectorContext) async throws -> ServerAPI.ConnectorSignInStatus {
        .init(state: .failed, message: "\(name) doesn't sign in.")
    }
}

public enum ConnectorError: Error, CustomStringConvertible, Equatable {
    /// Won't work without a change (bad settings, file refused); not retried.
    case failed(String)
    /// Try again later without counting as a failure (destination full or offline).
    case retryLater(String, after: TimeInterval)

    public var description: String {
        switch self {
        case .failed(let message), .retryLater(let message, _): message
        }
    }
}

/// One item's originals, checked against the iPhone's hashes and ready to read.
public struct ConnectorItem: Sendable {
    public struct File: Sendable {
        public var role: ServerAPI.ResourceRole
        public var url: URL
        public var filename: String
        public var size: Int
        public var sha256: String

        public init(role: ServerAPI.ResourceRole, url: URL, filename: String, size: Int, sha256: String) {
            self.role = role
            self.url = url
            self.filename = filename
            self.size = size
            self.sha256 = sha256
        }
    }

    public var assetID: String
    public var kind: ServerAPI.AssetKind
    public var captureDate: Date?
    public var files: [File]

    public func file(_ role: ServerAPI.ResourceRole) -> File? { files.first { $0.role == role } }

    /// The item as it looks now: an edit's full-size render if there is one.
    public var current: File? {
        let preference: [ServerAPI.ResourceRole] = kind == .video ? [.fullSizeVideo, .video] : [.fullSizePhoto, .photo]
        return preference.lazy.compactMap(file).first
    }

    /// The Live Photo motion that goes with `current`.
    public var currentMotion: File? {
        guard kind == .livePhoto else { return nil }
        return file(.fullSizePairedVideo) ?? file(.pairedVideo)
    }

    public init(assetID: String, kind: ServerAPI.AssetKind, captureDate: Date?, files: [File]) {
        self.assetID = assetID
        self.kind = kind
        self.captureDate = captureDate
        self.files = files
    }
}

/// A connector's saved settings, including values it keeps for itself (keys starting with
/// `_`, such as tokens), which are never shown to the app.
public actor ConnectorContext {
    public nonisolated let connectorID: String
    /// A folder inside the data directory for this connector's own files.
    public nonisolated let workDirectory: URL
    private let catalog: Catalog

    init(connectorID: String, catalog: Catalog, workDirectory: URL) {
        self.connectorID = connectorID
        self.catalog = catalog
        self.workDirectory = workDirectory
    }

    private var key: String { "connector.\(connectorID)" }

    public func settings() async throws -> [String: String] {
        guard let json = try await catalog.setting(key) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: Data(json.utf8))) ?? [:]
    }

    public func value(_ name: String) async throws -> String? { try await settings()[name] }

    public func set(_ values: [String: String?]) async throws {
        var current = try await settings()
        for (name, value) in values { current[name] = value }
        let data = try JSONEncoder().encode(current)
        try await catalog.setSetting(key, current.isEmpty ? nil : String(decoding: data, as: UTF8.self))
    }

    func clear() async throws { try await catalog.setSetting(key, nil) }
}

/// Runs the server's connectors: settings, turning them on, queueing copies, and copying.
actor ConnectorHub {
    static let jobPrefix = "connector:"
    static let enabledKey = "_enabled"
    static let accountKey = "_account"
    static let messageKey = "_message"

    let connectors: [String: any Connector]
    let order: [String]
    let catalog: Catalog
    let storage: Storage
    private var contexts: [String: ConnectorContext] = [:]

    init(connectors: [any Connector], catalog: Catalog, storage: Storage) {
        var byID: [String: any Connector] = [:]
        for connector in connectors where byID[connector.id] == nil { byID[connector.id] = connector }
        self.connectors = byID
        order = connectors.map(\.id).reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        self.catalog = catalog
        self.storage = storage
    }

    func context(_ id: String) -> ConnectorContext {
        if let existing = contexts[id] { return existing }
        let context = ConnectorContext(connectorID: id, catalog: catalog,
                                       workDirectory: storage.cacheRoot.appendingPathComponent("connector-\(id)", isDirectory: true))
        contexts[id] = context
        return context
    }

    func enabledIDs() async throws -> [String] {
        var enabled: [String] = []
        for id in order where try await context(id).value(Self.enabledKey) == "true" { enabled.append(id) }
        return enabled
    }

    /// Queues copies of an item whose originals were just stored and checked.
    func originalsVerified(_ assetID: String) async throws {
        for id in try await enabledIDs() { try await queue(id, assetID: assetID) }
    }

    private func queue(_ id: String, assetID: String) async throws {
        try await catalog.setCopyState(assetID, connector: id, state: "queued")
        try await catalog.enqueue(Self.jobPrefix + id, assetID: assetID)
    }

    func info(_ id: String) async throws -> ServerAPI.ConnectorInfo? {
        guard let connector = connectors[id] else { return nil }
        let settings = try await context(id).settings()
        let fields = connector.fields.map { field in
            var field = field
            let value = settings[field.key]
            field.isSet = !(value ?? "").isEmpty
            field.value = field.kind == .secret ? nil : value
            return field
        }
        return ServerAPI.ConnectorInfo(
            id: id, name: connector.name, summary: connector.summary, fields: fields, signsIn: connector.signsIn,
            account: settings[Self.accountKey], enabled: settings[Self.enabledKey] == "true",
            message: settings[Self.messageKey], counts: try await catalog.copyCounts(connector: id))
    }

    func all() async throws -> [ServerAPI.ConnectorInfo] {
        var result: [ServerAPI.ConnectorInfo] = []
        for id in order { if let info = try await info(id) { result.append(info) } }
        return result
    }

    /// Saves settings, then checks them before turning the connector on.
    func update(_ id: String, _ update: ServerAPI.ConnectorUpdate) async throws -> ServerAPI.ConnectorInfo {
        guard let connector = connectors[id] else { throw ConnectorError.failed("No such connector.") }
        let context = context(id)
        if let settings = update.settings {
            let known = Dictionary(uniqueKeysWithValues: connector.fields.map { ($0.key, $0) })
            var values: [String: String?] = [:]
            for (key, value) in settings {
                guard let field = known[key] else { throw ConnectorError.failed("Unknown setting \(key).") }
                if field.kind == .secret, value.isEmpty { continue }
                values[key] = value.isEmpty ? nil : String(value.prefix(4096))
            }
            try await context.set(values)
        }
        let wasEnabled = try await context.value(Self.enabledKey) == "true"
        let enable = update.enabled ?? wasEnabled
        if enable {
            let account = try await connector.check(context)
            try await context.set([Self.enabledKey: "true", Self.accountKey: account, Self.messageKey: nil])
            await catalog.log("connector_enabled", detail: id)
            if update.copyExisting == true {
                for assetID in try await catalog.assetsWithVerifiedOriginals()
                where try await catalog.copyState(assetID, connector: id)?.state != "copied" {
                    try await queue(id, assetID: assetID)
                }
            }
        } else if update.enabled == false {
            try await context.set([Self.enabledKey: nil])
            await catalog.log("connector_disabled", detail: id)
        }
        return try await info(id)!
    }

    /// Turns the connector off and forgets its settings and sign-in. Copies already made stay.
    func remove(_ id: String) async throws {
        guard connectors[id] != nil else { throw ConnectorError.failed("No such connector.") }
        try await context(id).clear()
        try await catalog.cancelJobs(prefix: Self.jobPrefix + id)
        await catalog.log("connector_removed", detail: id)
    }

    func beginSignIn(_ id: String) async throws -> ServerAPI.ConnectorSignIn {
        guard let connector = connectors[id], connector.signsIn else { throw ConnectorError.failed("This connector doesn't sign in.") }
        return try await connector.beginSignIn(context(id))
    }

    func pollSignIn(_ id: String) async throws -> ServerAPI.ConnectorSignInStatus {
        guard let connector = connectors[id], connector.signsIn else { throw ConnectorError.failed("This connector doesn't sign in.") }
        let status = try await connector.pollSignIn(context(id))
        if status.state == .done { try await context(id).set([Self.accountKey: status.account, Self.messageKey: nil]) }
        return status
    }

    /// Runs one copy job. Errors other than `ConnectorError` are retried by the job runner.
    func copy(_ id: String, assetID: String, originals: (AssetRecord, [ResourceRecord]) async throws -> [Role: URL])
        async throws {
        guard let connector = connectors[id] else {
            try await catalog.setCopyState(assetID, connector: id, state: "failed", message: "This server no longer has \(id).")
            return
        }
        let context = context(id)
        guard try await context.value(Self.enabledKey) == "true" else {
            try await catalog.setCopyState(assetID, connector: id, state: "failed", message: "\(connector.name) is turned off.")
            return
        }
        guard let asset = try await catalog.asset(assetID) else { return }
        let resources = try await catalog.resources(assetID)
        try await catalog.setCopyState(assetID, connector: id, state: "copying")
        let urls = try await originals(asset, resources)
        let item = ConnectorItem(
            assetID: assetID, kind: asset.kind, captureDate: Timestamp.date(asset.captureDate),
            files: resources.compactMap { resource in
                urls[resource.role].map {
                    .init(role: resource.role, url: $0, filename: resource.filename, size: resource.size, sha256: resource.sha256)
                }
            })
        let reference = try await connector.copy(item, context: context)
        try await catalog.setCopyState(assetID, connector: id, state: "copied", reference: reference)
        try await context.set([Self.messageKey: nil])
    }

    /// Records a copy that didn't work: `final` failures stay failed; others wait for a retry.
    func copyFailed(_ id: String, assetID: String, message: String, final: Bool) async throws {
        try await catalog.setCopyState(assetID, connector: id, state: final ? "failed" : "queued", message: message)
        try await context(id).set([Self.messageKey: message])
    }
}
