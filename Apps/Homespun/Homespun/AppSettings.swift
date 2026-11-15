// SPDX-License-Identifier: Apache-2.0
import Foundation
import HomespunCore
import Observation
import UIKit

/// Where compact copies are made, the paired server, and first-run progress.
@MainActor @Observable
final class AppSettings {
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

    var onboardingComplete: Bool { didSet { defaults.set(onboardingComplete, forKey: "onboardingComplete") } }
    /// The one-time explanation before removing originals was shown.
    var removalExplained: Bool { didSet { defaults.set(removalExplained, forKey: "removalExplained") } }
    /// The user checked the first removed batch; until then a removal takes at most `trialLimit`.
    var trialConfirmed: Bool { didSet { defaults.set(trialConfirmed, forKey: "trialConfirmed") } }
    static let trialLimit = 10
    /// Space freed on this iPhone so far, and since when (Activity's total, the Premium moment).
    var freedBytes: Int {
        didSet {
            defaults.set(freedBytes, forKey: "freedBytes")
            if freedSince == nil, freedBytes > 0 { freedSince = Date() }
        }
    }
    var freedSince: Date? { didSet { defaults.set(freedSince, forKey: "freedSince") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        serverURL = defaults.url(forKey: "serverURL")
        server = defaults.data(forKey: "serverInfo").flatMap { try? ServerAPI.decoder.decode(ServerAPI.ServerInfo.self, from: $0) }
        // Homespun always works through the paired server; the old mode choice (server or
        // "on this iPhone") is gone, so a paired iPhone keeps working whatever it had chosen.
        defaults.removeObject(forKey: "compactMode")
        defaults.removeObject(forKey: "useServer")
        onboardingComplete = defaults.bool(forKey: "onboardingComplete")
        removalExplained = defaults.bool(forKey: "removalExplained")
        trialConfirmed = defaults.bool(forKey: "trialConfirmed")
        freedBytes = defaults.integer(forKey: "freedBytes")
        freedSince = defaults.object(forKey: "freedSince") as? Date
    }

    var client: ServerClient? {
        guard let serverURL, let token = Keychain.token(for: serverURL.absoluteString) else { return nil }
        return ServerClient(baseURL: serverURL, token: token)
    }

    var isPaired: Bool { client != nil && server != nil }
    var usesServer: Bool { isPaired }
    var canCompact: Bool { usesServer }

    /// Compacts through the paired server. A Mac server does everything, Live Photos included;
    /// with a Linux server, this iPhone compresses Live Photo motion (only Apple's AVFoundation
    /// keeps it paired with the photo).
    func compactor(ledger: CompactLedger) -> (any Compacting)? {
        guard usesServer, let client, let server else { return nil }
        return ServerCompactor(client: client, mode: server.mode, profile: server.profile, ledger: ledger)
    }

    func remover(ledger: CompactLedger) -> OriginalRemover? {
        guard let client, let server else { return nil }
        return OriginalRemover(client: client, mode: server.mode, ledger: ledger)
    }

    // MARK: Pairing

    func pair(_ link: PairingLink) async throws {
        let response = try await ServerClient(baseURL: link.serverURL).pair(code: link.code, deviceName: UIDevice.current.name)
        try finishPairing(serverURL: link.serverURL, response: response)
    }

    /// Keeps a pairing made with a code or allowed on the server.
    func finishPairing(serverURL newURL: URL, response: ServerAPI.PairResponse) throws {
        try Keychain.setToken(response.token, for: newURL.absoluteString)
        if let serverURL, serverURL != newURL { Keychain.removeToken(for: serverURL.absoluteString) }
        serverURL = newURL
        defaults.set(newURL, forKey: "serverURL")
        store(response.server)
        serverStatus = .reachable
    }

    func unpair() {
        if let serverURL { Keychain.removeToken(for: serverURL.absoluteString) }
        serverURL = nil
        server = nil
        serverStatus = .unknown
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
