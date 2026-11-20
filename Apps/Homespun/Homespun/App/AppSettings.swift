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
        case securing
        case identityProblem(String)
        case needsServerUpdate(String)
    }

    /// Where these settings are kept (the demo has its own).
    let defaults: UserDefaults
    /// The photo library this app works on: Photos, or the demo's sample photos.
    let photos: any PhotoSource
    /// The demo (Try the Demo): sample photos and a pretend server, kept apart from everything else.
    let isDemo: Bool
    private let clock: AppClock
    private let tokens: any TokenStore
    private let installationStore: any InstallationStore
    /// How the server is reached (the demo's answers in the app itself).
    private let session: URLSession?
    private let verifyIdentity: (@Sendable (URL, String) async throws -> ServerPairing.Verified)?
    private let locateServer: ServerLocation.Finder
    private struct LocationWork {
        var id: UUID
        var task: Task<Bool, Never>
    }
    private var locationWork: LocationWork?
    private(set) var addressSearchFailed = false
    var findingAddress: Bool { locationWork != nil }
    private struct VerificationWork {
        var id: UUID
        var task: Task<Void, Never>
    }
    private var securityWork: VerificationWork?
    @ObservationIgnored private var infoWork: VerificationWork?
    private var lastIdentityAttempt = Date.distantPast
    private let identityRetryBaseDelay: TimeInterval
    private let identityNow: @Sendable () -> Date
    private var identityRetryTask: Task<Void, Never>?
    private var identityRetryCount = 0
    private(set) var nextIdentityRetry: Date?
    var identityNotice: Date?
    private(set) var identityObserved: ServerKeyFingerprint?
    private(set) var serverURL: URL?
    private(set) var server: ServerAPI.ServerInfo?
    private(set) var serverStatus: ServerStatus = .unknown {
        didSet { if serverStatus != .checking, serverStatus != .unknown { serverCheckedAt = clock.now() } }
    }
    /// When the server last answered, or didn't (for the widgets).
    private(set) var serverCheckedAt: Date?
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
            if freedSince == nil, freedBytes > 0 { freedSince = clock.now() }
        }
    }
    var freedSince: Date? { didSet { defaults.set(freedSince, forKey: "freedSince") } }

    init(defaults: UserDefaults = .standard, photos: any PhotoSource = PhotoKitSource(), tokens: any TokenStore = KeychainTokens(),
         session: URLSession? = nil, isDemo: Bool = false,
         verifyIdentity: (@Sendable (URL, String) async throws -> ServerPairing.Verified)? = nil,
         locateServer: @escaping ServerLocation.Finder = { try await ServerLocation.locate(name: $0, pins: $1, excluding: $2) },
         installationStore: (any InstallationStore)? = nil, identityRetryBaseDelay: TimeInterval = 60,
         identityNow: @escaping @Sendable () -> Date = { Date() }, clock: AppClock = .live,
         initialServerStatus: ServerStatus = .unknown) {
        self.defaults = defaults
        self.clock = clock
        self.photos = photos
        self.tokens = tokens
        if let installationStore { self.installationStore = installationStore }
        else if isDemo { self.installationStore = DefaultsInstallation(defaults: defaults) }
        else { self.installationStore = KeychainInstallation() }
        self.session = session
        self.isDemo = isDemo
        self.verifyIdentity = verifyIdentity
        self.locateServer = locateServer
        self.identityRetryBaseDelay = max(0.001, identityRetryBaseDelay)
        self.identityNow = identityNow
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
        if isDemo, let old = serverURL, old.scheme == "http", old.host == DemoServer.host,
           let token = tokens.token(for: old.absoluteString) {
            let url = DemoServer.baseURL
            try? tokens.setPins(ServerPins(pins: [DemoServer.fingerprint], source: "upgrade"), for: url.absoluteString)
            try? tokens.setToken(token, for: url.absoluteString)
            serverURL = url
            defaults.set(url, forKey: "serverURL")
            tokens.removeToken(for: old.absoluteString)
            tokens.removePins(for: old.absoluteString)
        }
        if initialServerStatus != .unknown {
            serverStatus = initialServerStatus
            if initialServerStatus != .checking { serverCheckedAt = clock.now() }
        }
    }

    var client: ServerClient? {
        guard let serverURL, let token = tokens.token(for: serverURL.absoluteString) else { return nil }
        return ServerClient(baseURL: serverURL, token: token, trust: connectionTrust, session: session,
                            reconnect: { [weak self] url, token in await self?.followServerAddress(from: url, token: token) })
    }

    var pins: ServerPins? { serverURL.flatMap { tokens.pins(for: $0.absoluteString) } }
    var bonjourServiceName: String? { pins?.serviceName ?? defaults.string(forKey: "serverBonjourName") ?? server?.name }
    var addressNotice: String? {
        guard defaults.object(forKey: "serverAddressChangedAt") != nil else { return nil }
        return "Found \(server?.name ?? bonjourServiceName ?? "your server") at its new address"
    }
    var connectionProblem: String? {
        switch serverStatus {
        case .identityProblem(let message), .needsServerUpdate(let message): message
        case .securing: "Securing the connection to your server…"
        default: nil
        }
    }

    var connectionTrust: ServerTrust {
        if isDemo { return .demo }
        if let message = connectionProblem { return .blocked(message) }
        guard serverURL?.scheme == "https", let pins else {
            return .blocked("Securing the connection to your server…")
        }
        return pins.trust
    }

    var tlsVersion: String { client?.delegate?.tlsVersion ?? "TLS" }
    func pairingIdentity() throws -> DeviceInstallation { try installationStore.load() }
    var pairingName: String { (try? installationStore.load().name) ?? UIDevice.current.name }
    func confirmDeviceName(_ name: String) { try? installationStore.confirm(name: name) }

    var isPaired: Bool {
        server != nil && serverURL.map { tokens.token(for: $0.absoluteString) != nil } == true
    }
    var usesServer: Bool { isPaired }
    var canCompact: Bool {
        guard usesServer else { return false }
        if case .blocked = connectionTrust { return false }
        return true
    }

    /// Compacts through the paired server. A Mac server does everything, Live Photos included;
    /// with a Linux server, this iPhone compresses Live Photo motion (only Apple's AVFoundation
    /// keeps it paired with the photo).
    func compactor(ledger: CompactLedger) -> (any Compacting)? {
        guard canCompact, let client, let server else { return nil }
        return photos.compactor(client: client, mode: server.mode, profile: server.profile, ledger: ledger)
    }

    func remover(ledger: CompactLedger) -> (any RemovingOriginals)? {
        guard canCompact, let client, let server else { return nil }
        return photos.remover(client: client, mode: server.mode, ledger: ledger)
    }

    func restorer(ledger: CompactLedger) -> (any RestoringOriginals)? {
        guard canCompact, let client else { return nil }
        return photos.restorer(client: client, ledger: ledger)
    }

    // MARK: Pairing

    struct DemoOnly: LocalizedError {
        var errorDescription: String? { "In the demo, Homespun pairs only with Homespun Demo. Leave the demo to pair your own server." }
    }

    func pair(_ link: PairingLink) async throws {
        guard !isDemo || link.serverURL.host == DemoServer.host else { throw DemoOnly() }
        let installation = try pairingIdentity()
        try finishPairing(try await ServerPairing.pair(link: link, deviceName: installation.name ?? UIDevice.current.name,
                                                      installID: installation.id), serviceName: link.name)
    }

    func approvePairing(url: URL, onNumber: (String, Date) -> Void,
                        confirmNumber: (String) async -> Bool) async throws -> ServerPairing.Paired {
        let installation = try pairingIdentity()
        return try await ServerPairing.approve(url: url, deviceName: installation.name ?? UIDevice.current.name,
                                               installID: installation.id, onNumber: onNumber, confirmNumber: confirmNumber)
    }

    func finishPairing(_ paired: ServerPairing.Paired, serviceName: String? = nil) throws {
        try finishPairing(serverURL: paired.url, response: paired.response, pins: paired.pins, serviceName: serviceName)
    }

    /// Keeps a pairing made with a code or allowed on the server.
    func finishPairing(serverURL newURL: URL, response: ServerAPI.PairResponse, pins: ServerPins, serviceName: String? = nil) throws {
        // The demo's sample photos never go to a real server.
        guard !isDemo || newURL.host == DemoServer.host else { throw DemoOnly() }
        guard newURL.scheme == "https" else { throw ServerPairing.IdentityFailure() }
        infoWork?.task.cancel()
        var pins = pins
        pins.serviceName = serviceName ?? pins.serviceName ?? response.server.name
        try tokens.setPins(pins, for: newURL.absoluteString)
        try tokens.setToken(response.token, for: newURL.absoluteString)
        if let serverURL, serverURL != newURL {
            tokens.removeToken(for: serverURL.absoluteString)
            tokens.removePins(for: serverURL.absoluteString)
        }
        serverURL = newURL
        defaults.set(newURL, forKey: "serverURL")
        defaults.set(response.deviceID, forKey: "serverDeviceID")
        defaults.set(pins.serviceName, forKey: "serverBonjourName")
        defaults.removeObject(forKey: "serverAddressChangedAt")
        defaults.removeObject(forKey: "serverLastAddressSearch")
        store(response.server)
        serverStatus = .reachable
        identityNotice = nil
        identityObserved = nil
        lastIdentityAttempt = .distantPast
        clearIdentityRetry()
        securityWork?.task.cancel()
        securityWork = nil
        locationWork?.task.cancel()
        locationWork = nil
        addressSearchFailed = false
        ServerSessions.shared.reset()
    }

    func unpair() {
        infoWork?.task.cancel()
        revokeCurrentDevice()
        if let serverURL {
            var accounts = [serverURL.absoluteString]
            if var alias = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) {
                alias.scheme = serverURL.scheme == "https" ? "http" : "https"
                if let url = alias.url { accounts.append(url.absoluteString) }
            }
            for account in accounts {
                tokens.removeToken(for: account)
                tokens.removePins(for: account)
            }
        }
        ServerSessions.shared.reset()
        identityNotice = nil
        identityObserved = nil
        lastIdentityAttempt = .distantPast
        clearIdentityRetry()
        securityWork?.task.cancel()
        securityWork = nil
        locationWork?.task.cancel()
        locationWork = nil
        addressSearchFailed = false
        serverURL = nil
        server = nil
        serverStatus = .unknown
        defaults.removeObject(forKey: "serverURL")
        defaults.removeObject(forKey: "serverInfo")
        defaults.removeObject(forKey: "serverBonjourName")
        defaults.removeObject(forKey: "serverAddressChangedAt")
        defaults.removeObject(forKey: "serverLastAddressSearch")
        defaults.removeObject(forKey: "serverDeviceID")
    }

    private func revokeCurrentDevice() {
        guard !isDemo, let original = client else { return }
        if case .blocked = original.trust { return }
        let (session, delegate) = ServerSessions.shared.freshSession(trust: original.trust)
        var client = ServerClient(baseURL: original.baseURL, token: original.token, trust: original.trust,
                                  session: session, delegate: delegate)
        client.timeout = 3
        let sender = client
        let knownID = defaults.string(forKey: "serverDeviceID")
        Task {
            defer { session.invalidateAndCancel() }
            do {
                let id: String?
                if let knownID, !knownID.isEmpty { id = knownID }
                else { id = try await sender.devices().first(where: \.isThisDevice)?.id }
                if let id { try await sender.removeDevice(id) }
            } catch {
                // Offline unpairing leaves the active record available for an owner-approved re-pair.
            }
        }
    }

    private func store(_ info: ServerAPI.ServerInfo) {
        server = info
        defaults.set(try? ServerAPI.encoder.encode(info), forKey: "serverInfo")
        if let name = info.deviceName { confirmDeviceName(name) }
        if defaults.string(forKey: "serverBonjourName") == nil { defaults.set(info.name, forKey: "serverBonjourName") }
        if let serverURL, var pins, pins.serviceName == nil {
            pins.serviceName = defaults.string(forKey: "serverBonjourName")
            try? tokens.setPins(pins, for: serverURL.absoluteString)
        }
    }

    /// Resolves an address change without ever giving a candidate the bearer token before its pin matches.
    func followServerAddress(from failedURL: URL, token expectedToken: String?) async -> ServerClient? {
        guard !isDemo, let expectedToken, let currentURL = serverURL,
              tokens.token(for: currentURL.absoluteString) == expectedToken,
              let saved = pins, !saved.pins.isEmpty else { return nil }
        if currentURL != failedURL { return client }
        if let locationWork {
            _ = await locationWork.task.value
            return serverURL != failedURL && client?.token == expectedToken ? client : nil
        }
        let last = defaults.object(forKey: "serverLastAddressSearch") as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) >= 60 else { return nil }
        defaults.set(Date(), forKey: "serverLastAddressSearch")
        let id = UUID()
        let work = Task { await moveToVerifiedAddress(from: failedURL, token: expectedToken, pins: saved) }
        locationWork = LocationWork(id: id, task: work)
        let moved = await work.value
        if locationWork?.id == id {
            locationWork = nil
            addressSearchFailed = !moved
        }
        return serverURL != failedURL && client?.token == expectedToken ? client : nil
    }

    private func moveToVerifiedAddress(from oldURL: URL, token: String, pins saved: ServerPins) async -> Bool {
        do {
            guard let found = try await locateServer(bonjourServiceName, Set(saved.pins), oldURL),
                  saved.pins.contains(found.fingerprint), found.candidate.url.scheme == "https",
                  found.candidate.url.host != nil, found.candidate.url != oldURL else { return false }
            try Task.checkCancellation()
            guard serverURL == oldURL, tokens.token(for: oldURL.absoluteString) == token,
                  pins?.pins == saved.pins else { return false }
            let url = found.candidate.url
            var pins = saved
            pins.serviceName = found.candidate.serviceName
            try tokens.setPins(pins, for: url.absoluteString)
            try tokens.setToken(token, for: url.absoluteString)
            defaults.set(url, forKey: "serverURL")
            serverURL = url
            defaults.set(pins.serviceName, forKey: "serverBonjourName")
            defaults.set(Date(), forKey: "serverAddressChangedAt")
            tokens.removeToken(for: oldURL.absoluteString)
            tokens.removePins(for: oldURL.absoluteString)
            ServerSessions.shared.reset(oldURL)
            ServerSessions.shared.reset(url)
            clearIdentityRetry()
            identityObserved = nil
            if connectionProblem != nil { serverStatus = .unknown }
            AppLog.server.notice("Found the paired server at its new address: \(url.absoluteString, privacy: .private)")
            return true
        } catch {
            return false
        }
    }

    /// Checks the server answers and picks up changes (for example Immich being connected).
    func refreshServerInfo() async {
        if let infoWork { await infoWork.task.value; return }
        let id = UUID()
        let task = Task { await checkServerInfo() }
        infoWork = VerificationWork(id: id, task: task)
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if infoWork?.id == id { infoWork = nil }
    }

    private func checkServerInfo() async {
        await secureLegacyPairing()
        if case .identityProblem = serverStatus, identityObserved != nil, let url = serverURL,
           let token = tokens.token(for: url.absoluteString) {
            // The old address may now belong to another server; its identity failure must not block finding our pinned key.
            _ = await followServerAddress(from: url, token: token)
        }
        guard connectionProblem == nil else { return }
        guard var client else { return }
        let before = serverStatus
        let knownGood = before == .reachable || (before == .unknown && server != nil)
        let token = client.token
        func current() -> Bool {
            guard let url = serverURL, token != nil else { return false }
            return tokens.token(for: url.absoluteString) == token && connectionProblem == nil
        }
        // A retry keeps the last result on screen until it learns something new.
        if serverStatus == .unknown { serverStatus = .checking }
        client.timeout = 12
        do {
            let info: ServerAPI.ServerInfo
            do {
                info = try await client.info()
            } catch {
                if Self.isCancellation(error) || error is ServerClient.IdentityMismatch
                    || error is ServerPairing.IdentityFailure || error is ServerPairing.UnrecognisedIdentity { throw error }
                if let failure = error as? ServerClient.Failure,
                   failure.status == 401 || failure.code == "tls_blocked" || failure.code == "insecure" { throw error }
                guard knownGood, current() else { throw error }
                // Confirm a transient failure before replacing a known-good result.
                info = try await client.info()
            }
            guard current() else { return }
            try Task.checkCancellation()
            // A live TLS connection can outlast a rotation. Only the proof, not this hint, authorizes a new pin.
            if let fingerprint = info.tls?.fingerprint, case .pinned(let trusted) = client.trust,
               !trusted.contains(fingerprint) {
                identityObserved = fingerprint
                await reverifyIdentity()
                if current(), serverStatus == .reachable { store(info) }
                return
            }
            store(info)
            serverStatus = .reachable
            Telemetry.shared.recordServerInfoDaily(info)
        } catch let mismatch as ServerClient.IdentityMismatch {
            guard current(), !Task.isCancelled else { return }
            identityObserved = mismatch.observed
            await reverifyIdentity()
        } catch where Self.isCancellation(error) {
            // The screen that asked went away (its task was cancelled): nothing was learned. Saying
            // "Can't reach" here showed a working server as unreachable until the next check.
            if serverStatus == .checking { serverStatus = before }
        } catch let error as ServerClient.Failure where error.status == 401 {
            guard current(), !Task.isCancelled else { return }
            serverStatus = .unreachable("The server no longer recognises this iPhone. Pair it again.")
        } catch {
            guard current(), !Task.isCancelled else { return }
            AppLog.server.notice("server unreachable: \(Telemetry.Event.code(error), privacy: .public)")
            serverStatus = .unreachable("Can't reach \(server?.name ?? "the server"). Make sure this iPhone is on your home network.")
        }
    }

    func secureLegacyPairing() async {
        guard let url = serverURL, !isDemo else { return }
        if url.scheme == "https", pins != nil {
            if nextIdentityRetry != nil, identityNow().timeIntervalSince(lastIdentityAttempt) >= identityRetryBaseDelay {
                await verifyPairing(reverify: true)
            }
            return
        }
        await verifyPairing(reverify: false)
    }

    func reverifyIdentity() async { await verifyPairing(reverify: true) }

    private func clearIdentityRetry() {
        identityRetryTask?.cancel()
        identityRetryTask = nil
        identityRetryCount = 0
        nextIdentityRetry = nil
    }

    private func scheduleIdentityRetry() {
        identityRetryCount += 1
        let delay = min(900, identityRetryBaseDelay * pow(2, Double(min(identityRetryCount - 1, 10))))
        nextIdentityRetry = identityNow().addingTimeInterval(delay)
        identityRetryTask?.cancel()
        identityRetryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self else { return }
            self.nextIdentityRetry = nil
            self.identityRetryTask = nil
            await self.verifyPairing(reverify: self.pins != nil)
        }
    }

    private func verifyPairing(reverify: Bool) async {
        if let securityWork { await securityWork.task.value; return }
        let id = UUID()
        let work = Task { await securePairing(reverify: reverify) }
        securityWork = VerificationWork(id: id, task: work)
        await work.value
        if securityWork?.id == id { securityWork = nil }
    }

    private func securePairing(reverify: Bool) async {
        guard let oldURL = serverURL, let token = tokens.token(for: oldURL.absoluteString) else { return }
        if identityNow().timeIntervalSince(lastIdentityAttempt) < identityRetryBaseDelay {
            if reverify, connectionProblem == nil {
                serverStatus = .unreachable("Checking the server's key again automatically.")
            }
            if nextIdentityRetry == nil {
                if case .identityProblem = serverStatus {} else { scheduleIdentityRetry() }
            }
            return
        }
        lastIdentityAttempt = identityNow()
        let previous = pins
        let allowSystemTrust = oldURL.scheme == "https"
            && (previous?.pins.isEmpty == true || (!reverify && !tokens.hasPinRecord(for: oldURL.absoluteString)))
        let before = serverStatus
        if previous == nil { serverStatus = .securing }
        do {
            let url = try ServerPairing.secureURL(oldURL)
            let verified: ServerPairing.Verified
            if !reverify, oldURL.scheme == "http", tokens.token(for: url.absoluteString) == token,
               let recovered = tokens.pins(for: url.absoluteString), let fingerprint = recovered.pins.first {
                verified = .init(url: url, fingerprint: fingerprint)
            } else {
                do {
                    if let verifyIdentity {
                        verified = try await verifyIdentity(oldURL, token)
                    } else {
                        verified = try await ServerPairing.verify(url: oldURL, token: token,
                            allowSystemTrust: allowSystemTrust)
                    }
                } catch where !reverify && previous == nil && ServerClient.isConnectionFailure(error) {
                    let last = defaults.object(forKey: "serverLastAddressSearch") as? Date ?? .distantPast
                    guard Date().timeIntervalSince(last) >= 60 else { throw error }
                    defaults.set(Date(), forKey: "serverLastAddressSearch")
                    guard let relocated = try await ServerLocation.verifyLegacy(name: bonjourServiceName, token: token, excluding: oldURL)
                    else { throw error }
                    verified = relocated
                }
            }
            guard serverURL == oldURL, tokens.token(for: oldURL.absoluteString) == token else { return }
            guard !verified.systemTrusted || allowSystemTrust else { throw ServerPairing.IdentityFailure(observed: verified.fingerprint) }
            var pins = ServerPins(pins: verified.systemTrusted ? [] : [verified.fingerprint], source: reverify ? "reverify" : "upgrade")
            pins.serviceName = verified.serviceName ?? previous?.serviceName ?? bonjourServiceName
            if reverify, let before = previous?.pins.first, before != verified.fingerprint {
                pins.previous = before
                pins.changedAt = Date()
                identityNotice = pins.changedAt
            }
            try tokens.setPins(pins, for: verified.url.absoluteString)
            try tokens.setToken(token, for: verified.url.absoluteString)
            serverURL = verified.url
            defaults.set(verified.url, forKey: "serverURL")
            if let name = pins.serviceName { defaults.set(name, forKey: "serverBonjourName") }
            if oldURL != verified.url {
                if oldURL.host != verified.url.host || oldURL.port != verified.url.port {
                    defaults.set(Date(), forKey: "serverAddressChangedAt")
                }
                tokens.removeToken(for: oldURL.absoluteString)
                tokens.removePins(for: oldURL.absoluteString)
            }
            ServerSessions.shared.reset()
            clearIdentityRetry()
            identityObserved = nil
            serverStatus = .reachable
            Telemetry.shared.record(.featureUsed(reverify ? "tls_reverified" : "tls_upgrade"))
            if !reverify { Telemetry.shared.record(.pairResult(method: "upgrade", error: nil)) }
        } catch {
            guard serverURL == oldURL, tokens.token(for: oldURL.absoluteString) == token else { return }
            if !reverify, !Self.isCancellation(error) { Telemetry.shared.record(.pairResult(method: "upgrade", error: error)) }
            switch error {
            case let failure as ServerPairing.IdentityFailure:
                identityObserved = failure.observed ?? identityObserved
                if let observed = failure.observed, previous?.pins.contains(observed) != true {
                    clearIdentityRetry()
                    serverStatus = .identityProblem("Can't confirm this is your server. Its changed security key failed the pairing proof.")
                } else {
                    serverStatus = .unreachable("The server's key check was interrupted. Checking again automatically.")
                    scheduleIdentityRetry()
                }
            case let failure as ServerPairing.UnrecognisedIdentity:
                identityObserved = failure.observed ?? identityObserved
                serverStatus = .unreachable("Looking for your paired server. This address couldn't confirm it.")
                scheduleIdentityRetry()
            case let failure as ServerClient.Failure where failure.status == 404:
                serverStatus = .unreachable("Looking for your paired server. This address couldn't confirm it.")
                scheduleIdentityRetry()
            case let failure as URLError where [.secureConnectionFailed, .serverCertificateUntrusted,
                                                 .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot].contains(failure.code):
                if previous != nil {
                    serverStatus = .unreachable("The encrypted connection was interrupted. Checking again automatically.")
                } else {
                    serverStatus = .needsServerUpdate("Update Homespun Server. This iPhone needs version 0.2 or later for encrypted connections.")
                }
                scheduleIdentityRetry()
            case _ where Self.isCancellation(error):
                serverStatus = before
            default:
                serverStatus = .unreachable("Can't reach the server for its key check. Checking again automatically.")
                scheduleIdentityRetry()
            }
        }
    }

    nonisolated static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        let error = error as NSError
        return error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled
    }
}
