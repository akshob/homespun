// SPDX-License-Identifier: AGPL-3.0-only
import AsyncHTTPClient
import Crypto
import Foundation
import HomespunCore
import Hummingbird
import HummingbirdTesting
import NIOSSL
import NIOPosix
import Testing
import X509
@testable import HomespunServerKit

@Test func tlsIdentityIsCreatedOnceAndKeptPrivate() async throws {
    let data = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: data) }
    let fingerprints = try await withThrowingTaskGroup(of: ServerKeyFingerprint.self) { group in
        for _ in 0..<2 { group.addTask { try TLSStore.loadOrCreate(data: data).0.fingerprint } }
        var result: [ServerKeyFingerprint] = []
        for try await fingerprint in group { result.append(fingerprint) }
        return result
    }
    #expect(Set(fingerprints).count == 1)
    let (identity, created) = try TLSStore.loadOrCreate(data: data)
    #expect(!created && identity.fingerprint == fingerprints.first)
    for (url, mode) in [(TLSStore.folder(data), 0o700), (TLSStore.identityFile(data), 0o600),
                         (TLSStore.certificateFile(data), 0o644)] {
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int == mode)
    }
    let certificate = try Certificate(derEncoded: identity.certificateDER)
    #expect(try certificate.extensions.subjectAlternativeNames?.contains {
        if case .ipAddress(let value) = $0 { return Array(value.bytes) == [127, 0, 0, 1] }
        return false
    } == true)
}

@Test func tlsIdentityRenewsAndRotationKeepsThePreviousKey() throws {
    let data = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: data) }
    let original = try TLSStore.loadOrCreate(data: data).0
    let renewed = try TLSStore.renew(data: data, now: Date().addingTimeInterval(86400))
    #expect(renewed.fingerprint == original.fingerprint && renewed.notAfter > original.notAfter)
    let oldPEM = try Data(contentsOf: TLSStore.identityFile(data))
    let replaced = try TLSStore.replaceKey(data: data)
    #expect(replaced.fingerprint != original.fingerprint)
    let backup = try #require(FileManager.default.contentsOfDirectory(at: TLSStore.folder(data),
                                                                     includingPropertiesForKeys: nil)
        .first { $0.lastPathComponent.hasPrefix("previous-") })
    #expect(try Data(contentsOf: backup) == oldPEM)
    #expect(try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? Int == 0o600)
}

@Test func unreadableIdentityStopsTheServerWithAHint() async throws {
    let data = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: data) }
    _ = try TLSStore.loadOrCreate(data: data)
    try Data("broken identity".utf8).write(to: TLSStore.identityFile(data))
    do {
        _ = try await HomespunServer(configuration: .init(dataDirectory: data))
        Issue.record("An unreadable identity was silently replaced")
    } catch {
        #expect(String(describing: error).contains("move the tls folder away"))
        #expect(try String(contentsOf: TLSStore.identityFile(data), encoding: .utf8) == "broken identity")
    }
}

private func withTLSClient(_ certificate: NIOSSLCertificate, _ body: (HTTPClient) async throws -> Void) async throws {
    var configuration = TLSConfiguration.makeClientConfiguration()
    configuration.trustRoots = .certificates([certificate])
    configuration.certificateVerification = .noHostnameVerification
    // Network.framework cannot disable hostname verification for this trust-root test.
    let client = HTTPClient(eventLoopGroupProvider: .shared(MultiThreadedEventLoopGroup.singleton),
                            configuration: .init(tlsConfiguration: configuration))
    do {
        try await body(client)
        try await client.shutdown()
    } catch {
        try? await client.shutdown()
        throw error
    }
}

@Test func listenerAcceptsTLSRejectsPlainHTTPAndReloadsRotatedKeys() async throws {
    let data = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: data) }
    let server = try await HomespunServer(configuration: .init(dataDirectory: data, port: 0))
    try await server.application().test(.ahc(.https)) { live in
        let port = try #require(live.port)
        let url = "https://localhost:\(port)/api/v1/health"
        try await withTLSClient(server.identity.current.certificate) { client in
            let response = try await client.execute(HTTPClientRequest(url: url), timeout: .seconds(5))
            let bytes = try await response.body.collect(upTo: 1024)
            #expect(try ServerAPI.decoder.decode(ServerAPI.Health.self, from: Data(bytes.readableBytesView)).tls == true)
            await #expect(throws: (any Error).self) {
                _ = try await client.execute(HTTPClientRequest(url: "http://localhost:\(port)/api/v1/health"),
                                              timeout: .seconds(2))
            }
        }
        let otherData = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: otherData) }
        let other = try TLSStore.loadOrCreate(data: otherData).0
        try await withTLSClient(other.certificate) { client in
            await #expect(throws: (any Error).self) {
                _ = try await client.execute(HTTPClientRequest(url: url), timeout: .seconds(3))
            }
        }
        let rotated = try TLSStore.replaceKey(data: data)
        for _ in 0..<120 where server.fingerprint != rotated.fingerprint {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(server.fingerprint == rotated.fingerprint)
        try await withTLSClient(rotated.certificate) { client in
            let response = try await client.execute(HTTPClientRequest(url: url), timeout: .seconds(5))
            #expect(response.status == .ok)
        }
    }
}

@Test func upgradeProofBindsTheServerKeyAndRejectsUnknownOrRevokedPairings() async throws {
    let fixture = try await Fixture()
    try await fixture.test { client, token in
        let hash = PairingCrypto.tokenHash(token), nonce = PairingCrypto.nonce()
        let request = ServerAPI.IdentityRequest(keyID: PairingCrypto.keyID(tokenHash: hash), nonce: PairingCrypto.encode(nonce))
        let response = try await client.call("/api/v1/tls/verify", .post, json: request).decode(ServerAPI.IdentityProof.self)
        #expect(response.fingerprint == fixture.server.fingerprint)
        let proof = try #require(PairingCrypto.decode(response.proof, count: 32))
        #expect(PairingCrypto.equal(proof, PairingCrypto.verifyProof(tokenHash: hash, nonce: nonce, fingerprint: response.fingerprint)))
        #expect(!PairingCrypto.equal(proof, PairingCrypto.verifyProof(tokenHash: hash, nonce: nonce,
            fingerprint: ServerKeyFingerprint(spki: Data("another key".utf8)))))
        let unknown = ServerAPI.IdentityRequest(keyID: PairingCrypto.encode(Data(count: 16)), nonce: request.nonce)
        let missing = try await client.call("/api/v1/tls/verify", .post, json: unknown)
        #expect(missing.status == .notFound)
        let device = try #require(try await fixture.server.catalog.devices().first)
        _ = try await fixture.server.catalog.revoke(deviceID: device.id)
        let revoked = try await client.call("/api/v1/tls/verify", .post, json: request)
        #expect(revoked.status == .notFound && revoked.data == missing.data)
        for _ in 0..<27 { _ = try await client.call("/api/v1/tls/verify", .post, json: unknown) }
        #expect(try await client.call("/api/v1/tls/verify", .post, json: unknown).status == .tooManyRequests)
    }
}

@Test func codeChallengeProvesTheCodeLimitsAttemptsAndBurnsIt() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let code = try await fixture.server.newPairingCode(), now = Date(), nonce = PairingCrypto.nonce()
    let challenges = CodeChallenges(catalog: fixture.server.catalog, rounds: 1_000)
    let challenge = try await challenges.challenge(nonce: nonce, fingerprint: fixture.server.fingerprint, now: now)
    let entry = try #require(challenge.proofs.first), salt = try #require(PairingCrypto.decode(entry.salt, count: 16))
    let key = try PairingCrypto.codeKey(codeHash: PairingCrypto.codeHash(code), salt: salt, rounds: 1_000)
    #expect(PairingCrypto.encode(PairingCrypto.codeCheck(key: key, nonce: nonce, salt: salt, id: challenge.id)) == entry.check)
    #expect(PairingCrypto.encode(PairingCrypto.codeProof(key: key, fingerprint: fixture.server.fingerprint,
                                                       nonce: nonce, salt: salt, id: challenge.id)) == entry.proof)
    let wrong = try PairingCrypto.codeKey(codeHash: PairingCrypto.codeHash("ZZZZ-ZZZZ"), salt: salt, rounds: 1_000)
    #expect(PairingCrypto.encode(PairingCrypto.codeCheck(key: wrong, nonce: nonce, salt: salt, id: challenge.id)) != entry.check)
    await #expect(throws: CodeChallenges.Failure.self) {
        _ = try await challenges.challenge(nonce: nonce, fingerprint: fixture.server.fingerprint, now: now)
    }
    for seconds in 1...2 {
        #expect(try await challenges.challenge(nonce: nonce, fingerprint: fixture.server.fingerprint,
                                               now: now.addingTimeInterval(Double(seconds))).proofs.count == 1)
    }
    #expect(try await challenges.challenge(nonce: nonce, fingerprint: fixture.server.fingerprint,
                                           now: now.addingTimeInterval(3)).proofs.isEmpty)
    #expect(try await fixture.server.catalog.openPairingCodes(now: now.addingTimeInterval(121)).isEmpty)
    #expect(await challenges.redeemable(id: challenge.id, codeHash: PairingCrypto.codeHash(code), now: now))
    #expect(await !challenges.redeemable(id: challenge.id, codeHash: PairingCrypto.codeHash(code), now: now))
}

@Test func challengeRateLimitHasAnActionableWireError() async throws {
    let data = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: data) }
    // Busy shared machines can take over a second between these router calls.
    let server = try await HomespunServer(configuration: .init(dataDirectory: data), approver: nil,
                                         builtIn: [], codeRounds: 1_000, challengeInterval: 60)
    try await Application(router: server.testRouter()).test(.router) { client in
        let body = ServerAPI.CodeChallengeRequest(nonce: PairingCrypto.encode(PairingCrypto.nonce()))
        #expect(try await client.call("/api/v1/pair/challenge", .post, json: body).status == .ok)
        let limited = try await client.call("/api/v1/pair/challenge", .post, json: body)
        #expect(limited.status == .tooManyRequests)
        #expect(try limited.decode(ServerAPI.ErrorBody.self).error.code == ServerAPI.ErrorCode.tooManyChallenges)
    }
}

@Test func challengeLimitsSurviveChangesToTheFourNewestCodes() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    _ = try await fixture.server.newPairingCode()
    let challenges = CodeChallenges(catalog: fixture.server.catalog, rounds: 1_000, minimumInterval: 0)
    let now = Date(), nonce = PairingCrypto.nonce(), fingerprint = fixture.server.fingerprint
    for _ in 0..<3 {
        #expect(try await challenges.challenge(nonce: nonce, fingerprint: fingerprint, now: now).proofs.count == 1)
    }
    var newer: [String] = []
    for _ in 0..<4 { newer.append(try await fixture.server.newPairingCode()) }
    #expect(try await challenges.challenge(nonce: nonce, fingerprint: fingerprint, now: now).proofs.count == 4)
    for code in newer {
        try await fixture.server.catalog.shortenPairingCode(hash: PairingCrypto.codeHash(code), until: now.addingTimeInterval(-1))
    }
    #expect(try await challenges.challenge(nonce: nonce, fingerprint: fingerprint, now: now).proofs.isEmpty)
}

@Test func pairingRequiresAChallengeAndApprovalRequiresCommitThenReveal() async throws {
    let approver = FakeApprover()
    approver.hold = true
    let fixture = try await Fixture(approver: approver)
    try await fixture.test { client, _ in
        // Raw execute intentionally skips the test helper that obtains challenges.
        let response = try await client.execute(uri: "/api/v1/pair", method: .post,
            headers: [.contentType: "application/json"],
            body: .init(bytes: ServerAPI.encoder.encode(ServerAPI.PairRequest(code: "K7Q4-M9XT", deviceName: "iPhone"))))
        #expect(response.status == .badRequest)
        #expect(try response.decode(ServerAPI.ErrorBody.self).error.code == ServerAPI.ErrorCode.challengeRequired)
        #expect(try await client.call("/api/v1/pair/requests", .post,
                                      json: ServerAPI.ApprovalRequest(deviceName: "iPhone")).status == .badRequest)
        let nonce = PairingCrypto.nonce()
        let ticket = try await client.call("/api/v1/pair/requests", .post,
            json: ServerAPI.ApprovalRequest(deviceName: "iPhone",
                                            commitment: PairingCrypto.encode(PairingCrypto.commitment(nonce: nonce))))
            .decode(ServerAPI.ApprovalTicket.self)
        #expect(approver.lock.withLock { approver.asked.isEmpty })
        let bad = try await client.call("/api/v1/pair/requests/\(ticket.id)/reveal", .post, token: ticket.secret,
                                        json: ServerAPI.ApprovalReveal(nonce: PairingCrypto.encode(PairingCrypto.nonce())))
        #expect(bad.status == .badRequest && approver.lock.withLock { approver.asked.isEmpty })
    }
    let approvals = PairingApprovals(approver: approver, serverName: "Mac mini", pause: 0)
    let nonce = PairingCrypto.nonce(), now = Date()
    let ticket = try await approvals.start(device: "iPhone", commitment: PairingCrypto.commitment(nonce: nonce), now: now)
    await #expect(throws: PairingApprovals.Failure.self) {
        try await approvals.reveal(id: ticket.id, secret: ticket.secret, nonce: nonce,
                                   fingerprint: fixture.server.fingerprint, now: now.addingTimeInterval(31))
    }
}

@Test func tlsFixtureFingerprintMatchesTheApp() throws {
    let file = try #require(Bundle.module.url(forResource: "tls-fixture", withExtension: "der", subdirectory: "Fixtures"))
    let certificate = try Certificate(derEncoded: Array(Data(contentsOf: file)))
    let key = try #require(P256.Signing.PublicKey(certificate.publicKey))
    #expect(ServerKeyFingerprint(spki: key.derRepresentation).base64url == "IlypPJ-wE200U-L1DoKMtMQyrDczNQMel-ae_YH5OgU")
}
