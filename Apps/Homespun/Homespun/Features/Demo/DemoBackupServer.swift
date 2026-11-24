// SPDX-License-Identifier: Apache-2.0
import Foundation
import HomespunCore

/// The demo's remote half of the same v2 graph. Originals become retained independently of
/// processing; bulk changes discover results, with no dependency on an earlier video finishing.
actor DemoBackupServer {
    private struct Record: Codable, Sendable {
        var id: UUID
        var owner: String
        var request: BackupAPI.Request
        var version: BackupAPI.Version
        var claimID: UUID
        var revision: Int64 = 1
        var compact: BackupAPI.CompactState = .requested
        var originals: [ServerAPI.ResourceStatus]
        var derivative: BackupAPI.Derivative?
        var wantsCompact: Bool
        var paused = false
        var cancelled = false
        var readyAfter: Date?
        var message: String?
        var complete: Bool { originals.allSatisfy { $0.state == .verified && $0.receivedBytes == $0.size } }
    }

    private struct Upload: Codable, Sendable {
        var request: BackupAPI.UploadRequest
        var offset: Int64 = 0
        var complete = false
        var failed = false
    }

    private struct FrozenSnapshot: Codable, Sendable {
        var owner: String
        var cursor: Int64
        var receipts: [BackupAPI.Receipt]
        var expires: Date
    }

    private struct AcceptedCommand: Codable, Sendable {
        var command: BackupAPI.Command
        var receipt: BackupAPI.Receipt
    }

    private struct State: Codable, Sendable {
        var origin = BackupAPI.Origin(serverID: UUID().uuidString, historyEpoch: UUID().uuidString)
        var records: [UUID: Record] = [:]
        var uploads: [UUID: Upload] = [:]
        var changes: [BackupAPI.Change] = []
        var commands: [UUID: AcceptedCommand] = [:]
        var acknowledgements: [UUID: BackupAPI.DeliveryAcknowledgement] = [:]
        var snapshots: [UUID: FrozenSnapshot] = [:]
        var sequence: Int64 = 0
        var generation: Int64 = 0
    }

    private let folder: URL
    private let pace: Double
    private let processingDelay: (@Sendable (ServerAPI.AssetKind) -> TimeInterval)?
    private let bundled: @Sendable (String) -> [ServerAPI.ResourceRole: URL]?
    private var state: State
    private var unreadable = false
    private var retired = false
    private var admitted = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private static let chunk = 1 << 20
    private static let pageSize = 200
    private var stateFile: URL { folder.appendingPathComponent("state.json") }
    private var recipe: BackupAPI.Recipe { .init(profile: .standard, backend: "demo-imageio", pipelineVersion: 2) }

    init(folder: URL, pace: Double, processingDelay: (@Sendable (ServerAPI.AssetKind) -> TimeInterval)? = nil,
         bundled: @escaping @Sendable (String) -> [ServerAPI.ResourceRole: URL]?) {
        self.folder = folder
        self.pace = pace
        self.processingDelay = processingDelay
        self.bundled = bundled
        let file = folder.appendingPathComponent("state.json")
        if FileManager.default.fileExists(atPath: file.path) {
            do { state = try JSONDecoder().decode(State.self, from: Data(contentsOf: file)) }
            catch { state = State(); unreadable = true }
        } else {
            state = State()
        }
    }

    func stopAndWait() async {
        retired = true
        if admitted > 0 { await withCheckedContinuation { waiters.append($0) } }
    }

    func statistics() -> (count: Int, bytes: Int64) {
        var seen = Set<String>(), bytes: Int64 = 0
        for record in state.records.values where record.complete {
            if seen.insert(record.version.manifestID).inserted {
                bytes += record.request.manifest.resources.reduce(0) { $0 + Int64($1.size) }
            }
        }
        return (seen.count, bytes)
    }

    func handle(method: String, url: URL, owner: String, headers: [String: String], body: Data) async -> DemoServer.Response {
        guard !retired, !unreadable else { return DemoServer.error(503, "This demo backup server is unavailable.") }
        admitted += 1
        defer {
            admitted -= 1
            if admitted == 0 {
                let pending = waiters
                waiters = []
                pending.forEach { $0.resume() }
            }
        }
        if pace > 0 { try? await Task.sleep(for: .seconds(0.05 * pace)) }
        guard !retired, !Task.isCancelled else { return DemoServer.error(503, "This demo has ended.") }
        let before = state
        do {
            return try route(method: method, url: url, owner: owner, headers: headers, body: body)
        } catch let failure as DemoServer.Failure {
            state = before
            return DemoServer.error(failure.status, failure.message, code: failure.code)
        } catch {
            state = before
            return DemoServer.error(500, "The demo's durable server progress could not be saved.")
        }
    }

    private func route(method: String, url: URL, owner: String, headers: [String: String], body: Data) throws -> DemoServer.Response {
        let path = Array(url.path.split(separator: "/").dropFirst(2).map(String.init))
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
        func header(_ name: String) -> String? { headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value }
        func decode<Value: Decodable>(_ type: Value.Type) throws -> Value { try ServerAPI.decoder.decode(type, from: body) }

        if method == "GET", path == ["capabilities"] {
            try save()
            return try json(BackupAPI.Capabilities(origin: state.origin, uploadProtocols: [.foregroundOffset], recipe: recipe))
        }
        if path == ["backup-requests"] {
            if method == "POST" {
                return try json(register(decode(BackupAPI.Request.self), owner: owner), status: 201)
            }
            if method == "GET", let operation = value("operation_id").flatMap(UUID.init(uuidString:)) {
                guard let record = state.records.values.first(where: { $0.owner == owner && $0.request.operationID == operation }) else {
                    throw DemoServer.Failure(status: 404, message: "This backup request has not been admitted.")
                }
                return try json(receipt(record))
            }
        }
        if path.count >= 2, path[0] == "backup-requests", let id = UUID(uuidString: path[1]) {
            let record = try record(id, owner: owner)
            if method == "GET", path.count == 2 { return try json(receipt(record)) }
            if method == "POST", path.count == 3, path[2] == "commands" {
                return try json(command(decode(BackupAPI.Command.self), record: record))
            }
        }
        if method == "POST", path == ["uploads"] {
            let request = try decode(BackupAPI.UploadRequest.self)
            let record = try record(request.requestID, owner: owner)
            guard record.version == request.version,
                  let resource = record.request.manifest.resources.first(where: { $0.role == request.role }) else { throw conflict() }
            if let old = state.uploads[request.uploadID] {
                guard old.request == request else { throw conflict() }
            } else {
                state.uploads[request.uploadID] = Upload(request: request)
                try save()
            }
            let upload = state.uploads[request.uploadID]!
            return try json(BackupAPI.UploadAdmission(upload: request, uploadProtocol: .foregroundOffset,
                offset: upload.offset, size: Int64(resource.size), maximumChunkBytes: Int64(Self.chunk)), status: 201)
        }
        if path.count >= 2, path[0] == "uploads", let id = UUID(uuidString: path[1]), let upload = state.uploads[id] {
            let record = try record(upload.request.requestID, owner: owner)
            guard upload.request.version == record.version,
                  let resource = record.request.manifest.resources.first(where: { $0.role == upload.request.role }) else { throw conflict() }
            if method == "HEAD", path.count == 2 {
                return .init(status: 204, headers: ["Upload-Offset": String(upload.offset),
                    "Upload-Length": String(resource.size), "Upload-Max-Chunk": String(Self.chunk)])
            }
            if method == "PATCH", path.count == 2 {
                guard header("Content-Type") == "application/offset+octet-stream",
                      header("Upload-Offset").flatMap(Int64.init) == upload.offset,
                      !upload.complete, !upload.failed else { throw conflict() }
                guard !body.isEmpty, body.count <= Self.chunk,
                      upload.offset <= Int64(resource.size) - Int64(body.count) else {
                    throw DemoServer.Failure(status: 413, message: "The upload exceeds its declared size.")
                }
                try append(body, to: upload, id: id)
                return .init(status: 204, headers: ["Upload-Offset": String(state.uploads[id]!.offset)])
            }
            if method == "POST", path.count == 3, path[2] == "complete" {
                return try json(complete(upload, id: id, record: record, resource: resource))
            }
        }
        if method == "GET", path == ["changes"] {
            guard value("epoch") == state.origin.historyEpoch else {
                throw DemoServer.Failure(status: 409, message: "The history epoch changed.", code: BackupAPI.ErrorCode.historyChanged)
            }
            guard let after = value("after").flatMap(Int64.init), after >= 0, after <= state.sequence else {
                throw DemoServer.Failure(status: 409, message: "Take a consistent snapshot.", code: BackupAPI.ErrorCode.snapshotRequired)
            }
            try advanceProcessing()
            let available = state.changes.filter { change in
                change.sequence > after && state.records[change.receipt.requestID]?.owner == owner
            }
            let page = Array(available.prefix(Self.pageSize)), more = available.count > page.count
            return try json(BackupAPI.Changes(origin: state.origin, cursor: more ? page.last!.sequence : state.sequence,
                                             hasMore: more, changes: page))
        }
        if method == "GET", path == ["snapshot"] {
            try advanceProcessing()
            return try json(snapshot(owner: owner, continuation: value("continuation")))
        }
        if path.count == 4, path[0] == "derivatives", path[2] == "resources", method == "GET",
           let generation = UUID(uuidString: path[1]), let role = ServerAPI.ResourceRole(rawValue: path[3]),
           let record = state.records.values.first(where: { $0.owner == owner && $0.derivative?.generationID == generation }),
           let resource = record.derivative?.resources.first(where: { $0.role == role }) {
            return try fileResponse(derivativeFile(generation, role), expected: resource.sha256, size: resource.size,
                                    filename: resource.filename, range: header("Range"), ifRange: header("If-Range"))
        }
        if path.count >= 5, path[0] == "assets", path[2] == "versions" {
            if method == "POST", path.count == 5, path[4] == "verify" {
                let version = try decode(BackupAPI.Version.self)
                guard version.assetID == path[1], version.manifestID == path[3],
                      let record = state.records.values.first(where: { $0.owner == owner && $0.version == version }) else { throw conflict() }
                return try json(proof(record))
            }
            if method == "GET", path.count == 6, path[4] == "resources",
               let id = value("request_id").flatMap(UUID.init(uuidString:)),
               let role = ServerAPI.ResourceRole(rawValue: path[5]) {
                let record = try record(id, owner: owner)
                guard record.version.assetID == path[1], record.version.manifestID == path[3],
                      record.complete, let resource = record.request.manifest.resources.first(where: { $0.role == role }) else { throw conflict() }
                return try fileResponse(originalFile(record, role), expected: resource.sha256, size: resource.size,
                                        filename: resource.filename, range: header("Range"), ifRange: header("If-Range"))
            }
        }
        if method == "POST", path.count == 3, path[0] == "deliveries", path[2] == "ack",
           let id = UUID(uuidString: path[1]) {
            let acknowledgement = try decode(BackupAPI.DeliveryAcknowledgement.self)
            let record = try record(acknowledgement.requestID, owner: owner)
            guard id == acknowledgement.deliveryID, acknowledgement.version == record.version,
                  acknowledgement.generationID == record.derivative?.generationID else { throw conflict() }
            if let old = state.acknowledgements[id] { guard old == acknowledgement else { throw conflict() } }
            state.acknowledgements[id] = acknowledgement
            try save()
            return .init(status: 204)
        }
        throw DemoServer.Failure(status: 404, message: "Unknown v2 demo operation.")
    }

    private func register(_ request: BackupAPI.Request, owner: String) throws -> BackupAPI.Receipt {
        _ = try request.manifest.validated()
        guard request.origin == state.origin, request.profile == recipe.profile else { throw conflict() }
        if let old = state.records.values.first(where: { $0.owner == owner && $0.request.operationID == request.operationID }) {
            guard old.request == request else {
                throw DemoServer.Failure(status: 409, message: "This operation already has a different immutable request.",
                                         code: BackupAPI.ErrorCode.idempotencyConflict)
            }
            return receipt(old)
        }
        guard state.generation < Int64.max else { throw conflict() }
        state.generation += 1
        let version = BackupAPI.Version(origin: state.origin, assetID: try request.manifest.assetID(),
            manifestID: try request.manifest.identifier(), descriptorGeneration: state.generation,
            recipeID: try BackupAPI.Recipe(profile: request.profile, backend: recipe.backend,
                                          pipelineVersion: recipe.pipelineVersion).identifier())
        let original = request.manifest.resources.map {
            ServerAPI.ResourceStatus(role: $0.role, sha256: $0.sha256, size: $0.size, state: .missing,
                                     receivedBytes: 0, verifiedAt: nil)
        }
        var record = Record(id: UUID(), owner: owner, request: request, version: version, claimID: UUID(),
                            originals: original, wantsCompact: request.compact)
        for index in record.originals.indices {
            let resource = record.request.manifest.resources[index], file = originalFile(record, resource.role)
            if FileManager.default.fileExists(atPath: file.path),
               try PhotoLibrary.size(of: file) == resource.size, try Fingerprint.sha256(of: file) == resource.sha256.lowercased() {
                record.originals[index].state = .verified
                record.originals[index].receivedBytes = resource.size
                record.originals[index].verifiedAt = Date()
            }
        }
        schedule(&record)
        try publish(record)
        return receipt(record)
    }

    private func append(_ data: Data, to supplied: Upload, id: UUID) throws {
        var upload = supplied
        let file = uploadFile(id)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if upload.offset == 0 { guard FileManager.default.createFile(atPath: file.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) } }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(upload.offset))
        try handle.write(contentsOf: data)
        upload.offset += Int64(data.count)
        try handle.truncate(atOffset: UInt64(upload.offset))
        try handle.synchronize()
        try handle.close()
        state.uploads[id] = upload
        try save()
    }

    private func complete(_ supplied: Upload, id: UUID, record suppliedRecord: Record,
                          resource: ServerAPI.ResourceDescriptor) throws -> BackupAPI.Receipt {
        if supplied.complete { return receipt(suppliedRecord) }
        var upload = supplied, record = suppliedRecord
        guard upload.offset == Int64(resource.size) else { throw conflict() }
        let staged = uploadFile(id), original = originalFile(record, resource.role)
        let source = FileManager.default.fileExists(atPath: staged.path) ? staged : original
        guard try PhotoLibrary.size(of: source) == resource.size,
              try Fingerprint.sha256(of: source) == resource.sha256.lowercased() else {
            throw DemoServer.Failure(status: 422, message: "This upload's full SHA-256 did not match. Start a new upload.")
        }
        if source == staged {
            try FileManager.default.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: original.path) {
                guard try Fingerprint.sha256(of: original) == resource.sha256.lowercased() else { throw conflict() }
            } else {
                try FileManager.default.moveItem(at: staged, to: original)
            }
        }
        upload.complete = true
        state.uploads[id] = upload
        guard let index = record.originals.firstIndex(where: { $0.role == resource.role }) else { throw conflict() }
        record.originals[index].state = .verified
        record.originals[index].receivedBytes = resource.size
        record.originals[index].verifiedAt = Date()
        schedule(&record)
        try publish(record)
        return receipt(state.records[record.id]!)
    }

    private func schedule(_ record: inout Record) {
        if record.complete, record.wantsCompact, !record.paused, !record.cancelled, record.derivative == nil {
            record.compact = .queued
            let delay = processingDelay?(record.request.manifest.kind) ?? (record.request.manifest.kind == .video ? 3 : 0.1) * pace
            record.readyAfter = record.readyAfter ?? Date().addingTimeInterval(delay)
        }
    }

    private func advanceProcessing() throws {
        let records = state.records.values.filter { $0.complete && $0.wantsCompact && !$0.paused && !$0.cancelled && $0.derivative == nil }
            .sorted { ($0.request.manifest.kind == .video ? 1 : 0) < ($1.request.manifest.kind == .video ? 1 : 0) }
        for var record in records where record.compact == .queued || record.compact == .processing {
            if record.compact == .queued { record.compact = .processing; try publish(record) }
            guard record.readyAfter.map({ $0 <= Date() }) == true else { continue }
            do {
                let generation = UUID(), resources = try makeCompact(record, generation: generation)
                if resources.reduce(0, { $0 + $1.size }) >= record.request.manifest.resources.reduce(0, { $0 + $1.size }) {
                    record.compact = .held
                    record.message = "Already compact. The byte-identical original stays on the server."
                } else {
                    record.compact = .ready
                    record.derivative = .init(generationID: generation, version: record.version, resources: resources)
                }
            } catch {
                record.compact = .failed
                record.message = "This demo compact copy could not be made. The verified original remains retained."
            }
            try publish(record)
        }
    }

    private func makeCompact(_ record: Record, generation: UUID) throws -> [ServerAPI.CompactResource] {
        let primary = try record.request.manifest.assetID()
        let directory = folder.appendingPathComponent("derivatives/\(generation.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let bundled = bundled(primary) {
            return try bundled.sorted(by: { $0.key.rawValue < $1.key.rawValue }).map { role, source in
                let file = derivativeFile(generation, role)
                try FileManager.default.copyItem(at: source, to: file)
                return try describe(file, role: role, filename: source.lastPathComponent)
            }
        }
        guard record.request.manifest.kind == .photo,
              let resource = record.request.manifest.resources.first(where: { $0.role == .photo }) else {
            throw DemoServer.Failure(status: 422, message: "This demo media has no validated derivative.")
        }
        let current = record.request.manifest.resources.contains(where: { $0.role == .fullSizePhoto }) ? ServerAPI.ResourceRole.fullSizePhoto : .photo
        let file = derivativeFile(generation, .photo)
        try DemoServer.shrink(originalFile(record, current), to: file, maxEdge: record.request.profile.photoMaxEdge)
        return [try describe(file, role: .photo, filename: (resource.filename as NSString).deletingPathExtension
                             + (DemoServer.writesHEIC ? ".HEIC" : ".JPG"))]
    }

    private func command(_ command: BackupAPI.Command, record supplied: Record) throws -> BackupAPI.Receipt {
        guard command.version == supplied.version else { throw conflict() }
        if let old = state.commands[command.operationID] {
            guard old.command == command else { throw conflict() }
            return old.receipt
        }
        var record = supplied
        switch command.action {
        case .pause: record.paused = true
        case .cancel:
            record.cancelled = true
            if record.derivative == nil { record.compact = .held; record.message = "The compact copy was cancelled. The original is retained." }
        case .retry:
            record.paused = false; record.cancelled = false
            if record.derivative == nil { record.compact = .requested; record.readyAfter = nil; record.message = nil; schedule(&record) }
        case .compactNow:
            record.wantsCompact = true
            record.paused = false; record.cancelled = false
            schedule(&record)
        }
        try publish(record, persist: false)
        let accepted = receipt(state.records[record.id]!)
        state.commands[command.operationID] = .init(command: command, receipt: accepted)
        try save()
        return accepted
    }

    private func proof(_ record: Record) throws -> BackupAPI.OriginalProof {
        guard record.complete else { throw conflict() }
        var verified: [ServerAPI.ResourceStatus] = []
        for resource in record.request.manifest.resources {
            let file = originalFile(record, resource.role)
            guard try PhotoLibrary.size(of: file) == resource.size,
                  try Fingerprint.sha256(of: file) == resource.sha256.lowercased() else { throw conflict() }
            verified.append(.init(role: resource.role, sha256: resource.sha256, size: resource.size,
                                  state: .verified, receivedBytes: resource.size, verifiedAt: Date()))
        }
        return .init(version: record.version, retention: record.request.retention == .permanent ? .permanent : .deferred,
                     claimID: record.request.retention == .permanent ? record.claimID : nil, verifiedAt: Date(), resources: verified)
    }

    private func snapshot(owner: String, continuation: String?) throws -> BackupAPI.Snapshot {
        let id: UUID, offset: Int
        if let continuation {
            let parts = continuation.split(separator: ".")
            guard parts.count == 2, let key = UUID(uuidString: String(parts[0])), let position = Int(parts[1]),
                  let snapshot = state.snapshots[key], snapshot.owner == owner, snapshot.expires > Date(),
                  position >= 0, position <= snapshot.receipts.count else {
                throw DemoServer.Failure(status: 409, message: "The snapshot expired.", code: BackupAPI.ErrorCode.snapshotRequired)
            }
            id = key; offset = position
        } else {
            id = UUID(); offset = 0
            state.snapshots[id] = .init(owner: owner, cursor: state.sequence,
                receipts: state.records.values.filter { $0.owner == owner }.map(receipt),
                expires: Date().addingTimeInterval(3600))
            try save()
        }
        let snapshot = state.snapshots[id]!, end = min(offset + Self.pageSize, snapshot.receipts.count)
        return .init(origin: state.origin, cursor: snapshot.cursor, receipts: Array(snapshot.receipts[offset..<end]),
                     continuation: end < snapshot.receipts.count ? id.uuidString + "." + String(end) : nil)
    }

    private func fileResponse(_ file: URL, expected: String, size: Int, filename: String,
                              range: String?, ifRange: String?) throws -> DemoServer.Response {
        guard size > 0, try PhotoLibrary.size(of: file) == size, try Fingerprint.sha256(of: file) == expected.lowercased() else {
            throw conflict()
        }
        let etag = "\"\(expected.lowercased())\""
        let data = try Data(contentsOf: file)
        var headers = ["ETag": etag, "Content-Type": DemoServer.mime(filename), "Accept-Ranges": "bytes"]
        if let range, ifRange == nil || ifRange == etag {
            let limits = range.dropFirst("bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
            guard range.hasPrefix("bytes="), limits.count == 2, let start = Int(limits[0]),
                  start >= 0, start < size, let end = limits[1].isEmpty ? size - 1 : Int(limits[1]),
                  end >= start else {
                return .init(status: 416, headers: ["Content-Range": "bytes */\(size)"])
            }
            let last = min(end, size - 1)
            headers["Content-Range"] = "bytes \(start)-\(last)/\(size)"
            headers["Content-Length"] = String(last - start + 1)
            return .init(status: 206, headers: headers, body: Data(data[start...last]))
        }
        headers["Content-Length"] = String(size)
        return .init(status: 200, headers: headers, body: data)
    }

    private func receipt(_ record: Record) -> BackupAPI.Receipt {
        .init(requestID: record.id, operationID: record.request.operationID, version: record.version, revision: record.revision,
              backup: record.complete ? .retained : .uploading, compact: record.compact,
              retention: record.complete ? (record.request.retention == .permanent ? .permanent : .deferred) : .pending,
              originals: record.originals, derivative: record.derivative, message: record.message)
    }

    private func publish(_ supplied: Record, persist: Bool = true) throws {
        var record = supplied
        if let old = state.records[record.id] {
            guard old.revision < Int64.max else { throw conflict() }
            record.revision = old.revision + 1
        }
        guard state.sequence < Int64.max else { throw conflict() }
        state.sequence += 1
        state.records[record.id] = record
        state.changes.append(.init(sequence: state.sequence, receipt: receipt(record)))
        if persist { try save() }
    }

    private func record(_ id: UUID, owner: String) throws -> Record {
        guard let record = state.records[id], record.owner == owner else {
            throw DemoServer.Failure(status: 404, message: "This request doesn't belong to this device.")
        }
        return record
    }

    private func originalFile(_ record: Record, _ role: ServerAPI.ResourceRole) -> URL {
        folder.appendingPathComponent("originals/\(record.version.manifestID)/\(role.rawValue)")
    }
    private func uploadFile(_ id: UUID) -> URL { folder.appendingPathComponent("uploads/\(id.uuidString)") }
    private func derivativeFile(_ id: UUID, _ role: ServerAPI.ResourceRole) -> URL {
        folder.appendingPathComponent("derivatives/\(id.uuidString)/\(role.rawValue)")
    }
    private func describe(_ file: URL, role: ServerAPI.ResourceRole, filename: String) throws -> ServerAPI.CompactResource {
        let digest = try Fingerprint.digests(of: file)
        return .init(role: role, filename: filename, size: digest.size, sha256: digest.sha256)
    }
    private func save() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: stateFile, options: .atomic)
    }
    private func json<Value: Encodable>(_ value: Value, status: Int = 200) throws -> DemoServer.Response {
        .init(status: status, body: try ServerAPI.encoder.encode(value))
    }
    private func conflict() -> DemoServer.Failure {
        .init(status: 409, message: "The original or request version changed.", code: BackupAPI.ErrorCode.versionChanged)
    }
}
