// SPDX-License-Identifier: Apache-2.0
import Foundation
import HomespunCore
import os
import UniformTypeIdentifiers

/// Talks to Homespun Server's `/api/v1`.
struct ServerClient: Sendable {
    struct Failure: LocalizedError {
        var status: Int
        var message: String
        /// The server's error code, for errors handled specially (`ServerAPI.ErrorCode`).
        var code: String?
        var errorDescription: String? { message }
    }

    private struct ConnectionState: Sendable {
        var url: URL
        var session: URLSession
        var delegate: ServerTrustDelegate?
        let lifetime: ServerSessionLifetime

        init(url: URL, session: URLSession, delegate: ServerTrustDelegate?) {
            self.url = url
            self.session = session
            self.delegate = delegate
            lifetime = delegate?.lifetime ?? ServerSessionLifetime()
        }
    }
    private let connection: OSAllocatedUnfairLock<ConnectionState>
    var baseURL: URL { connection.withLock { $0.url } }
    var token: String?
    let trust: ServerTrust
    var session: URLSession { connection.withLock { $0.session } }
    var delegate: ServerTrustDelegate? { connection.withLock { $0.delegate } }
    let reconnect: (@Sendable (URL, String?) async -> ServerClient?)?
    var timeout: TimeInterval = 60
    static let chunkSize = 8 << 20

    init(baseURL: URL, token: String? = nil, trust: ServerTrust, session: URLSession? = nil,
         delegate: ServerTrustDelegate? = nil,
         reconnect: (@Sendable (URL, String?) async -> ServerClient?)? = nil) {
        self.token = token
        self.trust = trust
        self.reconnect = reconnect
        let state: ConnectionState
        if trust == .demo {
            state = ConnectionState(url: baseURL, session: session ?? DemoServer.session, delegate: nil)
        } else if let session {
            state = ConnectionState(url: baseURL, session: session, delegate: delegate ?? session.delegate as? ServerTrustDelegate)
        } else {
            let pair = ServerSessions.shared.session(for: baseURL, trust: trust)
            state = ConnectionState(url: baseURL, session: pair.0, delegate: pair.1)
        }
        connection = OSAllocatedUnfairLock(initialState: state)
    }

    struct IdentityMismatch: LocalizedError {
        var observed: ServerKeyFingerprint?
        var errorDescription: String? { "This server answered with a different security key." }
    }

    func retireSession() {
        guard trust != .demo else { return }
        let current = connection.withLock { $0 }
        current.lifetime.retire(session: current.session)
    }

    private func request(_ path: String, method: String = "GET") throws -> URLRequest {
        if case .blocked(let reason) = trust { throw Failure(status: 0, message: reason, code: "tls_blocked") }
        guard baseURL.scheme == "https" else {
            throw Failure(status: 0, message: "Homespun only connects with encryption.", code: "insecure")
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/v1/" + path))
        request.httpMethod = method
        request.timeoutInterval = timeout
        return request
    }

    static func isConnectionFailure(_ error: any Error) -> Bool {
        guard let error = error as? URLError else { return false }
        return [.timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .dnsLookupFailed,
                .secureConnectionFailed].contains(error.code)
    }

    private func retarget(_ request: URLRequest, to url: URL) throws -> URLRequest {
        guard let original = request.url, var components = URLComponents(url: original, resolvingAgainstBaseURL: false),
              let destination = URLComponents(url: url, resolvingAgainstBaseURL: false), destination.scheme == "https" else {
            throw Failure(status: 0, message: "Homespun only connects with encryption.", code: "insecure")
        }
        components.scheme = destination.scheme
        components.host = destination.host
        components.port = destination.port
        guard let target = components.url else { throw URLError(.badURL) }
        var request = request
        request.url = target
        return request
    }

    private func run<Value>(_ request: URLRequest, retrying: Bool = false,
                            _ operation: (URLSession, URLRequest) async throws -> Value) async throws -> Value {
        let current = connection.withLock { $0 }
        var request = try retarget(request, to: current.url)
        let authorization = request.value(forHTTPHeaderField: "Authorization")
        request.setValue(nil, forHTTPHeaderField: "Authorization")
        let started = Date()
        do {
            return try await current.lifetime.withOperation(session: current.session) {
                if case .pinned(let pins) = trust, token != nil || authorization != nil {
                    guard let delegate = current.delegate else { throw ServerPairing.IdentityFailure() }
                    let timeout = timeout
                    try await delegate.pinGate.verify {
                        var probe = URLRequest(url: current.url.appendingPathComponent("api/v1/health"))
                        probe.timeoutInterval = timeout
                        _ = try await current.session.data(for: probe)
                        guard let observed = delegate.observed, pins.contains(observed) else {
                            ServerSessions.shared.reset(current.url)
                            current.lifetime.retire(session: current.session)
                            throw URLError(.secureConnectionFailed)
                        }
                    }
                }
                try current.lifetime.checkUsable()
                request.setValue(token.map { "Bearer \($0)" } ?? authorization, forHTTPHeaderField: "Authorization")
                return try await operation(current.session, request)
            }
        } catch {
            let mismatch = current.delegate?.mismatch(since: started) == true
            if mismatch { ServerSessions.shared.markSuspect(current.url) }
            let replacedSession = (error as? URLError)?.code == .cancelled && !Task.isCancelled
            if !retrying, mismatch || Self.isConnectionFailure(error) || replacedSession, let reconnect,
               let replacement = await reconnect(current.url, token),
               replacement.trust == trust, replacement.token == token, replacement.baseURL != current.url {
                let updated = replacement.connection.withLock { $0 }
                connection.withLock { $0 = updated }
                return try await run(request, retrying: true, operation)
            }
            if mismatch { throw IdentityMismatch(observed: current.delegate?.refused) }
            throw error
        }
    }

    private func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await run(request) { session, request in try await session.data(for: request) }
    }

    private func download(for request: URLRequest) async throws -> (URL, URLResponse) {
        try await run(request) { session, request in try await session.download(for: request) }
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
        var request = try request(path, method: method)
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try ServerAPI.encoder.encode(json)
        }
        let (data, response) = try await data(for: request)
        _ = try check(data, response)
        return try ServerAPI.decoder.decode(Response.self, from: data)
    }

    func pair(code: String, deviceName: String, challenge: String, installID: String) async throws -> ServerAPI.PairResponse {
        try await send("pair", method: "POST", json: ServerAPI.PairRequest(code: code, deviceName: deviceName,
                                                                       challenge: challenge, installID: installID),
                       as: ServerAPI.PairResponse.self)
    }

    func pairingOptions() async throws -> ServerAPI.PairingOptions {
        try await send("pair/options", as: ServerAPI.PairingOptions.self)
    }

    /// Asks someone at the server to allow this device.
    func requestApproval(deviceName: String, commitment: String) async throws -> ServerAPI.ApprovalTicket {
        try await send("pair/requests", method: "POST", json: ServerAPI.ApprovalRequest(deviceName: deviceName,
                                                                                   commitment: commitment),
                       as: ServerAPI.ApprovalTicket.self)
    }

    func pairingChallenge(nonce: String) async throws -> ServerAPI.CodeChallenge {
        try await send("pair/challenge", method: "POST", json: ServerAPI.CodeChallengeRequest(nonce: nonce),
                       as: ServerAPI.CodeChallenge.self)
    }

    func verifyIdentity(keyID: String, nonce: String) async throws -> ServerAPI.IdentityProof {
        try await send("tls/verify", method: "POST", json: ServerAPI.IdentityRequest(keyID: keyID, nonce: nonce),
                       as: ServerAPI.IdentityProof.self)
    }

    func revealApproval(_ id: String, nonce: String) async throws {
        var request = try request("pair/requests/\(id)/reveal", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try ServerAPI.encoder.encode(ServerAPI.ApprovalReveal(nonce: nonce))
        let (data, response) = try await data(for: request)
        _ = try check(data, response)
    }

    func health() async throws -> ServerAPI.Health { try await send("health", as: ServerAPI.Health.self) }

    /// For a client whose token is the ticket's secret.
    func approvalStatus(_ id: String) async throws -> ServerAPI.ApprovalStatus {
        try await send("pair/requests/\(id)", as: ServerAPI.ApprovalStatus.self)
    }

    func completeApproval(_ id: String, installID: String) async throws -> ServerAPI.PairResponse {
        try await send("pair/requests/\(id)/complete", method: "POST",
                       json: ServerAPI.ApprovalCompletion(installID: installID), as: ServerAPI.PairResponse.self)
    }

    /// Withdraws the question (closing the dialog). For a client whose token is the ticket's secret.
    func cancelApproval(_ id: String) async {
        _ = try? await data(for: request("pair/requests/\(id)", method: "DELETE"))
    }

    /// A one-time code for pairing another device.
    func newPairingCode() async throws -> ServerAPI.PairingCode {
        try await send("pairing-codes", method: "POST", as: ServerAPI.PairingCode.self)
    }

    func info() async throws -> ServerAPI.ServerInfo { try await send("info", as: ServerAPI.ServerInfo.self) }

    // MARK: Connectors

    func connectors() async throws -> [ServerAPI.ConnectorInfo] {
        try await send("connectors", as: [ServerAPI.ConnectorInfo].self)
    }

    func updateConnector(_ id: String, _ update: ServerAPI.ConnectorUpdate) async throws -> ServerAPI.ConnectorInfo {
        try await send("connectors/\(id)", method: "PUT", json: update, as: ServerAPI.ConnectorInfo.self)
    }

    func removeConnector(_ id: String) async throws {
        let (data, response) = try await data(for: request("connectors/\(id)", method: "DELETE"))
        _ = try check(data, response, accepting: [204])
    }

    func beginConnectorSignIn(_ id: String) async throws -> ServerAPI.ConnectorSignIn {
        try await send("connectors/\(id)/sign-in", method: "POST", as: ServerAPI.ConnectorSignIn.self)
    }

    func connectorSignInStatus(_ id: String) async throws -> ServerAPI.ConnectorSignInStatus {
        try await send("connectors/\(id)/sign-in", as: ServerAPI.ConnectorSignInStatus.self)
    }

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

    /// Reports the compact copy saved, with the files this iPhone compressed itself so the server
    /// recognises them later.
    func imported(_ assetID: String, deviceCopies: [ServerAPI.CopyHash] = []) async throws {
        _ = try await send("assets/\(assetID)/imported", method: "POST", json: ServerAPI.ImportedRequest(deviceCopies: deviceCopies),
                           as: ServerAPI.AssetStatus.self)
    }

    func verify(_ assetID: String) async throws -> ServerAPI.Verification {
        try await send("assets/\(assetID)/verify", method: "POST", as: ServerAPI.Verification.self)
    }

    /// A recent item was removed on this iPhone before its compact copy: the server moves its
    /// originals to its trash (30 days). Returns false if the server keeps it (it has a copy).
    @discardableResult
    func removedOnDevice(_ assetID: String) async throws -> Bool {
        do {
            _ = try await send("assets/\(assetID)/removed", method: "POST", as: ServerAPI.AssetStatus.self)
            return true
        } catch let failure as Failure where failure.code == ServerAPI.ErrorCode.keptOriginal || failure.status == 404 {
            return false
        }
    }

    /// Devices paired with the server.
    func devices() async throws -> [ServerAPI.DeviceInfo] { try await send("devices", as: [ServerAPI.DeviceInfo].self) }

    /// Renames this device, and its originals folder on the server with it.
    func renameDevice(_ id: String, to name: String) async throws -> ServerAPI.DeviceInfo {
        try await send("devices/\(id)", method: "PATCH", json: ServerAPI.RenameDeviceRequest(name: name), as: ServerAPI.DeviceInfo.self)
    }

    /// Unpairs a device (this one too: it can't use the server afterwards).
    func removeDevice(_ id: String) async throws {
        var request = try request("devices/\(id)", method: "DELETE")
        request.timeoutInterval = 15
        let (data, response) = try await data(for: request)
        _ = try check(data, response, accepting: [204])
    }

    /// Downloads one of an original's files into `directory`, under the name the server sends
    /// (its own name, `IMG_1234.HEIC`; `fallback` from servers that don't send one). Restore Original.
    func downloadOriginalFile(assetID: String, role: ServerAPI.ResourceRole, to directory: URL,
                              fallback: String) async throws -> URL {
        let (temporary, response) = try await download(for: request("assets/\(assetID)/original/\(role.rawValue)"))
        let http = response as? HTTPURLResponse
        guard http?.statusCode == 200 else {
            let data = (try? Data(contentsOf: temporary)) ?? Data()
            _ = try check(data, response, accepting: [200])
            throw Failure(status: http?.statusCode ?? 0, message: "The server didn't send the original.", code: nil)
        }
        let sent = http?.value(forHTTPHeaderField: "Content-Disposition") != nil ? response.suggestedFilename : nil
        // Without a name, at least the right extension (Photos goes by it).
        let typed = response.mimeType.flatMap { UTType(mimeType: $0)?.preferredFilenameExtension }.map { "\(fallback).\($0)" }
        let name = (sent?.isEmpty == false ? sent! : typed ?? fallback).replacingOccurrences(of: "/", with: "_")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: temporary, to: url)
        return url
    }

    /// Downloads an original from the server (for comparing it with its compact copy).
    func downloadOriginal(assetID: String, role: ServerAPI.ResourceRole, to directory: URL, name: String) async throws -> URL {
        let (temporary, response) = try await download(for: request("assets/\(assetID)/original/\(role.rawValue)"))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let data = (try? Data(contentsOf: temporary)) ?? Data()
            _ = try check(data, response, accepting: [200])
            throw Failure(status: status, message: "The server didn't send the original.", code: nil)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: temporary, to: url)
        return url
    }

    /// Where originals are kept on the server, and a move in progress.
    func storage() async throws -> ServerAPI.StorageInfo { try await send("storage", as: ServerAPI.StorageInfo.self) }

    /// Folders on the server's disks the originals could move to.
    func storageLocations() async throws -> [ServerAPI.StorageLocation] {
        try await send("storage/locations", as: [ServerAPI.StorageLocation].self)
    }

    /// Moves every original on the server to `path` (the server copies and checks each one).
    func moveOriginals(to path: String) async throws -> ServerAPI.StorageInfo {
        try await send("storage", method: "PUT", json: ServerAPI.MoveOriginalsRequest(originalsFolder: path),
                       as: ServerAPI.StorageInfo.self)
    }

    /// Which of these SHA-256s are compact copies or originals of items on the server.
    func lookupCopies(_ hashes: [String]) async throws -> [ServerAPI.CopyLookupResponse.Match] {
        try await send("copies/lookup", method: "POST", json: ServerAPI.CopyLookupRequest(sha256: hashes),
                       as: ServerAPI.CopyLookupResponse.self).matches
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
            var request = try request("", method: "PUT")
            request.url = URL(string: baseURL.absoluteString + "/api/v1/assets/\(assetID)/resources/\(role.rawValue)?offset=\(offset)")
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            let (data, response) = try await run(request) { session, request in try await session.upload(for: request, from: chunk) }
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
        let (temporary, response) = try await download(for: request("assets/\(assetID)/compact/\(compact.role.rawValue)"))
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
