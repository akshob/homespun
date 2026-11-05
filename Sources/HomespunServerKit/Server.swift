// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import HomespunCore
import Hummingbird
import Logging

/// Builds the Homespun Server application: HTTP API plus the background job runner.
public struct HomespunServer: Sendable {
    public let configuration: ServerConfiguration
    public let catalog: Catalog
    let storage: Storage
    let runner: JobRunner
    let routes: Routes

    public init(configuration: ServerConfiguration, logger: Logger = Logger(label: "homespun")) throws {
        self.configuration = configuration
        storage = Storage(root: configuration.dataDirectory)
        try storage.prepare()
        catalog = try Catalog(path: storage.catalog.path)
        let immich = configuration.immich.map { ImmichClient(configuration: $0) }
        runner = JobRunner(catalog: catalog, storage: storage, compactor: Compactor(profile: configuration.profile),
                           immich: immich, logger: logger)
        routes = Routes(configuration: configuration, catalog: catalog, storage: storage, immich: immich)
    }

    public func router() -> Router<HomespunRequestContext> {
        let router = Router(context: HomespunRequestContext.self)
        router.add(middleware: LogRequestsMiddleware(.info))
        routes.add(to: router)
        return router
    }

    public func application(logger: Logger = Logger(label: "homespun")) -> some ApplicationProtocol {
        // The idle timeout closes uploads that stall (a phone leaving Wi-Fi), releasing their lock.
        Application(router: router(), server: .http1(configuration: .init(idleTimeout: .seconds(60))),
                    configuration: .init(address: .hostname(configuration.host, port: configuration.port),
                                         serverName: "homespun"),
                    services: [runner], logger: logger)
    }

    /// Creates a one-time pairing code valid for `lifetime`.
    public func newPairingCode(lifetime: TimeInterval = 600) async throws -> String {
        let code = Pairing.newCode()
        try await catalog.addPairingCode(hash: Pairing.hash(Pairing.normalized(code)), expiresAt: Date().addingTimeInterval(lifetime))
        return code
    }

    /// Runs queued jobs until none is ready.
    public func drainJobs() async throws { try await runner.drain() }
}
