// SPDX-License-Identifier: Apache-2.0
import Foundation
import HomespunCore
import Network
import Observation

/// Finds Homespun Servers on the home network (Bonjour `_homespun._tcp` only, DESIGN §6.1), and
/// asks each what it runs on (`GET /api/v1/pair/options`, which needs no pairing).
@MainActor @Observable
final class ServerDiscovery {
    struct Found: Identifiable, Equatable {
        var id: String { name }
        var name: String
        var url: URL?
        var options: ServerAPI.PairingOptions?
        /// It answered, but has no pairing options: too old for this app (01·6.7).
        var needsUpdate = false
        /// It was found but doesn't answer at its address.
        var unreachable = false
        /// This iPhone has a token for it (paired before).
        var pairedBefore = false

        /// Known well enough to recommend or pair with.
        var isReady: Bool { url != nil && (options != nil || needsUpdate) }

        var advisorServer: SetupAdvisor.Server {
            SetupAdvisor.Server(id: name, name: options?.serverName ?? name, os: options?.platform?.os,
                                kind: options?.hardware?.kind, model: options?.hardware?.model,
                                freeBytes: options?.freeBytes, pairedBefore: pairedBefore, needsUpdate: needsUpdate)
        }
    }

    private(set) var servers: [Found] = []
    private(set) var isSearching = false
    /// When the list last gained or completed a server, so the page can wait for it to settle.
    private(set) var lastChange = Date.distantPast
    /// Nothing turned up after a few seconds, so the user should hear why that might be.
    private(set) var foundNothing = false
    /// iOS blocked the search: the user turned off Local Network access for Homespun.
    private(set) var blocked = false
    private var browser: NWBrowser?
    private var patience: Task<Void, Never>?

    /// Servers that can be recommended, as the advisor sees them.
    var ready: [Found] { servers.filter(\.isReady) }

    func found(_ id: String) -> Found? { servers.first { $0.name == id } }

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: "_homespun._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let endpoints = results.compactMap { result -> (String, NWEndpoint)? in
                if case .service(let name, _, _, _) = result.endpoint { return (name, result.endpoint) }
                return nil
            }
            Task { @MainActor in self?.update(endpoints) }
        }
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready: self?.blocked = false
                case .waiting(let error): self?.blocked = Self.isPolicyDenied(error)
                case .failed(let error):
                    self?.blocked = Self.isPolicyDenied(error)
                    self?.stop()
                default: break
                }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
        isSearching = true
        foundNothing = false
        patience = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, let self, self.servers.isEmpty else { return }
            self.foundNothing = true
        }
    }

    func stop() {
        browser?.cancel()
        browser = nil
        patience?.cancel()
        isSearching = false
    }

    /// Looks again from scratch (Look Again, or back from Settings).
    func restart() {
        stop()
        servers = []
        blocked = false
        start()
    }

    /// kDNSServiceErr_PolicyDenied: Local Network access is off for this app.
    private nonisolated static func isPolicyDenied(_ error: NWError) -> Bool {
        if case .dns(let code) = error { return code == -65570 }
        return false
    }

    /// UI tests on a Mac whose network has other Homespun servers name the ones they expect
    /// (`HOMESPUN_DISCOVER_ONLY`, comma-separated; empty for none).
    private static let only: Set<String>? = {
        #if DEBUG
        guard let names = ProcessInfo.processInfo.environment["HOMESPUN_DISCOVER_ONLY"] else { return nil }
        return Set(names.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        #else
        return nil
        #endif
    }()

    private func update(_ endpoints: [(String, NWEndpoint)]) {
        let endpoints = endpoints.filter { Self.only?.contains($0.0) ?? true }
        let names = Set(endpoints.map(\.0))
        servers.removeAll { !names.contains($0.name) }
        for (name, endpoint) in endpoints where !servers.contains(where: { $0.name == name }) {
            servers.append(Found(name: name, url: nil))
            lastChange = Date()
            Task { await describe(name, endpoint) }
        }
    }

    private func describe(_ name: String, _ endpoint: NWEndpoint) async {
        guard let url = await Self.resolve(endpoint) else {
            set(name) { $0.unreachable = true }
            return
        }
        set(name) {
            $0.url = url
            $0.pairedBefore = Keychain.token(for: url.absoluteString) != nil
        }
        var client = ServerClient(baseURL: url)
        client.timeout = 6
        do {
            let options = try await client.pairingOptions()
            set(name) { $0.options = options }
        } catch let failure as ServerClient.Failure where failure.status == 404 {
            set(name) { $0.needsUpdate = true }
        } catch {
            set(name) { $0.unreachable = true }
        }
    }

    private func set(_ name: String, _ change: (inout Found) -> Void) {
        guard let index = servers.firstIndex(where: { $0.name == name }) else { return }
        change(&servers[index])
        lastChange = Date()
    }

    /// The service's IPv4 address and port, found by connecting to it briefly.
    nonisolated static func resolve(_ endpoint: NWEndpoint) async -> URL? {
        let parameters = NWParameters.tcp
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        let connection = NWConnection(to: endpoint, using: parameters)
        let box = Resolution()
        return await withCheckedContinuation { continuation in
            box.continuation = continuation
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case .hostPort(let host, let port) = connection.currentPath?.remoteEndpoint {
                        var address = "\(host)"
                        if let percent = address.firstIndex(of: "%") { address = String(address[..<percent]) }
                        box.finish(URL(string: "http://\(address):\(port.rawValue)"))
                    } else {
                        box.finish(nil)
                    }
                    connection.cancel()
                case .failed, .cancelled: box.finish(nil)
                default: break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 8) {
                box.finish(nil)
                connection.cancel()
            }
        }
    }

    private final class Resolution: @unchecked Sendable {
        private let lock = NSLock()
        var continuation: CheckedContinuation<URL?, Never>?

        func finish(_ url: URL?) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: url)
        }
    }
}
