// SPDX-License-Identifier: Apache-2.0
import Foundation
import Network
import Observation

/// Finds Homespun Servers on the home network (Bonjour `_homespun._tcp`).
@MainActor @Observable
final class ServerDiscovery {
    struct Found: Identifiable, Equatable {
        var id: String { name }
        var name: String
        var url: URL?
    }

    private(set) var servers: [Found] = []
    private(set) var isSearching = false
    /// Nothing turned up after a few seconds, so the user should hear why that might be.
    private(set) var foundNothing = false
    /// iOS blocked the search: the user turned off Local Network access for Homespun.
    private(set) var blocked = false
    private var browser: NWBrowser?
    private var patience: Task<Void, Never>?

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

    /// kDNSServiceErr_PolicyDenied: Local Network access is off for this app.
    private nonisolated static func isPolicyDenied(_ error: NWError) -> Bool {
        if case .dns(let code) = error { return code == -65570 }
        return false
    }

    private func update(_ endpoints: [(String, NWEndpoint)]) {
        let names = Set(endpoints.map(\.0))
        servers.removeAll { !names.contains($0.name) }
        for (name, endpoint) in endpoints where !servers.contains(where: { $0.name == name }) {
            servers.append(Found(name: name, url: nil))
            Task {
                let url = await Self.resolve(endpoint)
                if let index = servers.firstIndex(where: { $0.name == name }) { servers[index].url = url }
            }
        }
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
