// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import HomespunCore
import HTTPTypes
import Hummingbird
import NIOCore
#if os(Linux)
import Glibc
#else
import Darwin
#endif

enum BackupDurability {
    static func directory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    static func publish(_ url: URL, root: URL,
                        syncDirectory: (URL) throws -> Void = BackupDurability.directory) throws {
        var parent = url.deletingLastPathComponent().standardizedFileURL
        let boundary = root.standardizedFileURL.pathComponents
        guard url.isFileURL, root.isFileURL, !boundary.isEmpty,
              parent.pathComponents.starts(with: boundary) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
        while true {
            let components = parent.pathComponents
            guard components.starts(with: boundary) else { throw CocoaError(.fileWriteInvalidFileName) }
            try syncDirectory(parent)
            // URL equality includes the directory hint/trailing slash. The same
            // filesystem boundary must stop the walk regardless of either hint.
            if components == boundary { return }
            let next = parent.deletingLastPathComponent().standardizedFileURL
            guard next.pathComponents.count < components.count else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
            parent = next
        }
    }
}

private struct BackupErrorEnvelope: RouterMiddleware {
    func handle(_ request: Request, context: HomespunRequestContext,
                next: (Request, HomespunRequestContext) async throws -> Response) async throws -> Response {
        do { return try await next(request, context) }
        catch let error as APIError {
            return try failure(error.message, code: error.code, status: error.status, request: request)
        }
        catch let error as HTTPError {
            var response = try failure(error.body ?? "Request rejected.",
                code: error.status == .conflict ? BackupAPI.ErrorCode.versionChanged : "request_rejected", status: error.status, request: request)
            response.headers.append(contentsOf: error.headers)
            return response
        } catch is DecodingError {
            return try failure("Invalid backup request.", code: "invalid_request", status: .badRequest, request: request)
        } catch is BackupAPI.ValidationError {
            return try failure("Invalid resource manifest or recipe.", code: "invalid_request", status: .badRequest, request: request)
        } catch {
            return try failure("Backup storage is unavailable; retry without releasing originals.",
                code: "storage_unavailable", status: .serviceUnavailable, request: request)
        }
    }

    private func failure(_ message: String, code: String, status: HTTPResponse.Status, request: Request) throws -> Response {
        var response = try json(ServerAPI.ErrorBody(error: .init(message: message, code: code)), status: status)
        if request.method == .head {
            response.body = .init()
            response.headers[.contentLength] = "0"
        }
        return response
    }
}

struct BackupRoutes: Sendable {
    static let offset = HTTPField.Name("Upload-Offset")!
    static let length = HTTPField.Name("Upload-Length")!
    static let chunk = HTTPField.Name("Upload-Max-Chunk")!
    let configuration: ServerConfiguration
    let catalog: Catalog
    let storage: Storage
    let originals: OriginalsStore
    let immich: ImmichState
    let budget: ServerWorkBudget
    var maximumChunk: Int { max(1, min(configuration.maximumChunkBytes, 8 << 20)) }
    var backend: String {
        #if os(macOS)
        Tools.path("ffmpeg") == nil ? "macos-apple-videotoolbox" : "macos-apple-x265"
        #else
        "linux-vips-x265"
        #endif
    }

    func add(to router: Router<HomespunRequestContext>) {
        let api = router.group("api/v2").add(middleware: BackupErrorEnvelope()).add(middleware: DeviceAuthentication(catalog: catalog))
        api.post("wake/enrollment") { request, context in
            guard let relay = configuration.wakeRelayURL else {
                throw APIError(.serviceUnavailable, code: "wake_unavailable", message: "An optional wake relay has not been configured by this server's owner.")
            }
            let bytes = try await request.body.collect(upTo: 4 << 10)
            let data = Data(bytes.readableBytesView)
            guard let keys = (try JSONSerialization.jsonObject(with: data) as? [String: Any]).map({ Set($0.keys) }),
                  keys == ["route_id", "generation_id", "token"] else {
                throw HTTPError(.badRequest, message: "Only an opaque route, generation and scoped sender token are accepted.")
            }
            let sender = try ServerAPI.decoder.decode(WakeRelayAPI.Sender.self, from: data)
            try await catalog.enrollBackupWake(sender, principal: principal(context), relay: relay)
            var headers = HTTPFields()
            headers[.eTag] = "\"\(sender.generationID.uuidString.lowercased())\""
            return Response(status: .noContent, headers: headers)
        }
        api.delete("wake/enrollment") { request, context in
            guard let text = request.headers[.ifMatch],
                  let generation = UUID(uuidString: text.trimmingCharacters(in: CharacterSet(charactersIn: "\""))) else {
                throw HTTPError(.badRequest, message: "Send If-Match with the generation being retired.")
            }
            try await catalog.removeBackupWake(principal: principal(context), expectedGeneration: generation)
            return Response(status: .noContent)
        }
        api.get("capabilities") { _, _ in
            let binding = await immich.backupBinding
            try await catalog.configureBackupExternal(binding)
            return try json(BackupAPI.Capabilities(origin: try await catalog.backupOrigin(),
                uploadProtocols: await immich.mode == .files ? [.foregroundOffset] : [],
                recipe: .init(profile: configuration.profile, backend: backend, pipelineVersion: 2),
                externalVerification: binding == nil ? nil : .fullResourceScrub))
        }
        api.post("backup-requests") { request, context in
            let body = try await decode(BackupAPI.Request.self, request)
            let manifest = try body.manifest.validated()
            guard manifest.resources.allSatisfy({ !$0.filename.isEmpty && $0.filename.utf8.count <= 255
                && ($0.sha1.map(Validation.isSHA1) ?? true) }) else { throw HTTPError(.badRequest) }
            for resource in manifest.resources {
                if try await catalog.madeCopy(sha256: resource.sha256.lowercased()) != nil {
                    throw APIError(.unprocessableContent, code: ServerAPI.ErrorCode.compactCopy,
                                   message: "This is a compact copy; its retained original must not be registered as a new selection.")
                }
            }
            let selectedRecipe = try self.recipe(body.profile)
            let external = await immich.mode != .files
            if external { try BackupExternal.validate(manifest) }
            try await catalog.configureBackupExternal(await immich.backupBinding)
            let (receipt, created) = try await catalog.admitBackup(body, principal: principal(context), recipe: selectedRecipe,
                                                                   external: external)
            return try json(receipt, status: created ? .created : .ok)
        }
        api.get("backup-requests") { request, context in
            guard let text: String = request.uri.queryParameters.get("operation_id"), let operation = UUID(uuidString: text) else {
                throw HTTPError(.badRequest, message: "Supply operation_id.")
            }
            return try json(try await catalog.findBackup(operation: operation, principal: principal(context)))
        }
        api.get("backup-requests/:id") { _, context in
            try json(try await catalog.backupReceipt(uuid(context, "id"), principal: principal(context)))
        }
        api.get("backup-requests/:id/copies") { _, context in
            let row = try await catalog.backupRequestRow(uuid(context, "id"), principal: principal(context))
            var result: [String: ServerAPI.ConnectorCounts] = [:]
            for connector in try await catalog.backupCopyConnectorIDs(row["manifest_id"]!.string!) {
                result[connector] = try await catalog.versionedCopyCounts(connector: connector, manifest: row["manifest_id"]!.string!)
            }
            return try json(result)
        }
        api.post("backup-requests/:id/commands") { request, context in
            let body = try await decode(BackupAPI.Command.self, request)
            return try json(try await catalog.commandBackup(uuid(context, "id"), principal: principal(context), command: body))
        }
        api.post("uploads") { request, context in
            guard await immich.mode == .files else { throw unsupported("Versioned original acquisition from Immich is not supported.") }
            let body = try await decode(BackupAPI.UploadRequest.self, request)
            let upload = try await catalog.createBackupUpload(body, principal: principal(context),
                staging: storage.staging, originalRoot: await originals.root,
                maximumStaging: configuration.maximumStagingBytes, minimumFree: configuration.minimumFreeBytes)
            return try json(admission(upload), status: .created)
        }
        api.head("uploads/:id") { _, context in
            let id = try uuid(context, "id"), principal = try self.principal(context)
            return try await catalog.mutations.withClaim("v2-upload/" + id) {
                let upload = try await catalog.backupUpload(id, principal: principal)
                guard upload.state == "open" || upload.state == "verified" else { throw HTTPError(.conflict) }
                try reconcile(upload)
                var headers = HTTPFields()
                headers[Self.offset] = String(upload.offset)
                headers[Self.length] = String(upload.object.size)
                headers[Self.chunk] = String(maximumChunk)
                headers[.cacheControl] = "no-store"
                return Response(status: .noContent, headers: headers)
            }
        }
        api.patch("uploads/:id") { request, context in try await patch(request, context) }
        api.post("uploads/:id/complete") { _, context in try await complete(context) }
        api.get("changes") { request, context in
            guard let after = request.uri.queryParameters.get("after", as: Int64.self),
                  let epoch: String = request.uri.queryParameters.get("epoch") else { throw HTTPError(.badRequest) }
            return try json(try await catalog.backupChanges(principal: principal(context), after: after, epoch: epoch, limit: 200))
        }
        api.get("snapshot") { request, context in
            let continuation: String? = request.uri.queryParameters.get("continuation")
            return try json(try await catalog.backupSnapshot(principal: principal(context), continuation: continuation, limit: 200))
        }
        api.get("derivatives/:id/resources/:role") { request, context in try await download(request, context) }
        api.get("assets/:asset/versions/:manifest/resources/:role") { request, context in
            guard let requestID: String = request.uri.queryParameters.get("request_id"),
                  let id = UUID(uuidString: requestID),
                  let role = Role(rawValue: try context.parameters.require("role")) else { throw HTTPError(.badRequest) }
            let principal = try self.principal(context)
            let version = try await catalog.backupVersion(id.uuidString.lowercased(), principal: principal)
            guard version.assetID == (try context.parameters.require("asset")),
                  version.manifestID == (try context.parameters.require("manifest")) else {
                throw APIError(.conflict, code: BackupAPI.ErrorCode.versionChanged, message: "The source version does not match this request.")
            }
            let source = try await catalog.backupRequestRow(id.uuidString.lowercased(), principal: principal)
            if source["source"]?.string == "external" {
                guard let client = await immich.client, let binding = await immich.backupBinding,
                      source["source_binding"]?.string == binding else { throw HTTPError(.conflict) }
                return try await budget.run(.externalFetch) {
                    let manifest = try await catalog.backupManifest(version.manifestID)
                    try externalSpace(manifest)
                    let directory = storage.cache("external-fetch-" + UUID().uuidString.lowercased())
                    do {
                        let files = try await BackupExternal.fetch(manifest, client: client, directory: directory, roles: [role])
                        guard await immich.backupBinding == binding, let file = files.first else { throw HTTPError(.conflict) }
                        var response = try ranged(request, reader: OriginalReader(URL(fileURLWithPath: file.path), cleanupDirectory: directory),
                                                  size: file.size, hash: file.sha256)
                        response.headers[.contentType] = Routes.mediaType(file.filename)
                        response.headers[.contentDisposition] = Routes.contentDisposition(file.filename)
                        return response
                    } catch { try? FileManager.default.removeItem(at: directory); throw error }
                }
            }
            return try await originals.place { root in
                guard let object = try await catalog.backupObjects(version.manifestID).first(where: { $0.role == role }),
                      let path = object.path, let url = OriginalsStore.resolve(path, in: root),
                      try JobRunner.size(of: url) == object.size else { throw HTTPError(.notFound) }
                var response = try ranged(request, reader: OriginalReader(url), size: object.size, hash: object.sha256)
                response.headers[.contentType] = Routes.mediaType(object.filename)
                response.headers[.contentDisposition] = Routes.contentDisposition(object.filename)
                return response
            }
        }
        api.post("deliveries/:id/ack") { request, context in
            let ack = try await decode(BackupAPI.DeliveryAcknowledgement.self, request)
            guard ack.deliveryID.uuidString.lowercased() == (try uuid(context, "id")) else { throw HTTPError(.badRequest) }
            return try json(try await catalog.acknowledgeBackup(ack, principal: principal(context)))
        }
        api.post("assets/:asset/versions/:manifest/verify") { request, context in
            let expected = try await decode(BackupAPI.Version.self, request)
            let asset = try context.parameters.require("asset"), manifest = try context.parameters.require("manifest")
            guard Validation.isSHA256(asset), Validation.isSHA256(manifest) else { throw HTTPError(.badRequest) }
            let principal = try self.principal(context)
            guard expected.assetID == asset, expected.manifestID == manifest else {
                throw APIError(.conflict, code: BackupAPI.ErrorCode.versionChanged, message: "The expected version and verification URL differ.")
            }
            if let client = await immich.client, let binding = await immich.backupBinding,
               (try? await catalog.externalProofRequest(expected, principal: principal, binding: binding)) != nil {
                return try await budget.run(.externalProof) {
                    let definition = try await catalog.backupManifest(manifest)
                    try externalSpace(definition)
                    let directory = storage.cache("external-scrub-" + UUID().uuidString.lowercased())
                    defer { try? FileManager.default.removeItem(at: directory) }
                    let files = try await BackupExternal.fetch(definition, client: client, directory: directory)
                    guard await immich.backupBinding == binding else { throw HTTPError(.conflict) }
                    try await catalog.externalProofRequest(expected, principal: principal, binding: binding)
                    return try json(BackupAPI.OriginalProof(version: expected, retention: .external, claimID: nil,
                        verifiedAt: Date(), resources: files.map {
                            .init(role: $0.role, sha256: $0.sha256, size: $0.size, state: .verified,
                                  receivedBytes: $0.size, verifiedAt: Date())
                        }))
                }
            }
            return try await budget.run(.verification) {
                let claim = try await catalog.backupProofClaim(asset: asset, manifest: manifest, version: expected, principal: principal)
                let resources = try await originals.place { root in
                    var verified: [ServerAPI.ResourceStatus] = []
                    for object in try await catalog.backupObjects(manifest) {
                        guard let path = object.path, Trash.restored(path) == nil,
                              let url = OriginalsStore.resolve(path, in: root) else { throw HTTPError(.conflict) }
                        let check = try await detached { try Fingerprint.digests(of: url) }
                        guard check.sha256 == object.sha256, check.size == object.size else {
                            throw APIError(.conflict, code: BackupAPI.ErrorCode.versionChanged, message: "An original is missing or changed.")
                        }
                        verified.append(.init(role: object.role, sha256: object.sha256, size: object.size,
                                              state: .verified, receivedBytes: object.size, verifiedAt: Date()))
                    }
                    return verified
                }
                _ = try await catalog.backupProofClaim(asset: asset, manifest: manifest, version: expected, principal: principal)
                return try json(BackupAPI.OriginalProof(version: expected, retention: .permanent, claimID: claim,
                                                       verifiedAt: Date(), resources: resources))
            }
        }
    }

    private func recipe(_ profile: CompressionProfile) throws -> BackupAPI.Recipe {
        let recipe = BackupAPI.Recipe(profile: profile, backend: backend, pipelineVersion: 2)
        _ = try recipe.identifier()
        guard profile.photoMaxEdge <= configuration.profile.photoMaxEdge,
              profile.photoQuality <= configuration.profile.photoQuality,
              profile.videoLongEdge <= configuration.profile.videoLongEdge,
              profile.videoShortEdge <= configuration.profile.videoShortEdge,
              profile.videoCRF >= configuration.profile.videoCRF,
              profile.audioBitrateKbps <= configuration.profile.audioBitrateKbps else {
            throw unsupported("The requested recipe exceeds this server's configured resource/quality limits.")
        }
        return recipe
    }

    private func externalSpace(_ manifest: BackupAPI.Manifest) throws {
        let bytes = try StorageBytes.sum(manifest.resources.map(\.size))
        guard bytes <= configuration.maximumStagingBytes, let free = OriginalsStore.space(at: storage.root.path).free,
              free >= configuration.minimumFreeBytes, bytes <= free - configuration.minimumFreeBytes else {
            throw APIError(.serviceUnavailable, code: "storage_backpressure", message: "Insufficient capacity for a full external byte scrub.")
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ request: Request) async throws -> T {
        let body = try await request.body.collect(upTo: 512 << 10)
        return try ServerAPI.decoder.decode(type, from: Data(body.readableBytesView))
    }

    private func principal(_ context: HomespunRequestContext) throws -> String {
        guard let id = context.deviceID else { throw HTTPError(.unauthorized) }
        return id
    }

    private func uuid(_ context: HomespunRequestContext, _ parameter: String) throws -> String {
        guard let id = UUID(uuidString: try context.parameters.require(parameter)) else { throw HTTPError(.badRequest) }
        return id.uuidString.lowercased()
    }

    private func unsupported(_ message: String) -> APIError {
        APIError(.unprocessableContent, code: "unsupported", message: message)
    }

    private func partial(_ id: String) -> URL { storage.staging.appendingPathComponent("v2-" + id + ".partial") }

    private func admission(_ upload: BackupUpload) -> BackupAPI.UploadAdmission {
        .init(upload: .init(uploadID: UUID(uuidString: upload.id)!, requestID: UUID(uuidString: upload.request)!,
                            version: upload.version, role: upload.object.role),
              uploadProtocol: .foregroundOffset, offset: upload.offset, size: Int64(upload.object.size),
              maximumChunkBytes: Int64(maximumChunk))
    }

    private func reconcile(_ upload: BackupUpload) throws {
        if upload.state == "verified" { return }
        let file = partial(upload.id)
        guard FileManager.default.fileExists(atPath: file.path) else {
            guard upload.offset == 0 else { throw HTTPError(.serviceUnavailable, message: "Durably acknowledged upload bytes are missing; storage needs repair.") }
            return
        }
        let size = try JobRunner.size(of: file)
        guard size >= upload.offset else { throw HTTPError(.serviceUnavailable, message: "The upload staging file lost acknowledged bytes.") }
        if size > upload.offset {
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.truncate(atOffset: UInt64(upload.offset))
            try handle.synchronize()
        }
    }

    private func patch(_ request: Request, _ context: HomespunRequestContext) async throws -> Response {
        guard request.headers[.contentType]?.lowercased() == "application/offset+octet-stream",
              let text = request.headers[Self.offset], let offset = Int64(text), offset >= 0 else {
            throw HTTPError(.badRequest, message: "PATCH requires Upload-Offset and application/offset+octet-stream.")
        }
        let id = try uuid(context, "id"), principal = try self.principal(context)
        return try await catalog.mutations.withClaim("v2-upload/" + id) {
            try await budget.run(.transfer) {
                let upload = try await catalog.backupUpload(id, principal: principal)
                guard upload.state == "open", upload.offset == offset else {
                    var headers = HTTPFields()
                    headers[Self.offset] = String(upload.offset)
                    throw HTTPError(.conflict, headers: headers, message: "The upload offset or state changed; issue HEAD before retrying.")
                }
                try reconcile(upload)
                let file = partial(id)
                if !FileManager.default.fileExists(atPath: file.path) {
                    guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                        throw HTTPError(.serviceUnavailable)
                    }
                    try BackupDurability.directory(storage.staging)
                }
                let handle = try FileHandle(forWritingTo: file)
                defer { try? handle.close() }
                var written: Int64 = 0
                do {
                    try handle.seek(toOffset: UInt64(offset))
                    for try await buffer in request.body {
                        guard buffer.readableBytes <= maximumChunk - Int(written),
                              Int64(buffer.readableBytes) <= Int64(upload.object.size) - offset - written else {
                            throw HTTPError(.contentTooLarge)
                        }
                        try handle.write(contentsOf: Data(buffer.readableBytesView))
                        written += Int64(buffer.readableBytes)
                    }
                    guard written > 0 else { throw HTTPError(.badRequest) }
                    try handle.synchronize()
                    try await catalog.advanceBackupUpload(upload, to: offset + written)
                } catch {
                    try handle.truncate(atOffset: UInt64(offset))
                    try handle.synchronize()
                    throw error
                }
                var headers = HTTPFields()
                headers[Self.offset] = String(offset + written)
                return Response(status: .noContent, headers: headers)
            }
        }
    }

    private func complete(_ context: HomespunRequestContext) async throws -> Response {
        let id = try uuid(context, "id"), principal = try self.principal(context)
        let initial = try await catalog.backupUpload(id, principal: principal)
        return try await catalog.mutations.withClaim("v2-object/" + initial.object.manifest + "/" + initial.object.role.rawValue) {
            try await catalog.mutations.withClaim("v2-upload/" + id) {
                let upload = try await catalog.backupUpload(id, principal: principal)
                guard upload.state == "open" || upload.state == "verified" else { throw HTTPError(.conflict) }
                if let path = upload.object.path {
                    return try json(try await catalog.completeBackupUpload(upload, path: path))
                }
                try reconcile(upload)
                guard upload.offset == upload.object.size else { throw HTTPError(.conflict, message: "Upload every byte before completion.") }
                let file = partial(id)
                return try await budget.run(.verification) {
                    let digests = try await detached { try Fingerprint.digests(of: file) }
                    guard digests.sha256 == upload.object.sha256, digests.size == upload.object.size else {
                        try await catalog.rejectBackupUpload(upload)
                        throw HTTPError(.unprocessableContent, message: "The upload hash does not match the immutable descriptor; use a new upload identifier.")
                    }
                    let receipt = try await originals.place { root in
                        try await BackupPublication.finish(upload, catalog: catalog, storage: storage, root: root)
                    }
                    try? FileManager.default.removeItem(at: file)
                    return try json(receipt)
                }
            }
        }
    }

    private func download(_ request: Request, _ context: HomespunRequestContext) async throws -> Response {
        let id = try uuid(context, "id"), principal = try self.principal(context)
        guard let role = Role(rawValue: try context.parameters.require("role")) else { throw HTTPError(.badRequest) }
        let derivative = try await catalog.backupDerivative(id, principal: principal)
        guard let file = derivative.resources.first(where: { $0.role == role }) else { throw HTTPError(.notFound) }
        let url = storage.compact("v2-" + id).appendingPathComponent(Storage.sanitized(file.filename))
        guard try JobRunner.size(of: url) == file.size else { throw HTTPError(.serviceUnavailable) }
        var response = try ranged(request, reader: OriginalReader(url), size: file.size, hash: file.sha256)
        response.headers[.contentType] = Routes.mediaType(file.filename)
        return response
    }

    private func ranged(_ request: Request, reader: OriginalReader, size: Int, hash: String) throws -> Response {
        let etag = "\"\(hash)\""
        var headers = HTTPFields()
        headers[.eTag] = etag
        headers[.acceptRanges] = "bytes"
        headers[.contentType] = "application/octet-stream"
        let ifRange = request.headers[.ifRange]
        if let range = request.headers[.range], ifRange == nil || ifRange == etag {
            guard let bytes = Routes.byteRange(range, size: size) else {
                headers[.contentRange] = "bytes */\(size)"
                headers[.contentLength] = "0"
                return Response(status: .rangeNotSatisfiable, headers: headers)
            }
            headers[.contentRange] = "bytes \(bytes.lowerBound)-\(bytes.upperBound)/\(size)"
            headers[.contentLength] = String(bytes.count)
            return Response(status: .partialContent, headers: headers,
                            body: reader.body(range: bytes))
        }
        headers[.contentLength] = String(size)
        return Response(status: .ok, headers: headers, body: reader.body(range: 0...(size - 1)))
    }
}
