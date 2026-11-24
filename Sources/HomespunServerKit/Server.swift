// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import HomespunCore
import Hummingbird
import HummingbirdCore
import Logging
import ServiceLifecycle

/// Builds the Homespun Server application: HTTP API plus the background job runner.
public struct HomespunServer: Sendable {
    public let configuration: ServerConfiguration
    public let catalog: Catalog
    public let identity: TLSIdentityBox
    public var fingerprint: ServerKeyFingerprint { identity.current.fingerprint }
    let transport: HTTPServerBuilder
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
         approver: (any PairingApprover)?, approvalPause: TimeInterval = 5, builtIn: [any Connector]? = nil,
         codeRounds: Int = PairingCrypto.codeRounds, challengeInterval: TimeInterval = 1) async throws {
        self.configuration = configuration
        self.logger = logger
        storage = Storage(root: configuration.dataDirectory)
        try storage.prepare()
        // Observational CLI construction is allowed beside the live server, but cannot change
        // its root settings, recover journals, or release worker leases.
        let initialization = try? ServerOwnership(dataDirectory: configuration.dataDirectory)
        defer { withExtendedLifetime(initialization) {} }
        let (tls, created) = try TLSStore.loadOrCreate(data: configuration.dataDirectory)
        identity = try TLSIdentityBox(tls)
        if initialization != nil, tls.notAfter.timeIntervalSinceNow < 90 * 86400 {
            do { try identity.update(TLSStore.renew(data: configuration.dataDirectory)) }
            catch { identity.record(error: String(describing: error)); logger.error("Can't renew the server certificate: \(error)") }
        }
        transport = try .homespun(identity: identity)
        if created { logger.notice("Made a new encryption key; paired iPhones confirm it automatically.") }
        if configuration.publicURL?.lowercased().hasPrefix("http://") == true {
            logger.notice("HOMESPUN_PUBLIC_URL now uses HTTPS; the port is unchanged.")
        }
        catalog = try Catalog(path: storage.catalog.path)
        let root: URL
        if initialization != nil {
            try await catalog.assignMissingFolders()
            root = try await Self.originalsRoot(catalog: catalog, configured: configuration.originalsDirectory,
                                               default: storage.originals, logger: logger)
        } else {
            root = try await catalog.setting(OriginalsStore.setting).map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? configuration.originalsDirectory ?? storage.originals
        }
        let renamePending = try await catalog.setting(DeviceRename.journal) != nil
        let trashPending = try await !catalog.trashJournals().isEmpty
        let recoveryPending = renamePending || trashPending
        if initialization != nil, !recoveryPending, try !Storage.prepareOriginals(root) {
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
                        connectors: hub, identity: identity,
                        codeChallenges: CodeChallenges(catalog: catalog, rounds: codeRounds, minimumInterval: challengeInterval))
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
            let renamePending = try await catalog.setting(DeviceRename.journal) != nil
            let movePending = try await catalog.setting(OriginalsMover.setting) != nil
            let trashPending = try await !catalog.trashJournals().isEmpty
            if try await catalog.storedOriginalCount() == 0, !renamePending, !movePending, !trashPending {
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

    /// Low-level router for tests or an already-owned lifecycle. Use `application()` or `run()`
    /// to serve: constructing an Application from this router alone does not install recovery.
    public func router() -> Router<HomespunRequestContext> {
        router(startup: nil)
    }

    private func router(startup: ServingStartup?) -> Router<HomespunRequestContext> {
        let router = Router(context: HomespunRequestContext.self)
        if let startup { router.add(middleware: ServingAdmission(startup: startup)) }
        router.add(middleware: LogRequestsMiddleware(.info))
        routes.add(to: router)
        return router
    }

    /// For tests that call routes directly; never serve it without the TLS listener.
    public func testRouter() -> Router<HomespunRequestContext> { router() }

    /// Serves until stopped, using the same ownership/recovery lifecycle as `application()`.
    public func run() async throws {
        try await application().runService()
    }

    public func application(logger: Logger = Logger(label: "homespun")) -> some ApplicationProtocol {
        // The idle timeout closes uploads that stall (a phone leaving Wi-Fi), releasing their lock.
        let startup = ServingStartup()
        let workers: [any Service] = [runner, copier, TLSMaintenance(data: configuration.dataDirectory, identity: identity, logger: logger)]
            + advertiser()
        var application = Application(router: router(startup: startup), server: transport,
                    configuration: .init(address: .hostname(configuration.host, port: configuration.port),
                                         serverName: "homespun"),
                    services: [OwnedServerServices(dataDirectory: configuration.dataDirectory, catalog: catalog,
                                                   originals: originals, storage: storage, mover: mover,
                                                   startup: startup, services: workers, logger: logger)], logger: logger)
        application.beforeServerStarts { try await startup.wait() }
        return application
    }

    private func advertiser() -> [any Service] {
        guard !["127.0.0.1", "::1", "localhost"].contains(configuration.host) else { return [] }
        return [ServiceAdvertiser(name: configuration.name, port: configuration.port, identity: identity, logger: logger)]
    }

    /// The pairing link and QR code `homespun-server pair` prints.
    public func pairingInstructions(code: String, minutes: Int = 10) -> String {
        guard let url = Network.publicURL(configuration: configuration) else {
            return "Pairing code: \(code)\nSet HOMESPUN_PUBLIC_URL to the address your iPhone uses to reach this server."
        }
        let proxy = Network.usesTLSProxy(url, configuration: configuration)
        let link = PairingLink(serverURL: url, code: code, name: configuration.name,
                               fingerprint: proxy ? nil : fingerprint).url.absoluteString
        let address = url.port != nil && url.host?.contains(":") != true
            ? "\(url.host ?? ""):\(url.port!)" : url.absoluteString
        var text = "Pair the Homespun app with this server. Scan the code with your iPhone's camera:\n\n"
        if let qr = try? TerminalQR.render(link) { text += qr + "\n\n" }
        text += "Or open this link on the iPhone (on a simulator, paste it in the app):\n  \(link)\n\n"
        text += "Or enter the address \(address) and the code \(code) in the app.\n"
        text += "Pairing code: \(code)  (works once, expires in \(minutes == 1 ? "1 minute" : "\(minutes) minutes"))\n"
        text += "Server key: \(fingerprint.display)\n"
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
        report.append("Encrypted with the key in \(TLSStore.folder(configuration.dataDirectory).path) (back it up with the data folder).")
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
        let ownership = try ServerOwnership(dataDirectory: configuration.dataDirectory)
        defer { withExtendedLifetime(ownership) {} }
        try await originals.refreshRoot(catalog: catalog)
        try await DeviceRename.recover(catalog: catalog, root: await originals.root)
        try await Trash(catalog: catalog, originals: originals, storage: storage).recover()
        try await runner.drain()
        try await copier.drain()
    }

    /// Deletes what has been in the trash for 30 days (the job runner does this hourly).
    func emptyTrash(now: Date = Date()) async throws -> Int {
        let ownership = try ServerOwnership(dataDirectory: configuration.dataDirectory)
        defer { withExtendedLifetime(ownership) {} }
        try await originals.refreshRoot(catalog: catalog)
        try await DeviceRename.recover(catalog: catalog, root: await originals.root)
        let trash = Trash(catalog: catalog, originals: originals, storage: storage)
        try await trash.recover()
        return try await trash.empty(now: now, logger: logger)
    }
}
