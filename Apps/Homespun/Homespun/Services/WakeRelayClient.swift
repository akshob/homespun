// SPDX-License-Identifier: Apache-2.0
import Foundation
import HomespunCore

protocol WakeRelayServing: Sendable {
    func begin(id: UUID, managementToken: String) async throws -> WakeRelayAPI.Registration
    func activate(id: UUID, managementToken: String, body: WakeRelayAPI.Activation) async throws
    func erase(id: UUID, managementToken: String) async throws
}

enum WakeEnrollmentFailure: Error, LocalizedError, Equatable {
    case unavailable, invalidResponse, storage, demo, noServer, expired

    var errorDescription: String? {
        switch self {
        case .unavailable: "Background wakeups are unavailable. Backups still reconcile when iOS next lets Homespun run."
        case .invalidResponse: "The wake service could not confirm this request."
        case .storage: "The private wake setting could not be saved. No new enrollment was started."
        case .demo: "The demo never enrolls for remote notifications."
        case .noServer: "Pair a server before enabling background wakeups."
        case .expired: "The wake enrollment expired and must be renewed."
        }
    }
}

actor WakeRelayClient: WakeRelayServing {
    private let baseURL: URL
    private let session: URLSession

    init(baseURL: URL) throws {
        guard baseURL.scheme == "https", baseURL.host != nil, baseURL.user == nil, baseURL.password == nil,
              baseURL.query == nil, baseURL.fragment == nil, (1...65_535).contains(baseURL.port ?? 443) else {
            throw WakeEnrollmentFailure.unavailable
        }
        self.baseURL = baseURL
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration, delegate: ServerTrustDelegate(policy: .system), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func begin(id: UUID, managementToken: String) async throws -> WakeRelayAPI.Registration {
        let data = try await request(id: id, suffix: "/begin", method: "POST", token: managementToken, expected: 201)
        return try ServerAPI.decoder.decode(WakeRelayAPI.Registration.self, from: data)
    }

    func activate(id: UUID, managementToken: String, body: WakeRelayAPI.Activation) async throws {
        _ = try await request(id: id, method: "PUT", token: managementToken,
                              body: ServerAPI.encoder.encode(body), expected: 204)
    }

    func erase(id: UUID, managementToken: String) async throws {
        _ = try await request(id: id, method: "DELETE", token: managementToken, expected: 204)
    }

    private func request(id: UUID, suffix: String = "", method: String, token: String,
                         body: Data? = nil, expected: Int) async throws -> Data {
        guard PairingCrypto.decode(token, count: 32) != nil else { throw WakeEnrollmentFailure.storage }
        let url = baseURL.appendingPathComponent("v1/routes/\(id.uuidString)" + suffix)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse,
              let actual = response.url, actual.scheme == "https", actual.host == baseURL.host,
              (actual.port ?? 443) == (baseURL.port ?? 443), data.count <= 4_096 else {
            throw WakeEnrollmentFailure.invalidResponse
        }
        if method != "DELETE", [404, 409, 410].contains(response.statusCode) { throw WakeEnrollmentFailure.expired }
        guard response.statusCode == expected else { throw WakeEnrollmentFailure.invalidResponse }
        return data
    }
}
