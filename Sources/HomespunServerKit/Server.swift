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
    let routes: Routes
    let immichState: ImmichState
    let logger: Logger

    public init(configuration: ServerConfiguration, logger: Logger = Logger(label: "homespun")) async throws {
        self.configuration = configuration
        self.logger = logger
        storage = Storage(root: configuration.dataDirectory)
        try storage.prepare()
        catalog = try Catalog(path: storage.catalog.path)
        immichState = try await ImmichState(catalog: catalog, fallback: configuration.immich)
        runner = JobRunner(catalog: catalog, storage: storage, compactor: Compactor(profile: configuration.profile),
                           immichState: immichState, logger: logger)
        routes = Routes(configuration: configuration, catalog: catalog, storage: storage, immichState: immichState)
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
                    services: [runner] + advertiser(), logger: logger)
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

    /// Writes the systemd unit or LaunchAgent and starts it. Returns what was done.
    public func installService(executable: String) throws -> String {
        let platform = HostPlatform.current()
        var environment = [
            "HOMESPUN_DATA": configuration.dataDirectory.path,
            "HOMESPUN_HOST": configuration.host,
            "HOMESPUN_PORT": String(configuration.port),
            "HOMESPUN_NAME": configuration.name,
        ]
        if let publicURL = configuration.publicURL { environment["HOMESPUN_PUBLIC_URL"] = publicURL }
        let current = ProcessInfo.processInfo.environment
        for key in ["PATH", "HOMESPUN_IMMICH_URL", "HOMESPUN_IMMICH_API_KEY_FILE"] {
            if let value = current[key] { environment[key] = value }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let plan = ServiceInstaller.plan(executable: executable, environment: environment, os: platform.os, home: home,
                                         userID: getuid(), user: NSUserName())
        try FileManager.default.createDirectory(at: plan.path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try plan.contents.write(to: plan.path, atomically: true, encoding: .utf8)
        var report = ["Wrote \(plan.path.path)"]
        for command in plan.commands {
            let ok = Tools.output(command[0], Array(command.dropFirst())) != nil
            report.append("\(ok ? "Ran" : "Could not run") \(command.joined(separator: " "))")
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

    /// Runs queued jobs until none is ready.
    public func drainJobs() async throws { try await runner.drain() }
}
