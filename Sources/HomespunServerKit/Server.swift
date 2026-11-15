// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import HomespunCore
import Hummingbird
import Logging
import ServiceLifecycle

/// Builds the Homespun Server application: HTTP API plus the background job runner.
public struct HomespunServer: Sendable {
    public let configuration: ServerConfiguration
    public let catalog: Catalog
    let storage: Storage
    let runner: JobRunner
    let copier: JobRunner
    let hub: ConnectorHub
    let routes: Routes
    let immichState: ImmichState
    let originals: OriginalsStore
    let mover: OriginalsMover
    let logger: Logger

    /// `connectors`: extra destinations besides the built-in ones (see `Connector`).
    public init(configuration: ServerConfiguration, connectors: [any Connector] = [],
                logger: Logger = Logger(label: "homespun")) async throws {
        try await self.init(configuration: configuration, connectors: connectors, logger: logger,
                            approver: DialogApprover.detect())
    }

    init(configuration: ServerConfiguration, connectors: [any Connector] = [], logger: Logger = Logger(label: "homespun"),
         approver: (any PairingApprover)?, approvalPause: TimeInterval = 5, builtIn: [any Connector]? = nil) async throws {
        self.configuration = configuration
        self.logger = logger
        storage = Storage(root: configuration.dataDirectory)
        try storage.prepare()
        catalog = try Catalog(path: storage.catalog.path)
        try await catalog.assignMissingFolders()
        let root = try await Self.originalsRoot(catalog: catalog, configured: configuration.originalsDirectory,
                                                default: storage.originals, logger: logger)
        if try !Storage.prepareOriginals(root) {
            logger.error("the originals folder \(root.path) isn't available (is its disk connected?)")
        }
        originals = OriginalsStore(root: root)
        mover = OriginalsMover(catalog: catalog, store: originals, dataDirectory: configuration.dataDirectory, logger: logger)
        immichState = try await ImmichState(catalog: catalog, fallback: configuration.immich)
        hub = ConnectorHub(connectors: (builtIn ?? Self.builtInConnectors(configuration)) + connectors,
                           catalog: catalog, storage: storage)
        let compactor = Compactor(profile: configuration.profile)
        runner = JobRunner(catalog: catalog, storage: storage, originals: originals, compactor: compactor,
                           immichState: immichState, hub: hub, logger: logger)
        copier = JobRunner(catalog: catalog, storage: storage, originals: originals, compactor: compactor,
                           immichState: immichState, hub: hub, logger: logger, pollInterval: .seconds(2), connectors: true)
        routes = Routes(configuration: configuration, catalog: catalog, storage: storage, originals: originals, mover: mover,
                        immichState: immichState,
                        approvals: PairingApprovals(approver: approver, serverName: configuration.name, pause: approvalPause),
                        connectors: hub)
    }

    /// The originals folder, saved in the catalog because stored paths are relative to it: once
    /// originals are there, `--originals` can't change it (moving them from the app can).
    static func originalsRoot(catalog: Catalog, configured: URL?, default fallback: URL, logger: Logger) async throws -> URL {
        let configured = configured?.standardizedFileURL
        var root: URL
        if let saved = try await catalog.setting(OriginalsStore.setting) {
            root = URL(fileURLWithPath: saved, isDirectory: true)
        } else if try await catalog.setting("originals.legacy") != nil {
            root = fallback  // stored before the folder was a setting of its own
        } else {
            root = configured ?? fallback
        }
        if let configured, configured != root.standardizedFileURL {
            if try await catalog.storedOriginalCount() == 0 {
                root = configured
            } else {
                logger.notice("originals are in \(root.path); ignoring --originals \(configured.path) (move them from the app)")
            }
        }
        try await catalog.setSetting(OriginalsStore.setting, root.standardizedFileURL.path)
        try await catalog.setSetting("originals.legacy", nil)
        return root
    }

    /// The connectors every server has.
    static func builtInConnectors(_ configuration: ServerConfiguration) -> [any Connector] {
        [OneDriveConnector(clientID: configuration.onedriveClientID)]
    }

    public func router() -> Router<HomespunRequestContext> {
        let router = Router(context: HomespunRequestContext.self)
        router.add(middleware: LogRequestsMiddleware(.info))
        routes.add(to: router)
        return router
    }

    /// Serves until stopped. Other commands (pair, import, …) run beside a serving server, so
    /// only this releases job leases: nothing holds one before these runners start.
    public func run() async throws {
        try await catalog.releaseLeases()
        await mover.resume()
        try await application().runService()
    }

    public func application(logger: Logger = Logger(label: "homespun")) -> some ApplicationProtocol {
        // The idle timeout closes uploads that stall (a phone leaving Wi-Fi), releasing their lock.
        Application(router: router(), server: .http1(configuration: .init(idleTimeout: .seconds(60))),
                    configuration: .init(address: .hostname(configuration.host, port: configuration.port),
                                         serverName: "homespun"),
                    services: [runner, copier] + advertiser(), logger: logger)
    }

    private func advertiser() -> [any Service] {
        guard !["127.0.0.1", "::1", "localhost"].contains(configuration.host) else { return [] }
        return [ServiceAdvertiser(name: configuration.name, port: configuration.port, logger: logger)]
    }

    /// The pairing link and QR code `homespun-server pair` prints.
    public func pairingInstructions(code: String) -> String {
        guard let url = Network.publicURL(configuration: configuration) else {
            return "Pairing code: \(code)\nSet HOMESPUN_PUBLIC_URL to the address your iPhone uses to reach this server."
        }
        let link = PairingLink(serverURL: url, code: code, name: configuration.name).url.absoluteString
        let address = url.scheme == "http" && url.port != nil ? "\(url.host ?? ""):\(url.port!)" : url.absoluteString
        var text = "Pair the Homespun app with this server. Scan the code with your iPhone's camera:\n\n"
        if let qr = try? TerminalQR.render(link) { text += qr + "\n\n" }
        text += "Or open this link on the iPhone (on a simulator, paste it in the app):\n  \(link)\n\n"
        text += "Or enter the address \(address) and the code \(code) in the app.\n"
        text += "Pairing code: \(code)  (works once, expires in 10 minutes)\n"
        if ["127.0.0.1", "::1", "localhost"].contains(configuration.host) {
            text += "\nNote: the server listens only on this computer. Set HOMESPUN_HOST=0.0.0.0 (install-service does).\n"
        }
        return text
    }

    public struct ServiceFailure: Error, CustomStringConvertible { public var description: String }

    /// Copies the server to `~/.local/bin`, writes the systemd unit or LaunchAgent, and starts
    /// it. Returns what was done, or throws `ServiceFailure` with the same report when a step failed.
    public func installService(executable source: String) throws -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let executable = try ServiceInstaller.install(source, home: home).path
        let platform = HostPlatform.current()
        var environment = [
            "HOMESPUN_DATA": configuration.dataDirectory.path,
            "HOMESPUN_HOST": configuration.host,
            "HOMESPUN_PORT": String(configuration.port),
            "HOMESPUN_NAME": configuration.name,
        ]
        if let originals = configuration.originalsDirectory { environment["HOMESPUN_ORIGINALS"] = originals.path }
        if let publicURL = configuration.publicURL { environment["HOMESPUN_PUBLIC_URL"] = publicURL }
        let current = ProcessInfo.processInfo.environment
        for key in ["PATH", "HOMESPUN_IMMICH_URL", "HOMESPUN_IMMICH_API_KEY_FILE", "HOMESPUN_ONEDRIVE_CLIENT_ID"] {
            if let value = current[key] { environment[key] = value }
        }
        let plan = ServiceInstaller.plan(executable: executable, environment: environment, os: platform.os, home: home,
                                         userID: getuid(), user: NSUserName())
        try FileManager.default.createDirectory(at: plan.path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try plan.contents.write(to: plan.path, atomically: true, encoding: .utf8)
        var report = ["Installed \(executable)", "Wrote \(plan.path.path)"]
        for command in plan.prepare { _ = Tools.output(command[0], Array(command.dropFirst())) }
        var failed = false
        for command in plan.commands {
            // launchctl bootout finishes in the background, so bootstrap can fail at first.
            var ok = false
            for attempt in 0..<5 where !ok {
                if attempt > 0 { Thread.sleep(forTimeInterval: 1) }
                ok = Tools.output(command[0], Array(command.dropFirst())) != nil
            }
            report.append("\(ok ? "Ran" : "Could not run") \(command.joined(separator: " "))")
            failed = failed || !ok
        }
        guard !failed else {
            report.append("Homespun Server is not running as a service yet. Fix the step above, then run install-service again.")
            throw ServiceFailure(description: report.joined(separator: "\n"))
        }
        report.append("Homespun Server now starts automatically. Data: \(configuration.dataDirectory.path)")
        return report.joined(separator: "\n")
    }

    /// Creates a one-time pairing code valid for `lifetime`.
    public func newPairingCode(lifetime: TimeInterval = 600) async throws -> String {
        let code = Pairing.newCode()
        try await catalog.addPairingCode(hash: Pairing.hash(Pairing.normalized(code)), expiresAt: Date().addingTimeInterval(lifetime))
        return code
    }

    /// A connector's saved settings, for tools and tests of your own connectors.
    public func connectorContext(_ id: String) async -> ConnectorContext { await hub.context(id) }

    /// Runs queued jobs until none is ready.
    public func drainJobs() async throws {
        try await runner.drain()
        try await copier.drain()
    }
}
