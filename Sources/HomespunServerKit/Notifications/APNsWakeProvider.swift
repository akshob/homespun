// SPDX-License-Identifier: AGPL-3.0-only
import AsyncHTTPClient
import Crypto
import Foundation
import HomespunCore
import NIOCore
import NIOSSL

enum APNsWakeFailure: Error {
    case configuration, malformedResponse, unsupportedHTTPVersion
}

actor APNsWakeProvider {
    private struct ProviderHeader: Encodable { var alg = "ES256"; var kid: String }
    private struct ProviderClaims: Encodable { var iss: String; var iat: Int64 }
    private struct ProviderError: Decodable { var reason: String }
    private let key: P256.Signing.PrivateKey
    private let keyID: String
    private let teamID: String
    private let topic: String
    private var client: HTTPClient?
    private var closed = false
    private var cached: (value: String, issued: Date)?

    init(keyPEM: String, keyID: String, teamID: String, topic: String = "photos.homespun.app") throws {
        guard Self.identifier(keyID), Self.identifier(teamID),
              ["photos.homespun.app", "photos.homespun.app.dev"].contains(topic) else { throw APNsWakeFailure.configuration }
        self.key = try P256.Signing.PrivateKey(pemRepresentation: keyPEM)
        self.keyID = keyID
        self.teamID = teamID
        self.topic = topic
    }

    func send(_ lease: WakeRelayStore.Lease, now: Date = Date()) async throws -> WakeRelayStore.Outcome {
        guard !lease.deviceToken.isEmpty, lease.deviceToken.utf8.count <= 1_024,
              lease.deviceToken.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw APNsWakeFailure.configuration
        }
        let host = lease.environment == .production ? "api.push.apple.com" : "api.sandbox.push.apple.com"
        var request = HTTPClientRequest(url: "https://\(host)/3/device/\(lease.deviceToken)")
        request.method = .POST
        request.headers.add(name: "authorization", value: "bearer \(try providerToken(now: now))")
        request.headers.add(name: "apns-topic", value: topic)
        request.headers.add(name: "apns-push-type", value: "background")
        request.headers.add(name: "apns-priority", value: "5")
        request.headers.add(name: "apns-collapse-id", value: "homespun-results")
        request.headers.add(name: "apns-expiration", value: String(Int64(now.addingTimeInterval(3_600).timeIntervalSince1970)))
        request.body = .bytes(ByteBuffer(string: #"{"aps":{"content-available":1}}"#))
        let response = try await httpClient().execute(request, timeout: .seconds(20))
        let body = try await response.body.collect(upTo: 4_096)
        guard response.version.major == 2 else { throw APNsWakeFailure.unsupportedHTTPVersion }
        if response.status.code == 200 {
            guard body.readableBytes == 0 else { throw APNsWakeFailure.malformedResponse }
            return .sent
        }
        if response.status.code == 410 { return .invalidDevice }
        if response.status.code == 400 {
            let reason = try JSONDecoder().decode(ProviderError.self, from: Data(body.readableBytesView)).reason
            if ["BadDeviceToken", "DeviceTokenNotForTopic"].contains(reason) { return .invalidDevice }
        }
        return .retry
    }

    func shutdown() async throws {
        closed = true
        if let client { try await client.shutdown() }
        client = nil
    }

    private func httpClient() throws -> HTTPClient {
        guard !closed else { throw APNsWakeFailure.configuration }
        if let client { return client }
        var tls = TLSConfiguration.makeClientConfiguration()
        tls.minimumTLSVersion = .tlsv12
        let configuration = HTTPClient.Configuration(tlsConfiguration: tls, redirectConfiguration: .disallow)
        let client = HTTPClient(eventLoopGroupProvider: .singleton, configuration: configuration)
        self.client = client
        return client
    }

    func providerToken(now: Date) throws -> String {
        if let cached, now >= cached.issued, now.timeIntervalSince(cached.issued) < 45 * 60 { return cached.value }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let header = PairingCrypto.encode(try encoder.encode(ProviderHeader(kid: keyID)))
        let claims = PairingCrypto.encode(try encoder.encode(ProviderClaims(iss: teamID, iat: Int64(now.timeIntervalSince1970))))
        let payload = header + "." + claims
        let signature = try key.signature(for: Data(payload.utf8))
        let value = payload + "." + PairingCrypto.encode(signature.rawRepresentation)
        cached = (value, now)
        return value
    }

    private static func identifier(_ value: String) -> Bool {
        value.utf8.count == 10 && value.utf8.allSatisfy { (65...90).contains($0) || (48...57).contains($0) }
    }
}
