// SPDX-License-Identifier: Apache-2.0
import Foundation
import HomespunCore
import Observation
import UIKit

/// Where compact copies are made, the paired server, and first-run progress.
@MainActor @Observable
final class AppSettings {
    enum Mode: String { case server, device }

    enum ServerStatus: Equatable {
        case unknown, checking, reachable
        case unreachable(String)
    }

    private let defaults: UserDefaults
    private(set) var serverURL: URL?
    private(set) var server: ServerAPI.ServerInfo?
    private(set) var serverStatus: ServerStatus = .unknown
    /// A pairing link opened from the Camera app, waiting for the user to confirm.
    var pendingLink: PairingLink?

    /// nil until the user pairs a server or chooses this iPhone in Settings.
    var mode: Mode? { didSet { defaults.set(mode?.rawValue, forKey: "compactMode") } }
    var onboardingComplete: Bool { didSet { defaults.set(onboardingComplete, forKey: "onboardingComplete") } }
    /// The one-time explanation before removing originals was shown.
    var removalExplained: Bool { didSet { defaults.set(removalExplained, forKey: "removalExplained") } }
    /// The user checked the first removed batch; until then a removal takes at most `trialLimit`.
    var trialConfirmed: Bool { didSet { defaults.set(trialConfirmed, forKey: "trialConfirmed") } }
    static let trialLimit = 10

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        serverURL = defaults.url(forKey: "serverURL")
        server = defaults.data(forKey: "serverInfo").flatMap { try? ServerAPI.decoder.decode(ServerAPI.ServerInfo.self, from: $0) }
        mode = defaults.string(forKey: "compactMode").flatMap(Mode.init(rawValue:))
            ?? (defaults.bool(forKey: "useServer") ? .server : nil)
        onboardingComplete = defaults.bool(forKey: "onboardingComplete")
        removalExplained = defaults.bool(forKey: "removalExplained")
        trialConfirmed = defaults.bool(forKey: "trialConfirmed")
        if mode == .server, client == nil { mode = nil }
    }

    var client: ServerClient? {
        guard let serverURL, let token = Keychain.token(for: serverURL.absoluteString) else { return nil }
        return ServerClient(baseURL: serverURL, token: token)
    }

    var isPaired: Bool { client != nil && server != nil }
    var usesServer: Bool { mode == .server && isPaired }
    var canCompact: Bool { usesServer || mode == .device }

    func compactor(ledger: CompactLedger) -> any Compacting {
        if usesServer, let client, let server {
            return ServerCompactor(client: client, mode: server.mode, profile: server.profile, ledger: ledger)
        }
        return OnDeviceCompactor(ledger: ledger)
    }

    func remover(ledger: CompactLedger) -> OriginalRemover? {
        guard let client, let server else { return nil }
        return OriginalRemover(client: client, mode: server.mode, ledger: ledger)
    }

    // MARK: Pairing

    func pair(_ link: PairingLink) async throws {
        let response = try await ServerClient(baseURL: link.serverURL).pair(code: link.code, deviceName: UIDevice.current.name)
        try Keychain.setToken(response.token, for: link.serverURL.absoluteString)
        if let serverURL, serverURL != link.serverURL { Keychain.removeToken(for: serverURL.absoluteString) }
        serverURL = link.serverURL
        defaults.set(link.serverURL, forKey: "serverURL")
        store(response.server)
        serverStatus = .reachable
        mode = .server
    }

    func pair(address: String, code: String) async throws {
        guard let url = PairingLink.serverURL(from: address) else {
            throw ServerClient.Failure(status: 0, message: "Enter the server's address, for example 192.168.1.20:8787.")
        }
        try await pair(PairingLink(serverURL: url, code: code))
    }

    func unpair() {
        if let serverURL { Keychain.removeToken(for: serverURL.absoluteString) }
        serverURL = nil
        server = nil
        serverStatus = .unknown
        if mode == .server { mode = nil }
        defaults.removeObject(forKey: "serverURL")
        defaults.removeObject(forKey: "serverInfo")
    }

    private func store(_ info: ServerAPI.ServerInfo) {
        server = info
        defaults.set(try? ServerAPI.encoder.encode(info), forKey: "serverInfo")
    }

    /// Checks the server answers and picks up changes (for example Immich being connected).
    func refreshServerInfo() async {
        guard var client else { return }
        if serverStatus != .reachable { serverStatus = .checking }
        client.timeout = 6
        do {
            store(try await client.info())
            serverStatus = .reachable
        } catch let error as ServerClient.Failure where error.status == 401 {
            serverStatus = .unreachable("The server no longer recognises this iPhone. Pair it again.")
        } catch {
            serverStatus = .unreachable("Can't reach \(server?.name ?? "the server"). Make sure this iPhone is on your home network.")
        }
    }
}
