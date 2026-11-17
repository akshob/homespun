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
    let originals: OriginalsStore
    let mover: OriginalsMover
    let immichState: ImmichState
    let approvals: PairingApprovals
    let connectors: ConnectorHub
    let locks = UploadLocks()
    var trash: Trash { Trash(catalog: catalog, originals: originals, storage: storage) }

    func info() async -> ServerAPI.ServerInfo {
        .init(name: configuration.name, version: ServerConfiguration.version, mode: await immichState.mode,
              profile: configuration.profile, platform: HostPlatform.current(), hardware: HostPlatform.hardware,
              freeBytes: OriginalsStore.space(at: await originals.root.path).free)
    }

    func add(to router: Router<HomespunRequestContext>) {
        let api = router.group("api/v1")
        api.get("health") { _, _ in try json(ServerAPI.Health()) }
        api.post("pair") { request, context in try await pair(request, context) }
        api.get("pair/options") { _, _ in
            try json(ServerAPI.PairingOptions(serverName: configuration.name, canApprove: approvals.canApprove,
                                              pairCommand: HostPlatform.serverCommand + " pair",
                                              platform: HostPlatform.current(), hardware: HostPlatform.hardware,
                                              freeBytes: OriginalsStore.space(at: await originals.root.path).free))
        }
        api.post("pair/requests") { request, context in try await requestApproval(request, context) }
        api.get("pair/requests/:id") { request, context in try await approvalStatus(request, context) }
        api.delete("pair/requests/:id") { request, context in
            guard await approvals.cancel(id: context.parameters.get("id") ?? "", secret: bearer(request) ?? "") else {
                throw HTTPError(.notFound)
            }
            return Response(status: .noContent)
        }

        let authenticated = api.group().add(middleware: DeviceAuthentication(catalog: catalog))
        authenticated.get("info") { _, _ in try json(await info()) }
        authenticated.post("pairing-codes") { _, _ in
            let code = Pairing.newCode(), lifetime = 600
            try await catalog.addPairingCode(hash: Pairing.hash(Pairing.normalized(code)),
                                             expiresAt: Date().addingTimeInterval(TimeInterval(lifetime)))
            return try json(ServerAPI.PairingCode(code: code, expiresIn: lifetime), status: .created)
        }
        authenticated.get("setup") { _, _ in
            try json(await SetupChecks(configuration: configuration, storage: storage, immichState: immichState,
                                       catalog: catalog, originalsFolder: await originals.root).report())
        }
        authenticated.get("storage") { _, context in try json(try await storageInfo(context)) }
        authenticated.get("storage/locations") { _, _ in
            try json(OriginalsLocations.suggestions(current: await originals.root))
        }
        authenticated.put("storage") { request, context in
            let body = try await request.decode(as: ServerAPI.MoveOriginalsRequest.self, context: context)
            do {
                try await mover.start(to: body.originalsFolder)
            } catch let failure as OriginalsMover.Failure {
                throw HTTPError(.unprocessableContent, message: failure.description)
            }
            return try json(try await storageInfo(context), status: .accepted)
        }
        authenticated.get("settings/immich") { _, _ in try json(await immichState.settings()) }
        authenticated.put("settings/immich") { request, context in try await connectImmich(request, context) }
        authenticated.delete("settings/immich") { _, _ in
            try await immichState.clear()
            return try json(await immichState.settings())
        }
        authenticated.get("connectors") { _, _ in try json(try await connectors.all()) }
        authenticated.put("connectors/:id") { request, context in
            let update = try await request.decode(as: ServerAPI.ConnectorUpdate.self, context: context)
            return try json(try await connectorCall { try await connectors.update(context.parameters.get("id") ?? "", update) })
        }
        authenticated.delete("connectors/:id") { _, context in
            try await connectorCall { try await connectors.remove(context.parameters.get("id") ?? "") }
            return Response(status: .noContent)
        }
        authenticated.post("connectors/:id/sign-in") { _, context in
            try json(try await connectorCall { try await connectors.beginSignIn(context.parameters.get("id") ?? "") })
        }
        authenticated.get("connectors/:id/sign-in") { _, context in
            try json(try await connectorCall { try await connectors.pollSignIn(context.parameters.get("id") ?? "") })
        }
        authenticated.post("assets") { request, context in try await register(request, context) }
        authenticated.get("assets/:id") { _, context in try json(try await status(context)) }
        authenticated.put("assets/:id/resources/:role") { request, context in try await upload(request, context) }
        authenticated.get("assets/:id/compact/:role") { _, context in try await download(context) }
        authenticated.post("assets/:id/imported") { request, context in try await imported(request, context) }
        authenticated.post("assets/:id/verify") { _, context in try json(try await verify(context)) }
        authenticated.post("assets/:id/removed") { _, context in try json(try await removedOnDevice(context)) }
        authenticated.get("assets/:id/original/:role") { request, context in try await original(request, context) }
        authenticated.get("devices") { _, context in
            try json(try await catalog.devices().filter { $0.revokedAt == nil }.map {
                ServerAPI.DeviceInfo(id: $0.id, name: $0.name, folder: $0.folder, pairedAt: Timestamp.date($0.createdAt),
                                     lastSeenAt: Timestamp.date($0.lastSeenAt), isThisDevice: $0.id == context.deviceID)
            })
        }
        // A phone renames itself, and its originals folder with it.
        authenticated.patch("devices/:id") { request, context in
            let id = context.parameters.get("id") ?? ""
            guard id == context.deviceID else { throw HTTPError(.forbidden, message: "A device can rename only itself.") }
            let body = try await request.decode(as: ServerAPI.RenameDeviceRequest.self, context: context)
            let device: DeviceRecord
            do {
                device = try await DeviceRename(catalog: catalog, originals: originals, mover: mover).rename(device: id, to: body.name)
            } catch let failure as DeviceRename.Failure {
                switch failure {
                case .invalid(let message): throw HTTPError(.badRequest, message: message)
                case .notFound: throw HTTPError(.notFound, message: failure.description)
                case .taken(let message), .busy(let message): throw HTTPError(.conflict, message: message)
                case .unavailable(let message): throw HTTPError(.serviceUnavailable, message: message)
                }
            }
            return try json(ServerAPI.DeviceInfo(id: device.id, name: device.name, folder: device.folder,
                                                 pairedAt: Timestamp.date(device.createdAt),
                                                 lastSeenAt: Timestamp.date(device.lastSeenAt), isThisDevice: true))
        }
        authenticated.delete("devices/:id") { _, context in
            guard try await catalog.revoke(deviceID: context.parameters.get("id") ?? "") else {
                throw HTTPError(.notFound, message: "No such device.")
            }
            return Response(status: .noContent)
        }
        authenticated.post("copies/lookup") { request, context in
            let body = try await request.decode(as: ServerAPI.CopyLookupRequest.self, context: context)
            let hashes = body.sha256.map { $0.lowercased() }
            guard hashes.count <= ServerAPI.CopyLookupRequest.maximumCount, hashes.allSatisfy(Validation.isSHA256) else {
                throw HTTPError(.badRequest, message: "Send up to \(ServerAPI.CopyLookupRequest.maximumCount) SHA-256 hashes.")
            }
            return try json(ServerAPI.CopyLookupResponse(matches: try await catalog.lookup(Array(Set(hashes)))))
        }
    }

    // MARK: Pairing

    private func bearer(_ request: Request) -> String? {
        guard let header = request.headers[.authorization], header.hasPrefix("Bearer ") else { return nil }
        return String(header.dropFirst(7))
    }

    func requestApproval(_ request: Request, _ context: HomespunRequestContext) async throws -> Response {
        let body = try await request.decode(as: ServerAPI.ApprovalRequest.self, context: context)
        do {
            return try json(try await approvals.start(device: body.deviceName), status: .accepted)
        } catch PairingApprovals.Failure.unavailable {
            throw HTTPError(.conflict, message: "\(configuration.name) can't ask for approval. Run "
                            + "`\(HostPlatform.serverCommand) pair` on it for a pairing code.")
        } catch PairingApprovals.Failure.busy {
            throw HTTPError(.tooManyRequests, message: "\(configuration.name) is busy with another device. "
                            + "Try again in a moment.")
        }
    }

    func approvalStatus(_ request: Request, _ context: HomespunRequestContext) async throws -> Response {
        let status = try await approvals.status(id: context.parameters.get("id") ?? "", secret: bearer(request) ?? "") { name in
            let token = Pairing.newToken()
            let device = DeviceRecord(id: UUID().uuidString, name: name, createdAt: "", lastSeenAt: nil, revokedAt: nil)
            try await catalog.addApprovedDevice(device, tokenHash: Pairing.hash(token))
            return ServerAPI.PairResponse(deviceID: device.id, token: token, server: await info())
        }
        guard let status else { throw HTTPError(.notFound, message: "No such pairing request. Ask again.") }
        return try json(status)
    }

    func pair(_ request: Request, _ context: HomespunRequestContext) async throws -> Response {
        let body = try await request.decode(as: ServerAPI.PairRequest.self, context: context)
        let name = String(body.deviceName.prefix(100)).trimmingCharacters(in: .whitespacesAndNewlines)
        let code = Pairing.normalized(body.code)
        guard code.count == 8, !name.isEmpty else { throw HTTPError(.badRequest, message: "Enter the 8-character code.") }
        let token = Pairing.newToken()
        let device = DeviceRecord(id: UUID().uuidString, name: name, createdAt: "", lastSeenAt: nil, revokedAt: nil)
        guard try await catalog.redeemPairingCode(hash: Pairing.hash(code), device: device, tokenHash: Pairing.hash(token)) else {
            throw HTTPError(.forbidden, message: "That code is wrong, used, or expired. Run `\(HostPlatform.serverCommand) pair` for a new one.")
        }
        return try json(ServerAPI.PairResponse(deviceID: device.id, token: token, server: await info()), status: .created)
    }

    // MARK: Settings

    /// Tests the Immich URL and key before saving them. The key is kept on the server only.
    func connectImmich(_ request: Request, _ context: HomespunRequestContext) async throws -> Response {
        let body = try await request.decode(as: ServerAPI.ImmichSettingsRequest.self, context: context)
        let key = body.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: body.url.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme ?? ""), url.host != nil else {
            throw HTTPError(.badRequest, message: "Enter Immich's address, for example http://192.168.1.20:2283.")
        }
        guard !key.isEmpty, key.count <= 200, !key.contains(where: \.isWhitespace) else {
            throw HTTPError(.badRequest, message: "Paste the API key from Immich.")
        }
        let configuration = ImmichConfiguration(url: url, apiKey: key)
        let permissions: [String]
        do { permissions = try await ImmichState.test(configuration) } catch {
            throw HTTPError(.unprocessableContent, message: "\(error)")
        }
        try await immichState.set(configuration)
        return try json(ServerAPI.ImmichSettings(url: url.absoluteString, keyHint: String(key.suffix(4)), permissions: permissions,
                                                 connected: true, message: ImmichState.permissionWarning(permissions)))
    }

    /// A connector's own errors are messages for the app (422); anything else is a server error.
    private func connectorCall<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as ConnectorError {
            throw HTTPError(.unprocessableContent, message: error.description)
        }
    }

    // MARK: Assets

    func register(_ request: Request, _ context: HomespunRequestContext) async throws -> Response {
        let body = try await request.decode(as: ServerAPI.RegisterAssetRequest.self, context: context)
        let mode = await immichState.mode
        try validate(body, mode: mode)
        for resource in body.resources {
            if let copy = try await catalog.madeCopy(sha256: resource.sha256.lowercased()) {
                throw APIError(.unprocessableContent, code: ServerAPI.ErrorCode.compactCopy,
                               message: "This is a compact copy Homespun made"
                                   + (copy.originalName.map { " of \($0)" } ?? "") + "; its original is on the server.")
            }
        }
        let assetID = body.assetID!
        // Backed up again after it was removed on the phone (recovered from Recently Deleted): its
        // files come out of the trash first, so files that changed meanwhile are handled like any edit.
        if mode == .files, let trashed = try await catalog.asset(assetID) {
            let inTrash = try await catalog.resources(assetID).contains { $0.storedPath.flatMap(Trash.restored) != nil }
            if trashed.state == .trashed || inTrash { try await trash.restore(trashed) }
        }
        let outcome = try await catalog.register(body, assetID: assetID, device: context.deviceID ?? "",
                                                 initialState: mode == .files ? .receiving : .verifying)
        guard var asset = try await catalog.asset(assetID) else { throw HTTPError(.internalServerError) }
        if mode == .files {
            try await catalog.setHoldCompact(assetID, !body.wantsCompact)
            asset = try await catalog.asset(assetID) ?? asset
        }
        let resources = try await catalog.resources(assetID)
        switch mode {
        case .files:
            // A server restart during verification leaves a complete partial file; finish it now.
            for resource in resources where resource.state != .verified {
                let partial = storage.partial(assetID, resource.role)
                let key = "\(assetID)/\(resource.role.rawValue)"
                if (try? JobRunner.size(of: partial)) == resource.size, await locks.acquire(key) {
                    try? await finishUpload(asset, resource, partial)
                    await locks.release(key)
                }
            }
            let resources = try await catalog.resources(assetID)
            let asset = try await catalog.asset(assetID) ?? asset
            // Originals imported in place came with compact copies made elsewhere, not here: make
            // one now that the phone backs up an original it still has.
            let hasCompact = !(try await catalog.compact(assetID)).isEmpty
            let importedWithoutCopy = asset.state == .imported && !hasCompact
                && resources.contains { $0.externalPath != nil || $0.importedFrom != nil }
            if asset.state == .receiving || importedWithoutCopy, resources.allSatisfy({ $0.state == .verified }) {
                // Imported originals were checked at import; enabling a connector copies them.
                try await originalsComplete(asset, copyToConnectors: !importedWithoutCopy)
            } else if asset.state == .stored, !asset.holdCompact {
                // Its time came: the phone wants the compact copy now.
                try await originalsComplete(asset, copyToConnectors: true)
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

    func validate(_ body: ServerAPI.RegisterAssetRequest, mode: ServerAPI.StorageMode) throws {
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
            if mode == .immich, resource.sha1 == nil {
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
        guard await immichState.mode == .files else {
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
        let catalog = catalog
        try await originals.place { root in
            // Read here, not before: a rename of the phone may have just moved its folder.
            let folder = try await catalog.folder(forAsset: asset.id)
            guard FileManager.default.fileExists(atPath: root.path) else {
                throw HTTPError(.serviceUnavailable, message: "The originals folder \(root.path) isn't available (is its disk connected?).")
            }
            let destination = OriginalsStore.destination(root: root, folder: folder, filename: resource.filename, sha256: sha256,
                                                         captureDate: Timestamp.date(asset.captureDate))
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: partial, to: destination)
            try? FileManager.default.setAttributes([.posixPermissions: 0o440], ofItemAtPath: destination.path)
            try await catalog.markResource(asset.id, role: resource.role, state: .verified,
                                           storedPath: OriginalsStore.relative(destination, to: root))
        }
        if try await catalog.resources(asset.id).allSatisfy({ $0.state == .verified }) {
            try await originalsComplete(try await catalog.asset(asset.id) ?? asset, copyToConnectors: true)
        }
    }

    /// Every original is in and checked: make the compact copy, unless the phone asked to wait
    /// (a recent item). Cloud copies wait too, so a photo cleaned up on the phone never reaches one.
    private func originalsComplete(_ asset: AssetRecord, copyToConnectors: Bool) async throws {
        if asset.holdCompact {
            try await catalog.setState(asset.id, .stored)
            return
        }
        try await catalog.setState(asset.id, .queued)
        try await catalog.enqueue(JobRunner.compress, assetID: asset.id)
        if copyToConnectors { try await connectors.originalsVerified(asset.id) }
    }

    /// `POST /api/v1/assets/{id}/removed`: the phone no longer has this recent item (the person
    /// deleted it before its compact copy was due). Its originals go to the server's trash. Items
    /// with a compact copy, or kept as is, stay: freeing up space removes originals on purpose.
    func removedOnDevice(_ context: HomespunRequestContext) async throws -> ServerAPI.AssetStatus {
        let assetID = try assetID(context)
        guard await immichState.mode == .files else {
            throw HTTPError(.conflict, message: "Originals are in Immich; Homespun Server doesn't keep them.")
        }
        guard let asset = try await catalog.asset(assetID) else { throw HTTPError(.notFound) }
        switch asset.state {
        case .stored, .receiving: try await trash.remove(asset)
        case .trashed: break
        default:
            throw APIError(.conflict, code: ServerAPI.ErrorCode.keptOriginal,
                           message: "This original stays on the server: it already has a compact copy or was kept as is.")
        }
        guard let status = try await catalog.status(assetID) else { throw HTTPError(.notFound) }
        return status
    }

    private func resourceStatus(_ assetID: String, _ role: Role) async throws -> ServerAPI.ResourceStatus {
        guard let status = try await catalog.status(assetID)?.resources.first(where: { $0.role == role }) else {
            throw HTTPError(.notFound)
        }
        return status
    }

    // MARK: Originals

    /// `GET …/original/{role}`: the original itself, for comparing it with its compact copy (also
    /// after it left the phone). Supports one `Range`, so a video can be streamed.
    func original(_ request: Request, _ context: HomespunRequestContext) async throws -> Response {
        let assetID = try assetID(context), role = try role(context)
        guard let resource = try await catalog.resources(assetID).first(where: { $0.role == role }),
              resource.state == .verified else { throw HTTPError(.notFound, message: "No such original.") }
        let url: URL
        if let path = resource.externalPath {
            url = URL(fileURLWithPath: path)
        } else if let stored = resource.storedPath, let resolved = await originals.url(stored) {
            url = resolved
        } else {
            throw HTTPError(.notFound, message: "This original is in Immich; open it there.")
        }
        guard (try? JobRunner.size(of: url)) == resource.size else {
            throw HTTPError(.notFound, message: "The original is missing or changed on the server.")
        }
        var headers = HTTPFields()
        headers[.contentType] = Self.mediaType(resource.filename)
        headers[.acceptRanges] = "bytes"
        // Its own name, so a restored original goes back into Photos as it was (IMG_1234.HEIC).
        headers[.contentDisposition] = Self.contentDisposition(resource.filename)
        if let header = request.headers[.range] {
            guard let range = Self.byteRange(header, size: resource.size) else {
                headers[.contentRange] = "bytes */\(resource.size)"
                return Response(status: .rangeNotSatisfiable, headers: headers)
            }
            headers[.contentRange] = "bytes \(range.lowerBound)-\(range.upperBound)/\(resource.size)"
            headers[.contentLength] = String(range.count)
            return Response(status: .partialContent, headers: headers,
                            body: try await FileIO().loadFile(path: url.path, range: range, context: context))
        }
        headers[.contentLength] = String(resource.size)
        return Response(status: .ok, headers: headers, body: try await FileIO().loadFile(path: url.path, context: context))
    }

    /// `attachment` with the file's name: plain for ASCII, and RFC 5987's `filename*` for the rest.
    static func contentDisposition(_ filename: String) -> String {
        let name = Storage.sanitized(filename)
        let plain = String(name.unicodeScalars.map { $0.isASCII && $0 != "\"" && $0 != "\\" ? Character($0) : "_" })
        let encoded = filename.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~")))
            ?? plain
        return "attachment; filename=\"\(plain)\"; filename*=UTF-8''\(encoded)"
    }

    /// One `bytes=` range (`a-b`, `a-` or `-n`), clamped to the file; nil if it can't be served.
    static func byteRange(_ header: String, size: Int) -> ClosedRange<Int>? {
        guard header.hasPrefix("bytes="), size > 0 else { return nil }
        let spec = header.dropFirst(6)
        guard !spec.contains(","), let dash = spec.firstIndex(of: "-") else { return nil }
        let first = spec[..<dash].trimmingCharacters(in: .whitespaces), last = spec[spec.index(after: dash)...].trimmingCharacters(in: .whitespaces)
        if first.isEmpty {
            guard let count = Int(last), count > 0 else { return nil }
            return max(0, size - count)...(size - 1)
        }
        guard let start = Int(first), start < size else { return nil }
        let end = last.isEmpty ? size - 1 : min(Int(last) ?? -1, size - 1)
        return end >= start ? start...end : nil
    }

    static func mediaType(_ filename: String) -> String {
        switch (filename as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg": "image/jpeg"
        case "heic", "heif": "image/heic"
        case "png": "image/png"
        case "dng": "image/x-adobe-dng"
        case "mov": "video/quicktime"
        case "mp4", "m4v": "video/mp4"
        default: "application/octet-stream"
        }
    }

    // MARK: Originals folder

    func storageInfo(_ context: HomespunRequestContext) async throws -> ServerAPI.StorageInfo {
        let root = await originals.root
        let stored = try await catalog.storedOriginals().filter { Trash.restored($0.path) == nil }
        let folder = try await context.deviceID.asyncMap { try await catalog.folder(forDevice: $0) } ?? nil
        let space = OriginalsStore.space(at: root.path)
        let trashed = try await catalog.trashTotals()
        return ServerAPI.StorageInfo(
            originalsFolder: root.path, deviceFolder: folder.map { root.appendingPathComponent($0).path },
            freeBytes: space.free, capacityBytes: space.capacity, storedCount: stored.count,
            storedBytes: stored.reduce(Int64(0)) { $0 + Int64($1.size) }, move: await mover.status,
            trashCount: trashed.count, trashBytes: trashed.bytes)
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

    func imported(_ request: Request, _ context: HomespunRequestContext) async throws -> Response {
        let assetID = try assetID(context)
        let body = try await request.body.collect(upTo: 64 << 10)
        var copies: [ServerAPI.CopyHash] = []
        if body.readableBytes > 0 {
            copies = try ServerAPI.decoder.decode(ServerAPI.ImportedRequest.self, from: Data(body.readableBytesView)).deviceCopies
            guard copies.allSatisfy({ Validation.isSHA256($0.sha256) && ($0.sha1.map(Validation.isSHA1) ?? true) }) else {
                throw HTTPError(.badRequest, message: "Bad hash.")
            }
        }
        guard try await catalog.markImported(assetID, device: context.deviceID ?? "") else {
            throw HTTPError(.conflict, message: "The compact copy is not ready.")
        }
        // Only files the server left to the phone; anything else it made itself.
        let deviceMade = Set(try await catalog.asset(assetID)?.deviceCompresses ?? [])
        try await catalog.rememberCopies(assetID, copies.filter { deviceMade.contains($0.role) })
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
            } else if let path = resource.externalPath {
                let url = URL(fileURLWithPath: path)
                let check = try? await detached { (try Fingerprint.sha256(of: url), try JobRunner.size(of: url)) }
                verified = check?.0 == resource.sha256 && check?.1 == resource.size
                detail = verified ? nil : "the original at \(path) is missing or changed"
            } else if let path = resource.storedPath, let url = await originals.url(path) {
                let check = try? await detached { (try Fingerprint.sha256(of: url), try JobRunner.size(of: url)) }
                verified = check?.0 == resource.sha256 && check?.1 == resource.size
                detail = verified ? nil : "stored file is missing or changed"
            } else if let immich = await immichState.client, let id = resource.immichAssetID, let sha1 = resource.sha1 {
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

/// An error with a `code` the app acts on, in the same JSON shape as other errors.
struct APIError: HTTPResponseError {
    let status: HTTPResponse.Status
    let code: String
    let message: String

    init(_ status: HTTPResponse.Status, code: String, message: String) {
        self.status = status
        self.code = code
        self.message = message
    }

    func response(from request: Request, context: some RequestContext) throws -> Response {
        try json(ServerAPI.ErrorBody(error: .init(message: message, code: code)), status: status)
    }
}

func json<T: Encodable>(_ value: T, status: HTTPResponse.Status = .ok) throws -> Response {
    var headers = HTTPFields()
    headers[.contentType] = "application/json; charset=utf-8"
    return Response(status: status, headers: headers,
                    body: .init(byteBuffer: ByteBuffer(bytes: try ServerAPI.encoder.encode(value))))
}
