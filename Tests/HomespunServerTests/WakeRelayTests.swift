// SPDX-License-Identifier: AGPL-3.0-only
import Crypto
import Foundation
import HomespunCore
import Hummingbird
import HummingbirdTesting
import Testing
@testable import HomespunServerKit

private func wakePolicy() -> WakeRelayPolicy {
    .init(maximumRoutes: 10, minimumInterval: 1_200, pendingLifetime: 86_400,
          activeLifetime: 90 * 86_400, leaseDuration: 60)
}

private func wakeSecret() -> String { PairingCrypto.encode(PairingCrypto.nonce()) }

@Test func relayErasureFencesLateActivationWithoutKeepingDeviceTokensOrPermanentTombstones() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try WakeRelayStore(directory: directory, policy: wakePolicy())
    let id = UUID(), management = wakeSecret(), sender = wakeSecret(), now = Date()
    let first = try await store.begin(id: id, managementToken: management, now: now)
    let body = WakeRelayAPI.Activation(generationID: first.generationID, deviceToken: String(repeating: "a", count: 64),
                                      environment: .production, senderToken: sender)
    try await store.erase(id: id, managementToken: management)
    #expect(try await store.routeCount() == 0)
    let delayedBegin = try await store.begin(id: id, managementToken: management, now: now)
    #expect(delayedBegin.generationID != first.generationID)
    await #expect(throws: WakeRelayFailure.generationChanged) {
        try await store.activate(id: id, managementToken: management, body: body, now: now)
    }
    #expect(try await store.claim(owner: UUID(), now: now) == nil)
    try await store.erase(id: id, managementToken: management)
    await #expect(throws: WakeRelayFailure.notFound) {
        try await store.activate(id: id, managementToken: management, body: body, now: now)
    }
}

@Test func relayHintsCoalesceAndCannotBypassTheSilentPushInterval() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try WakeRelayStore(directory: directory, policy: wakePolicy())
    let id = UUID(), management = wakeSecret(), sender = wakeSecret(), now = Date()
    let registration = try await store.begin(id: id, managementToken: management, now: now)
    try await store.activate(id: id, managementToken: management,
        body: .init(generationID: registration.generationID, deviceToken: String(repeating: "b", count: 64),
                    environment: .production, senderToken: sender), now: now)
    let first = UUID(), second = UUID(), third = UUID()
    for nonce in [first, second] {
        try await store.hint(id: id, senderToken: sender, body: .init(generationID: registration.generationID, nonce: nonce), now: now)
    }
    let lease = try #require(try await store.claim(owner: UUID(), now: now))
    #expect(lease.nonce == second)
    try await store.hint(id: id, senderToken: sender, body: .init(generationID: registration.generationID, nonce: third), now: now)
    try await store.finish(lease, outcome: .sent)
    #expect(try await store.claim(owner: UUID(), now: now.addingTimeInterval(1_199)) == nil)
    let later = try #require(try await store.claim(owner: UUID(), now: now.addingTimeInterval(1_201)))
    #expect(later.nonce == third)
    await #expect(throws: WakeRelayFailure.unauthorized) {
        try await store.hint(id: id, senderToken: wakeSecret(),
                             body: .init(generationID: registration.generationID, nonce: UUID()), now: now)
    }
}

@Test func oldProviderCompletionCannotEraseARotatedToken() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try WakeRelayStore(directory: directory, policy: wakePolicy())
    let id = UUID(), management = wakeSecret(), sender = wakeSecret(), now = Date()
    let registration = try await store.begin(id: id, managementToken: management, now: now)
    func activation(_ token: String) -> WakeRelayAPI.Activation {
        .init(generationID: registration.generationID, deviceToken: token, environment: .production, senderToken: sender)
    }
    try await store.activate(id: id, managementToken: management, body: activation(String(repeating: "a", count: 64)), now: now)
    try await store.hint(id: id, senderToken: sender, body: .init(generationID: registration.generationID, nonce: UUID()), now: now)
    let lease = try #require(try await store.claim(owner: UUID(), now: now))
    try await store.activate(id: id, managementToken: management, body: activation(String(repeating: "b", count: 64)), now: now)
    try await store.finish(lease, outcome: .invalidDevice)
    #expect(try await store.routeCount() == 1)
    let rotated = try #require(try await store.claim(owner: UUID(), now: now.addingTimeInterval(1_201)))
    #expect(rotated.deviceToken == String(repeating: "b", count: 64))
}

@Test func relayExpiryAndGenerationDoNotRecreateAnErasedEnrollment() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try WakeRelayStore(directory: directory, policy: wakePolicy())
    let id = UUID(), management = wakeSecret(), now = Date()
    _ = try await store.begin(id: id, managementToken: management, now: now)
    #expect(try await store.claim(owner: UUID(), now: now.addingTimeInterval(86_401)) == nil)
    #expect(try await store.routeCount() == 0)
}

@Test func relayRejectsMediaMetadataBeforeItCanBecomeAWakePayload() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try WakeRelayStore(directory: directory, policy: wakePolicy())
    let app = Application(router: WakeRelay(store: store, environment: .production).router())
    try await app.test(.router) { client in
        let response = try await client.call("/v1/routes/\(UUID().uuidString)/hint", .post, token: wakeSecret(),
            body: Data(#"{"generation_id":"00000000-0000-0000-0000-000000000000","nonce":"00000000-0000-0000-0000-000000000001","asset_id":"must not be accepted"}"#.utf8))
        #expect(response.status == .badRequest)
        #expect(try await store.routeCount() == 0)
    }
}

@Test func providerJWTUsesES256AndDoesNotIncludeDeviceOrServerMetadata() async throws {
    let key = P256.Signing.PrivateKey()
    let provider = try APNsWakeProvider(keyPEM: key.pemRepresentation, keyID: "TESTKEY001", teamID: "TESTTEAM01")
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let jwt = try await provider.providerToken(now: now)
    let parts = jwt.split(separator: ".").map(String.init)
    #expect(parts.count == 3)
    func decode(_ value: String) throws -> Data {
        let standard = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return try #require(Data(base64Encoded: standard + String(repeating: "=", count: (4 - standard.count % 4) % 4)))
    }
    let header = try JSONSerialization.jsonObject(with: decode(parts[0])) as? [String: String]
    let claims = try JSONSerialization.jsonObject(with: decode(parts[1])) as? [String: Any]
    #expect(header == ["alg": "ES256", "kid": "TESTKEY001"])
    #expect(Set(claims?.keys.map { $0 } ?? []) == ["iss", "iat"])
    let signature = try P256.Signing.ECDSASignature(rawRepresentation: decode(parts[2]))
    #expect(key.publicKey.isValidSignature(signature, for: Data((parts[0] + "." + parts[1]).utf8)))
    #expect(try await provider.providerToken(now: now.addingTimeInterval(60)) == jwt)
    try await provider.shutdown()
}
