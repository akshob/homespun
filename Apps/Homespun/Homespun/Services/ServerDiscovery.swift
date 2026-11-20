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
        var fingerprintHint: ServerKeyFingerprint?

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
    /// Servers that answer without looking on the network (the demo's pretend server); nil: Bonjour.
    private let pretend: [(name: String, url: URL)]?
    private let describeOptions: Bool
    private var pretending: Task<Void, Never>?

    init(pretend: [(name: String, url: URL)]? = nil, describeOptions: Bool = true) {
        self.pretend = pretend
        self.describeOptions = describeOptions
    }

    /// Servers that can be recommended, as the advisor sees them.
    var ready: [Found] { servers.filter(\.isReady) }

    func found(_ id: String) -> Found? { servers.first { $0.name == id } }

    func start() {
        if let pretend {
            guard pretending == nil else { return }
            isSearching = true
            // Found after a moment, as a real one would be.
            pretending = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled, let self else { return }
                for (name, url) in pretend where !self.servers.contains(where: { $0.name == name }) {
                    self.servers.append(Found(name: name, url: url))
                    self.lastChange = Date()
                    await self.ask(name, url)
                }
            }
            return
        }
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_homespun._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let endpoints = results.compactMap { result -> (String, NWEndpoint, ServerKeyFingerprint?)? in
                guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                let fingerprint: ServerKeyFingerprint?
                if case .bonjour(let record) = result.metadata {
                    fingerprint = record["fp"].flatMap(ServerKeyFingerprint.init(base64url:))
                } else {
                    fingerprint = nil
                }
                return (name, result.endpoint, fingerprint)
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
        pretending?.cancel()
        pretending = nil
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

    private func update(_ endpoints: [(String, NWEndpoint, ServerKeyFingerprint?)]) {
        let endpoints = endpoints.filter { Self.only?.contains($0.0) ?? true }
        let names = Set(endpoints.map(\.0))
        servers.removeAll { !names.contains($0.name) }
        for (name, endpoint, fingerprint) in endpoints {
            if let index = servers.firstIndex(where: { $0.name == name }) {
                servers[index].fingerprintHint = fingerprint
                if let fingerprint, Keychain.recognises(fingerprint) { servers[index].pairedBefore = true }
            } else {
                servers.append(Found(name: name, url: nil,
                                     pairedBefore: fingerprint.map(Keychain.recognises) ?? false, fingerprintHint: fingerprint))
                lastChange = Date()
                Task { await describe(name, endpoint) }
            }
        }
    }

    private func describe(_ name: String, _ endpoint: NWEndpoint) async {
        guard let url = await Self.resolve(endpoint) else {
            set(name) { $0.unreachable = true }
            return
        }
        set(name) {
            $0.url = url
            $0.pairedBefore = $0.pairedBefore || Keychain.token(for: url.absoluteString) != nil
                || Keychain.token(for: url.absoluteString.replacingOccurrences(of: "https://", with: "http://")) != nil
        }
        if describeOptions { await ask(name, url) }
    }

    /// Asks a server found at `url` what it runs on.
    private func ask(_ name: String, _ url: URL) async {
        var client = ServerClient(baseURL: url, trust: url.host == DemoServer.host ? .demo : .capture(expected: nil))
        defer { client.retireSession() }
        client.timeout = 6
        do {
            let options = try await client.pairingOptions()
            set(name) { $0.options = options; $0.needsUpdate = (options.pairingVersion ?? 0) < 2 }
        } catch let failure as ServerClient.Failure where failure.status == 404 {
            set(name) { $0.needsUpdate = true }
        } catch let error as URLError where error.code == .secureConnectionFailed {
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
                        box.finish(URL(string: "https://\(address):\(port.rawValue)"))
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
