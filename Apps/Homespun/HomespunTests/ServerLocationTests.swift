// SPDX-License-Identifier: Apache-2.0
import Foundation
import HomespunCore
import os
import Testing
@testable import Homespun

private final class LocationProtocol: URLProtocol, @unchecked Sendable {
    struct State: Sendable {
        var oldURL: URL
        var newURL: URL
        var info: ServerAPI.ServerInfo
        var verified = false
        var earlyToken = false
        var oldStatus: Int?
        var oldFailure = URLError.Code.cannotConnectToHost
        var delegate: ServerTrustDelegate?
        var observePin = true
        var requests: [(URL, String?)] = []
    }
    static let state = OSAllocatedUnfairLock<State?>(initialState: nil)

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "address-fixture.local" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else { return }
        let value = Self.state.withLock { state -> State? in
            guard var current = state else { return nil }
            let token = request.value(forHTTPHeaderField: "Authorization")
            current.requests.append((url, token))
            if url.port == current.newURL.port, token != nil, !current.verified { current.earlyToken = true }
            state = current
            return current
        }
        guard let value else { return }
        if url.port == value.oldURL.port, value.oldStatus == nil {
            client?.urlProtocol(self, didFailWithError: URLError(value.oldFailure))
            return
        }
        let status = url.port == value.oldURL.port ? value.oldStatus! : 200
        let health = url.path.hasSuffix("/health")
        if health, value.observePin, value.delegate?.evaluate(try! serverTrustFixture()) == true {
            Self.state.withLock { $0?.verified = true }
        }
        let data = health ? try! ServerAPI.encoder.encode(ServerAPI.Health(tls: true))
            : status == 200 ? try! ServerAPI.encoder.encode(value.info)
            : try! ServerAPI.encoder.encode(ServerAPI.ErrorBody(error: .init(message: "Try later")))
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@MainActor @Suite(.serialized) struct ServerLocationTests {
    private let old = URL(string: "https://address-fixture.local:19001")!
    private let moved = URL(string: "https://address-fixture.local:19002")!
    private let key = ServerKeyFingerprint(base64url: "IlypPJ-wE200U-L1DoKMtMQyrDczNQMel-ae_YH5OgU")!

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LocationProtocol.self]
        let delegate = ServerTrustDelegate(policy: .pinned([key]))
        LocationProtocol.state.withLock { $0?.delegate = delegate }
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    private func info() -> ServerAPI.ServerInfo {
        .init(name: "Home Server", version: "0.2.0", mode: .files, profile: .standard,
              tls: .init(fingerprint: key, notAfter: .distantFuture))
    }

    @Test(arguments: [URLError.Code.cannotConnectToHost, .secureConnectionFailed])
    func aMatchingPinMovesCredentialsAndRetriesTheOriginalRequest(_ failure: URLError.Code) async throws {
        let name = "address-move-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let tokens = KeychainTokens()
        defer {
            for url in [old, moved] {
                tokens.removeToken(for: url.absoluteString)
                tokens.removePins(for: url.absoluteString)
            }
        }
        defaults.set(old, forKey: "serverURL")
        try tokens.setToken("paired token", for: old.absoluteString)
        let saved = ServerPins(pins: [key], source: "link", serviceName: "Home Server")
        try tokens.setPins(saved, for: old.absoluteString)
        let serverInfo = info()
        LocationProtocol.state.withLock { $0 = .init(oldURL: old, newURL: moved, info: serverInfo, oldFailure: failure) }
        defer { LocationProtocol.state.withLock { $0 = nil } }
        let session = session()
        defer { session.invalidateAndCancel() }
        let moved = moved, key = key
        let settings = AppSettings(defaults: defaults, tokens: tokens, session: session, locateServer: { service, pins, _ in
            #expect(service == "Home Server" && pins == [key])
            #expect(tokens.token(for: moved.absoluteString) == nil)
            LocationProtocol.state.withLock { $0?.verified = true }
            return .init(candidate: .init(url: moved, serviceName: "Home Server"), fingerprint: key)
        })
        let client = try #require(settings.client)
        #expect(try await client.info().name == "Home Server")
        #expect(settings.serverURL == moved && client.baseURL == moved)
        #expect(tokens.token(for: old.absoluteString) == nil && tokens.pins(for: old.absoluteString) == nil)
        #expect(tokens.token(for: moved.absoluteString) == "paired token" && tokens.pins(for: moved.absoluteString) == saved)
        #expect(settings.addressNotice == "Found Home Server at its new address")
        _ = try await client.info()
        let recorded = try #require(LocationProtocol.state.withLock { $0 })
        #expect(!recorded.earlyToken && recorded.requests.filter { $0.0.port == old.port }.count == 1)
        #expect(recorded.requests.filter { $0.0.port == moved.port && !$0.0.path.hasSuffix("/health") }
            .allSatisfy { $0.1 == "Bearer paired token" })
    }

    @Test func anUnmatchedPinCannotMoveOrReceiveTheToken() async throws {
        let name = "address-refused-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let tokens = LegacyPairingUpgradeTests.Tokens()
        defaults.set(old, forKey: "serverURL")
        try tokens.setToken("paired token", for: old.absoluteString)
        try tokens.setPins(ServerPins(pins: [key], source: "link"), for: old.absoluteString)
        let moved = moved
        let settings = AppSettings(defaults: defaults, tokens: tokens, locateServer: { _, _, _ in
            .init(candidate: .init(url: moved, serviceName: "Home Server"),
                  fingerprint: ServerKeyFingerprint(spki: Data("different key".utf8)))
        })
        #expect(await settings.followServerAddress(from: old, token: "paired token") == nil)
        #expect(settings.serverURL == old && tokens.token(for: old.absoluteString) == "paired token")
        #expect(tokens.token(for: moved.absoluteString) == nil && tokens.pins(for: moved.absoluteString) == nil)
    }

    @Test func anIdentityFailureAtTheOldAddressDoesNotBlockLaterPinnedRecovery() async throws {
        let name = "address-identity-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let tokens = LegacyPairingUpgradeTests.Tokens()
        defaults.set(old, forKey: "serverURL")
        try tokens.setToken("paired token", for: old.absoluteString)
        try tokens.setPins(ServerPins(pins: [key], source: "link"), for: old.absoluteString)
        let serverInfo = info(), moved = moved, key = key
        LocationProtocol.state.withLock { $0 = .init(oldURL: old, newURL: moved, info: serverInfo) }
        defer { LocationProtocol.state.withLock { $0 = nil } }
        let session = session()
        defer { session.invalidateAndCancel() }
        let settings = AppSettings(defaults: defaults, tokens: tokens, session: session, verifyIdentity: { _, _ in
            throw ServerPairing.IdentityFailure(observed: ServerKeyFingerprint(spki: Data("other server".utf8)))
        }, locateServer: { _, _, _ in
            LocationProtocol.state.withLock { $0?.verified = true }
            return .init(candidate: .init(url: moved, serviceName: "Home Server"), fingerprint: key)
        })
        await settings.reverifyIdentity()
        guard case .identityProblem = settings.serverStatus else { Issue.record("Expected an identity failure"); return }
        await settings.refreshServerInfo()
        #expect(settings.serverURL == moved && settings.serverStatus == .reachable)
        #expect(LocationProtocol.state.withLock { $0?.earlyToken } == false)
    }

    @Test func HTTPFailuresDoNotTriggerAddressDiscovery() async throws {
        actor Calls {
            var count = 0
            func record() { count += 1 }
        }
        let calls = Calls(), name = "address-http-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let tokens = LegacyPairingUpgradeTests.Tokens()
        defaults.set(old, forKey: "serverURL")
        try tokens.setToken("paired token", for: old.absoluteString)
        try tokens.setPins(ServerPins(pins: [key], source: "link"), for: old.absoluteString)
        let serverInfo = info()
        LocationProtocol.state.withLock { $0 = .init(oldURL: old, newURL: moved, info: serverInfo, oldStatus: 503) }
        defer { LocationProtocol.state.withLock { $0 = nil } }
        let session = session()
        defer { session.invalidateAndCancel() }
        let settings = AppSettings(defaults: defaults, tokens: tokens, session: session, locateServer: { _, _, _ in
            await calls.record()
            return nil
        })
        do {
            _ = try await settings.client?.info()
            Issue.record("Expected an HTTP failure")
        } catch let failure as ServerClient.Failure { #expect(failure.status == 503) }
        #expect(await calls.count == 0)
    }

    @Test func discoveryIsLimitedToOncePerMinute() async throws {
        actor Calls {
            var count = 0
            func record() { count += 1 }
        }
        let calls = Calls(), name = "address-rate-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let tokens = LegacyPairingUpgradeTests.Tokens()
        defaults.set(old, forKey: "serverURL")
        try tokens.setToken("paired token", for: old.absoluteString)
        try tokens.setPins(ServerPins(pins: [key], source: "link"), for: old.absoluteString)
        let settings = AppSettings(defaults: defaults, tokens: tokens, locateServer: { _, _, _ in
            await calls.record()
            return nil
        })
        _ = await settings.followServerAddress(from: old, token: "paired token")
        _ = await settings.followServerAddress(from: old, token: "paired token")
        #expect(await calls.count == 1)
    }

    @Test func namesAndTXTHintsOnlyOrderCandidatesThePinDecides() async throws {
        let preferred = ServerLocation.Candidate(url: URL(string: "https://address-fixture.local:19003")!,
                                                 serviceName: "Home Server", fingerprintHint: key)
        let genuine = ServerLocation.Candidate(url: moved, serviceName: "Renamed Server")
        let key = key
        let found = try await ServerLocation.find(in: [genuine, preferred], name: "Home Server", pins: [key], excluding: old) { url, _ in
            url == preferred.url ? ServerKeyFingerprint(spki: Data("imposter".utf8)) : key
        }
        #expect(found?.candidate == genuine)
    }

    @Test func aResumedSessionWithoutAPinObservationNeverSendsTheToken() async throws {
        let serverInfo = info()
        LocationProtocol.state.withLock {
            $0 = .init(oldURL: moved, newURL: moved, info: serverInfo, oldStatus: 200, observePin: false)
        }
        defer { LocationProtocol.state.withLock { $0 = nil } }
        let session = session()
        defer { session.invalidateAndCancel() }
        let client = ServerClient(baseURL: moved, token: "paired token", trust: .pinned([key]), session: session)
        do {
            _ = try await client.info()
            Issue.record("A session without a pinned challenge sent a token")
        } catch let error as URLError { #expect(error.code == .secureConnectionFailed) }
        let requests = try #require(LocationProtocol.state.withLock { $0?.requests })
        #expect(requests.count == 1 && requests[0].0.path.hasSuffix("/health") && requests[0].1 == nil)
    }

    @Test func concurrentTokenRequestsShareOnePinProbeForTheSessionLifetime() async throws {
        let serverInfo = info()
        LocationProtocol.state.withLock { $0 = .init(oldURL: moved, newURL: moved, info: serverInfo, oldStatus: 200) }
        defer { LocationProtocol.state.withLock { $0 = nil } }
        let session = session()
        defer { session.invalidateAndCancel() }
        let client = ServerClient(baseURL: moved, token: "paired token", trust: .pinned([key]), session: session)
        async let first = client.info()
        async let second = client.info()
        _ = try await (first, second)
        _ = try await client.info()
        let state = try #require(LocationProtocol.state.withLock { $0 })
        #expect(!state.earlyToken && state.requests.filter { $0.0.path.hasSuffix("/health") }.count == 1)
        #expect(state.requests.filter { $0.1 != nil }.count == 3)
    }

    @Test func identityEventsDoNotDisableSessionCaching() {
        let url = URL(string: "https://session-fixture.local:19005")!
        defer { ServerSessions.shared.reset(url) }
        ServerSessions.shared.markSuspect(url)
        let first = ServerSessions.shared.session(for: url, trust: .pinned([key]))
        let second = ServerSessions.shared.session(for: url, trust: .pinned([key]))
        #expect(first.0 === second.0 && first.1 === second.1)
    }
}
