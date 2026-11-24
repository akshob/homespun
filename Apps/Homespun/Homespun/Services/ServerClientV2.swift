// SPDX-License-Identifier: Apache-2.0
import Foundation
import HomespunCore

struct BackupUploadPosition: Equatable, Sendable {
    var offset: Int64
    var size: Int64
    var maximumChunkBytes: Int64
}

protocol BackupRemote: Sendable {
    var baseURL: URL { get }
    func capabilities() async throws -> BackupAPI.Capabilities
    func submit(_ request: BackupAPI.Request) async throws -> BackupAPI.Receipt
    func lookup(operationID: UUID) async throws -> [BackupAPI.Receipt]
    func status(_ requestID: UUID) async throws -> BackupAPI.Receipt
    func command(requestID: UUID, _ command: BackupAPI.Command) async throws -> BackupAPI.Receipt
    func admitUpload(_ request: BackupAPI.UploadRequest) async throws -> BackupAPI.UploadAdmission
    func uploadPosition(_ uploadID: UUID) async throws -> BackupUploadPosition
    func append(_ bytes: Data, uploadID: UUID, offset: Int64) async throws -> Int64
    func completeUpload(_ uploadID: UUID) async throws -> BackupAPI.Receipt
    func changes(after cursor: Int64, epoch: String) async throws -> BackupAPI.Changes
    func snapshot(continuation: String?) async throws -> BackupAPI.Snapshot
    /// The caller must capture the returned temporary file into the protected inbox before suspending.
    func download(generation: UUID, resource: ServerAPI.CompactResource) async throws -> URL
    func downloadOriginal(version: BackupAPI.Version, requestID: UUID,
                          resource: ServerAPI.ResourceDescriptor) async throws -> URL
    func verify(_ version: BackupAPI.Version) async throws -> BackupAPI.OriginalProof
    func acknowledge(_ acknowledgement: BackupAPI.DeliveryAcknowledgement) async throws
}

/// Foreground-only v2 requests use the same pre-credential TLS gate, redirect refusal and admitted
/// session lifetime as v1. A captured binding never follows the server currently selected in Settings.
struct ServerClientV2: BackupRemote {
    private let transport: ServerClient
    var baseURL: URL { transport.baseURL }
    static let maximumBufferedChunk = 1 << 20
    static let nativeTransfersAvailable = false

    init(_ client: ServerClient) {
        transport = ServerClient(baseURL: client.baseURL, token: client.token, trust: client.trust,
                                 session: client.session, delegate: client.delegate, reconnect: nil)
    }

    func capabilities() async throws -> BackupAPI.Capabilities {
        let value: BackupAPI.Capabilities = try await json("capabilities")
        guard value.apiVersion == BackupAPI.version else {
            throw Self.failure("Update Homespun Server before using the durable backup queue.")
        }
        _ = try value.recipe.identifier()
        return value
    }

    func submit(_ request: BackupAPI.Request) async throws -> BackupAPI.Receipt {
        try await json("backup-requests", method: "POST", body: request)
    }

    func lookup(operationID: UUID) async throws -> [BackupAPI.Receipt] {
        try await json("backup-requests", query: [.init(name: "operation_id", value: operationID.uuidString)])
    }

    func status(_ requestID: UUID) async throws -> BackupAPI.Receipt {
        try await json("backup-requests/\(requestID.uuidString)")
    }

    func command(requestID: UUID, _ command: BackupAPI.Command) async throws -> BackupAPI.Receipt {
        try await json("backup-requests/\(requestID.uuidString)/commands", method: "POST", body: command)
    }

    func admitUpload(_ request: BackupAPI.UploadRequest) async throws -> BackupAPI.UploadAdmission {
        let result: BackupAPI.UploadAdmission = try await json("uploads", method: "POST", body: request)
        guard result.upload == request, result.uploadProtocol == .foregroundOffset,
              result.offset >= 0, result.offset <= result.size, result.size > 0, result.maximumChunkBytes > 0 else {
            throw Self.failure("The server returned an invalid upload admission.")
        }
        return result
    }

    func uploadPosition(_ uploadID: UUID) async throws -> BackupUploadPosition {
        let request = try transport.request("uploads/\(uploadID.uuidString)", method: "HEAD", apiVersion: 2)
        let (data, response) = try await transport.data(for: request)
        _ = try transport.check(data, response, accepting: [200, 204])
        guard let response = response as? HTTPURLResponse,
              let offset = Self.integer("Upload-Offset", response),
              let size = Self.integer("Upload-Length", response),
              let chunk = Self.integer("Upload-Max-Chunk", response),
              offset >= 0, size > 0, offset <= size, chunk > 0 else {
            throw Self.failure("The server returned an invalid upload offset.")
        }
        return .init(offset: offset, size: size, maximumChunkBytes: chunk)
    }

    func append(_ bytes: Data, uploadID: UUID, offset: Int64) async throws -> Int64 {
        guard !bytes.isEmpty, bytes.count <= Self.maximumBufferedChunk, offset >= 0,
              offset <= Int64.max - Int64(bytes.count) else {
            throw Self.failure("The upload chunk exceeds its bounded foreground allowance.")
        }
        var request = try transport.request("uploads/\(uploadID.uuidString)", method: "PATCH", apiVersion: 2)
        request.setValue("application/offset+octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(String(offset), forHTTPHeaderField: "Upload-Offset")
        let (data, response) = try await transport.run(request) {
            try await $0.upload(for: $1, from: bytes)
        }
        _ = try transport.check(data, response, accepting: [200, 204])
        guard let response = response as? HTTPURLResponse, let received = Self.integer("Upload-Offset", response),
              received == offset + Int64(bytes.count) else { throw Self.failure("The server did not acknowledge this upload chunk.") }
        return received
    }

    func completeUpload(_ uploadID: UUID) async throws -> BackupAPI.Receipt {
        try await json("uploads/\(uploadID.uuidString)/complete", method: "POST")
    }

    func changes(after cursor: Int64, epoch: String) async throws -> BackupAPI.Changes {
        try await json("changes", query: [.init(name: "after", value: String(cursor)), .init(name: "epoch", value: epoch)])
    }

    func snapshot(continuation: String?) async throws -> BackupAPI.Snapshot {
        try await json("snapshot", query: continuation.map { [.init(name: "continuation", value: $0)] } ?? [])
    }

    func download(generation: UUID, resource: ServerAPI.CompactResource) async throws -> URL {
        let request = try transport.request("derivatives/\(generation.uuidString)/resources/\(resource.role.rawValue)", apiVersion: 2)
        let (file, response) = try await transport.download(for: request)
        do {
            _ = try transport.check(Data(), response, accepting: [200])
            guard let http = response as? HTTPURLResponse, let etag = http.value(forHTTPHeaderField: "ETag"),
                  !etag.hasPrefix("W/"), etag == "\"\(resource.sha256.lowercased())\"",
                  try PhotoLibrary.size(of: file) == resource.size, resource.size > 0 else {
                throw Self.failure("The downloaded compact resource does not match its immutable generation.")
            }

            func downloadOriginal(version: BackupAPI.Version, requestID: UUID,
                                  resource: ServerAPI.ResourceDescriptor) async throws -> URL {
                let request = try transport.request(
                    "assets/\(version.assetID)/versions/\(version.manifestID)/resources/\(resource.role.rawValue)",
                    apiVersion: 2, query: [.init(name: "request_id", value: requestID.uuidString)])
                let (file, response) = try await transport.download(for: request)
                do {
                    _ = try transport.check(Data(), response, accepting: [200])
                    guard let response = response as? HTTPURLResponse,
                          response.value(forHTTPHeaderField: "ETag") == "\"\(resource.sha256.lowercased())\"",
                          resource.size > 0, try PhotoLibrary.size(of: file) == resource.size else {
                        throw Self.failure("The downloaded original does not match the retained version.")
                    }
                    return file
                } catch {
                    try? FileManager.default.removeItem(at: file)
                    throw error
                }
            }
            return file
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }

    func verify(_ version: BackupAPI.Version) async throws -> BackupAPI.OriginalProof {
        let proof: BackupAPI.OriginalProof = try await json(
            "assets/\(version.assetID)/versions/\(version.manifestID)/verify", method: "POST", body: version)
        guard proof.version == version else { throw Self.failure("The server verified a different original version.") }
        return proof
    }

    func acknowledge(_ acknowledgement: BackupAPI.DeliveryAcknowledgement) async throws {
        var request = try transport.request("deliveries/\(acknowledgement.deliveryID.uuidString)/ack", method: "POST", apiVersion: 2)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try ServerAPI.encoder.encode(acknowledgement)
        let (data, response) = try await transport.data(for: request)
        _ = try transport.check(data, response, accepting: [200, 204])
    }

    private func json<Value: Decodable>(_ path: String, method: String = "GET",
                                        body: (some Encodable)? = Optional<Int>.none,
                                        query: [URLQueryItem] = []) async throws -> Value {
        var request = try transport.request(path, method: method, apiVersion: 2, query: query)
        if let body {
            request.httpBody = try ServerAPI.encoder.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await transport.data(for: request)
        _ = try transport.check(data, response)
        return try ServerAPI.decoder.decode(Value.self, from: data)
    }

    private static func integer(_ name: String, _ response: HTTPURLResponse) -> Int64? {
        response.value(forHTTPHeaderField: name).flatMap(Int64.init)
    }

    private static func failure(_ message: String) -> ServerClient.Failure {
        .init(status: 0, message: message, code: "backup_protocol")
    }
}
