// SPDX-License-Identifier: Apache-2.0
import Foundation
import HomespunCore
import Testing
@testable import Homespun

@MainActor @Suite(.serialized) struct AppSettingsTests {
    @Test func retryKeepsTheLastServerStatusUntilItConcludes() async throws {
        let name = "server-check-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let (settings, session) = try pairedSettings(defaults: defaults)
        defer { session.invalidateAndCancel() }
        let first = Task { await settings.refreshServerInfo() }
        try await pendingRequest()
        #expect(settings.serverStatus == .reachable)
        ServerCheckProtocol.fail()
        try await pendingRequest()
        #expect(settings.serverStatus == .reachable, "one failed check must not replace a known-good result")
        ServerCheckProtocol.fail()
        await first.value
        guard case .unreachable = settings.serverStatus else {
            Issue.record("the failed check wasn't reported")
            return
        }
        let unreachable = settings.serverStatus
        let checkedAt = settings.serverCheckedAt
        let retry = Task { await settings.refreshServerInfo() }
        try await pendingRequest()
        #expect(settings.serverStatus == unreachable, "retrying must not blink the accessory off")
        #expect(settings.serverCheckedAt == checkedAt)
        ServerCheckProtocol.fail()
        await retry.value
        #expect(settings.serverStatus == unreachable)
    }

    @Test(arguments: [false, true])
    func aSuccessfulConfirmationKeepsTheServerReachable(_ relaunch: Bool) async throws {
        let name = "server-retry-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let (settings, session) = try pairedSettings(defaults: defaults, relaunch: relaunch)
        defer { session.invalidateAndCancel() }
        for _ in 0..<2 {
            let check = Task { await settings.refreshServerInfo() }
            try await pendingRequest()
            ServerCheckProtocol.fail()
            try await pendingRequest()
            #expect(settings.serverStatus == (relaunch && settings.serverCheckedAt == nil ? .checking : .reachable))
            try ServerCheckProtocol.succeed()
            await check.value
            #expect(settings.serverStatus == .reachable)
        }
    }

    @Test func concurrentChecksShareTheSameConfirmation() async throws {
        let name = "server-concurrent-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let (settings, session) = try pairedSettings(defaults: defaults)
        defer { session.invalidateAndCancel() }
        let first = Task { await settings.refreshServerInfo() }
        try await pendingRequest()
        let second = Task { await settings.refreshServerInfo() }
        defer { first.cancel(); second.cancel() }
        try await Task.sleep(for: .milliseconds(50))
        try #require(ServerCheckProtocol.pending.count == 1)
        ServerCheckProtocol.fail()
        try await pendingRequest()
        #expect(settings.serverStatus == .reachable && ServerCheckProtocol.pending.count == 1)
        try ServerCheckProtocol.succeed()
        await first.value
        await second.value
        #expect(settings.serverStatus == .reachable && ServerCheckProtocol.pending.isEmpty)
    }

    @Test(arguments: [true, false])
    func aChangedInfoKeyRequiresProofWithoutBlinkingTheLastStatus(_ valid: Bool) async throws {
        actor Proof {
            var started = false
            private var continuation: CheckedContinuation<Void, Never>?
            func wait() async {
                started = true
                await withCheckedContinuation { continuation = $0 }
            }
            func finish() { continuation?.resume(); continuation = nil }
        }
        let name = "server-info-proof-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let proof = Proof(), changed = ServerKeyFingerprint(spki: Data("rotated key".utf8))
        let (settings, session) = try pairedSettings(defaults: defaults, verifyIdentity: { url, _ in
            await proof.wait()
            guard valid else { throw ServerPairing.IdentityFailure(observed: changed) }
            return .init(url: url, fingerprint: changed)
        })
        defer { session.invalidateAndCancel() }
        let check = Task { await settings.refreshServerInfo() }
        defer { check.cancel() }
        try await pendingRequest()
        var info = ServerCheckProtocol.info
        info.tls = .init(fingerprint: changed, notAfter: .distantFuture)
        try ServerCheckProtocol.succeed(info: info)
        for _ in 0..<500 {
            if await proof.started { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(await proof.started)
        #expect(settings.serverStatus == .reachable && settings.connectionProblem == nil)
        await proof.finish()
        await check.value
        if valid {
            #expect(settings.serverStatus == .reachable && settings.pins?.pins == [changed])
        } else {
            guard case .identityProblem = settings.serverStatus else {
                Issue.record("A failed proof must not become a reachability retry")
                return
            }
            #expect(settings.pins?.pins == [ServerCheckProtocol.key] && settings.nextIdentityRetry == nil)
            #expect(settings.connectionProblem != nil && !settings.canCompact)
        }
        #expect(ServerCheckProtocol.pending.isEmpty)
    }

    @Test func unpairingDuringACheckDoesNotRestoreTheConnection() async throws {
        let name = "server-check-unpair-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let (settings, session) = try pairedSettings(defaults: defaults)
        defer { session.invalidateAndCancel() }
        let check = Task { await settings.refreshServerInfo() }
        try await pendingRequest()
        settings.unpair()
        await check.value
        #expect(settings.serverURL == nil && settings.serverStatus == .unknown)
    }

    @Test func addressRecoveryKeepsTheLastStatusUntilInfoConcludes() async throws {
        let name = "server-recovery-status-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let moved = URL(string: "https://server.invalid:2443")!
        let (settings, session) = try pairedSettings(defaults: defaults,
            verifyIdentity: { _, _ in throw URLError(.timedOut) }, locateServer: { _, _, _ in
                .init(candidate: .init(url: moved, serviceName: "Home Server"), fingerprint: ServerCheckProtocol.key)
            })
        defer { session.invalidateAndCancel() }
        await settings.reverifyIdentity()
        let last = settings.serverStatus
        guard case .unreachable = last else { Issue.record("Expected a transient verification failure"); return }
        let client = try #require(settings.client)
        _ = await settings.followServerAddress(from: client.baseURL, token: client.token)
        #expect(settings.serverURL == moved && settings.serverStatus == last && settings.nextIdentityRetry == nil)
        let check = Task { await settings.refreshServerInfo() }
        defer { check.cancel() }
        try await pendingRequest()
        #expect(settings.serverStatus == last)
        try ServerCheckProtocol.succeed()
        await check.value
        #expect(settings.serverStatus == .reachable)
    }

    private func pairedSettings(defaults: UserDefaults, relaunch: Bool = false,
        verifyIdentity: (@Sendable (URL, String) async throws -> ServerPairing.Verified)? = nil,
        locateServer: @escaping ServerLocation.Finder = { _, _, _ in nil }
    ) throws -> (AppSettings, URLSession) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ServerCheckProtocol.self]
        let delegate = ServerTrustDelegate(policy: .pinned([ServerCheckProtocol.key]))
        #expect(delegate.evaluate(try serverTrustFixture()))
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let make = {
            AppSettings(defaults: defaults, tokens: DemoTokens(defaults: defaults), session: session,
                        verifyIdentity: verifyIdentity, locateServer: locateServer)
        }
        let settings = make()
        try settings.finishPairing(serverURL: URL(string: "https://server.invalid")!,
            response: .init(deviceID: "test-device", token: "test-token", server: ServerCheckProtocol.info),
            pins: .init(pins: [ServerCheckProtocol.key], source: "link"))
        return (relaunch ? make() : settings, session)
    }

    private func pendingRequest() async throws {
        for _ in 0..<500 {
            if !ServerCheckProtocol.pending.isEmpty { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw RequestDidNotStart()
    }

    private struct RequestDidNotStart: Error {}
}

private final class ServerCheckProtocol: URLProtocol, @unchecked Sendable {
    static let pending = Requests()
    static let key = ServerKeyFingerprint(base64url: "IlypPJ-wE200U-L1DoKMtMQyrDczNQMel-ae_YH5OgU")!
    static let info = ServerAPI.ServerInfo(name: "Home Server", version: "0.2.0", mode: .files, profile: .standard,
                                          tls: .init(fingerprint: key, notAfter: .distantFuture))

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.url?.path.hasSuffix("/health") == true {
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        } else {
            Self.pending.append(self)
        }
    }
    override func stopLoading() { Self.pending.remove(self) }

    static func fail() {
        let request = pending.take()
        if let request { request.client?.urlProtocol(request, didFailWithError: URLError(.cannotConnectToHost)) }
    }

    static func succeed(info: ServerAPI.ServerInfo = ServerCheckProtocol.info) throws {
        guard let request = pending.take(), let url = request.request.url else { return }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        request.client?.urlProtocol(request, didReceive: response, cacheStoragePolicy: .notAllowed)
        request.client?.urlProtocol(request, didLoad: try ServerAPI.encoder.encode(info))
        request.client?.urlProtocolDidFinishLoading(request)
    }

    final class Requests: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [ServerCheckProtocol] = []
        var isEmpty: Bool { lock.withLock { requests.isEmpty } }
        var count: Int { lock.withLock { requests.count } }

        func append(_ request: ServerCheckProtocol) { lock.withLock { requests.append(request) } }
        func remove(_ request: ServerCheckProtocol) { lock.withLock { requests.removeAll { $0 === request } } }
        func take() -> ServerCheckProtocol? { lock.withLock { requests.isEmpty ? nil : requests.removeFirst() } }
    }
}
