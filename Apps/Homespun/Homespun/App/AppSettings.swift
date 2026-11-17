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

    /// Where these settings are kept (the demo has its own).
    let defaults: UserDefaults
    /// The photo library this app works on: Photos, or the demo's sample photos.
    let photos: any PhotoSource
    /// The demo (Try the Demo): sample photos and a pretend server, kept apart from everything else.
    let isDemo: Bool
    private let tokens: any TokenStore
    /// How the server is reached (the demo's answers in the app itself).
    private let session: URLSession
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

    init(defaults: UserDefaults = .standard, photos: any PhotoSource = PhotoKitSource(), tokens: any TokenStore = KeychainTokens(),
         session: URLSession = .shared, isDemo: Bool = false) {
        self.defaults = defaults
        self.photos = photos
        self.tokens = tokens
        self.session = session
        self.isDemo = isDemo
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
        guard let serverURL, let token = tokens.token(for: serverURL.absoluteString) else { return nil }
        return ServerClient(baseURL: serverURL, token: token, session: session)
    }

    var isPaired: Bool { client != nil && server != nil }
    var usesServer: Bool { isPaired }
    var canCompact: Bool { usesServer }

    /// Compacts through the paired server. A Mac server does everything, Live Photos included;
    /// with a Linux server, this iPhone compresses Live Photo motion (only Apple's AVFoundation
    /// keeps it paired with the photo).
    func compactor(ledger: CompactLedger) -> (any Compacting)? {
        guard usesServer, let client, let server else { return nil }
        return photos.compactor(client: client, mode: server.mode, profile: server.profile, ledger: ledger)
    }

    func remover(ledger: CompactLedger) -> (any RemovingOriginals)? {
        guard let client, let server else { return nil }
        return photos.remover(client: client, mode: server.mode, ledger: ledger)
    }

    func restorer(ledger: CompactLedger) -> (any RestoringOriginals)? {
        guard let client else { return nil }
        return photos.restorer(client: client, ledger: ledger)
    }

    // MARK: Pairing

    struct DemoOnly: LocalizedError {
        var errorDescription: String? { "In the demo, Homespun pairs only with Homespun Demo. Leave the demo to pair your own server." }
    }

    func pair(_ link: PairingLink) async throws {
        guard !isDemo || link.serverURL.host == DemoServer.host else { throw DemoOnly() }
        let response = try await ServerClient(baseURL: link.serverURL, session: session).pair(code: link.code,
                                                                                           deviceName: UIDevice.current.name)
        try finishPairing(serverURL: link.serverURL, response: response)
    }

    /// Keeps a pairing made with a code or allowed on the server.
    func finishPairing(serverURL newURL: URL, response: ServerAPI.PairResponse) throws {
        // The demo's sample photos never go to a real server.
        guard !isDemo || newURL.host == DemoServer.host else { throw DemoOnly() }
        try tokens.setToken(response.token, for: newURL.absoluteString)
        if let serverURL, serverURL != newURL { tokens.removeToken(for: serverURL.absoluteString) }
        serverURL = newURL
        defaults.set(newURL, forKey: "serverURL")
        store(response.server)
        serverStatus = .reachable
    }

    func unpair() {
        if let serverURL { tokens.removeToken(for: serverURL.absoluteString) }
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
        let before = serverStatus
        if serverStatus != .reachable { serverStatus = .checking }
        client.timeout = 6
        do {
            let info = try await client.info()
            store(info)
            serverStatus = .reachable
            Telemetry.shared.recordServerInfoDaily(info)
        } catch where Self.isCancellation(error) {
            // The screen that asked went away (its task was cancelled): nothing was learned. Saying
            // "Can't reach" here showed a working server as unreachable until the next check.
            if serverStatus == .checking { serverStatus = before }
        } catch let error as ServerClient.Failure where error.status == 401 {
            serverStatus = .unreachable("The server no longer recognises this iPhone. Pair it again.")
        } catch {
            AppLog.server.notice("server unreachable: \(Telemetry.Event.code(error), privacy: .public)")
            serverStatus = .unreachable("Can't reach \(server?.name ?? "the server"). Make sure this iPhone is on your home network.")
        }
    }

    nonisolated static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        let error = error as NSError
        return error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled
    }
}
