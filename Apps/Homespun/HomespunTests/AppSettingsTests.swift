// SPDX-License-Identifier: Apache-2.0
import Foundation
import HomespunCore
import Security
import Testing
@testable import Homespun

@MainActor @Suite(.serialized) struct AppSettingsTests {
    @Test func workspaceConfigurationRejectsCoercionInsteadOfUsingMeasuredDefaults() {
        let invalid: [Any] = [
            NSNumber(value: true), NSNumber(value: false), NSNumber(value: 1.5), NSNumber(value: Float(-2.5)),
            NSNumber(value: Double.leastNonzeroMagnitude), NSNumber(value: Double(1).nextUp), NSNumber(value: Double.nan),
            NSNumber(value: Double.infinity), NSNumber(value: -Double.infinity),
            NSNumber(value: Double(Int64.max)), NSNumber(value: Double(Int64.min).nextDown),
            NSNumber(value: UInt64.max), NSDecimalNumber.notANumber, NSDecimalNumber(string: "9223372036854775808"),
            NSDecimalNumber(string: "-9223372036854775809"), NSDecimalNumber(string: "9007199254740992.5"),
            "3",
        ]
        for key in ["backupWorkspaceBytes", "backupMinimumAvailableBytes", "backupFinalizationReserveBytes", "backupMaximumTransfers"] {
            for value in invalid {
                #expect(throws: BackupSpaceFailure.invalidPolicy) {
                    try AppSettings.backupSpacePolicy(available: 8_192, configuredValue: { $0 == key ? value : nil })
                }
            }
        }
    }

    @Test func workspaceConfigurationPreservesExactIntegersAndDefaultsOnlyForAbsentValues() throws {
        let available: Int64 = 8_192
        let derived = try AppSettings.backupSpacePolicy(available: available, configuredValue: { _ in nil })
        #expect(derived.maximumTransientBytes == available / 4)
        #expect(derived.minimumAvailableBytes == available / 8)
        #expect(derived.finalizationReserveBytes == derived.maximumTransientBytes / 4)
        let values: [String: NSNumber] = [
            "backupWorkspaceBytes": NSNumber(value: Int64.max),
            "backupMinimumAvailableBytes": NSNumber(value: Double(0)),
            "backupFinalizationReserveBytes": NSNumber(value: Float(0)),
            "backupMaximumTransfers": NSNumber(value: Double(3)),
        ]
        let configured = try AppSettings.backupSpacePolicy(available: available, configuredValue: { values[$0] })
        #expect(configured.maximumTransientBytes == Int64.max && configured.minimumAvailableBytes == 0)
        #expect(configured.finalizationReserveBytes == 0 && configured.maximumTransfers == 3)
        let decimal = try AppSettings.backupSpacePolicy(available: available, configuredValue: {
            $0 == "backupWorkspaceBytes" ? NSDecimalNumber(string: "9223372036854775807") : nil
        })
        #expect(decimal.maximumTransientBytes == Int64.max)
        #expect(throws: BackupSpaceFailure.invalidPolicy) {
            try AppSettings.backupSpacePolicy(available: available, configuredValue: {
                $0 == "backupMaximumTransfers" ? NSNumber(value: 129) : nil
            })
        }
    }

    @Test(arguments: [errSecSuccess, errSecItemNotFound])
    func legacyReviewCodeCleanupRunsOnlyOnce(_ status: OSStatus) {
        let name = "keychain-cleanup-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        var deletions = 0
        let delete: ([CFString: Any]) -> OSStatus = { query in
            deletions += 1
            #expect(query[kSecClass] as? String == kSecClassGenericPassword as String)
            #expect(query[kSecAttrService] as? String == "photos.homespun.demo-review-code")
            #expect(query[kSecAttrAccount] as? String == "review")
            #expect(query[kSecAttrSynchronizable] as? Bool == false)
            #expect(query.count == 4, "cleanup must target only the retired review credential")
            return status
        }
        Keychain.removeLegacyReviewCode(defaults: defaults, delete: delete)
        Keychain.removeLegacyReviewCode(defaults: defaults, delete: delete)
        #expect(deletions == 1)
    }

    @Test func legacyReviewCodeCleanupRetriesAfterKeychainFailure() {
        let name = "keychain-cleanup-retry-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        var deletions = 0
        let delete: ([CFString: Any]) -> OSStatus = { _ in
            deletions += 1
            return deletions == 1 ? errSecInteractionNotAllowed : errSecSuccess
        }
        for _ in 0..<3 {
            Keychain.removeLegacyReviewCode(defaults: defaults, delete: delete)
        }
        #expect(deletions == 2)
    }

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
