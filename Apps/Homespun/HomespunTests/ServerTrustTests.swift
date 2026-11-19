// SPDX-License-Identifier: Apache-2.0
import Foundation
import HomespunCore
import Security
import Testing
@testable import Homespun

func serverTrustFixture() throws -> SecTrust {
    let bytes = Data(base64Encoded: """
        MIIBpjCCAUugAwIBAgIUbiMnX4ZhPz9mj7u4KdIJPiuw3UEwCgYIKoZIzj0EAwIwGjEYMBYGA1UEAwwPSG9tZXNwdW4gU2VydmVyMB4XDTI2MTExODE3MjYxN1oXDTI5MDIyMDE3MjYxN1owGjEYMBYGA1UEAwwPSG9tZXNwdW4gU2VydmVyMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEFzpgvUqCIGzM0ofHMz7//5xDTR27yZg7m1aEXyNs7y9f3BxneuJr2j3ggBPzPtw5TI17dhyg6OlXgkRuIVm2yqNvMG0wHQYDVR0OBBYEFB1PUhJ9H/TN71UckiRJ3nk0gU8mMB8GA1UdIwQYMBaAFB1PUhJ9H/TN71UckiRJ3nk0gU8mMA8GA1UdEwEB/wQFMAMBAf8wGgYDVR0RBBMwEYIJbG9jYWxob3N0hwR/AAABMAoGCCqGSM49BAMCA0kAMEYCIQDBjU4YMPr/j8goHVKxv0R3r9FlbuGmxp9/TWZ2RB0CggIhAMf9aUieCOqjtvud/ZSy5zSmMpb+3Jb5KHWTeplJ35Ab
        """)!
    let certificate = try #require(SecCertificateCreateWithData(nil, bytes as CFData))
    var trust: SecTrust?
    #expect(SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(true, nil), &trust) == errSecSuccess)
    return try #require(trust)
}

@Test func fingerprintOfFixtureCertificateMatchesTheServer() throws {
    #expect(ServerKey.fingerprint(of: try serverTrustFixture())?.base64url == "IlypPJ-wE200U-L1DoKMtMQyrDczNQMel-ae_YH5OgU")
}

@Test func serverTrustDecisionsFailClosed() {
    let key = ServerKeyFingerprint(spki: Data("key".utf8)), other = ServerKeyFingerprint(spki: Data("other".utf8))
    #expect(ServerTrustDelegate.accepts(policy: .pinned([key]), seen: key, observed: nil))
    #expect(!ServerTrustDelegate.accepts(policy: .pinned([key]), seen: other, observed: key))
    #expect(!ServerTrustDelegate.accepts(policy: .pinned([key]), seen: nil, observed: nil))
    #expect(ServerTrustDelegate.accepts(policy: .capture(expected: nil), seen: key, observed: nil))
    #expect(!ServerTrustDelegate.accepts(policy: .capture(expected: nil), seen: other, observed: key))
    #expect(!ServerTrustDelegate.accepts(policy: .capture(expected: key), seen: other, observed: nil))
    let certificate = Data("trusted RSA certificate".utf8), changed = Data("changed certificate".utf8)
    #expect(ServerTrustDelegate.accepts(policy: .capture(expected: nil), seen: nil, observed: nil, trustedCertificate: certificate))
    #expect(!ServerTrustDelegate.accepts(policy: .capture(expected: nil), seen: nil, observed: nil,
                                         capturedCertificate: certificate, trustedCertificate: changed))
    #expect(!ServerTrustDelegate.accepts(policy: .capture(expected: nil), seen: key, observed: nil,
                                         capturedCertificate: certificate))
    #expect(!ServerTrustDelegate.accepts(policy: .capture(expected: nil), seen: nil, observed: key,
                                         trustedCertificate: certificate))
    #expect(!ServerTrustDelegate.accepts(policy: .pinned([key]), seen: nil, observed: nil, trustedCertificate: certificate))
    #expect(!ServerTrustDelegate.accepts(policy: .capture(expected: key), seen: nil, observed: nil, trustedCertificate: certificate))
}

@Test func rsaCertificatesCannotBecomeServerPins() throws {
    let bytes = Data(base64Encoded: """
        MIIDITCCAgmgAwIBAgIUMwQR/CuFXWDS/uvIfLLDecXv6rMwDQYJKoZIhvcNAQELBQAwIDEeMBwGA1UEAwwVSG9tZXNwdW4gVGVzdCBGaXh0dXJlMB4XDTI2MTExODE3Mzc0OVoXDTI5MDIyMDE3Mzc0OVowIDEeMBwGA1UEAwwVSG9tZXNwdW4gVGVzdCBGaXh0dXJlMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAiZBjpU1fP5+k06k+qXvr6Gc7p0Fcwba4qmJmLl6OgbKI3lxn+iPkJqGK2ef95v4FKrwRJ1l0meijOpMqLgEhwc5U3IstDNnx7vpNIah/T/zENn+mwST5qT2VeJsp3cAxW4mu9G/BsLIQw2i7tf+2kBffTraXJ6IZE/JRhbXQColX+86BDXxoiK8y/Hh4hY6XGVWLFR4+12A5X1vmCPO8pwuaN1u7TxvWw5cuBIEl3vebWLHBzowGcZBCDpp4kxo5HCVokV3ZqPEB70xGx1U6bm9c7NrhLctEQGDS55CTY3y6nkNEAwFICXwkrVXw4zjQnFAOBWwIpYsSrbg7NjohJwIDAQABo1MwUTAdBgNVHQ4EFgQUkNR3uUKTxHbiDIBw6tSyDhULtLkwHwYDVR0jBBgwFoAUkNR3uUKTxHbiDIBw6tSyDhULtLkwDwYDVR0TAQH/BAUwAwEB/zANBgkqhkiG9w0BAQsFAAOCAQEATyYrz3Ia3zPsJJSZOu+YYojOso7GoCZb8z2QVZlxrVDLjCx1dQBl3wP0QIwEnjZg9ykrY/U3SspJp5OP5cRB4sjkfg1j12Cw+RGRaxvy5PK6Lo6iB1uoYU+03otLN/5V7QGjy3CyggfQyAdvA1DhF1vJNoYS0tFWiMgVrO9Es/NZDVnRnsGi24WMHfjGZkQ34H5kB90iqZe5iRK6CNMFedyvGWNEAihMK+QvWWrTQPmouuj5CWp//3AI6FdHxglYvwtL4TF61SSeNvzmz6CB83d5BCFMN31ZDi4B4zJKET6vFXRVEJ70dh2hDuM25ePcjT7AW6I8h+bLc7uodmORGw==
        """)!
    let certificate = try #require(SecCertificateCreateWithData(nil, bytes as CFData))
    #expect(ServerKey.fingerprint(of: certificate) == nil)
}

@Test func serverClientRefusesPlainHTTPBeforeSendingAnything() async throws {
    let client = ServerClient(baseURL: URL(string: "http://192.168.1.20:8787")!, token: "never send this", trust: .system)
    do {
        _ = try await client.info()
        Issue.record("Plain HTTP was accepted")
    } catch let failure as ServerClient.Failure {
        #expect(failure.code == "insecure")
    }
}

@MainActor @Test func identityMismatchesAreNotCancellationsAndNeverReportTheKey() {
    let fingerprint = ServerKeyFingerprint(spki: Data("a server key".utf8))
    let error = ServerClient.IdentityMismatch(observed: fingerprint)
    #expect(!AppSettings.isCancellation(error))
    #expect(Telemetry.Event.code(error) == "tls_identity")
    #expect(Telemetry.Event.code(ServerPairing.IdentityFailure(observed: fingerprint)) == "tls_identity")
}

@Test func proxyUpgradesNeedBothSystemTrustAndTheBackendTokenProof() {
    let proxy = ServerKeyFingerprint(spki: Data("proxy key".utf8))
    let backend = ServerKeyFingerprint(spki: Data("backend key".utf8))
    let hash = PairingCrypto.tokenHash("pairing token"), nonce = PairingCrypto.nonce()
    let proof = ServerAPI.IdentityProof(fingerprint: backend,
        proof: PairingCrypto.encode(PairingCrypto.verifyProof(tokenHash: hash, nonce: nonce, fingerprint: backend)),
        notAfter: .distantFuture)
    #expect(!ServerPairing.validIdentityProof(proof, observed: proxy, tokenHash: hash, nonce: nonce))
    #expect(ServerPairing.validIdentityProof(proof, observed: proxy, tokenHash: hash, nonce: nonce, systemTrusted: true))
    #expect(ServerPairing.validIdentityProof(proof, observed: nil, tokenHash: hash, nonce: nonce, systemTrusted: true))
    #expect(!ServerPairing.validIdentityProof(proof, observed: nil, tokenHash: hash, nonce: nonce))
    #expect(!ServerPairing.validIdentityProof(proof, observed: proxy, tokenHash: hash,
                                             nonce: PairingCrypto.nonce(), systemTrusted: true))
    #expect(!ServerPairing.validIdentityProof(proof, observed: proxy, tokenHash: PairingCrypto.tokenHash("wrong token"),
                                             nonce: nonce, systemTrusted: true))
    var changed = proof
    changed.fingerprint = proxy
    #expect(!ServerPairing.validIdentityProof(changed, observed: proxy, tokenHash: hash, nonce: nonce, systemTrusted: true))
}

@Test func unreadableKeychainPinsRemainARecordRatherThanALegacyPairing() {
    let account = "tls-pin-fixture-\(UUID().uuidString)"
    defer { Keychain.removePins(for: account) }
    let item: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
        kSecAttrService: "photos.homespun.server-pins", kSecAttrAccount: account,
        kSecValueData: Data("unreadable pins".utf8),
        kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
    #expect(SecItemAdd(item as CFDictionary, nil) == errSecSuccess)
    #expect(Keychain.pins(for: account) == nil && Keychain.hasPinRecord(for: account))
    Keychain.removePins(for: account)
    #expect(!Keychain.hasPinRecord(for: account))
}

@MainActor @Test func installationIdentitySurvivesUnpair() throws {
    let first = try KeychainInstallation().load()
    let name = "installation-unpair-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { UserDefaults.standard.removePersistentDomain(forName: name) }
    let settings = AppSettings(defaults: defaults, tokens: LegacyPairingUpgradeTests.Tokens())
    settings.unpair()
    let returning = AppSettings(defaults: defaults, tokens: LegacyPairingUpgradeTests.Tokens())
    #expect(try returning.pairingIdentity().id == first.id)
    #expect(try KeychainInstallation().load().id == first.id)
}

@MainActor @Suite struct LegacyPairingUpgradeTests {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date(timeIntervalSince1970: 1_000_000)
        var now: Date { lock.withLock { value } }
        func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
    }

    final class Tokens: TokenStore, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: String] = [:]
        private var fingerprints: [String: ServerPins] = [:]
        private var malformed: Set<String> = []
        func token(for server: String) -> String? { lock.withLock { values[server] } }
        func setToken(_ token: String, for server: String) throws { lock.withLock { values[server] = token } }
        func removeToken(for server: String) { lock.withLock { values[server] = nil } }
        func pins(for server: String) -> ServerPins? { lock.withLock { fingerprints[server] } }
        func setPins(_ pins: ServerPins, for server: String) throws {
            lock.withLock { fingerprints[server] = pins; _ = malformed.remove(server) }
        }
        func removePins(for server: String) {
            lock.withLock { fingerprints[server] = nil; _ = malformed.remove(server) }
        }
        func hasPinRecord(for server: String) -> Bool { lock.withLock { fingerprints[server] != nil || malformed.contains(server) } }
        func corruptPins(for server: String) { lock.withLock { fingerprints[server] = nil; _ = malformed.insert(server) } }
    }
    private let old = URL(string: "http://192.168.1.20:8787")!
    private let secure = URL(string: "https://192.168.1.20:8787")!
    private let fingerprint = ServerKeyFingerprint(spki: Data("verified key".utf8))

    @Test func existingTrustedHTTPSProxyKeepsSystemTrustAfterVerification() async throws {
        let name = "tls-proxy-\(UUID().uuidString)", tokens = Tokens()
        let defaults = UserDefaults(suiteName: name)!
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        defaults.set(secure, forKey: "serverURL")
        try tokens.setToken("pairing token", for: secure.absoluteString)
        let secure = secure, fingerprint = fingerprint
        let settings = AppSettings(defaults: defaults, tokens: tokens, verifyIdentity: { _, _ in
            .init(url: secure, fingerprint: fingerprint, systemTrusted: true)
        })
        await settings.secureLegacyPairing()
        #expect(settings.pins?.pins.isEmpty == true && settings.client?.trust == .system)
    }

    @Test func anExistingPinCannotBeReplacedWithSystemTrust() async throws {
        let name = "tls-pin-policy-\(UUID().uuidString)", tokens = Tokens()
        let defaults = UserDefaults(suiteName: name)!
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        defaults.set(secure, forKey: "serverURL")
        try tokens.setToken("pairing token", for: secure.absoluteString)
        try tokens.setPins(ServerPins(pins: [fingerprint], source: "link"), for: secure.absoluteString)
        let secure = secure, fingerprint = fingerprint
        let settings = AppSettings(defaults: defaults, tokens: tokens, verifyIdentity: { _, _ in
            .init(url: secure, fingerprint: fingerprint, systemTrusted: true)
        })
        await settings.reverifyIdentity()
        #expect(settings.pins?.pins == [fingerprint])
        #expect(settings.client?.trust == .pinned([fingerprint]))
        #expect(settings.nextIdentityRetry != nil)
    }

    @Test func anUnreadablePinRecordIsNotAnUnpinnedLegacyPairing() async throws {
        let name = "tls-unreadable-pins-\(UUID().uuidString)", tokens = Tokens()
        let defaults = UserDefaults(suiteName: name)!
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        defaults.set(secure, forKey: "serverURL")
        try tokens.setToken("pairing token", for: secure.absoluteString)
        tokens.corruptPins(for: secure.absoluteString)
        let secure = secure, fingerprint = fingerprint
        let settings = AppSettings(defaults: defaults, tokens: tokens, verifyIdentity: { _, _ in
            .init(url: secure, fingerprint: fingerprint, systemTrusted: true)
        })
        await settings.secureLegacyPairing()
        #expect(tokens.pins(for: secure.absoluteString) == nil)
        guard case .identityProblem = settings.serverStatus else { Issue.record("An unreadable pin record was weakened"); return }
    }

    @Test func simultaneousForegroundRefreshesWaitForTheSameUpgrade() async throws {
        actor Attempts {
            var count = 0
            func record() { count += 1 }
        }
        let name = "tls-concurrent-\(UUID().uuidString)", tokens = Tokens(), attempts = Attempts()
        let defaults = UserDefaults(suiteName: name)!
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        defaults.set(old, forKey: "serverURL")
        try tokens.setToken("pairing token", for: old.absoluteString)
        let secure = secure, fingerprint = fingerprint
        let settings = AppSettings(defaults: defaults, tokens: tokens, verifyIdentity: { _, _ in
            await attempts.record()
            try await Task.sleep(for: .milliseconds(50))
            return .init(url: secure, fingerprint: fingerprint)
        })
        let first = Task { await settings.secureLegacyPairing() }
        let second = Task { await settings.secureLegacyPairing() }
        await first.value
        await second.value
        let count = await attempts.count
        #expect(count == 1 && settings.serverURL == secure && settings.serverStatus == .reachable)
    }

    @Test func unpairingDuringVerificationDoesNotRestoreTheOldPairingOrItsError() async throws {
        let name = "tls-cancelled-\(UUID().uuidString)", tokens = Tokens()
        let defaults = UserDefaults(suiteName: name)!
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        defaults.set(old, forKey: "serverURL")
        try tokens.setToken("pairing token", for: old.absoluteString)
        let settings = AppSettings(defaults: defaults, tokens: tokens, verifyIdentity: { _, _ in
            try await Task.sleep(for: .seconds(10))
            throw ServerPairing.IdentityFailure()
        })
        let work = Task { await settings.secureLegacyPairing() }
        while settings.serverStatus != .securing { await Task.yield() }
        settings.unpair()
        await work.value
        #expect(settings.serverURL == nil && settings.serverStatus == .unknown)
    }

    @Test func upgradeMovesPinsAndTokenBeforeRemovingTheOldAccount() async throws {
        let name = "tls-upgrade-\(UUID().uuidString)", tokens = Tokens()
        let defaults = UserDefaults(suiteName: name)!
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        defaults.set(old, forKey: "serverURL")
        try tokens.setToken("pairing token", for: old.absoluteString)
        let secure = secure, fingerprint = fingerprint
        let settings = AppSettings(defaults: defaults, tokens: tokens, verifyIdentity: { url, token in
            #expect(url.scheme == "http" && token == "pairing token")
            return .init(url: secure, fingerprint: fingerprint)
        })
        if case .blocked? = settings.client?.trust {} else { Issue.record("A legacy pairing was not blocked") }
        await settings.secureLegacyPairing()
        #expect(settings.serverURL == secure && settings.pins?.pins == [fingerprint])
        #expect(tokens.token(for: old.absoluteString) == nil && tokens.token(for: secure.absoluteString) == "pairing token")
    }

    @Test func interruptedUpgradeFinishesFromTheNewKeychainAccount() async throws {
        let name = "tls-recovery-\(UUID().uuidString)", tokens = Tokens()
        let defaults = UserDefaults(suiteName: name)!
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        defaults.set(old, forKey: "serverURL")
        try tokens.setToken("pairing token", for: old.absoluteString)
        try tokens.setToken("pairing token", for: secure.absoluteString)
        try tokens.setPins(ServerPins(pins: [fingerprint], source: "upgrade"), for: secure.absoluteString)
        let settings = AppSettings(defaults: defaults, tokens: tokens, verifyIdentity: { _, _ in
            Issue.record("A verified, interrupted upgrade was needlessly repeated")
            throw ServerPairing.IdentityFailure()
        })
        await settings.secureLegacyPairing()
        #expect(settings.serverURL == secure && tokens.token(for: old.absoluteString) == nil)
    }

    @Test func badProofBlocksThePairingAndRetainsItsToken() async throws {
        let name = "tls-failed-\(UUID().uuidString)", tokens = Tokens()
        let defaults = UserDefaults(suiteName: name)!
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        defaults.set(old, forKey: "serverURL")
        try tokens.setToken("pairing token", for: old.absoluteString)
        let fingerprint = fingerprint
        let settings = AppSettings(defaults: defaults, tokens: tokens, verifyIdentity: { _, _ in
            throw ServerPairing.IdentityFailure(observed: fingerprint)
        })
        await settings.secureLegacyPairing()
        guard case .identityProblem = settings.serverStatus else { Issue.record("A bad proof didn't block the pairing"); return }
        #expect(tokens.token(for: old.absoluteString) == "pairing token" && tokens.pins(for: secure.absoluteString) == nil)
        do {
            _ = try await settings.client?.info()
            Issue.record("The blocked client sent a request")
        } catch let failure as ServerClient.Failure { #expect(failure.code == "tls_blocked") }
    }

    @Test(arguments: [0, 1, 2, 3, 4])
    func transientReverificationKeepsThePinnedPairingUsableAndRetriesAutomatically(_ failure: Int) async throws {
        actor Attempts {
            var count = 0
            func next() -> Int { count += 1; return count }
        }
        let name = "tls-transient-\(UUID().uuidString)", defaults = UserDefaults(suiteName: name)!, tokens = Tokens()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        defaults.set(secure, forKey: "serverURL")
        defaults.set(try ServerAPI.encoder.encode(ServerAPI.ServerInfo(name: "Home Server", version: "0.2",
            mode: .files, profile: .standard)), forKey: "serverInfo")
        try tokens.setToken("pairing token", for: secure.absoluteString)
        try tokens.setPins(ServerPins(pins: [fingerprint], source: "link"), for: secure.absoluteString)
        let attempts = Attempts(), secure = secure, updated = ServerKeyFingerprint(spki: Data("updated key".utf8))
        let settings = AppSettings(defaults: defaults, tokens: tokens, verifyIdentity: { _, _ in
            if await attempts.next() == 1 {
                switch failure {
                case 0: throw URLError(.timedOut)
                case 1: throw ServerClient.Failure(status: 429, message: "Try later")
                case 2: throw ServerClient.Failure(status: 503, message: "Try later")
                case 3: throw URLError(.secureConnectionFailed)
                default: throw ServerPairing.UnrecognisedIdentity(observed: updated)
                }
            }
            return .init(url: secure, fingerprint: updated)
        }, identityRetryBaseDelay: 0.03)
        await settings.reverifyIdentity()
        guard case .unreachable = settings.serverStatus else { Issue.record("A transient check blocked the pairing"); return }
        #expect(settings.canCompact && settings.connectionProblem == nil && settings.pins?.pins == [fingerprint])
        #expect(settings.nextIdentityRetry != nil)
        let deadline = Date().addingTimeInterval(5)
        while settings.serverStatus != .reachable, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(settings.serverStatus == .reachable && settings.pins?.pins == [updated])
        #expect(await attempts.count == 2 && settings.nextIdentityRetry == nil)
        #expect(tokens.token(for: secure.absoluteString) == "pairing token")
    }

    @Test func activationAndBackgroundPreparationRetryWithCappedBackoff() async throws {
        actor Attempts {
            var count = 0
            func next() -> Int { count += 1; return count }
        }
        let name = "tls-backoff-\(UUID().uuidString)", defaults = UserDefaults(suiteName: name)!, tokens = Tokens()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        defaults.set(secure, forKey: "serverURL")
        try tokens.setToken("pairing token", for: secure.absoluteString)
        try tokens.setPins(ServerPins(pins: [fingerprint], source: "link"), for: secure.absoluteString)
        let attempts = Attempts(), clock = Clock(), secure = secure, fingerprint = fingerprint
        let settings = AppSettings(defaults: defaults, tokens: tokens, verifyIdentity: { _, _ in
            if await attempts.next() <= 6 { throw ServerClient.Failure(status: 429, message: "Try later") }
            return .init(url: secure, fingerprint: fingerprint)
        }, identityNow: { clock.now })
        await settings.reverifyIdentity()
        #expect(settings.nextIdentityRetry?.timeIntervalSince(clock.now) == 60)
        clock.advance(61)
        await settings.secureLegacyPairing()
        #expect(settings.nextIdentityRetry?.timeIntervalSince(clock.now) == 120)
        clock.advance(61)
        await settings.secureLegacyPairing()
        #expect(await attempts.count == 3 && settings.nextIdentityRetry?.timeIntervalSince(clock.now) == 240)
        for expected in [480.0, 900, 900] {
            clock.advance(901)
            await settings.reverifyIdentity()
            #expect(settings.nextIdentityRetry?.timeIntervalSince(clock.now) == expected)
        }
        clock.advance(901)
        await settings.secureLegacyPairing()
        #expect(settings.serverStatus == .reachable && settings.nextIdentityRetry == nil)
    }

    @Test func aChangedKeyWithAnInvalidProofBlocksWithoutAutomaticTrustOrRetry() async throws {
        let name = "tls-real-proof-\(UUID().uuidString)", defaults = UserDefaults(suiteName: name)!, tokens = Tokens()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        defaults.set(secure, forKey: "serverURL")
        try tokens.setToken("pairing token", for: secure.absoluteString)
        try tokens.setPins(ServerPins(pins: [fingerprint], source: "link"), for: secure.absoluteString)
        let settings = AppSettings(defaults: defaults, tokens: tokens, verifyIdentity: { _, _ in
            throw ServerPairing.IdentityFailure(observed: ServerKeyFingerprint(spki: Data("unverified key".utf8)))
        }, identityRetryBaseDelay: 0.01)
        await settings.reverifyIdentity()
        guard case .identityProblem = settings.serverStatus else { Issue.record("A bad proof was trusted"); return }
        #expect(settings.pins?.pins == [fingerprint] && settings.nextIdentityRetry == nil && !settings.canCompact)
    }
}
