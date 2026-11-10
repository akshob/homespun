// SPDX-License-Identifier: Apache-2.0
import Foundation
import HomespunCore

/// Talks to Homespun Server's `/api/v1`.
struct ServerClient: Sendable {
    struct Failure: LocalizedError {
        var status: Int
        var message: String
        /// The server's error code, for errors handled specially (`ServerAPI.ErrorCode`).
        var code: String?
        var errorDescription: String? { message }
    }

    let baseURL: URL
    var token: String?
    var session: URLSession = .shared
    var timeout: TimeInterval = 60
    static let chunkSize = 8 << 20

    private func request(_ path: String, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/v1/" + path))
        request.httpMethod = method
        request.timeoutInterval = timeout
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    private func check(_ data: Data, _ response: URLResponse, accepting: Set<Int> = [200, 201, 202]) throws -> Int {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard accepting.contains(status) else {
            let detail = (try? ServerAPI.decoder.decode(ServerAPI.ErrorBody.self, from: data))?.error
            throw Failure(status: status, message: detail?.message ?? "The server returned HTTP \(status).", code: detail?.code)
        }
        return status
    }

    private func send<Response: Decodable>(_ path: String, method: String = "GET", json: (some Encodable)? = Optional<Int>.none,
                                           as type: Response.Type) async throws -> Response {
        var request = request(path, method: method)
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try ServerAPI.encoder.encode(json)
        }
        let (data, response) = try await session.data(for: request)
        _ = try check(data, response)
        return try ServerAPI.decoder.decode(Response.self, from: data)
    }

    func pair(code: String, deviceName: String) async throws -> ServerAPI.PairResponse {
        try await send("pair", method: "POST", json: ServerAPI.PairRequest(code: code, deviceName: deviceName),
                       as: ServerAPI.PairResponse.self)
    }

    func pairingOptions() async throws -> ServerAPI.PairingOptions {
        try await send("pair/options", as: ServerAPI.PairingOptions.self)
    }

    /// Asks someone at the server to allow this device.
    func requestApproval(deviceName: String) async throws -> ServerAPI.ApprovalTicket {
        try await send("pair/requests", method: "POST", json: ServerAPI.ApprovalRequest(deviceName: deviceName),
                       as: ServerAPI.ApprovalTicket.self)
    }

    /// For a client whose token is the ticket's secret.
    func approvalStatus(_ id: String) async throws -> ServerAPI.ApprovalStatus {
        try await send("pair/requests/\(id)", as: ServerAPI.ApprovalStatus.self)
    }

    /// Withdraws the question (closing the dialog). For a client whose token is the ticket's secret.
    func cancelApproval(_ id: String) async {
        _ = try? await session.data(for: request("pair/requests/\(id)", method: "DELETE"))
    }

    /// A one-time code for pairing another device.
    func newPairingCode() async throws -> ServerAPI.PairingCode {
        try await send("pairing-codes", method: "POST", as: ServerAPI.PairingCode.self)
    }

    func info() async throws -> ServerAPI.ServerInfo { try await send("info", as: ServerAPI.ServerInfo.self) }

    func setup() async throws -> ServerSetup.Report { try await send("setup", as: ServerSetup.Report.self) }

    func immichSettings() async throws -> ServerAPI.ImmichSettings {
        try await send("settings/immich", as: ServerAPI.ImmichSettings.self)
    }

    func connectImmich(url: String, apiKey: String) async throws -> ServerAPI.ImmichSettings {
        try await send("settings/immich", method: "PUT", json: ServerAPI.ImmichSettingsRequest(url: url, apiKey: apiKey),
                       as: ServerAPI.ImmichSettings.self)
    }

    func disconnectImmich() async throws -> ServerAPI.ImmichSettings {
        try await send("settings/immich", method: "DELETE", as: ServerAPI.ImmichSettings.self)
    }

    func register(_ body: ServerAPI.RegisterAssetRequest) async throws -> ServerAPI.AssetStatus {
        try await send("assets", method: "POST", json: body, as: ServerAPI.AssetStatus.self)
    }

    func status(_ assetID: String) async throws -> ServerAPI.AssetStatus {
        try await send("assets/\(assetID)", as: ServerAPI.AssetStatus.self)
    }

    func imported(_ assetID: String) async throws {
        _ = try await send("assets/\(assetID)/imported", method: "POST", as: ServerAPI.AssetStatus.self)
    }

    func verify(_ assetID: String) async throws -> ServerAPI.Verification {
        try await send("assets/\(assetID)/verify", method: "POST", as: ServerAPI.Verification.self)
    }

    /// Uploads `file` from wherever the server says it left off, in chunks.
    func upload(_ file: URL, assetID: String, role: ServerAPI.ResourceRole, size: Int,
                progress: @Sendable (Int) -> Void) async throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var offset = try await status(assetID).resources.first { $0.role == role }?.receivedBytes ?? 0
        var conflicts = 0
        // At offset == size an empty request asks the server to verify bytes it already has.
        while true {
            try Task.checkCancellation()
            try handle.seek(toOffset: UInt64(min(offset, size)))
            let chunk = offset < size ? try handle.read(upToCount: Self.chunkSize) ?? Data() : Data()
            var request = request("", method: "PUT")
            request.url = URL(string: baseURL.absoluteString + "/api/v1/assets/\(assetID)/resources/\(role.rawValue)?offset=\(offset)")
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            let (data, response) = try await session.upload(for: request, from: chunk)
            let code = try check(data, response, accepting: [200, 409])
            if code == 409 {
                conflicts += 1
                guard conflicts < 10 else { throw Failure(status: 409, message: "The upload keeps restarting.") }
                guard let resource = try? ServerAPI.decoder.decode(ServerAPI.ResourceStatus.self, from: data) else {
                    // Another upload of this file is still open on the server; it times out.
                    try await Task.sleep(for: .seconds(Double(conflicts) * 3))
                    continue
                }
                offset = resource.receivedBytes
                continue
            }
            let resource = try ServerAPI.decoder.decode(ServerAPI.ResourceStatus.self, from: data)
            if resource.state == .verified { return }
            guard resource.receivedBytes > offset else {
                throw Failure(status: code, message: "The server did not accept \(role.rawValue).")
            }
            offset = resource.receivedBytes
            progress(offset)
        }
    }

    /// Downloads a compact file and checks its size and SHA-256.
    func download(_ compact: ServerAPI.CompactResource, assetID: String, to directory: URL) async throws -> URL {
        let (temporary, response) = try await session.download(for: request("assets/\(assetID)/compact/\(compact.role.rawValue)"))
        _ = try check(Data(), response)
        let destination = directory.appendingPathComponent(compact.filename.split(separator: "/").last.map(String.init) ?? "compact")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        let digests = try Fingerprint.digests(of: destination)
        guard digests.size == compact.size, digests.sha256 == compact.sha256 else {
            throw PhotoLibrary.Failure.verificationFailed(compact.filename)
        }
        return destination
    }
}
