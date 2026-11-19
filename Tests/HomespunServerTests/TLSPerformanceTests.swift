// SPDX-License-Identifier: AGPL-3.0-only
import AsyncHTTPClient
import Foundation
import HomespunCore
import Hummingbird
import HummingbirdTesting
import NIOSSL
import Testing
@testable import HomespunServerKit

@Test(.enabled(if: ProcessInfo.processInfo.environment["HOMESPUN_PERF"] == "1"))
func tlsUploadThroughput() async throws {
    let bytes = Data(repeating: 0xA5, count: 256 << 20)
    let hash = Fingerprint.sha256(of: bytes)
    var rates: [Double] = []
    for encrypted in [false, true] {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = try await HomespunServer(configuration: .init(dataDirectory: directory, port: 0))
        let token = "performance-only-token"
        try await server.catalog.addApprovedDevice(.init(id: UUID().uuidString, name: "Performance", createdAt: "",
                                                          lastSeenAt: nil, revokedAt: nil), tokenHash: Pairing.hash(token))
        // Plain HTTP exists only inside this opt-in comparison; the production listener is TLS-only.
        let scheme = encrypted ? "https" : "http"
        let app = Application(router: server.testRouter(), server: encrypted ? server.transport : .http1(),
                              configuration: .init(address: .hostname("127.0.0.1", port: 0)))
        let measured = try await app.test(.ahc(encrypted ? .https : .http)) { client in
            let registration = ServerAPI.RegisterAssetRequest(kind: .photo, captureDate: nil, resources: [
                .init(role: .photo, filename: "payload.bin", size: bytes.count, sha256: hash)
            ], compact: false)
            let response = try await client.call("/api/v1/assets", .post, token: token, json: registration)
            #expect(response.status == .created || response.status == .ok)
            let start = ContinuousClock.now
            for offset in stride(from: 0, to: bytes.count, by: 8 << 20) {
                let result = try await client.call("/api/v1/assets/\(hash)/resources/photo?offset=\(offset)", .put,
                                                   token: token, body: bytes.subdata(in: offset..<offset + (8 << 20)))
                #expect(result.status == .ok, "\(scheme) upload returned \(result.status)")
            }
            return 256 / ((ContinuousClock.now - start) / .seconds(1))
        }
        rates.append(measured)
    }
    let ratio = rates[1] / rates[0]
    print(String(format: "PERF tls-upload plain=%.1f MiB/s tls=%.1f MiB/s ratio=%.3f", rates[0], rates[1], ratio))
    #if os(Linux)
    #expect(ratio >= 0.70 && rates[1] >= 200)
    #endif
}
