// SPDX-License-Identifier: Apache-2.0
import Foundation
import HomespunCore
import ImageIO
import Synchronization
import UniformTypeIdentifiers

/// The demo's pretend Homespun Server, "Homespun Demo": it answers the calls `ServerClient` makes from
/// inside the app (`DemoURLProtocol`), with short pauses so progress shows, and keeps what it's sent in
/// the demo's folder. It never touches the network. Uploads arrive in small pieces and are checked
/// byte for byte like the real server's; its compact copies of photos are made smaller here, and those
/// of videos and the Live Photo come with the app's samples.
actor DemoServer {
    static let name = "Homespun Demo"
    static let host = "homespun-demo.local"
    static let baseURL = URL(string: "https://\(host):8787")!
    static let fingerprint = ServerKeyFingerprint(spki: Data("homespun demo key".utf8))
    static let notAfter = Date(timeIntervalSince1970: 2_000_000_000)
    /// The server the demo's requests reach while the demo is on.
    static let running = Mutex<DemoServer?>(nil)

    /// How much of an upload one request takes: a photo arrives in a few pieces, so its progress shows.
    static let piece = 64 * 1024
    /// How long until someone at the pretend Mac clicks Allow.
    static let approvalSeconds = 2.5

    struct Response: Sendable {
        var status: Int
        var headers: [String: String] = ["Content-Type": "application/json"]
        var body = Data()
    }

    struct Failure: Error {
        var status: Int
        var message: String
        var code: String?
    }

    struct Device: Codable, Equatable {
        var id: String
        var name: String
        var pairedAt: Date
        var lastSeenAt: Date?
        /// This iPhone's token (the other, pretend devices have none).
        var token: String?
        var installID: String?
    }

    struct Resource: Codable, Equatable {
        var role: ServerAPI.ResourceRole
        var filename: String
        var size: Int
        var sha256: String
        var received = 0
        var state = ServerAPI.ResourceState.missing
        var verifiedAt: Date?
    }

    struct Asset: Codable, Equatable {
        var id: String
        var kind: ServerAPI.AssetKind
        var captureDate: Date?
        var resources: [Resource]
        var state: ServerAPI.AssetState
        var wantsCompact: Bool
        var compact: [ServerAPI.CompactResource] = []
        /// Status checks since it was queued: each one moves it on a step.
        var steps = 0
        var message: String?
    }

    struct State: Codable, Equatable {
        var devices: [Device] = []
        var assets: [String: Asset] = [:]
        var originalsFolder = DemoServer.folders[0].path
        var move: ServerAPI.MoveStatus?
    }

    private struct Approval {
        var ticket: ServerAPI.ApprovalTicket
        var deviceName: String
        var asked: Date
        var closed = false
        var commitment: Data
        var serverNonce: Data
        var revealed = false
    }

    private var challenges: [String: Date] = [:]

    struct Place: Sendable {
        var path: String
        var name: String
        var free: Int64
        var capacity: Int64
    }

    /// Where originals can go on the pretend Mac.
    static let folders: [Place] = [
        Place(path: "/Volumes/Homespun", name: "Homespun", free: 1_420_000_000_000, capacity: 2_000_000_000_000),
        Place(path: "/Volumes/Archive", name: "Archive", free: 3_650_000_000_000, capacity: 4_000_000_000_000),
        Place(path: "/Users/Shared/Homespun", name: "Macintosh HD", free: 212_000_000_000, capacity: 494_000_000_000),
    ]

    static let platform = ServerSetup.Platform(os: .macOS, name: "macOS 26.1", packageManager: .homebrew)
    static let hardware = ServerAPI.Hardware(kind: .desktop, model: "Mac mini")

    static var info: ServerAPI.ServerInfo {
        ServerAPI.ServerInfo(name: name, version: "1.0.0 (demo)", mode: .files, profile: .standard, platform: platform,
                             hardware: hardware, freeBytes: folders[0].free,
                             tls: .init(fingerprint: fingerprint, notAfter: notAfter))
    }

    let folder: URL
    nonisolated let generation: String
    nonisolated let clientSession: URLSession
    private var retired = false
    private var admitted = 0
    private var retirementWaiters: [CheckedContinuation<Void, Never>] = []
    private let backup: DemoBackupServer
    /// How long its answers take, as a share of a server's on the Wi‑Fi (0 in tests).
    let pace: Double
    private var state: State
    private var approvals: [String: Approval] = [:]
    /// The compact copy that comes with the app for an original (videos and the Live Photo), by its
    /// main file's SHA-256.
    private let bundledCompact: @Sendable (String) -> [ServerAPI.ResourceRole: URL]?

    init(folder: URL, pace: Double = 1, processingDelay: (@Sendable (ServerAPI.AssetKind) -> TimeInterval)? = nil,
         bundledCompact: @escaping @Sendable (String) -> [ServerAPI.ResourceRole: URL]?) {
        self.folder = folder
        let generation = UUID().uuidString
        self.generation = generation
        clientSession = Self.makeSession(generation: generation)
        self.pace = pace
        self.bundledCompact = bundledCompact
        backup = DemoBackupServer(folder: folder.appendingPathComponent("v2"), pace: pace,
                                  processingDelay: processingDelay, bundled: bundledCompact)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        state = (try? decoder.decode(State.self, from: Data(contentsOf: folder.appendingPathComponent("state.json")))) ?? State()
        if state.devices.isEmpty {
            // Paired earlier, so Devices shows more than this iPhone.
            state.devices = [Device(id: "demo-ipad", name: "Family iPad", pairedAt: Date(timeIntervalSinceNow: -86_400 * 210),
                                    lastSeenAt: Date(timeIntervalSinceNow: -86_400 * 3))]
        }
    }

    var snapshot: State { state }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? encoder.encode(state).write(to: folder.appendingPathComponent("state.json"), options: .atomic)
    }

    // MARK: Answering

    func handle(method: String, url: URL, token: String?, body: Data, headers: [String: String] = [:]) async -> Response {
        guard !retired else { return Self.error(503, "This demo has ended.") }
        admitted += 1
        defer {
            admitted -= 1
            if admitted == 0 {
                let waiters = retirementWaiters
                retirementWaiters = []
                waiters.forEach { $0.resume() }
            }
        }
        if pace > 0 { try? await Task.sleep(for: .seconds(Self.delay(method: method, path: url.path) * pace)) }
        guard !retired, !Task.isCancelled else { return Self.error(503, "This demo has ended.") }
        let parts = url.path.split(separator: "/").map(String.init)
        if parts.count >= 3, parts[0] == "api", parts[1] == "v2" {
            guard let token, let device = state.devices.first(where: { $0.token == token }) else {
                return Self.error(401, "Pair this device with the demo first.")
            }
            return await backup.handle(method: method, url: url, owner: device.id, headers: headers, body: body)
        }
        if method == "GET", parts == ["api", "v1", "storage"],
           let token, let device = state.devices.first(where: { $0.token == token }) {
            var information = storage(device)
            let statistics = await backup.statistics()
            information.storedCount += statistics.count
            information.storedBytes += statistics.bytes
            information.freeBytes = information.freeBytes.map { max(0, $0 - statistics.bytes) }
            return (try? Self.json(information)) ?? Self.error(500, "The demo storage status couldn't be read.")
        }
        guard parts.count >= 3, parts[0] == "api", parts[1] == "v1" else { return Self.error(404, "Not found.") }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        do {
            return try route(method, Array(parts.dropFirst(2)), query: query, token: token, body: body)
        } catch let failure as Failure {
            return Self.error(failure.status, failure.message, code: failure.code)
        } catch {
            return Self.error(400, "Homespun Demo couldn't read that request.")
        }
    }

    func stopAndWait() async {
        retired = true
        await backup.stopAndWait()
        if admitted > 0 { await withCheckedContinuation { retirementWaiters.append($0) } }
    }

    private static func delay(method: String, path: String) -> Double {
        if path.contains("/resources/") { return 0.12 }
        if path.hasSuffix("/verify") { return 0.35 }
        if path.contains("/compact/") || path.contains("/original/") { return 0.3 }
        if path.hasSuffix("/assets") { return 0.25 }
        return method == "GET" ? 0.12 : 0.2
    }

    private func route(_ method: String, _ path: [String], query: [URLQueryItem], token: String?, body: Data) throws -> Response {
        /// The path's parts in the places of `*`, if the request is `verb` on `pattern`.
        func on(_ verb: String, _ pattern: String) -> [String]? {
            let want = pattern.split(separator: "/").map(String.init)
            guard verb == method, want.count == path.count else { return nil }
            var captured: [String] = []
            for (part, have) in zip(want, path) {
                if part == "*" { captured.append(have) } else if part != have { return nil }
            }
            return captured
        }
        func decode<Value: Decodable>(_ type: Value.Type) throws -> Value { try ServerAPI.decoder.decode(type, from: body) }

        // Before pairing.
        if on("GET", "health") != nil { return try Self.json(ServerAPI.Health(tls: true)) }
        if on("GET", "pair/options") != nil {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-testUntrustedPairingAdvice") {
                return try Self.json(ServerAPI.PairingOptions(
                    serverName: Self.name, canApprove: false,
                    pairCommand: "UNTRUSTED_PAIR_COMMAND /untrusted/server-path",
                    platform: Self.platform, hardware: Self.hardware, freeBytes: Self.folders[0].free,
                    pairingVersion: 2, encrypted: true))
            }
            #endif
            return try Self.json(ServerAPI.PairingOptions(serverName: Self.name, canApprove: true, pairCommand: "homespun-server pair",
                                                          platform: Self.platform, hardware: Self.hardware,
                                                          freeBytes: Self.folders[0].free, pairingVersion: 2, encrypted: true))
        }
        if on("POST", "tls/verify") != nil {
            let request = try decode(ServerAPI.IdentityRequest.self)
            guard let nonce = PairingCrypto.decode(request.nonce, count: 32),
                  let token = state.devices.compactMap(\.token).first(where: {
                      PairingCrypto.keyID(tokenHash: PairingCrypto.tokenHash($0)) == request.keyID
                  }) else { throw Failure(status: 404, message: "Pair this device again.") }
            return try Self.json(ServerAPI.IdentityProof(fingerprint: Self.fingerprint,
                proof: PairingCrypto.encode(PairingCrypto.verifyProof(tokenHash: PairingCrypto.tokenHash(token),
                                                                      nonce: nonce, fingerprint: Self.fingerprint)),
                notAfter: Self.notAfter))
        }
        if on("POST", "pair/challenge") != nil {
            let request = try decode(ServerAPI.CodeChallengeRequest.self)
            guard let nonce = PairingCrypto.decode(request.nonce, count: 32) else { throw Failure(status: 400, message: "Invalid nonce.") }
            let id = UUID().uuidString, salt = PairingCrypto.nonce(count: 16)
            let key = try PairingCrypto.codeKey(codeHash: PairingCrypto.codeHash("DEMO-2468"), salt: salt)
            challenges[id] = Date().addingTimeInterval(60)
            return try Self.json(ServerAPI.CodeChallenge(id: id, rounds: PairingCrypto.codeRounds, proofs: [
                .init(salt: PairingCrypto.encode(salt),
                      check: PairingCrypto.encode(PairingCrypto.codeCheck(key: key, nonce: nonce, salt: salt, id: id)),
                      proof: PairingCrypto.encode(PairingCrypto.codeProof(key: key, fingerprint: Self.fingerprint,
                                                                         nonce: nonce, salt: salt, id: id)))
            ], expiresIn: 60))
        }
        if on("POST", "pair") != nil {
            let request = try decode(ServerAPI.PairRequest.self)
            guard PairingCrypto.codeHash(request.code) == PairingCrypto.codeHash("DEMO-2468"),
                  let id = request.challenge, let expires = challenges.removeValue(forKey: id), expires > Date() else {
                throw Failure(status: 403, message: "Try DEMO-2468.")
            }
            return try Self.json(pair(deviceName: request.deviceName, installID: request.installID))
        }
        if on("POST", "pair/requests") != nil {
            let request = try decode(ServerAPI.ApprovalRequest.self)
            guard request.installID == nil else { throw Failure(status: 400, message: "Wait for approval.") }
            guard let text = request.commitment, let commitment = PairingCrypto.decode(text, count: 32) else {
                throw Failure(status: 400, message: "A commitment is required.")
            }
            let id = UUID().uuidString.lowercased()
            let nonce = PairingCrypto.nonce()
            let ticket = ServerAPI.ApprovalTicket(id: id, secret: UUID().uuidString, expiresIn: 120,
                                                  serverNonce: PairingCrypto.encode(nonce))
            approvals[id] = Approval(ticket: ticket, deviceName: request.deviceName, asked: Date(),
                                     commitment: commitment, serverNonce: nonce)
            return try Self.json(ticket, status: 201)
        }
        if let id = on("POST", "pair/requests/*/reveal")?.first {
            let reveal = try decode(ServerAPI.ApprovalReveal.self)
            guard var approval = approvals[id], approval.ticket.secret == token,
                  !approval.closed, !approval.revealed, Date().timeIntervalSince(approval.asked) < 30,
                  let nonce = PairingCrypto.decode(reveal.nonce, count: 32),
                  PairingCrypto.equal(approval.commitment, PairingCrypto.commitment(nonce: nonce)) else {
                throw Failure(status: 400, message: "The pairing couldn't be confirmed.")
            }
            approval.revealed = true
            approval.ticket.match = PairingCrypto.sas(fingerprint: Self.fingerprint, appNonce: nonce, serverNonce: approval.serverNonce)
            approval.asked = Date()
            approvals[id] = approval
            return Response(status: 202)
        }
        if let id = on("GET", "pair/requests/*")?.first {
            guard let approval = approvals[id], approval.ticket.secret == token, !approval.closed else {
                throw Failure(status: 404, message: "No such request.")
            }
            // Someone at the pretend Mac clicks Allow after a moment.
            guard approval.revealed, Date().timeIntervalSince(approval.asked) >= Self.approvalSeconds * min(pace, 1) else {
                return try Self.json(ServerAPI.ApprovalStatus(state: .waiting))
            }
            return try Self.json(ServerAPI.ApprovalStatus(state: .approved))
        }
        if let id = on("POST", "pair/requests/*/complete")?.first {
            let body = try decode(ServerAPI.ApprovalCompletion.self)
            guard var approval = approvals[id], approval.ticket.secret == token, !approval.closed, approval.revealed,
                  Date().timeIntervalSince(approval.asked) >= Self.approvalSeconds * min(pace, 1) else {
                throw Failure(status: 404, message: "No approved request.")
            }
            approval.closed = true
            approvals[id] = approval
            return try Self.json(pair(deviceName: approval.deviceName, installID: body.installID), status: 201)
        }
        if let id = on("DELETE", "pair/requests/*")?.first {
            approvals[id]?.closed = true
            return Response(status: 204, headers: [:])
        }

        guard let device = state.devices.first(where: { $0.token != nil && $0.token == token }) else {
            throw Failure(status: 401, message: "This device isn't paired.")
        }
        if on("GET", "info") != nil {
            var info = Self.info
            info.deviceName = device.name
            return try Self.json(info)
        }
        if on("POST", "pairing-codes") != nil {
            return try Self.json(ServerAPI.PairingCode(code: "DEMO-2468", expiresIn: 600), status: 201)
        }
        if on("GET", "setup") != nil { return try Self.json(setupReport()) }
        if on("GET", "storage") != nil { return try Self.json(storage(device)) }
        if on("GET", "storage/locations") != nil {
            return try Self.json(Self.folders.map {
                ServerAPI.StorageLocation(path: $0.path, name: $0.name, freeBytes: $0.free, capacityBytes: $0.capacity,
                                          isCurrent: $0.path == state.originalsFolder)
            })
        }
        if on("PUT", "storage") != nil {
            return try Self.json(startMove(to: try decode(ServerAPI.MoveOriginalsRequest.self).originalsFolder, device: device))
        }
        if on("GET", "settings/immich") != nil {
            return try Self.json(ServerAPI.ImmichSettings(url: nil, keyHint: nil, permissions: [], connected: false, message: nil))
        }
        if on("PUT", "settings/immich") != nil || on("DELETE", "settings/immich") != nil {
            throw Failure(status: 409, message: "Immich isn't part of the demo. With your own server, Homespun can read "
                          + "originals from your Immich server.")
        }
        if on("GET", "connectors") != nil { return try Self.json([Self.oneDrive]) }
        if on("PUT", "connectors/*") != nil || on("POST", "connectors/*/sign-in") != nil
            || on("GET", "connectors/*/sign-in") != nil {
            throw Failure(status: 409, message: "Cloud copies can't be turned on in the demo. With your own server, signing in "
                          + "to OneDrive copies each original there too.")
        }
        if on("DELETE", "connectors/*") != nil { return Response(status: 204, headers: [:]) }
        if on("GET", "devices") != nil {
            return try Self.json(state.devices.map {
                ServerAPI.DeviceInfo(id: $0.id, name: $0.name, folder: $0.name, pairedAt: $0.pairedAt,
                                     lastSeenAt: $0.id == device.id ? Date() : $0.lastSeenAt, isThisDevice: $0.id == device.id)
            })
        }
        if let id = on("PATCH", "devices/*")?.first {
            guard id == device.id, let index = state.devices.firstIndex(where: { $0.id == id }) else {
                throw Failure(status: 403, message: "A device can rename only itself.")
            }
            let name = try decode(ServerAPI.RenameDeviceRequest.self).name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.count <= ServerAPI.RenameDeviceRequest.maximumLength else {
                throw Failure(status: 400, message: "A name has 1 to \(ServerAPI.RenameDeviceRequest.maximumLength) characters.")
            }
            state.devices[index].name = name
            save()
            let renamed = state.devices[index]
            return try Self.json(ServerAPI.DeviceInfo(id: renamed.id, name: renamed.name, folder: renamed.name,
                                                      pairedAt: renamed.pairedAt, lastSeenAt: Date(), isThisDevice: true))
        }
        if let id = on("DELETE", "devices/*")?.first {
            guard id != device.id else {
                throw Failure(status: 409, message: "In the demo, this iPhone stays paired. To stop, leave the demo in the Server tab.")
            }
            state.devices.removeAll { $0.id == id }
            save()
            return Response(status: 204, headers: [:])
        }
        if on("POST", "assets") != nil { return try register(try decode(ServerAPI.RegisterAssetRequest.self)) }
        if let id = on("GET", "assets/*")?.first { return try Self.json(status(advance(id))) }
        if let captured = on("PUT", "assets/*/resources/*") {
            guard let offset = query.first(where: { $0.name == "offset" })?.value.flatMap(Int.init), offset >= 0 else {
                throw Failure(status: 400, message: "Missing ?offset=.")
            }
            return try upload(captured[0], role: captured[1], offset: offset, body: body)
        }
        if let captured = on("GET", "assets/*/compact/*") { return try compactFile(captured[0], role: captured[1]) }
        if let id = on("POST", "assets/*/imported")?.first {
            var asset = try asset(id)
            if asset.state == .ready { asset.state = .imported }
            state.assets[asset.id] = asset
            save()
            return try Self.json(status(asset))
        }
        if let id = on("POST", "assets/*/verify")?.first { return try Self.json(verify(id)) }
        if let id = on("POST", "assets/*/removed")?.first {
            var asset = try asset(id)
            guard [.stored, .receiving, .trashed].contains(asset.state) else {
                throw Failure(status: 409, message: "Homespun Demo keeps this original.", code: ServerAPI.ErrorCode.keptOriginal)
            }
            asset.state = .trashed
            state.assets[asset.id] = asset
            save()
            return try Self.json(status(asset))
        }
        if let captured = on("GET", "assets/*/original/*") { return try originalFile(captured[0], role: captured[1]) }
        if on("POST", "copies/lookup") != nil {
            return try Self.json(ServerAPI.CopyLookupResponse(matches: lookup(try decode(ServerAPI.CopyLookupRequest.self).sha256)))
        }
        throw Failure(status: 404, message: "Homespun Demo doesn't know \(method) \(path.joined(separator: "/")).")
    }

    // MARK: Pairing

    /// Pairs this iPhone (again: its record keeps its name and originals, with a new token).
    private func pair(deviceName: String, installID: String?) -> ServerAPI.PairResponse {
        let token = UUID().uuidString
        if let installID, let index = state.devices.firstIndex(where: { $0.token != nil && $0.installID == installID }) {
            state.devices[index].token = token
            state.devices[index].lastSeenAt = Date()
            save()
            var info = Self.info
            info.deviceName = state.devices[index].name
            return ServerAPI.PairResponse(deviceID: state.devices[index].id, token: token, server: info)
        }
        let device = Device(id: UUID().uuidString, name: deviceName, pairedAt: Date(), lastSeenAt: Date(),
                            token: token, installID: installID)
        state.devices.insert(device, at: 0)
        save()
        var info = Self.info
        info.deviceName = device.name
        return ServerAPI.PairResponse(deviceID: device.id, token: token, server: info)
    }

    private func setupReport() -> ServerSetup.Report {
        let place = Self.folders.first { $0.path == state.originalsFolder } ?? Self.folders[0]
        return ServerSetup.Report(platform: Self.platform, checks: [
            .init(id: "photos", title: "Photos", status: .ok, detail: "Compressed with ImageIO."),
            .init(id: "videos", title: "Videos", status: .ok, detail: "Compressed with x265 (ffmpeg)."),
            .init(id: "live_photos", title: "Live Photos", status: .ok, detail: "Motion is compressed on this Mac."),
            .init(id: "discovery", title: "Home network", status: .ok, detail: "The app can find \"\(Self.name)\" on your network."),
            .init(id: "storage", title: "Storage", status: .ok,
                  detail: "\(place.free.formatted(.byteCount(style: .file))) free in \(place.path)."),
            .init(id: "service", title: "Starts automatically", status: .ok, detail: "Runs as a LaunchAgent."),
            .init(id: "immich", title: "Immich", status: .info, detail: "Not connected. Originals are kept on this server."),
        ])
    }

    // MARK: Storage

    private static func bytes(_ asset: Asset) -> Int64 { Int64(asset.resources.reduce(0) { $0 + $1.size }) }

    private func storage(_ device: Device) -> ServerAPI.StorageInfo {
        advanceMove()
        let kept = state.assets.values.filter { $0.state != .trashed && $0.resources.allSatisfy { $0.state == .verified } }
        let trash = state.assets.values.filter { $0.state == .trashed }
        let bytes = kept.reduce(Int64(0)) { $0 + Self.bytes($1) }
        let place = Self.folders.first { $0.path == state.originalsFolder } ?? Self.folders[0]
        return ServerAPI.StorageInfo(originalsFolder: state.originalsFolder, deviceFolder: device.name, freeBytes: place.free - bytes,
                                     capacityBytes: place.capacity, storedCount: kept.count, storedBytes: bytes, move: state.move,
                                     trashCount: trash.count, trashBytes: trash.reduce(Int64(0)) { $0 + Self.bytes($1) })
    }

    private func startMove(to path: String, device: Device) throws -> ServerAPI.StorageInfo {
        guard Self.folders.contains(where: { $0.path == path }) else { throw Failure(status: 400, message: "That folder isn't on Homespun Demo.") }
        if let move = state.move, [.copying, .finishing].contains(move.state) {
            throw Failure(status: 409, message: "Originals are moving already.")
        }
        guard path != state.originalsFolder else { return storage(device) }
        let kept = state.assets.values.filter { $0.resources.allSatisfy { $0.state == .verified } }
        state.move = ServerAPI.MoveStatus(state: .copying, from: state.originalsFolder, to: path, copied: 0, total: kept.count,
                                          copiedBytes: 0, totalBytes: kept.reduce(Int64(0)) { $0 + Self.bytes($1) })
        save()
        return storage(device)
    }

    /// A move goes a third of the way each time the app looks.
    private func advanceMove() {
        guard var move = state.move, [.copying, .finishing].contains(move.state) else { return }
        move.copied = min(move.total, move.copied + max(1, (move.total + 2) / 3))
        move.copiedBytes = move.total == 0 ? move.totalBytes : move.totalBytes * Int64(move.copied) / Int64(move.total)
        if move.copied >= move.total {
            move.state = .done
            move.finishedAt = Date()
            state.originalsFolder = move.to
        }
        state.move = move
        save()
    }

    // MARK: Assets

    private func asset(_ id: String) throws -> Asset {
        guard let asset = state.assets[id.lowercased()] else { throw Failure(status: 404, message: "Unknown asset.") }
        return asset
    }

    private func status(_ asset: Asset) -> ServerAPI.AssetStatus {
        ServerAPI.AssetStatus(assetID: asset.id, kind: asset.kind, state: asset.state, message: asset.message,
                              resources: asset.resources.map {
                                  ServerAPI.ResourceStatus(role: $0.role, sha256: $0.sha256, size: $0.size, state: $0.state,
                                                           receivedBytes: $0.received, verifiedAt: $0.verifiedAt)
                              },
                              compact: [.ready, .imported].contains(asset.state) ? asset.compact : [], deviceCompresses: [])
    }

    private func register(_ request: ServerAPI.RegisterAssetRequest) throws -> Response {
        let roles = request.resources.map(\.role)
        guard let id = request.assetID, Set(roles).count == roles.count,
              request.resources.allSatisfy({ $0.size > 0 && $0.sha256.count == 64 }) else {
            throw Failure(status: 400, message: "An asset needs its \(request.primaryRole.rawValue) and distinct roles.")
        }
        if lookup(request.resources.map(\.sha256)).contains(where: { !$0.isOriginal }) {
            throw Failure(status: 409, message: "This is a compact copy Homespun Demo made.", code: ServerAPI.ErrorCode.compactCopy)
        }
        if var asset = state.assets[id] {
            let complete = asset.resources.allSatisfy { $0.state == .verified }
            if asset.state == .trashed {
                asset.state = complete ? (request.wantsCompact ? .queued : .stored) : .receiving
                asset.steps = 0
            } else if asset.state == .stored, request.wantsCompact {
                // Its time came: the compact copy now.
                asset.wantsCompact = true
                asset.state = .queued
                asset.steps = 0
            }
            state.assets[id] = asset
            save()
            return try Self.json(status(asset))
        }
        let asset = Asset(id: id, kind: request.kind, captureDate: request.captureDate,
                          resources: request.resources.map {
                              Resource(role: $0.role, filename: $0.filename, size: $0.size, sha256: $0.sha256.lowercased())
                          },
                          state: .receiving, wantsCompact: request.wantsCompact)
        state.assets[id] = asset
        save()
        return try Self.json(status(asset), status: 201)
    }

    private func originalURL(_ id: String, _ role: ServerAPI.ResourceRole) -> URL {
        folder.appendingPathComponent("originals/\(id)/\(role.rawValue)")
    }

    /// Takes up to `piece` bytes at `offset` (the client sends the rest from where this one stops); the
    /// last piece is checked against the file's SHA-256.
    private func upload(_ id: String, role name: String, offset: Int, body: Data) throws -> Response {
        guard let role = ServerAPI.ResourceRole(rawValue: name) else { throw Failure(status: 400, message: "Unknown resource role.") }
        var asset = try asset(id)
        guard let index = asset.resources.firstIndex(where: { $0.role == role }) else {
            throw Failure(status: 404, message: "Register the asset first.")
        }
        var resource = asset.resources[index]
        func answer(_ status: Int = 200) throws -> Response {
            try Self.json(ServerAPI.ResourceStatus(role: role, sha256: resource.sha256, size: resource.size, state: resource.state,
                                                   receivedBytes: resource.received, verifiedAt: resource.verifiedAt), status: status)
        }
        if resource.state == .verified { return try answer() }
        guard offset == resource.received else { return try answer(409) }
        guard offset + body.count <= resource.size else { throw Failure(status: 413, message: "More bytes than declared.") }
        let url = originalURL(asset.id, role)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if offset == 0 { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let piece = body.prefix(Self.piece)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seek(toOffset: UInt64(offset))
        try handle.write(contentsOf: piece)
        try handle.close()
        resource.received = offset + piece.count
        resource.state = .partial
        if resource.received == resource.size {
            guard try Fingerprint.sha256(of: url) == resource.sha256 else {
                try? FileManager.default.removeItem(at: url)
                resource.received = 0
                resource.state = .mismatch
                asset.resources[index] = resource
                state.assets[asset.id] = asset
                save()
                throw Failure(status: 422, message: "SHA-256 mismatch; upload \(role.rawValue) again.")
            }
            resource.state = .verified
            resource.verifiedAt = Date()
        }
        asset.resources[index] = resource
        if asset.state == .receiving, asset.resources.allSatisfy({ $0.state == .verified }) {
            asset.state = asset.wantsCompact ? .queued : .stored
            asset.steps = 0
        }
        state.assets[asset.id] = asset
        save()
        return try answer()
    }

    /// Each look at a queued item moves it on: compressing, then ready with its compact copy.
    private func advance(_ id: String) throws -> Asset {
        var asset = try asset(id)
        guard [.queued, .compressing].contains(asset.state) else { return asset }
        asset.steps += 1
        if asset.steps == 1 {
            asset.state = .compressing
        } else {
            do {
                asset.compact = try makeCompact(asset)
                asset.state = .ready
            } catch {
                asset.state = .failed
                asset.message = "Homespun Demo couldn't make this compact copy."
            }
        }
        state.assets[asset.id] = asset
        save()
        return asset
    }

    private func compactFolder(_ id: String) -> URL { folder.appendingPathComponent("compact/\(id)", isDirectory: true) }

    private func makeCompact(_ asset: Asset) throws -> [ServerAPI.CompactResource] {
        let output = compactFolder(asset.id)
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        guard let primary = asset.resources.first(where: { $0.role == (asset.kind == .video ? .video : .photo) }) else {
            throw Failure(status: 500, message: "No main file.")
        }
        if let bundled = bundledCompact(primary.sha256) {
            var made: [ServerAPI.CompactResource] = []
            for role in [ServerAPI.ResourceRole.photo, .pairedVideo, .video] {
                guard let source = bundled[role] else { continue }
                let destination = output.appendingPathComponent(source.lastPathComponent)
                try FileManager.default.copyItem(at: source, to: destination)
                made.append(try Self.describe(destination, role: role))
            }
            return made
        }
        let name = (primary.filename as NSString).deletingPathExtension + (Self.writesHEIC ? ".HEIC" : ".JPG")
        let destination = output.appendingPathComponent(name)
        try Self.shrink(originalURL(asset.id, .photo), to: destination, maxEdge: CompressionProfile.standard.photoMaxEdge)
        return [try Self.describe(destination, role: .photo)]
    }

    private static func describe(_ url: URL, role: ServerAPI.ResourceRole) throws -> ServerAPI.CompactResource {
        let digests = try Fingerprint.digests(of: url)
        return ServerAPI.CompactResource(role: role, filename: url.lastPathComponent, size: digests.size, sha256: digests.sha256)
    }

    /// HEIC where this iPhone can write it, else JPEG.
    static let writesHEIC = (CGImageDestinationCopyTypeIdentifiers() as? [String])?.contains(UTType.heic.identifier) ?? false

    /// A smaller photo, upright, keeping the original's date.
    static func shrink(_ source: URL, to destination: URL, maxEdge: Int) throws {
        guard let input = CGImageSourceCreateWithURL(source as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(input, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxEdge,
              ] as CFDictionary) else { throw Failure(status: 500, message: "Couldn't read the photo.") }
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: writesHEIC ? 0.5 : 0.6,
                                           kCGImagePropertyOrientation: 1]
        if let original = CGImageSourceCopyPropertiesAtIndex(input, 0, nil) as? [CFString: Any],
           let exif = original[kCGImagePropertyExifDictionary] {
            properties[kCGImagePropertyExifDictionary] = exif
        }
        let type = writesHEIC ? UTType.heic : UTType.jpeg
        guard let output = CGImageDestinationCreateWithURL(destination as CFURL, type.identifier as CFString, 1, nil) else {
            throw Failure(status: 500, message: "Couldn't write the compact copy.")
        }
        CGImageDestinationAddImage(output, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(output) else { throw Failure(status: 500, message: "Couldn't write the compact copy.") }
    }

    private func compactFile(_ id: String, role name: String) throws -> Response {
        let asset = try asset(id)
        guard [.ready, .imported].contains(asset.state), let file = asset.compact.first(where: { $0.role.rawValue == name }) else {
            throw Failure(status: 404, message: "No compact copy yet.")
        }
        let data = try Data(contentsOf: compactFolder(asset.id).appendingPathComponent(file.filename))
        return Response(status: 200, headers: ["Content-Type": Self.mime(file.filename)], body: data)
    }

    private func verify(_ id: String) throws -> ServerAPI.Verification {
        let asset = try asset(id)
        return ServerAPI.Verification(assetID: asset.id, checkedAt: Date(), resources: asset.resources.map { resource in
            guard resource.state == .verified, let digests = try? Fingerprint.digests(of: originalURL(asset.id, resource.role)) else {
                return .init(role: resource.role, sha256: nil, size: nil, verified: false, detail: "Not on Homespun Demo.")
            }
            let same = digests.sha256 == resource.sha256 && digests.size == resource.size
            return .init(role: resource.role, sha256: digests.sha256, size: digests.size, verified: same,
                         detail: same ? nil : "The stored copy doesn't match.")
        })
    }

    private func originalFile(_ id: String, role name: String) throws -> Response {
        let asset = try asset(id)
        guard let resource = asset.resources.first(where: { $0.role.rawValue == name }), resource.state == .verified else {
            throw Failure(status: 404, message: "Homespun Demo doesn't have that original.")
        }
        let data = try Data(contentsOf: originalURL(asset.id, resource.role))
        return Response(status: 200, headers: ["Content-Type": Self.mime(resource.filename),
                                               "Content-Disposition": "attachment; filename=\"\(resource.filename)\""], body: data)
    }

    private func lookup(_ hashes: [String]) -> [ServerAPI.CopyLookupResponse.Match] {
        let wanted = Set(hashes.map { $0.lowercased() })
        var matches: [ServerAPI.CopyLookupResponse.Match] = []
        for asset in state.assets.values where asset.state != .trashed {
            let verified = asset.resources.allSatisfy { $0.state == .verified }
            let bytes = asset.resources.reduce(0) { $0 + $1.size }
            for resource in asset.resources where wanted.contains(resource.sha256) && CopyMatching.roles.contains(resource.role) {
                matches.append(.init(sha256: resource.sha256, assetID: asset.id, role: resource.role, isOriginal: true,
                                     originalsVerified: verified, originalBytes: bytes))
            }
            for file in asset.compact where wanted.contains(file.sha256) {
                matches.append(.init(sha256: file.sha256, assetID: asset.id, role: file.role, isOriginal: false,
                                     originalsVerified: verified, originalBytes: bytes))
            }
        }
        return matches
    }

    static let oneDrive = ServerAPI.ConnectorInfo(
        id: "onedrive", name: "OneDrive",
        summary: "Copies each original to your OneDrive, in Apps › Homespun. Homespun can see only that folder.",
        fields: [.init(key: "folder", label: "Folder", help: "Inside Apps › Homespun in your OneDrive.", placeholder: "Photos")],
        signsIn: true, account: nil, enabled: false, message: nil, counts: .init())

    // MARK: Helpers

    static func json(_ value: some Encodable, status: Int = 200) throws -> Response {
        Response(status: status, body: try ServerAPI.encoder.encode(value))
    }

    static func error(_ status: Int, _ message: String, code: String? = nil) -> Response {
        Response(status: status, body: (try? ServerAPI.encoder.encode(ServerAPI.ErrorBody(error: .init(message: message, code: code))))
                 ?? Data())
    }

    static func mime(_ filename: String) -> String {
        UTType(filenameExtension: (filename as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    /// The session the demo's client uses: its protocol answers, so sessions copied from it reach the demo too.
    nonisolated static var session: URLSession { running.withLock { $0?.clientSession ?? offlineSession } }
    private nonisolated static let offlineSession = makeSession(generation: nil)
    nonisolated static let generationHeader = "X-Homespun-Demo-Generation"

    private nonisolated static func makeSession(generation: String?) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DemoURLProtocol.self] + (configuration.protocolClasses ?? [])
        if let generation { configuration.httpAdditionalHeaders = [generationHeader: generation] }
        return URLSession(configuration: configuration)
    }
}

/// Hands requests for the demo's server (`DemoServer.host`) to it, inside the app: through
/// `DemoServer.session`, and through the shared session while the demo is on (setup's pairing pages).
final class DemoURLProtocol: URLProtocol, @unchecked Sendable {
    private var answering: Task<Void, Never>?

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == DemoServer.host }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = request
        let body = Self.body(of: request)
        // The loader and its client, handed to the task that answers (URLProtocol predates Sendable).
        let loader = Unchecked(value: (protocol: self as URLProtocol, client: client))
        let server = DemoServer.running.withLock { server -> DemoServer? in
            guard let server else { return nil }
            if let generation = request.value(forHTTPHeaderField: DemoServer.generationHeader),
               generation != server.generation { return nil }
            return server
        }
        answering = Task {
            let answer: DemoServer.Response
            if let server, let url = request.url {
                let token = request.value(forHTTPHeaderField: "Authorization").map { String($0.dropFirst("Bearer ".count)) }
                answer = await server.handle(method: request.httpMethod ?? "GET", url: url, token: token, body: body,
                                             headers: request.allHTTPHeaderFields ?? [:])
            } else {
                answer = DemoServer.error(503, "The demo isn't on.")
            }
            guard !Task.isCancelled, let url = request.url else { return }
            var headers = answer.headers
            headers["Content-Length"] = "\(answer.body.count)"
            guard let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1",
                                                 headerFields: headers) else { return }
            let (loading, client) = loader.value
            client?.urlProtocol(loading, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !answer.body.isEmpty { client?.urlProtocol(loading, didLoad: answer.body) }
            client?.urlProtocolDidFinishLoading(loading)
        }
    }

    override func stopLoading() { answering?.cancel() }

    /// A request's body: `httpBody`, or (uploads, and most requests through URLSession) its stream.
    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
