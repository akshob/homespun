// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import HTTPTypes
import HomespunCore
import Hummingbird
import NIOCore

public struct HomespunRequestContext: RequestContext {
    public var coreContext: CoreRequestContextStorage
    /// The paired device, set by `DeviceAuthentication`.
    public var deviceID: String?

    public init(source: ApplicationRequestContextSource) {
        coreContext = .init(source: source)
    }

    public var requestDecoder: JSONDecoder { ServerAPI.decoder }
    public var responseEncoder: JSONEncoder { ServerAPI.encoder }
}

/// Requires `Authorization: Bearer <token>` from a paired, unrevoked device.
struct DeviceAuthentication: RouterMiddleware {
    let catalog: Catalog

    func handle(_ request: Request, context: HomespunRequestContext,
                next: (Request, HomespunRequestContext) async throws -> Response) async throws -> Response {
        guard let header = request.headers[.authorization], header.hasPrefix("Bearer "),
              let device = try await catalog.device(tokenHash: Pairing.hash(String(header.dropFirst(7)))) else {
            throw HTTPError(.unauthorized, message: "Pair this device with the server first.")
        }
        var context = context
        context.deviceID = device.id
        return try await next(request, context)
    }
}

/// One upload at a time per resource.
actor UploadLocks {
    private var held: Set<String> = []
    func acquire(_ key: String) -> Bool { held.insert(key).inserted }
    func release(_ key: String) { held.remove(key) }
}

struct Routes: Sendable {
    let configuration: ServerConfiguration
    let catalog: Catalog
    let storage: Storage
    let immich: ImmichClient?
    let locks = UploadLocks()

    var info: ServerAPI.ServerInfo {
        .init(name: configuration.name, version: ServerConfiguration.version, mode: configuration.mode,
              profile: configuration.profile)
    }

    func add(to router: Router<HomespunRequestContext>) {
        let api = router.group("api/v1")
        api.get("health") { _, _ in try json(ServerAPI.Health()) }
        api.post("pair") { request, context in try await pair(request, context) }

        let authenticated = api.group().add(middleware: DeviceAuthentication(catalog: catalog))
        authenticated.get("info") { _, _ in try json(info) }
        authenticated.post("assets") { request, context in try await register(request, context) }
        authenticated.get("assets/:id") { _, context in try json(try await status(context)) }
        authenticated.put("assets/:id/resources/:role") { request, context in try await upload(request, context) }
        authenticated.get("assets/:id/compact/:role") { _, context in try await download(context) }
        authenticated.post("assets/:id/imported") { _, context in try await imported(context) }
        authenticated.post("assets/:id/verify") { _, context in try json(try await verify(context)) }
    }

    // MARK: Pairing

    func pair(_ request: Request, _ context: HomespunRequestContext) async throws -> Response {
        let body = try await request.decode(as: ServerAPI.PairRequest.self, context: context)
        let name = String(body.deviceName.prefix(100)).trimmingCharacters(in: .whitespacesAndNewlines)
        let code = Pairing.normalized(body.code)
        guard code.count == 8, !name.isEmpty else { throw HTTPError(.badRequest, message: "Enter the 8-character code.") }
        let token = Pairing.newToken()
        let device = DeviceRecord(id: UUID().uuidString, name: name, createdAt: "", lastSeenAt: nil, revokedAt: nil)
        guard try await catalog.redeemPairingCode(hash: Pairing.hash(code), device: device, tokenHash: Pairing.hash(token)) else {
            throw HTTPError(.forbidden, message: "That code is wrong, used, or expired. Run `homespun-server pair` for a new one.")
        }
        return try json(ServerAPI.PairResponse(deviceID: device.id, token: token, server: info), status: .created)
    }

    // MARK: Assets

    func register(_ request: Request, _ context: HomespunRequestContext) async throws -> Response {
        let body = try await request.decode(as: ServerAPI.RegisterAssetRequest.self, context: context)
        try validate(body)
        let assetID = body.assetID!
        let mode = configuration.mode
        let outcome = try await catalog.register(body, assetID: assetID, device: context.deviceID ?? "",
                                                 initialState: mode == .files ? .receiving : .verifying)
        guard let asset = try await catalog.asset(assetID) else { throw HTTPError(.internalServerError) }
        let resources = try await catalog.resources(assetID)
        switch mode {
        case .files:
            if asset.state == .receiving, resources.allSatisfy({ $0.state == .verified }) {
                try await catalog.setState(assetID, .queued)
                try await catalog.enqueue(JobRunner.compress, assetID: assetID)
            }
        case .immich:
            // Registering again re-checks Immich, for example after the Immich app backed the item up.
            if [.verifying, .waitingForImmich].contains(asset.state) || (asset.state == .failed && outcome != .unchanged) {
                try await catalog.setState(assetID, .verifying)
                try await catalog.enqueue(JobRunner.immich, assetID: assetID)
            }
        }
        return try json(try await catalog.status(assetID)!, status: outcome == .created ? .created : .ok)
    }

    func validate(_ body: ServerAPI.RegisterAssetRequest) throws {
        let roles = body.resources.map(\.role)
        guard !roles.isEmpty, roles.count <= 16, Set(roles).count == roles.count else {
            throw HTTPError(.badRequest, message: "An asset needs 1 to 16 resources with distinct roles.")
        }
        guard body.assetID != nil else { throw HTTPError(.badRequest, message: "Missing the \(body.primaryRole.rawValue) resource.") }
        if body.kind == .livePhoto, !roles.contains(.pairedVideo) {
            throw HTTPError(.badRequest, message: "A Live Photo needs its paired video.")
        }
        for resource in body.resources {
            guard Validation.isSHA256(resource.sha256) else { throw HTTPError(.badRequest, message: "Bad SHA-256.") }
            guard resource.size > 0 else {
                throw HTTPError(.unprocessableContent, message: "\(resource.role.rawValue) is empty; zero-byte originals are not accepted.")
            }
            guard !resource.filename.isEmpty, resource.filename.utf8.count <= 255 else {
                throw HTTPError(.badRequest, message: "Bad filename.")
            }
            if let sha1 = resource.sha1, !Validation.isSHA1(sha1) { throw HTTPError(.badRequest, message: "Bad SHA-1.") }
            if configuration.mode == .immich, resource.sha1 == nil {
                throw HTTPError(.badRequest, message: "Immich mode needs the SHA-1 of every resource.")
            }
        }
    }

    func assetID(_ context: HomespunRequestContext) throws -> String {
        let id = try context.parameters.require("id").lowercased()
        guard Validation.isSHA256(id) else { throw HTTPError(.badRequest, message: "Bad asset ID.") }
        return id
    }

    func role(_ context: HomespunRequestContext) throws -> Role {
        guard let role = Role(rawValue: try context.parameters.require("role")) else {
            throw HTTPError(.badRequest, message: "Unknown resource role.")
        }
        return role
    }

    func status(_ context: HomespunRequestContext) async throws -> ServerAPI.AssetStatus {
        guard let status = try await catalog.status(try assetID(context)) else { throw HTTPError(.notFound, message: "Unknown asset.") }
        return status
    }

    // MARK: Upload

    /// `PUT …/resources/{role}?offset=N` appends the body at byte N. A wrong offset gets 409 with
    /// the current status so the app can resume. The last chunk triggers SHA-256 verification.
    func upload(_ request: Request, _ context: HomespunRequestContext) async throws -> Response {
        guard configuration.mode == .files else {
            throw HTTPError(.conflict, message: "This server reads originals from Immich; nothing is uploaded.")
        }
        let assetID = try assetID(context), role = try role(context)
        guard let asset = try await catalog.asset(assetID),
              let resource = try await catalog.resources(assetID).first(where: { $0.role == role }) else {
            throw HTTPError(.notFound, message: "Register the asset first.")
        }
        guard let offset = request.uri.queryParameters.get("offset", as: Int.self), offset >= 0 else {
            throw HTTPError(.badRequest, message: "Missing ?offset=.")
        }
        if resource.state == .verified { return try json(try await resourceStatus(assetID, role)) }

        let key = "\(assetID)/\(role.rawValue)"
        guard await locks.acquire(key) else { throw HTTPError(.conflict, message: "This resource is already uploading.") }
        do {
            let response = try await receive(request, asset: asset, resource: resource, offset: offset)
            await locks.release(key)
            return response
        } catch {
            await locks.release(key)
            throw error
        }
    }

    private func receive(_ request: Request, asset: AssetRecord, resource: ResourceRecord, offset: Int) async throws
        -> Response {
        let assetID = asset.id, role = resource.role
        let partial = storage.partial(assetID, role)
        if !FileManager.default.fileExists(atPath: partial.path) {
            guard FileManager.default.createFile(atPath: partial.path, contents: nil) else { throw HTTPError(.internalServerError, message: "Cannot write to the staging folder.") }
        }
        let present = try JobRunner.size(of: partial)
        if present != resource.receivedBytes { try await catalog.setReceived(assetID, role: role, bytes: present) }
        guard offset == present else { return try json(try await resourceStatus(assetID, role), status: .conflict) }

        let handle = try FileHandle(forWritingTo: partial)
        var written = present
        do {
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(present))
            for try await buffer in request.body {
                written += buffer.readableBytes
                guard written <= resource.size, written - present <= configuration.maximumChunkBytes else {
                    try handle.truncate(atOffset: UInt64(present))
                    throw HTTPError(.contentTooLarge, message: "More bytes than declared, or chunk too large.")
                }
                try handle.write(contentsOf: Data(buffer.readableBytesView))
            }
            try handle.synchronize()
        }
        try await catalog.setReceived(assetID, role: role, bytes: written)
        if written == resource.size { try await finishUpload(asset, resource, partial) }
        return try json(try await resourceStatus(assetID, role))
    }

    private func finishUpload(_ asset: AssetRecord, _ resource: ResourceRecord, _ partial: URL) async throws {
        let sha256 = try await detached { try Fingerprint.sha256(of: partial) }
        guard sha256 == resource.sha256 else {
            try? FileManager.default.removeItem(at: partial)
            try await catalog.markResource(asset.id, role: resource.role, state: .mismatch)
            throw HTTPError(.unprocessableContent, message: "SHA-256 mismatch; upload \(resource.role.rawValue) again.")
        }
        let destination = storage.originalDestination(filename: resource.filename, sha256: sha256,
                                                      captureDate: Timestamp.date(asset.captureDate))
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: partial, to: destination)
        try? FileManager.default.setAttributes([.posixPermissions: 0o440], ofItemAtPath: destination.path)
        try await catalog.markResource(asset.id, role: resource.role, state: .verified,
                                       storedPath: storage.relative(destination))
        if try await catalog.resources(asset.id).allSatisfy({ $0.state == .verified }) {
            try await catalog.setState(asset.id, .queued)
            try await catalog.enqueue(JobRunner.compress, assetID: asset.id)
        }
    }

    private func resourceStatus(_ assetID: String, _ role: Role) async throws -> ServerAPI.ResourceStatus {
        guard let status = try await catalog.status(assetID)?.resources.first(where: { $0.role == role }) else {
            throw HTTPError(.notFound)
        }
        return status
    }

    // MARK: Compact copies

    func download(_ context: HomespunRequestContext) async throws -> Response {
        let assetID = try assetID(context), role = try role(context)
        guard let asset = try await catalog.asset(assetID), [.ready, .imported].contains(asset.state),
              let file = try await catalog.compact(assetID).first(where: { $0.role == role }),
              let url = storage.resolve(file.path) else {
            throw HTTPError(.notFound, message: "No compact copy for that role.")
        }
        let body = try await FileIO().loadFile(path: url.path, context: context)
        var headers = HTTPFields()
        headers[.contentType] = "application/octet-stream"
        headers[.contentLength] = String(file.size)
        return Response(status: .ok, headers: headers, body: body)
    }

    func imported(_ context: HomespunRequestContext) async throws -> Response {
        let assetID = try assetID(context)
        guard try await catalog.markImported(assetID, device: context.deviceID ?? "") else {
            throw HTTPError(.conflict, message: "The compact copy is not ready.")
        }
        return try json(try await status(context))
    }

    // MARK: Verification

    /// Re-checks every original now: stored files are hashed again; Immich assets must still
    /// exist, be untrashed, and report the SHA-1 whose bytes Homespun verified.
    func verify(_ context: HomespunRequestContext) async throws -> ServerAPI.Verification {
        let assetID = try assetID(context)
        guard try await catalog.asset(assetID) != nil else { throw HTTPError(.notFound, message: "Unknown asset.") }
        var results: [ServerAPI.Verification.Resource] = []
        for resource in try await catalog.resources(assetID) {
            var verified = false, detail: String?
            if resource.state != .verified {
                detail = "not verified (\(resource.state.rawValue))"
            } else if let path = resource.storedPath, let url = storage.resolve(path) {
                let check = try? await detached { (try Fingerprint.sha256(of: url), try JobRunner.size(of: url)) }
                verified = check?.0 == resource.sha256 && check?.1 == resource.size
                detail = verified ? nil : "stored file is missing or changed"
            } else if let immich, let id = resource.immichAssetID, let sha1 = resource.sha1 {
                (verified, detail) = try await immich.stillHolds(id: id, sha1Hex: sha1)
            } else {
                detail = "no copy on record"
            }
            results.append(.init(role: resource.role, sha256: verified ? resource.sha256 : nil,
                                 size: verified ? resource.size : nil, verified: verified, detail: detail))
        }
        await catalog.log("verified", asset: assetID, device: context.deviceID,
                          detail: results.allSatisfy(\.verified) ? "all" : "incomplete")
        return ServerAPI.Verification(assetID: assetID, checkedAt: Date(), resources: results)
    }
}

func json<T: Encodable>(_ value: T, status: HTTPResponse.Status = .ok) throws -> Response {
    var headers = HTTPFields()
    headers[.contentType] = "application/json; charset=utf-8"
    return Response(status: status, headers: headers,
                    body: .init(byteBuffer: ByteBuffer(bytes: try ServerAPI.encoder.encode(value))))
}
