// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import HTTPTypes
import HomespunCore
import Hummingbird
import HummingbirdTesting
import NIOCore
import Testing
#if canImport(AVFoundation)
import HomespunTestSupport
#endif
@testable import HomespunServerKit

// MARK: Helpers

func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("homespun-server-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func run(_ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw CocoaError(.executableLoad) }
}

let ffmpegAvailable = (try? run(["ffmpeg", "-version"])) != nil

/// Synthetic media: a detailed still, a short movie, and its "motion" twin. On macOS the still
/// and motion are a real Live Photo pair (shared content identifier), as the server checks it.
struct Media {
    let photo: URL, motion: URL, movie: URL

    static func make(in directory: URL) async throws -> Media {
        let media = Media(photo: directory.appendingPathComponent("IMG_0001.JPG"),
                          motion: directory.appendingPathComponent("IMG_0001.MOV"),
                          movie: directory.appendingPathComponent("IMG_0002.MP4"))
        #if canImport(AVFoundation)
        let identifier = "5E4F1A2B-3C4D-4E5F-8A9B-0C1D2E3F4A5B"
        try Synthetic.photo(at: media.photo, .init(width: 1600, height: 1200, contentIdentifier: identifier))
        try await Synthetic.video(at: media.motion, .init(width: 640, height: 480, bitrate: 8_000_000,
                                                          liveIdentifier: identifier))
        let ffmpegMedia = [(media.movie, "1280x720")]
        #else
        try run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=1600x1200", "-frames:v", "1",
                 "-q:v", "1", media.photo.path])
        let ffmpegMedia = [(media.motion, "640x480"), (media.movie, "1280x720")]
        #endif
        for (url, size) in ffmpegMedia {
            try run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=\(size):rate=30:duration=2",
                     "-f", "lavfi", "-i", "sine=frequency=440:duration=2", "-c:v", "mpeg4", "-q:v", "2",
                     "-c:a", "aac", "-shortest", url.path])
        }
        return media
    }
}

/// A Mac server compresses Live Photo motion itself; elsewhere the phone does.
#if os(macOS)
let liveCompactRoles: [ServerAPI.ResourceRole] = [.photo, .pairedVideo], liveDeviceCompresses: [ServerAPI.ResourceRole] = []
#else
let liveCompactRoles: [ServerAPI.ResourceRole] = [.photo], liveDeviceCompresses: [ServerAPI.ResourceRole] = [.pairedVideo]
#endif

func descriptor(_ role: ServerAPI.ResourceRole, _ url: URL, name: String? = nil) throws -> ServerAPI.ResourceDescriptor {
    let digests = try Fingerprint.digests(of: url)
    return .init(role: role, filename: name ?? url.lastPathComponent, size: digests.size, sha256: digests.sha256,
                 sha1: digests.sha1)
}

let testProfile = CompressionProfile(photoMaxEdge: 512, videoLongEdge: 320, videoShortEdge: 180)

extension TestClientProtocol {
    func call(_ uri: String, _ method: HTTPRequest.Method = .get, token: String? = nil, json: (some Encodable)? = Optional<Int>.none,
              body: Data? = nil) async throws -> TestResponse {
        var headers = HTTPFields()
        if let token { headers[.authorization] = "Bearer \(token)" }
        var buffer: ByteBuffer?
        if let json {
            headers[.contentType] = "application/json"
            buffer = ByteBuffer(bytes: try ServerAPI.encoder.encode(json))
        } else if let body {
            buffer = ByteBuffer(bytes: body)
        }
        return try await execute(uri: uri, method: method, headers: headers, body: buffer)
    }
}

extension TestResponse {
    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try ServerAPI.decoder.decode(T.self, from: Data(body.readableBytesView))
    }
    var data: Data { Data(body.readableBytesView) }
}

/// A server in a temporary data directory with one paired device.
struct Fixture {
    let directory: URL
    let server: HomespunServer

    init(immich: ImmichConfiguration? = nil, approver: (any PairingApprover)? = nil) async throws {
        directory = try temporaryDirectory()
        var configuration = ServerConfiguration(dataDirectory: directory.appendingPathComponent("data"),
                                                name: "test", profile: testProfile, immich: immich)
        configuration.maximumChunkBytes = 1 << 20
        server = try await HomespunServer(configuration: configuration, approver: approver, approvalPause: 0.3)
    }

    func pair(_ client: some TestClientProtocol) async throws -> String {
        let code = try await server.newPairingCode()
        let response = try await client.call("/api/v1/pair", .post,
                                             json: ServerAPI.PairRequest(code: code.lowercased(), deviceName: "Test iPhone"))
        #expect(response.status == .created)
        return try response.decode(ServerAPI.PairResponse.self).token
    }

    func test(_ body: @escaping @Sendable (any TestClientProtocol, String) async throws -> Void) async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = Application(router: server.router())
        try await app.test(.router) { client in try await body(client, try await pair(client)) }
    }

    /// Uploads a file in 512 KiB chunks, sending one wrong offset to exercise resume.
    func upload(_ client: some TestClientProtocol, token: String, asset: String, role: ServerAPI.ResourceRole,
                file: URL) async throws -> ServerAPI.ResourceStatus {
        let data = try Data(contentsOf: file), chunk = 512 << 10
        let path = "/api/v1/assets/\(asset)/resources/\(role.rawValue)"
        var offset = 0, last: ServerAPI.ResourceStatus?
        while offset < data.count {
            let end = min(offset + chunk, data.count)
            let response = try await client.call(path + "?offset=\(offset)", .put, token: token, body: data[offset..<end])
            #expect(response.status == .ok, "\(String(decoding: response.data, as: UTF8.self))")
            last = try response.decode(ServerAPI.ResourceStatus.self)
            if offset == 0, end < data.count {
                let wrong = try await client.call(path + "?offset=0", .put, token: token, body: data[end..<min(end + chunk, data.count)])
                #expect(wrong.status == .conflict)
                #expect(try wrong.decode(ServerAPI.ResourceStatus.self).receivedBytes == end)
            }
            offset = end
        }
        return try #require(last)
    }
}

// MARK: Pairing

@Test func pairingCodesWorkOnceAndTokensAreRequired() async throws {
    let fixture = try await Fixture()
    try await fixture.test { client, token in
        #expect(try await client.call("/api/v1/health").status == .ok)
        #expect(try await client.call("/api/v1/info").status == .unauthorized)
        #expect(try await client.call("/api/v1/info", token: "hs1_wrong").status == .unauthorized)
        let info = try await client.call("/api/v1/info", token: token).decode(ServerAPI.ServerInfo.self)
        #expect(info.mode == .files && info.name == "test")

        let code = try await fixture.server.newPairingCode()
        let request = ServerAPI.PairRequest(code: code, deviceName: "Second")
        #expect(try await client.call("/api/v1/pair", .post, json: request).status == .created)
        #expect(try await client.call("/api/v1/pair", .post, json: request).status == .forbidden)

        // Too many wrong codes invalidate outstanding ones.
        let fresh = try await fixture.server.newPairingCode()
        for _ in 0..<Catalog.pairingFailureLimit {
            _ = try await client.call("/api/v1/pair", .post, json: ServerAPI.PairRequest(code: "ZZZZ-ZZZZ", deviceName: "x"))
        }
        #expect(try await client.call("/api/v1/pair", .post, json: ServerAPI.PairRequest(code: fresh, deviceName: "y")).status
                == .forbidden)

        let devices = try await fixture.server.catalog.devices()
        #expect(devices.count == 2)
        #expect(try await fixture.server.catalog.revoke(deviceID: devices[0].id))
        #expect(try await client.call("/api/v1/info", token: token).status == .unauthorized)
    }
}

// MARK: Files mode

@Test(.enabled(if: ffmpegAvailable)) func filesModePhotoRoundTrip() async throws {
    let fixture = try await Fixture()
    let media = try await Media.make(in: fixture.directory)
    try await fixture.test { client, token in
        let photo = try descriptor(.photo, media.photo)
        let register = ServerAPI.RegisterAssetRequest(kind: .photo, captureDate: Date(timeIntervalSince1970: 1_714_592_096),
                                                      resources: [photo])
        let created = try await client.call("/api/v1/assets", .post, token: token, json: register)
        #expect(created.status == .created)
        let asset = photo.sha256
        #expect(try created.decode(ServerAPI.AssetStatus.self).state == .receiving)

        let uploaded = try await fixture.upload(client, token: token, asset: asset, role: .photo, file: media.photo)
        #expect(uploaded.state == .verified && uploaded.receivedBytes == photo.size)
        let stored = fixture.directory.appendingPathComponent("data/originals/2024/05/IMG_0001.JPG")
        #expect(try Data(contentsOf: stored) == Data(contentsOf: media.photo))

        try await fixture.server.drainJobs()
        let ready = try await client.call("/api/v1/assets/\(asset)", token: token).decode(ServerAPI.AssetStatus.self)
        #expect(ready.state == .ready && ready.deviceCompresses.isEmpty)
        let compact = try #require(ready.compact.first)
        #expect(compact.role == .photo && compact.filename == "IMG_0001.jpg" && compact.size < photo.size)

        let download = try await client.call("/api/v1/assets/\(asset)/compact/photo", token: token)
        #expect(download.status == .ok && Fingerprint.sha256(of: download.data) == compact.sha256)

        let verification = try await client.call("/api/v1/assets/\(asset)/verify", .post, token: token)
            .decode(ServerAPI.Verification.self)
        #expect(verification.allVerified && verification.resources.first?.sha256 == photo.sha256)

        #expect(try await client.call("/api/v1/assets/\(asset)/imported", .post, token: token)
            .decode(ServerAPI.AssetStatus.self).state == .imported)
        // Registering again changes nothing and needs no upload.
        let again = try await client.call("/api/v1/assets", .post, token: token, json: register)
        #expect(again.status == .ok)
        #expect(try again.decode(ServerAPI.AssetStatus.self).state == .imported)

        // A changed stored original no longer verifies.
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: stored.path)
        try Data("tampered".utf8).write(to: stored)
        let tampered = try await client.call("/api/v1/assets/\(asset)/verify", .post, token: token)
            .decode(ServerAPI.Verification.self)
        #expect(!tampered.allVerified)
    }
}

@Test(.enabled(if: ffmpegAvailable)) func livePhotoAndVideoCompactCopies() async throws {
    let fixture = try await Fixture()
    let media = try await Media.make(in: fixture.directory)
    try await fixture.test { client, token in
        let still = try descriptor(.photo, media.photo), motion = try descriptor(.pairedVideo, media.motion)
        _ = try await client.call("/api/v1/assets", .post, token: token,
                                  json: ServerAPI.RegisterAssetRequest(kind: .livePhoto, captureDate: nil, resources: [still, motion]))
        _ = try await fixture.upload(client, token: token, asset: still.sha256, role: .photo, file: media.photo)
        try await fixture.server.drainJobs()
        #expect(try await client.call("/api/v1/assets/\(still.sha256)", token: token)
            .decode(ServerAPI.AssetStatus.self).state == .receiving)
        _ = try await fixture.upload(client, token: token, asset: still.sha256, role: .pairedVideo, file: media.motion)
        try await fixture.server.drainJobs()
        let live = try await client.call("/api/v1/assets/\(still.sha256)", token: token).decode(ServerAPI.AssetStatus.self)
        #expect(live.state == .ready && Set(live.compact.map(\.role)) == Set(liveCompactRoles)
                && live.deviceCompresses == liveDeviceCompresses, "\(live.message ?? "")")
        #expect(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("data/originals/undated/IMG_0001.MOV").path))

        let movie = try descriptor(.video, media.movie)
        _ = try await client.call("/api/v1/assets", .post, token: token,
                                  json: ServerAPI.RegisterAssetRequest(kind: .video, captureDate: nil, resources: [movie]))
        _ = try await fixture.upload(client, token: token, asset: movie.sha256, role: .video, file: media.movie)
        try await fixture.server.drainJobs()
        let video = try await client.call("/api/v1/assets/\(movie.sha256)", token: token).decode(ServerAPI.AssetStatus.self)
        #expect(video.state == .ready, "\(video.message ?? "")")
        #expect(video.compact.first?.filename == "IMG_0002.mp4")
        #expect((video.compact.first?.size ?? .max) < movie.size)
    }
}

@Test(.enabled(if: ffmpegAvailable)) func uploadsAreCheckedAndPathsAreSafe() async throws {
    let fixture = try await Fixture()
    let media = try await Media.make(in: fixture.directory)
    try await fixture.test { client, token in
        let photo = try descriptor(.photo, media.photo, name: "../../etc/.passwd")
        _ = try await client.call("/api/v1/assets", .post, token: token,
                                  json: ServerAPI.RegisterAssetRequest(kind: .photo, captureDate: nil, resources: [photo]))
        let path = "/api/v1/assets/\(photo.sha256)/resources/photo"
        var corrupt = try Data(contentsOf: media.photo)
        corrupt[corrupt.count / 2] ^= 0xFF
        let mismatch = try await client.call(path + "?offset=0", .put, token: token, body: corrupt)
        #expect(mismatch.status == .unprocessableContent)
        let status = try await client.call("/api/v1/assets/\(photo.sha256)", token: token).decode(ServerAPI.AssetStatus.self)
        #expect(status.resources.first?.state == .mismatch && status.resources.first?.receivedBytes == 0)

        let tooMuch = try await client.call(path + "?offset=0", .put, token: token,
                                            body: try Data(contentsOf: media.photo) + Data([0]))
        #expect(tooMuch.status == .contentTooLarge)
        #expect(try await client.call(path + "?offset=0", .put, token: token, body: try Data(contentsOf: media.photo)).status == .ok)
        let stored = fixture.directory.appendingPathComponent("data/originals/undated/passwd")
        #expect(FileManager.default.fileExists(atPath: stored.path))

        let empty = ServerAPI.ResourceDescriptor(role: .photo, filename: "a.jpg", size: 0, sha256: String(repeating: "a", count: 64))
        #expect(try await client.call("/api/v1/assets", .post, token: token,
                                      json: ServerAPI.RegisterAssetRequest(kind: .photo, captureDate: nil, resources: [empty])).status
                == .unprocessableContent)
        #expect(try await client.call("/api/v1/assets/\(photo.sha256)/compact/photo", token: token).status == .notFound)
        #expect(try await client.call("/api/v1/assets/nothex/compact/photo", token: token).status == .badRequest)
    }
}

@Test(.enabled(if: ffmpegAvailable)) func editsAndInterruptedVerificationAreHandled() async throws {
    let fixture = try await Fixture()
    let media = try await Media.make(in: fixture.directory)
    try await fixture.test { client, token in
        let photo = try descriptor(.photo, media.photo)
        let asset = photo.sha256
        // All bytes arrived but the server stopped before verifying them.
        _ = try await client.call("/api/v1/assets", .post, token: token,
                                  json: ServerAPI.RegisterAssetRequest(kind: .photo, captureDate: nil, resources: [photo]))
        let staging = fixture.directory.appendingPathComponent("data/staging/\(asset)-photo.partial")
        try FileManager.default.copyItem(at: media.photo, to: staging)
        let finished = try await client.call("/api/v1/assets/\(asset)/resources/photo?offset=\(photo.size)", .put,
                                             token: token, body: Data())
        #expect(try finished.decode(ServerAPI.ResourceStatus.self).state == .verified)
        try await fixture.server.drainJobs()
        #expect(try await client.call("/api/v1/assets/\(asset)/imported", .post, token: token).status == .ok)

        // An edit adds resources: the old compact copy is dropped until the new ones arrive.
        let render = try descriptor(.fullSizePhoto, media.motion, name: "FullSizeRender.mov")
        let edited = ServerAPI.RegisterAssetRequest(kind: .photo, captureDate: nil, resources: [photo, render])
        let changed = try await client.call("/api/v1/assets", .post, token: token, json: edited)
            .decode(ServerAPI.AssetStatus.self)
        #expect(changed.state == .receiving && changed.compact.isEmpty)
        #expect(changed.resources.first { $0.role == .photo }?.state == .verified)

        // Registering again finishes a complete partial file left by a restart.
        let renderStaging = fixture.directory.appendingPathComponent("data/staging/\(asset)-full_size_photo.partial")
        try FileManager.default.copyItem(at: media.motion, to: renderStaging)
        let recovered = try await client.call("/api/v1/assets", .post, token: token, json: edited)
            .decode(ServerAPI.AssetStatus.self)
        #expect(recovered.state == .queued && recovered.resources.allSatisfy { $0.state == .verified })
    }
}

// MARK: Immich mode

/// A fake Immich server holding some originals, for the endpoints Homespun uses.
final class FakeImmich: @unchecked Sendable {
    struct Stored { var id: String; var data: Data; var trashed = false; var livePhotoVideoId: String? }
    let lock = NSLock()
    var assets: [String: Stored] = [:]
    let key = "immich-test-key"
    var permissions = ["asset.read", "asset.download"]

    @discardableResult
    func add(_ data: Data, motion: String? = nil) -> String {
        let id = UUID().uuidString.lowercased()
        lock.withLock { assets[id] = Stored(id: id, data: data, livePhotoVideoId: motion) }
        return id
    }

    func json(_ stored: Stored) -> [String: Any] {
        var value: [String: Any] = ["id": stored.id, "checksum": Data(Fingerprint.sha1Bytes(stored.data)).base64EncodedString(),
                                    "isTrashed": stored.trashed, "type": "IMAGE", "originalFileName": "x"]
        if let motion = stored.livePhotoVideoId { value["livePhotoVideoId"] = motion }
        return value
    }

    func router() -> Router<BasicRequestContext> {
        let router = Router()
        let authorized: @Sendable (Request) throws -> Void = { request in
            guard request.headers[HTTPField.Name("x-api-key")!] == self.key else { throw HTTPError(.unauthorized) }
        }
        router.get("api/server/ping") { _, _ in
            Response(status: .ok, body: .init(byteBuffer: ByteBuffer(string: #"{"res":"pong"}"#)))
        }
        router.get("api/api-keys/me") { request, _ in
            try authorized(request)
            let body = try JSONSerialization.data(withJSONObject: ["id": "k", "name": "homespun",
                                                                    "permissions": self.lock.withLock { self.permissions }])
            return Response(status: .ok, body: .init(byteBuffer: ByteBuffer(bytes: body)))
        }
        router.post("api/search/metadata") { request, _ in
            try authorized(request)
            let body = try JSONSerialization.jsonObject(with: Data(try await request.body.collect(upTo: 1 << 20).readableBytesView)) as! [String: Any]
            let checksum = body["checksum"] as? String
            let archive = body["visibility"] as? String == "archive"
            let items = archive ? [] : self.lock.withLock { self.assets.values.filter { !$0.trashed && Data(Fingerprint.sha1Bytes($0.data)).base64EncodedString() == checksum } }
            let data = try JSONSerialization.data(withJSONObject: ["assets": ["items": items.map(self.json)], "albums": ["items": []]])
            return Response(status: .ok, body: .init(byteBuffer: ByteBuffer(bytes: data)))
        }
        router.get("api/assets/:id") { request, context in
            try authorized(request)
            guard let stored = self.lock.withLock({ self.assets[context.parameters.get("id") ?? ""] }) else { throw HTTPError(.badRequest) }
            return Response(status: .ok, body: .init(byteBuffer: ByteBuffer(bytes: try JSONSerialization.data(withJSONObject: self.json(stored)))))
        }
        router.get("api/assets/:id/original") { request, context in
            try authorized(request)
            guard let stored = self.lock.withLock({ self.assets[context.parameters.get("id") ?? ""] }) else { throw HTTPError(.notFound) }
            return Response(status: .ok, body: .init(byteBuffer: ByteBuffer(bytes: stored.data)))
        }
        return router
    }
}

extension Fingerprint {
    static func sha1Bytes(_ data: Data) -> [UInt8] {
        let hex = sha1(of: data)
        return stride(from: 0, to: hex.count, by: 2).map {
            UInt8(hex[hex.index(hex.startIndex, offsetBy: $0)..<hex.index(hex.startIndex, offsetBy: $0 + 2)], radix: 16)!
        }
    }
}

@Test(.enabled(if: ffmpegAvailable)) func immichModeFindsVerifiesAndRechecksOriginals() async throws {
    let immich = FakeImmich()
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let media = try await Media.make(in: directory)
    try await Application(router: immich.router(), configuration: .init(address: .hostname("localhost", port: 0)))
        .test(.live) { immichClient in
            let url = URL(string: "http://localhost:\(immichClient.port!)")!
            let fixture = try await Fixture(immich: ImmichConfiguration(url: url, apiKey: immich.key))
            try await fixture.test { client, token in
                let still = try descriptor(.photo, media.photo), motion = try descriptor(.pairedVideo, media.motion)
                let register = ServerAPI.RegisterAssetRequest(kind: .livePhoto, captureDate: nil, resources: [still, motion])
                let asset = still.sha256
                // Not backed up to Immich yet.
                _ = try await client.call("/api/v1/assets", .post, token: token, json: register)
                try await fixture.server.drainJobs()
                var status = try await client.call("/api/v1/assets/\(asset)", token: token).decode(ServerAPI.AssetStatus.self)
                #expect(status.state == .waitingForImmich && status.resources.allSatisfy { $0.state == .notInImmich })
                #expect(try await client.call("/api/v1/assets/\(asset)/resources/photo?offset=0", .put, token: token,
                                              body: Data([1])).status == .conflict)

                // The Immich app backs it up; registering again finds and verifies it.
                let motionID = immich.add(try Data(contentsOf: media.motion))
                let stillID = immich.add(try Data(contentsOf: media.photo), motion: motionID)
                _ = try await client.call("/api/v1/assets", .post, token: token, json: register)
                try await fixture.server.drainJobs()
                status = try await client.call("/api/v1/assets/\(asset)", token: token).decode(ServerAPI.AssetStatus.self)
                #expect(status.state == .ready, "\(status.message ?? "")")
                #expect(status.resources.allSatisfy { $0.state == .verified } && status.deviceCompresses == liveDeviceCompresses)
                #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.appendingPathComponent("data/cache").path).isEmpty)
                #expect(try FileManager.default.subpathsOfDirectory(atPath: fixture.directory.appendingPathComponent("data/originals").path).isEmpty)

                var verification = try await client.call("/api/v1/assets/\(asset)/verify", .post, token: token)
                    .decode(ServerAPI.Verification.self)
                #expect(verification.allVerified)
                immich.lock.withLock { immich.assets[motionID]?.trashed = true }
                verification = try await client.call("/api/v1/assets/\(asset)/verify", .post, token: token)
                    .decode(ServerAPI.Verification.self)
                #expect(!verification.allVerified && verification.resources.first { $0.role == .pairedVideo }?.detail == "in the Immich trash")
                _ = stillID

                // An Immich copy whose bytes differ from the phone's is never trusted.
                let movie = try descriptor(.video, media.movie)
                var wrong = try Data(contentsOf: media.movie)
                immich.add(wrong)
                wrong[0] ^= 1
                let lying = ServerAPI.ResourceDescriptor(role: .video, filename: "m.mp4", size: movie.size,
                                                         sha256: movie.sha256, sha1: Fingerprint.sha1(of: try Data(contentsOf: media.movie)))
                _ = try await client.call("/api/v1/assets", .post, token: token,
                                          json: ServerAPI.RegisterAssetRequest(kind: .video, captureDate: nil, resources: [
                                            .init(role: .video, filename: "m.mp4", size: wrong.count,
                                                  sha256: Fingerprint.sha256(of: wrong), sha1: lying.sha1)]))
                try await fixture.server.drainJobs()
                let failed = try await client.call("/api/v1/assets/\(Fingerprint.sha256(of: wrong))", token: token)
                    .decode(ServerAPI.AssetStatus.self)
                #expect(failed.state == .failed && failed.resources.first?.state == .mismatch)
            }
        }
}

// MARK: Setup

/// Answers approval requests the way the test says; `hold` waits until withdrawn.
final class FakeApprover: PairingApprover, @unchecked Sendable {
    let lock = NSLock()
    var answer: Bool? = true
    var hold = false
    var asked: [(device: String, match: String)] = []
    var withdrawn = 0

    func ask(device: String, match: String, server: String, seconds: Int) async -> Bool? {
        let (hold, answer) = lock.withLock { asked.append((device, match)); return (self.hold, self.answer) }
        guard hold else { return answer }
        try? await Task.sleep(for: .seconds(30))
        if Task.isCancelled { lock.withLock { withdrawn += 1 } }
        return nil
    }
}

@Test func devicesPairByApprovalOrWithACodeFromAPairedDevice() async throws {
    let approver = FakeApprover()
    let fixture = try await Fixture(approver: approver)
    try await fixture.test { client, token in
        let options = try await client.call("/api/v1/pair/options").decode(ServerAPI.PairingOptions.self)
        #expect(options.canApprove && options.serverName == "test" && options.pairCommand.hasSuffix(" pair"))

        func ask(_ name: String) async throws -> TestResponse {
            try await client.call("/api/v1/pair/requests", .post, json: ServerAPI.ApprovalRequest(deviceName: name))
        }
        func status(_ ticket: ServerAPI.ApprovalTicket, secret: String? = nil) async throws -> TestResponse {
            try await client.call("/api/v1/pair/requests/\(ticket.id)", token: secret ?? ticket.secret)
        }
        func answer(_ ticket: ServerAPI.ApprovalTicket) async throws -> ServerAPI.ApprovalStatus {
            for _ in 0..<50 {
                let current = try await status(ticket).decode(ServerAPI.ApprovalStatus.self)
                if current.state != .waiting { return current }
                try await Task.sleep(for: .milliseconds(20))
            }
            return .init(state: .waiting)
        }

        // Allowed: the device gets a token once, and the dialog named it (on one line) with the shown number.
        let allowed = try await ask("Alex\u{0}'s\u{2028}iPad").decode(ServerAPI.ApprovalTicket.self)
        #expect(allowed.match.count == 4)
        #expect(try await status(allowed, secret: "wrong").status == .notFound)
        // Until the device collects its token, no one else can take the approval's place.
        try await Task.sleep(for: .milliseconds(100))
        #expect(try await ask("Imposter").status == .tooManyRequests)
        let approved = try await answer(allowed)
        let pairing = try #require(approved.pairing)
        #expect(approved.state == .approved && approver.lock.withLock { approver.asked.last?.device } == "Alex's iPad")
        #expect(approver.lock.withLock { approver.asked.last?.match } == allowed.match)
        #expect(try await client.call("/api/v1/info", token: pairing.token).status == .ok)
        #expect(try await status(allowed).status == .notFound)

        // Denied: no device, and a pause before the next question.
        #expect(try await ask("Too soon").status == .tooManyRequests)
        try await Task.sleep(for: .milliseconds(400))
        approver.lock.withLock { approver.answer = false }
        let denied = try await ask("Stranger").decode(ServerAPI.ApprovalTicket.self)
        #expect(try await answer(denied) == .init(state: .denied))
        #expect(try await ask("Stranger").status == .tooManyRequests)
        #expect(try await fixture.server.catalog.devices().count == 2)
    }

    // One question at a time; withdrawing it closes the dialog.
    let holding = FakeApprover()
    holding.hold = true
    let second = try await Fixture(approver: holding)
    try await second.test { client, token in
        let request = ServerAPI.ApprovalRequest(deviceName: "iPhone")
        let ticket = try await client.call("/api/v1/pair/requests", .post, json: request).decode(ServerAPI.ApprovalTicket.self)
        #expect(try await client.call("/api/v1/pair/requests", .post, json: request).status == .tooManyRequests)
        #expect(try await client.call("/api/v1/pair/requests/\(ticket.id)", .delete, token: "wrong").status == .notFound)
        #expect(try await client.call("/api/v1/pair/requests/\(ticket.id)", .delete, token: ticket.secret).status == .noContent)
        #expect(try await client.call("/api/v1/pair/requests", .post, json: request).status == .tooManyRequests)
        try await Task.sleep(for: .milliseconds(200))
        #expect(holding.lock.withLock { holding.withdrawn } == 1)

        // A paired device makes a code for another device.
        let code = try await client.call("/api/v1/pairing-codes", .post, token: token).decode(ServerAPI.PairingCode.self)
        #expect(code.expiresIn == 600)
        #expect(try await client.call("/api/v1/pairing-codes", .post).status == .unauthorized)
        let paired = try await client.call("/api/v1/pair", .post, json: ServerAPI.PairRequest(code: code.code, deviceName: "iPad"))
        #expect(paired.status == .created)
    }

    // Without someone at the screen (Linux, or a server started over SSH) the app asks for a code.
    let headless = try await Fixture()
    try await headless.test { client, _ in
        #expect(try await !client.call("/api/v1/pair/options").decode(ServerAPI.PairingOptions.self).canApprove)
        let refused = try await client.call("/api/v1/pair/requests", .post, json: ServerAPI.ApprovalRequest(deviceName: "iPhone"))
        #expect(refused.status == .conflict && String(decoding: refused.data, as: UTF8.self).contains(" pair` on it"))
    }
}

@Test func setupHelpersPickTheHomeNetworkAndWriteServices() throws {
    let interfaces: [Network.Interface] = [
        .init(name: "lo", address: "127.0.0.1"), .init(name: "lxdbr0", address: "10.85.43.1"),
        .init(name: "wg0", address: "10.230.195.1"), .init(name: "docker0", address: "172.17.0.1"),
        .init(name: "eno2", address: "10.0.0.116"), .init(name: "wlo1", address: "192.168.1.5"),
    ]
    #expect(Network.preferredAddress(interfaces) == "10.0.0.116")
    #expect(Network.preferredAddress(Array(interfaces.prefix(4)) + [.init(name: "wlan0", address: "192.168.1.5")]) == "192.168.1.5")
    #expect(Network.preferredAddress(Array(interfaces.prefix(4))) == nil)

    let qr = try TerminalQR.render("homespun://pair?server=10.0.0.116:8787&code=K7Q4-M9XT")
    let rows = qr.split(separator: "\n")
    #expect(rows.count > 10 && rows.allSatisfy { $0.hasPrefix("\u{1B}[30;47m") && $0.hasSuffix("\u{1B}[0m") })
    #expect(Set(rows.map { $0.count }).count == 1)

    let home = URL(fileURLWithPath: "/home/alex")
    let environment = ["HOMESPUN_DATA": "/srv/homespun", "HOMESPUN_HOST": "0.0.0.0", "PATH": "/usr/bin"]
    let linux = ServiceInstaller.plan(executable: "/opt/hs/homespun-server", environment: environment, os: .linux,
                                      home: home, userID: 1000, user: "alex")
    #expect(linux.path.path == "/home/alex/.config/systemd/user/homespun.service")
    #expect(linux.contents.contains("ExecStart=/opt/hs/homespun-server serve")
            && linux.contents.contains("Environment=\"HOMESPUN_DATA=/srv/homespun\""))
    #expect(linux.commands.contains(["systemctl", "--user", "enable", "--now", "homespun.service"]))
    let mac = ServiceInstaller.plan(executable: "/Users/alex/hs & co/homespun-server", environment: environment, os: .macOS,
                                    home: URL(fileURLWithPath: "/Users/alex"), userID: 501, user: "alex")
    #expect(mac.path.path == "/Users/alex/Library/LaunchAgents/photos.homespun.server.plist")
    let plist = try PropertyListSerialization.propertyList(from: Data(mac.contents.utf8), format: nil) as? [String: Any]
    #expect((plist?["ProgramArguments"] as? [String]) == ["/Users/alex/hs & co/homespun-server", "serve"])
    #expect((plist?["EnvironmentVariables"] as? [String: String])?["HOMESPUN_DATA"] == "/srv/homespun")
    #expect(mac.prepare == [["launchctl", "bootout", "gui/501/photos.homespun.server"]])
    #expect(mac.commands == [["launchctl", "bootstrap", "gui/501", mac.path.path]])
}

@Test func pairingInstructionsAndSelfCheck() async throws {
    let fixture = try await Fixture()
    try await fixture.test { client, token in
        let text = fixture.server.pairingInstructions(code: "K7Q4-M9XT")
        #expect(text.contains("homespun://pair?server=") && text.contains("K7Q4-M9XT") && text.contains("only on this computer"))
        let report = try await client.call("/api/v1/setup", token: token).decode(ServerSetup.Report.self)
        #expect(Set(report.checks.map(\.id)) == ["photos", "videos", "live_photos", "discovery", "storage", "service", "immich"])
        #expect(report.checks.first { $0.id == "photos" }?.status == .ok)
        #expect(report.checks.first { $0.id == "immich" }?.status == .info)
        #expect(report.checks.first { $0.id == "service" }?.fix.first?.contains("install-service --data") == true)
        let info = try await client.call("/api/v1/info", token: token).decode(ServerAPI.ServerInfo.self)
        #expect(info.platform == report.platform)

        var configuration = fixture.server.configuration
        configuration.publicURL = "photos.example.lan:9000"
        #expect(Network.publicURL(configuration: configuration)?.absoluteString == "http://photos.example.lan:9000")
        // The catalog holds secrets, so only the server's user can read it.
        let catalog = fixture.server.storage.catalog.path
        for file in [catalog, catalog + "-wal"] {
            #expect(try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? Int == 0o600)
        }
    }
}

@Test func immichIsConnectedFromTheApp() async throws {
    let immich = FakeImmich()
    try await Application(router: immich.router(), configuration: .init(address: .hostname("localhost", port: 0)))
        .test(.live) { immichClient in
            let url = "http://localhost:\(immichClient.port!)"
            let fixture = try await Fixture()
            try await fixture.test { client, token in
                let wrong = ServerAPI.ImmichSettingsRequest(url: url, apiKey: "nope")
                let rejected = try await client.call("/api/v1/settings/immich", .put, token: token, json: wrong)
                #expect(rejected.status == .unprocessableContent)
                #expect(String(decoding: rejected.data, as: UTF8.self).contains("did not accept"))
                #expect(try await client.call("/api/v1/settings/immich", .put, token: token,
                                              json: ServerAPI.ImmichSettingsRequest(url: "ftp://x", apiKey: "k")).status == .badRequest)

                immich.lock.withLock { immich.permissions = ["asset.read"] }
                #expect(try await client.call("/api/v1/settings/immich", .put, token: token,
                                              json: ServerAPI.ImmichSettingsRequest(url: url, apiKey: immich.key)).status
                        == .unprocessableContent)

                immich.lock.withLock { immich.permissions = ["all"] }
                let connected = try await client.call("/api/v1/settings/immich", .put, token: token,
                                                      json: ServerAPI.ImmichSettingsRequest(url: url, apiKey: immich.key))
                    .decode(ServerAPI.ImmichSettings.self)
                #expect(connected.connected && connected.keyHint == "-key" && connected.message?.contains("only asset.read") == true)
                #expect(try await client.call("/api/v1/info", token: token).decode(ServerAPI.ServerInfo.self).mode == .immich)
                let shown = try await client.call("/api/v1/settings/immich", token: token)
                #expect(!String(decoding: shown.data, as: UTF8.self).contains(immich.key))
                #expect(try shown.decode(ServerAPI.ImmichSettings.self).connected)

                // The setting survives a restart.
                let restarted = try await HomespunServer(configuration: fixture.server.configuration)
                let immichMode = await restarted.immichState.mode
                #expect(immichMode == .immich)

                let cleared = try await client.call("/api/v1/settings/immich", .delete, token: token)
                    .decode(ServerAPI.ImmichSettings.self)
                #expect(!cleared.connected && cleared.url == nil)
                #expect(try await client.call("/api/v1/info", token: token).decode(ServerAPI.ServerInfo.self).mode == .files)

                // Disconnecting outlasts an Immich set in the environment.
                var configured = fixture.server.configuration
                configured.immich = ImmichConfiguration(url: URL(string: url)!, apiKey: immich.key)
                let reconfigured = try await HomespunServer(configuration: configured)
                let reconfiguredMode = await reconfigured.immichState.mode
                #expect(reconfiguredMode == .files)
            }
        }
}

@Test func applicationRunsWithItsServices() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    // Listening on all interfaces adds Bonjour advertising, which must not stop the server
    // when the tools are missing.
    let configuration = ServerConfiguration(dataDirectory: directory, host: "0.0.0.0", port: 0, name: "test")
    let server = try await HomespunServer(configuration: configuration)
    try await server.application().test(.live) { client in
        try await Task.sleep(for: .seconds(2))
        #expect(try await client.call("/api/v1/health").status == .ok)
    }
    // Shutting down also stops the Bonjour helper, if this computer has one.
    if let tool = ServiceAdvertiser.tool {
        let name = (tool as NSString).lastPathComponent
        #expect(Tools.output("pgrep", ["-f", "\(name) .*test _homespun._tcp"]) == nil, "\(name) outlived the server")
    }
}
