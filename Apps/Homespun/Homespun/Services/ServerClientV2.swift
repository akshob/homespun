// SPDX-License-Identifier: Apache-2.0
import Foundation
import HomespunCore
import CryptoKit
import Darwin
import Synchronization

private final class ForegroundTaskOwner: Sendable {
    private struct State { var task: URLSessionTask?; var cancelled = false }
    private let state = Mutex(State())
    func install(_ task: URLSessionTask) {
        let cancelled = state.withLock { value in value.task = task; return value.cancelled }
        if cancelled { task.cancel() }
    }
    func cancel() {
        let task = state.withLock { value in value.cancelled = true; return value.task }
        task?.cancel()
    }
    func finish() {
        let task = state.withLock { value in defer { value.task = nil }; return value.task }
        task?.cancel()
    }
}

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
    func download(generation: UUID, resource: ServerAPI.CompactResource, to file: URL) async throws -> HTTPURLResponse
    func downloadOriginal(version: BackupAPI.Version, requestID: UUID,
                          resource: ServerAPI.ResourceDescriptor, to file: URL) async throws -> HTTPURLResponse
    func verify(_ version: BackupAPI.Version) async throws -> BackupAPI.OriginalProof
    func acknowledge(_ acknowledgement: BackupAPI.DeliveryAcknowledgement) async throws
    func enrollWake(_ sender: WakeRelayAPI.Sender) async throws
    func resolveCopy(_ lookup: BackupAPI.CopyLookup) async throws -> BackupAPI.CopyCandidate
    func adoptCopy(_ adoption: BackupAPI.CopyAdoption) async throws -> BackupAPI.Receipt
}

extension BackupRemote {
    func resolveCopy(_ lookup: BackupAPI.CopyLookup) async throws -> BackupAPI.CopyCandidate {
        throw BackupStageFailure.blocked("Update Homespun Server, then run Find Compact Copies again. Existing copies have been kept.")
    }

    func adoptCopy(_ adoption: BackupAPI.CopyAdoption) async throws -> BackupAPI.Receipt {
        throw BackupStageFailure.blocked("This server cannot revalidate existing compact copies. No original has been removed.")
    }

    func enrollWake(_ sender: WakeRelayAPI.Sender) async throws {
        throw BackupStageFailure.blocked("This connection does not support optional wake enrollment.")
    }
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

    func resolveCopy(_ lookup: BackupAPI.CopyLookup) async throws -> BackupAPI.CopyCandidate {
        try await json("copies/resolve", method: "POST", body: lookup)
    }

    func adoptCopy(_ adoption: BackupAPI.CopyAdoption) async throws -> BackupAPI.Receipt {
        try await json("copies/adopt", method: "POST", body: adoption)
    }

    func lookup(operationID: UUID) async throws -> [BackupAPI.Receipt] {
        let receipt: BackupAPI.Receipt
        do {
            receipt = try await json("backup-requests", query: [.init(name: "operation_id", value: operationID.uuidString)])
        } catch let failure as ServerClient.Failure where failure.status == 404 {
            return []
        }
        guard receipt.operationID == operationID else { throw BackupStore.Failure.invalidReceipt }
        return [receipt]
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
        try authenticated()
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
        try authenticated()
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

    func download(generation: UUID, resource: ServerAPI.CompactResource, to file: URL) async throws -> HTTPURLResponse {
        let request = try transport.request("derivatives/\(generation.uuidString)/resources/\(resource.role.rawValue)", apiVersion: 2)
        return try await stream(request, size: resource.size, sha256: resource.sha256, to: file)
    }

    func downloadOriginal(version: BackupAPI.Version, requestID: UUID,
                          resource: ServerAPI.ResourceDescriptor, to file: URL) async throws -> HTTPURLResponse {
        let request = try transport.request(
            "assets/\(version.assetID)/versions/\(version.manifestID)/resources/\(resource.role.rawValue)",
            apiVersion: 2, query: [.init(name: "request_id", value: requestID.uuidString)])
        return try await stream(request, size: resource.size, sha256: resource.sha256, to: file)
    }

    /// No task delegate is replaced: existing TLS/redirect handlers remain authoritative. Only
    /// bounded buffers are written, after headers match the parent-reserved immutable resource.
    private func stream(_ request: URLRequest, size: Int, sha256: String, to file: URL) async throws -> HTTPURLResponse {
        try authenticated()
        guard size > 0, file.isFileURL else { throw Self.failure("Invalid reserved download resource.") }
        let owner = ForegroundTaskOwner()
        return try await withTaskCancellationHandler {
            try await transport.run(request) { session, request in
                let (bytes, response) = try await session.bytes(for: request)
                owner.install(bytes.task)
                defer { owner.finish() }
                _ = try transport.check(Data(), response, accepting: [200])
                guard let response = response as? HTTPURLResponse,
                      response.expectedContentLength == Int64(size),
                      response.value(forHTTPHeaderField: "ETag") == "\"\(sha256.lowercased())\"",
                      response.value(forHTTPHeaderField: "Content-Encoding").map({ $0 == "identity" }) ?? true else {
                    throw Self.failure("The response does not match this immutable resource.")
                }
                try Task.checkCancellation()
                let descriptor = Darwin.open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
                guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
                let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                defer { try? handle.close() }
                try BackupFiles.protect(file)
                var buffer = Data(), received = 0, hash = SHA256()
                buffer.reserveCapacity(64 << 10)
                func write() throws {
                    try Task.checkCancellation()
                    try handle.write(contentsOf: buffer)
                    hash.update(data: buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
                for try await byte in bytes {
                    guard received < size else { throw Self.failure("The resource exceeded its reserved size.") }
                    buffer.append(byte)
                    received += 1
                    if buffer.count == 64 << 10 { try write() }
                }
                if !buffer.isEmpty { try write() }
                guard received == size, hash.finalize().map({ String(format: "%02x", $0) }).joined() == sha256.lowercased() else {
                    throw Self.failure("The complete resource size and SHA-256 did not verify.")
                }
                try handle.synchronize()
                try handle.close()
                return response
            }
        } onCancel: { owner.cancel() }
    }

    func verify(_ version: BackupAPI.Version) async throws -> BackupAPI.OriginalProof {
        let proof: BackupAPI.OriginalProof = try await json(
            "assets/\(version.assetID)/versions/\(version.manifestID)/verify", method: "POST", body: version)
        guard proof.version == version else { throw Self.failure("The server verified a different original version.") }
        return proof
    }

    func acknowledge(_ acknowledgement: BackupAPI.DeliveryAcknowledgement) async throws {
        try authenticated()
        var request = try transport.request("deliveries/\(acknowledgement.deliveryID.uuidString)/ack", method: "POST", apiVersion: 2)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try ServerAPI.encoder.encode(acknowledgement)
        let (data, response) = try await transport.data(for: request)
        _ = try transport.check(data, response, accepting: [200, 204])
    }

    func enrollWake(_ sender: WakeRelayAPI.Sender) async throws {
        try authenticated()
        var request = try transport.request("wake/enrollment", method: "POST", apiVersion: 2)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try ServerAPI.encoder.encode(sender)
        let (data, response) = try await transport.data(for: request)
        _ = try transport.check(data, response, accepting: [204])
        guard let response = response as? HTTPURLResponse,
              response.value(forHTTPHeaderField: "ETag") == "\"\(sender.generationID.uuidString.lowercased())\"" else {
            throw BackupStore.Failure.invalidReceipt
        }
    }

    private func json<Value: Decodable>(_ path: String, method: String = "GET",
                                        body: (some Encodable)? = Optional<Int>.none,
                                        query: [URLQueryItem] = []) async throws -> Value {
        try authenticated()
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

    private func authenticated() throws {
        switch transport.trust {
        case .system: return
        case .pinned(let pins) where !pins.isEmpty: return
        case .demo where baseURL.host == DemoServer.host: return
        default: throw ServerPairing.IdentityFailure()
        }
    }

    private static func failure(_ message: String) -> ServerClient.Failure {
        .init(status: 0, message: message, code: "backup_protocol")
    }
}
