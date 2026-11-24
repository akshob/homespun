// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import HomespunCore

/// The Immich connection in use. Set from the app (stored in the catalog) or, if the app has
/// never set or cleared it, from `HOMESPUN_IMMICH_URL` and `HOMESPUN_IMMICH_API_KEY_FILE`.
/// Without one, originals are stored on this server.
actor ImmichState {
    private let catalog: Catalog
    private var configuration: ImmichConfiguration?

    init(catalog: Catalog, fallback: ImmichConfiguration?) async throws {
        self.catalog = catalog
        switch try await catalog.setting("immich_url") {
        case nil:
            configuration = fallback
        case let stored?:
            // An empty URL records "disconnected from the app", which outlasts the environment.
            if let url = URL(string: stored), !stored.isEmpty, let key = try await catalog.setting("immich_api_key") {
                configuration = ImmichConfiguration(url: url, apiKey: key)
            }
        }
    }

    var mode: ServerAPI.StorageMode { configuration == nil ? .files : .immich }
    var current: ImmichConfiguration? { configuration }
    var client: ImmichClient? { configuration.map { ImmichClient(configuration: $0) } }
    var backupBinding: String? {
        configuration.map {
            Fingerprint.sha256(of: Data(("homespun.immich.binding.v1\n" + $0.url.absoluteString + "\n" + $0.apiKey).utf8))
        }
    }

    struct Failure: Error, CustomStringConvertible { var description: String }

    /// Checks the URL and key against Immich: it must answer, and the key must allow reading
    /// and downloading assets. Returns the key's permissions.
    static func test(_ configuration: ImmichConfiguration) async throws -> [String] {
        let client = ImmichClient(configuration: configuration)
        guard try await client.ping() else { throw Failure(description: "No Immich server answered at \(configuration.url.absoluteString).") }
        guard let permissions = try await client.keyPermissions() else {
            throw Failure(description: "Immich did not accept that API key.")
        }
        let needed: Set = ["asset.read", "asset.download"]
        guard permissions.contains("all") || needed.isSubset(of: Set(permissions)) else {
            throw Failure(description: "The API key needs the asset.read and asset.download permissions.")
        }
        return permissions.sorted()
    }

    func set(_ configuration: ImmichConfiguration) async throws {
        try await catalog.setSetting("immich_url", configuration.url.absoluteString)
        try await catalog.setSetting("immich_api_key", configuration.apiKey)
        self.configuration = configuration
        await catalog.log("immich_connected", detail: configuration.url.absoluteString)
    }

    func clear() async throws {
        try await catalog.setSetting("immich_url", "")
        try await catalog.setSetting("immich_api_key", nil)
        configuration = nil
        await catalog.log("immich_disconnected")
    }

    /// What the app shows; never includes the key.
    func settings() async -> ServerAPI.ImmichSettings {
        guard let configuration else {
            return .init(url: nil, keyHint: nil, permissions: [], connected: false, message: nil)
        }
        let hint = String(configuration.apiKey.suffix(4))
        do {
            let permissions = try await Self.test(configuration)
            return .init(url: configuration.url.absoluteString, keyHint: hint, permissions: permissions, connected: true,
                         message: Self.permissionWarning(permissions))
        } catch {
            return .init(url: configuration.url.absoluteString, keyHint: hint, permissions: [], connected: false,
                         message: "\(error)")
        }
    }

    static func permissionWarning(_ permissions: [String]) -> String? {
        let extra = Set(permissions).subtracting(["asset.read", "asset.download"])
        return extra.isEmpty ? nil
            : "This key can do more than Homespun needs. For safety, create one with only asset.read and asset.download."
    }
}
