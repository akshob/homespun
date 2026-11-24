// SPDX-License-Identifier: AGPL-3.0-only
import AsyncHTTPClient
import Foundation
import HomespunCore
import NIOCore
import NIOSSL

enum WakeHintResult: Sendable { case accepted, gone, retry }
enum WakeHintFailure: Error { case invalidEndpoint, invalidCredential, closed }

protocol WakeHintSending: Sendable {
    func send(_ sender: WakeRelayAPI.Sender, nonce: UUID) async throws -> WakeHintResult
}

/// The home server knows only a scoped send credential; it never receives an APNs token or key.
actor WakeHintClient: WakeHintSending {
    private let baseURL: URL
    private var client: HTTPClient?
    private var closed = false

    init(baseURL: URL) throws {
        guard baseURL.scheme == "https", baseURL.host != nil, baseURL.user == nil, baseURL.password == nil,
              baseURL.query == nil, baseURL.fragment == nil, (1...65_535).contains(baseURL.port ?? 443) else {
            throw WakeHintFailure.invalidEndpoint
        }
        self.baseURL = baseURL
    }

    func send(_ sender: WakeRelayAPI.Sender, nonce: UUID) async throws -> WakeHintResult {
        guard !closed else { throw WakeHintFailure.closed }
        guard PairingCrypto.decode(sender.token, count: 32) != nil else { throw WakeHintFailure.invalidCredential }
        let client: HTTPClient
        if let existing = self.client { client = existing }
        else {
            var tls = TLSConfiguration.makeClientConfiguration()
            tls.minimumTLSVersion = .tlsv12
            client = HTTPClient(eventLoopGroupProvider: .singleton,
                configuration: .init(tlsConfiguration: tls, redirectConfiguration: .disallow))
            self.client = client
        }
        let url = baseURL.appendingPathComponent("v1/routes/\(sender.routeID.uuidString)/hint")
        var request = HTTPClientRequest(url: url.absoluteString)
        request.method = .POST
        request.headers.add(name: "authorization", value: "Bearer \(sender.token)")
        request.headers.add(name: "content-type", value: "application/json")
        request.body = .bytes(ByteBuffer(bytes: try ServerAPI.encoder.encode(
            WakeRelayAPI.Hint(generationID: sender.generationID, nonce: nonce))))
        let response = try await client.execute(request, timeout: .seconds(20))
        _ = try await response.body.collect(upTo: 1_024)
        switch response.status.code {
        case 202: return .accepted
        case 401, 404, 409, 410: return .gone
        default: return .retry
        }
    }

    func shutdown() async throws {
        closed = true
        if let client { try await client.shutdown() }
        client = nil
    }
}
