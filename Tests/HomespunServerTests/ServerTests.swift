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
            if var pair = json as? ServerAPI.PairRequest, pair.challenge == nil {
                let challenge = try await call("/api/v1/pair/challenge", .post,
                                               json: ServerAPI.CodeChallengeRequest(nonce: PairingCrypto.encode(PairingCrypto.nonce())))
                    .decode(ServerAPI.CodeChallenge.self)
                pair.challenge = challenge.id
                buffer = ByteBuffer(bytes: try ServerAPI.encoder.encode(pair))
            } else {
                buffer = ByteBuffer(bytes: try ServerAPI.encoder.encode(json))
            }
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

    init(immich: ImmichConfiguration? = nil, approver: (any PairingApprover)? = nil,
         connectors: [any Connector] = [], originals: String? = nil, directory: URL? = nil) async throws {
        let base = try directory ?? temporaryDirectory()
        self.directory = base
        var configuration = ServerConfiguration(dataDirectory: base.appendingPathComponent("data"),
                                                name: "test", profile: testProfile, immich: immich)
        configuration.originalsDirectory = originals.map { base.appendingPathComponent($0, isDirectory: true) }
        configuration.maximumChunkBytes = 1 << 20
        server = try await HomespunServer(configuration: configuration, connectors: connectors, approver: approver,
                                          // Long enough for a slow machine's requests to fit inside it.
                                          approvalPause: 2, builtIn: [], codeRounds: 1_000, challengeInterval: 0)
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
        let app = Application(router: server.testRouter())
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
        let stored = fixture.directory.appendingPathComponent("data/originals/Test iPhone/2024/05/IMG_0001.JPG")
        #expect(try Data(contentsOf: stored) == Data(contentsOf: media.photo))

        try await fixture.server.drainJobs()
        let ready = try await client.call("/api/v1/assets/\(asset)", token: token).decode(ServerAPI.AssetStatus.self)
        #expect(ready.state == .ready && ready.deviceCompresses.isEmpty)
        let compact = try #require(ready.compact.first)
        #expect(compact.role == .photo && compact.filename == "IMG_0001.jpg" && compact.size < photo.size)

        let download = try await client.call("/api/v1/assets/\(asset)/compact/photo", token: token)
        #expect(download.status == .ok && Fingerprint.sha256(of: download.data) == compact.sha256)

        // The compact copy, picked again on the phone (say, outside the Homespun album), is not an original.
        let copy = ServerAPI.ResourceDescriptor(role: .photo, filename: "IMG_0001.jpg", size: download.data.count,
                                                sha256: compact.sha256, sha1: Fingerprint.sha1(of: download.data))
        let refused = try await client.call("/api/v1/assets", .post, token: token,
                                            json: ServerAPI.RegisterAssetRequest(kind: .photo, captureDate: nil, resources: [copy]))
        let error = try refused.decode(ServerAPI.ErrorBody.self).error
        #expect(refused.status == .unprocessableContent && error.code == ServerAPI.ErrorCode.compactCopy)
        #expect(error.message.contains("of IMG_0001.JPG"))
        #expect(try await client.call("/api/v1/assets/\(compact.sha256)", token: token).status == .notFound)

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

@Test(.enabled(if: ffmpegAvailable), arguments: [false, true], [false, true])
func registeringFailedFilesRetriesWithoutUploadingAgain(exhaustedRetries: Bool, compact: Bool) async throws {
    let fixture = try await Fixture()
    let media = try await Media.make(in: fixture.directory)
    try await fixture.test { client, token in
        let movie = try descriptor(.video, media.movie)
        let request = ServerAPI.RegisterAssetRequest(kind: .video, captureDate: nil, resources: [movie])
        _ = try await client.call("/api/v1/assets", .post, token: token, json: request)
        _ = try await fixture.upload(client, token: token, asset: movie.sha256, role: .video, file: media.movie)
        let catalog = fixture.server.catalog
        let originals = try await catalog.resources(movie.sha256)

        // Both permanent processing errors and exhausted transient retries leave the asset failed.
        var job = try #require(try await catalog.claim(owner: "test", lease: 60))
        if exhaustedRetries {
            job.attempts = Catalog.maximumAttempts
            #expect(try await !catalog.fail(job, error: "Test processing failure"))
        } else {
            try await catalog.finish(job)
        }
        try await catalog.setState(movie.sha256, .failed, message: "Test processing failure")

        let retry = ServerAPI.RegisterAssetRequest(kind: .video, captureDate: nil, resources: [movie], compact: compact)
        let response = try await client.call("/api/v1/assets", .post, token: token, json: retry)
        #expect(response.status == .ok)
        let status = try response.decode(ServerAPI.AssetStatus.self)
        #expect(status.state == (compact ? .queued : .stored))
        #expect(status.message == nil)
        #expect(status.resources.first?.state == .verified)
        #expect(status.resources.first?.receivedBytes == movie.size)
        #expect(try await catalog.resources(movie.sha256) == originals)
        if !compact {
            #expect(try await catalog.jobStatus(JobRunner.compress, assetID: movie.sha256)
                    == (exhaustedRetries ? "failed" : "succeeded"))
        }

        // Asking for the compact copy again neither uploads the original nor duplicates the job.
        let again = try await client.call("/api/v1/assets", .post, token: token, json: request)
            .decode(ServerAPI.AssetStatus.self)
        #expect(again.state == .queued && again.message == nil)
        #expect(try await catalog.jobStatus(JobRunner.compress, assetID: movie.sha256) == "queued")
        let queued = try #require(try await catalog.claim(owner: "test", lease: 60))
        #expect(queued.id == job.id && queued.attempts == 1)
        #expect(try await catalog.claim(owner: "test", lease: 60) == nil)
        try await catalog.releaseLeases()
        try await fixture.server.drainJobs()
        let ready = try await client.call("/api/v1/assets/\(movie.sha256)", token: token)
            .decode(ServerAPI.AssetStatus.self)
        #expect(ready.state == .ready && ready.message == nil && !ready.compact.isEmpty)
        let unchanged = try await client.call("/api/v1/assets", .post, token: token, json: request)
            .decode(ServerAPI.AssetStatus.self)
        #expect(unchanged == ready)
        #expect(try await catalog.jobStatus(JobRunner.compress, assetID: movie.sha256) == "succeeded")
    }
}

@Test(arguments: [ServerAPI.ResourceState.missing, .partial, .mismatch])
func registeringFailedFilesRequiresEveryOriginalVerified(resourceState: ServerAPI.ResourceState) async throws {
    let fixture = try await Fixture()
    try await fixture.test { client, token in
        let movie = ServerAPI.ResourceDescriptor(role: .video, filename: "video.mov", size: 100,
                                                  sha256: String(repeating: "a", count: 64))
        let request = ServerAPI.RegisterAssetRequest(kind: .video, captureDate: nil, resources: [movie])
        _ = try await client.call("/api/v1/assets", .post, token: token, json: request)
        try await fixture.server.catalog.markResource(movie.sha256, role: .video, state: resourceState)
        try await fixture.server.catalog.setState(movie.sha256, .failed, message: "Original is not verified")

        let status = try await client.call("/api/v1/assets", .post, token: token, json: request)
            .decode(ServerAPI.AssetStatus.self)
        #expect(status.state == .failed && status.message == "Original is not verified")
        #expect(status.resources.first?.state == resourceState)
        #expect(try await fixture.server.catalog.jobStatus(JobRunner.compress, assetID: movie.sha256) == nil)
    }
}

/// A connector that records what it was given, or fails the way a test asks.
final class FakeConnector: Connector, @unchecked Sendable {
    enum Behaviour { case copy, fail, retryLater, error }
    let id = "fake"
    let name = "Fake cloud"
    let summary = "A test destination."
    var fields: [ServerAPI.ConnectorField] {
        [.init(key: "folder", label: "Folder"), .init(key: "token", label: "Token", kind: .secret)]
    }
    let lock = NSLock()
    var behaviour = Behaviour.copy
    var checkError: String?
    var copies: [(assetID: String, files: [ServerAPI.ResourceRole: Data], settings: [String: String])] = []

    func check(_ context: ConnectorContext) async throws -> String? {
        if let error = lock.withLock({ checkError }) { throw ConnectorError.failed(error) }
        return "Folder \(try await context.value("folder") ?? "?")"
    }

    func copy(_ item: ConnectorItem, context: ConnectorContext) async throws -> String? {
        switch lock.withLock({ behaviour }) {
        case .fail: throw ConnectorError.failed("The fake cloud refused it.")
        case .retryLater: throw ConnectorError.retryLater("The fake cloud is full.", after: 3600)
        case .error: throw CocoaError(.fileWriteUnknown)
        case .copy: break
        }
        var files: [ServerAPI.ResourceRole: Data] = [:]
        for file in item.files {
            let data = try Data(contentsOf: file.url)
            #expect(Fingerprint.sha256(of: data) == file.sha256 && data.count == file.size)
            files[file.role] = data
        }
        let settings = try await context.settings()
        lock.withLock { copies.append((item.assetID, files, settings)) }
        return "fake://\(item.assetID.prefix(8))"
    }
}

@Test(.enabled(if: ffmpegAvailable)) func connectorsCopyCheckedOriginals() async throws {
    let fake = FakeConnector()
    let fixture = try await Fixture(connectors: [fake])
    let media = try await Media.make(in: fixture.directory)
    try await fixture.test { client, token in
        func connectors() async throws -> [ServerAPI.ConnectorInfo] {
            try await client.call("/api/v1/connectors", token: token).decode([ServerAPI.ConnectorInfo].self)
        }
        func update(_ body: ServerAPI.ConnectorUpdate) async throws -> TestResponse {
            try await client.call("/api/v1/connectors/fake", .put, token: token, json: body)
        }
        func add(_ url: URL, _ kind: ServerAPI.AssetKind, _ role: ServerAPI.ResourceRole) async throws -> String {
            let resource = try descriptor(role, url)
            _ = try await client.call("/api/v1/assets", .post, token: token,
                                      json: ServerAPI.RegisterAssetRequest(kind: kind, captureDate: nil, resources: [resource]))
            _ = try await fixture.upload(client, token: token, asset: resource.sha256, role: role, file: url)
            try await fixture.server.drainJobs()
            return resource.sha256
        }
        #expect(try await client.call("/api/v1/connectors").status == .unauthorized)
        var fakeInfo = try #require(try await connectors().first)
        #expect(fakeInfo.id == "fake" && !fakeInfo.enabled && fakeInfo.fields.map(\.key) == ["folder", "token"])

        // Off: nothing is copied.
        let first = try await add(media.photo, .photo, .photo)
        #expect(fake.lock.withLock { fake.copies.isEmpty })

        // Turning it on checks the settings; secrets are kept but never sent back.
        fake.lock.withLock { fake.checkError = "Wrong folder." }
        let refused = try await update(.init(enabled: true, settings: ["folder": "Photos", "token": "s3cret"]))
        #expect(refused.status == .unprocessableContent && String(decoding: refused.data, as: UTF8.self).contains("Wrong folder."))
        #expect(try await update(.init(settings: ["nope": "x"])).status == .unprocessableContent)
        fake.lock.withLock { fake.checkError = nil }
        let enabled = try await update(.init(enabled: true))
        #expect(!String(decoding: enabled.data, as: UTF8.self).contains("s3cret"))
        fakeInfo = try enabled.decode(ServerAPI.ConnectorInfo.self)
        #expect(fakeInfo.enabled && fakeInfo.account == "Folder Photos")
        #expect(fakeInfo.fields.map(\.value) == ["Photos", nil] && fakeInfo.fields.map(\.isSet) == [true, true])

        // New originals are copied once checked; the item's own state doesn't change.
        let second = try await add(media.movie, .video, .video)
        let copied = try #require(fake.lock.withLock { fake.copies.first })
        let movie = try Data(contentsOf: media.movie)
        #expect(copied.assetID == second && copied.files[.video] == movie)
        #expect(copied.settings["token"] == "s3cret")
        #expect(try await connectors().first?.counts == .init(copied: 1))
        #expect(try await client.call("/api/v1/assets/\(second)", token: token).decode(ServerAPI.AssetStatus.self).state == .ready)

        // A recent item waiting for its compact copy isn't copied until it gets one.
        let recentPhoto = fixture.directory.appendingPathComponent("IMG_0004.JPG")
        try (Data(contentsOf: media.photo) + Data("a recent photo".utf8)).write(to: recentPhoto)
        let recent = try descriptor(.photo, recentPhoto)
        _ = try await client.call("/api/v1/assets", .post, token: token,
                                  json: ServerAPI.RegisterAssetRequest(kind: .photo, captureDate: nil, resources: [recent],
                                                                       compact: false))
        _ = try await fixture.upload(client, token: token, asset: recent.sha256, role: .photo, file: recentPhoto)
        try await fixture.server.drainJobs()
        #expect(fake.lock.withLock { fake.copies.count } == 1)
        _ = try await client.call("/api/v1/assets", .post, token: token,
                                  json: ServerAPI.RegisterAssetRequest(kind: .photo, captureDate: nil, resources: [recent],
                                                                       compact: true))
        try await fixture.server.drainJobs()
        #expect(fake.lock.withLock { fake.copies.map(\.assetID) }.contains(recent.sha256))
        #expect(try await connectors().first?.counts == .init(copied: 2))

        // A full destination waits without failing; a refusal is final and shown in the app.
        fake.lock.withLock { fake.behaviour = .retryLater }
        let thirdPhoto = fixture.directory.appendingPathComponent("IMG_0003.JPG")
        try (Data(contentsOf: media.photo) + Data("another photo".utf8)).write(to: thirdPhoto)
        let third = try await add(thirdPhoto, .photo, .photo)
        fakeInfo = try #require(try await connectors().first)
        #expect(fakeInfo.counts == .init(copied: 2, pending: 1) && fakeInfo.message == "The fake cloud is full.")
        #expect(try await client.call("/api/v1/assets/\(third)", token: token).decode(ServerAPI.AssetStatus.self).state == .ready)
        // Copying what's already on the server skips copies already made (the waiting one stays waiting).
        fake.lock.withLock { fake.behaviour = .fail }
        #expect(try await update(.init(copyExisting: true)).status == .ok)
        try await fixture.server.drainJobs()
        fakeInfo = try #require(try await connectors().first)
        #expect(fakeInfo.counts == .init(copied: 2, pending: 1, failed: 1) && fakeInfo.message == "The fake cloud refused it.")

        // Asking again retries the failed one; removing forgets the settings but keeps copies made.
        fake.lock.withLock { fake.behaviour = .copy }
        #expect(try await update(.init(copyExisting: true)).status == .ok)
        try await fixture.server.drainJobs()
        #expect(Set(fake.lock.withLock { fake.copies.map(\.assetID) }) == [first, second, recent.sha256])
        #expect(try await connectors().first?.counts == .init(copied: 3, pending: 1))
        #expect(try await client.call("/api/v1/connectors/fake", .delete, token: token).status == .noContent)
        fakeInfo = try #require(try await connectors().first)
        #expect(!fakeInfo.enabled && fakeInfo.account == nil && fakeInfo.fields.allSatisfy { !$0.isSet })
        #expect(fakeInfo.counts == .init(copied: 3))
        #expect(try await client.call("/api/v1/connectors/nope", .put, token: token, json: ServerAPI.ConnectorUpdate(enabled: true))
            .status == .unprocessableContent)
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
        #expect(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("data/originals/Test iPhone/undated/IMG_0001.MOV").path))

        // The phone reports the motion it compressed itself, so the copy is recognised later
        // (after a reinstall, say); only files the server left to the phone count.
        let phoneMotion = Fingerprint.sha256(of: Data("motion compressed on the phone".utf8))
        let fakeStill = Fingerprint.sha256(of: Data("not the server's still".utf8))
        #expect(try await client.call("/api/v1/assets/\(still.sha256)/imported", .post, token: token,
                                      json: ServerAPI.ImportedRequest(deviceCopies: [.init(role: .photo, sha256: "nope")]))
            .status == .badRequest)
        let imported = try await client.call("/api/v1/assets/\(still.sha256)/imported", .post, token: token, json: ServerAPI.ImportedRequest(
            deviceCopies: [.init(role: .pairedVideo, sha256: phoneMotion), .init(role: .photo, sha256: fakeStill)]))
        #expect(try imported.decode(ServerAPI.AssetStatus.self).state == .imported)
        let known = try await client.call("/api/v1/copies/lookup", .post, token: token,
                                          json: ServerAPI.CopyLookupRequest(sha256: [phoneMotion, fakeStill]))
            .decode(ServerAPI.CopyLookupResponse.self).matches
        #expect(known.map(\.sha256) == (liveDeviceCompresses.contains(.pairedVideo) ? [phoneMotion] : []))

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
        let stored = fixture.directory.appendingPathComponent("data/originals/Test iPhone/undated/passwd")
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
            let fake = FakeConnector()
            let fixture = try await Fixture(immich: ImmichConfiguration(url: url, apiKey: immich.key), connectors: [fake])
            try await fixture.test { client, token in
                #expect(try await client.call("/api/v1/connectors/fake", .put, token: token,
                                              json: ServerAPI.ConnectorUpdate(enabled: true)).status == .ok)
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
                // A connector gets the originals downloaded from Immich again and checked.
                let copied = try #require(fake.lock.withLock { fake.copies.first })
                let stillData = try Data(contentsOf: media.photo), motionData = try Data(contentsOf: media.motion)
                #expect(copied.assetID == asset && copied.files[.photo] == stillData && copied.files[.pairedVideo] == motionData)
                #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.appendingPathComponent("data/cache").path).isEmpty)
                #expect(try FileManager.default.subpathsOfDirectory(atPath: fixture.directory.appendingPathComponent("data/originals").path).isEmpty)

                // The self-check notices when the Immich app uploads Homespun's compact copies.
                func copiesCheck() async throws -> ServerSetup.Check? {
                    try await client.call("/api/v1/setup", token: token).decode(ServerSetup.Report.self)
                        .checks.first { $0.id == "immich_copies" }
                }
                // Copies from before SHA-1s were kept are looked up from their files.
                try await fixture.server.catalog.forgetCopySHA1s()
                #expect(try await copiesCheck()?.status == .ok)
                let compactPhoto = try await client.call("/api/v1/assets/\(asset)/compact/photo", token: token).data
                _ = immich.add(compactPhoto)
                let warned = try #require(try await copiesCheck())
                #expect(warned.status == .warning && warned.detail.hasPrefix("1 of the latest")
                        && warned.detail.contains("exclude the Homespun album"))

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
            let response = try await client.call("/api/v1/pair/requests", .post,
                json: ServerAPI.ApprovalRequest(deviceName: name, commitment: PairingCrypto.encode(
                    PairingCrypto.commitment(nonce: Data(repeating: 1, count: 32)))))
            if response.status == .accepted {
                let ticket = try response.decode(ServerAPI.ApprovalTicket.self)
                _ = try await client.call("/api/v1/pair/requests/\(ticket.id)/reveal", .post, token: ticket.secret,
                                          json: ServerAPI.ApprovalReveal(nonce: PairingCrypto.encode(Data(repeating: 1, count: 32))))
            }
            return response
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
        #expect(allowed.match == nil && allowed.serverNonce != nil)
        #expect(try await status(allowed, secret: "wrong").status == .notFound)
        // Until the device collects its token, no one else can take the approval's place.
        try await Task.sleep(for: .milliseconds(100))
        #expect(try await ask("Imposter").status == .tooManyRequests)
        let approved = try await answer(allowed)
        #expect(approved.pairing == nil)
        let pairing = try await client.call("/api/v1/pair/requests/\(allowed.id)/complete", .post, token: allowed.secret,
            json: ServerAPI.ApprovalCompletion(installID: UUID().uuidString)).decode(ServerAPI.PairResponse.self)
        #expect(approved.state == .approved && approver.lock.withLock { approver.asked.last?.device } == "Alex's iPad")
        let nonce = try #require(allowed.serverNonce.flatMap { PairingCrypto.decode($0, count: 32) })
        let sas = PairingCrypto.sas(fingerprint: fixture.server.fingerprint, appNonce: Data(repeating: 1, count: 32), serverNonce: nonce)
        #expect(approver.lock.withLock { approver.asked.last?.match } == String(sas.prefix(3)) + " " + sas.suffix(3))
        #expect(try await client.call("/api/v1/info", token: pairing.token).status == .ok)
        #expect(try await status(allowed).status == .notFound)

        // Denied: no device, and a pause before the next question.
        #expect(try await ask("Too soon").status == .tooManyRequests)
        try await Task.sleep(for: .milliseconds(2100))
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
        let nonce = PairingCrypto.nonce()
        let request = ServerAPI.ApprovalRequest(deviceName: "iPhone",
                                                commitment: PairingCrypto.encode(PairingCrypto.commitment(nonce: nonce)))
        let ticket = try await client.call("/api/v1/pair/requests", .post, json: request).decode(ServerAPI.ApprovalTicket.self)
        #expect(try await client.call("/api/v1/pair/requests/\(ticket.id)/complete", .post, token: ticket.secret,
            json: ServerAPI.ApprovalCompletion(installID: UUID().uuidString)).status == .notFound)
        _ = try await client.call("/api/v1/pair/requests/\(ticket.id)/reveal", .post, token: ticket.secret,
                                  json: ServerAPI.ApprovalReveal(nonce: PairingCrypto.encode(nonce)))
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
        let refused = try await client.call("/api/v1/pair/requests", .post, json: ServerAPI.ApprovalRequest(
            deviceName: "iPhone", commitment: PairingCrypto.encode(PairingCrypto.commitment(nonce: PairingCrypto.nonce()))))
        #expect(refused.status == .conflict && String(decoding: refused.data, as: UTF8.self).contains(" pair` on it"))
    }
}

@Test func refusesToKeepOriginalsInASourceCheckout() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data().write(to: directory.appendingPathComponent("Package.swift"))
    await #expect(throws: Storage.UnsafeLocation.self) {
        _ = try await HomespunServer(configuration: ServerConfiguration(dataDirectory: directory))
    }
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("originals").path))
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
        #expect(Set(report.checks.map(\.id)) == ["encryption", "photos", "videos", "live_photos", "discovery", "storage", "service", "immich"])
        #expect(report.checks.first?.id == "encryption" && report.checks.first?.status == .ok)
        #expect(text.contains("fp=") && text.contains("Server key: "))
        #expect(report.checks.first { $0.id == "photos" }?.status == .ok)
        #expect(report.checks.first { $0.id == "immich" }?.status == .info)
        #expect(report.checks.first { $0.id == "service" }?.fix.first?.contains("install-service --data") == true)
        let info = try await client.call("/api/v1/info", token: token).decode(ServerAPI.ServerInfo.self)
        #expect(info.platform == report.platform)

        var configuration = fixture.server.configuration
        configuration.publicURL = "photos.example.lan:9000"
        #expect(Network.publicURL(configuration: configuration)?.absoluteString == "https://photos.example.lan:9000")
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
    try await server.application().test(.ahc(.https)) { client in
        try await Task.sleep(for: .seconds(2))
        #expect(try await client.call("/api/v1/health").status == .ok)
    }
    // Shutting down also stops the Bonjour helper, if this computer has one.
    if let tool = ServiceAdvertiser.tool {
        let name = (tool as NSString).lastPathComponent
        #expect(Tools.output("pgrep", ["-f", "\(name) .*test _homespun._tcp"]) == nil, "\(name) outlived the server")
    }
}

extension Catalog {
    /// Like a catalog from before compact copies' SHA-1s were kept.
    func forgetCopySHA1s() throws { try database.execute("UPDATE made_copies SET sha1 = NULL") }
}

// MARK: Importing an existing library

@Test func importedLibraryIsRecognisedByItsCompactCopies() async throws {
    let fixture = try await Fixture()
    let archive = fixture.directory.appendingPathComponent("archive/2021/11", isDirectory: true)
    try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
    func file(_ name: String, _ text: String) throws -> URL {
        let url = archive.appendingPathComponent(name)
        try Data(String(repeating: text, count: 1000).utf8).write(to: url)
        return url
    }
    let still = try file("IMG_2144.HEIC", "still"), motion = try file("IMG_2144.MOV", "motion")
    let movie = try file("IMG_2145.MOV", "movie"), gone = archive.appendingPathComponent("IMG_9999.HEIC")
    let stillCopy = Data("compact still".utf8), motionCopy = Data("compact motion".utf8)
    let movieHash = try Fingerprint.sha256(of: movie)
    func line(_ item: ServerAPI.ImportItem) throws -> String { String(decoding: try ServerAPI.encoder.encode(item), as: UTF8.self) }
    let live = ServerAPI.ImportItem(
        kind: .livePhoto, captureDate: Date(timeIntervalSince1970: 1_636_061_270),
        originals: [.init(role: .photo, path: still.path), .init(role: .pairedVideo, path: motion.path)],
        copies: [.init(role: .photo, sha256: Fingerprint.sha256(of: stillCopy)),
                 .init(role: .pairedVideo, sha256: Fingerprint.sha256(of: motionCopy))])
    // A video that couldn't be made smaller: its "copy" is the original itself.
    let video = ServerAPI.ImportItem(kind: .video, captureDate: nil, originals: [.init(role: .video, path: movie.path)],
                                     copies: [.init(role: .video, sha256: movieHash)])
    let manifest = fixture.directory.appendingPathComponent("manifest.jsonl")
    try ([try line(live), try line(video), "# comment", "",
          try line(.init(kind: .photo, captureDate: nil, originals: [.init(role: .photo, path: gone.path)], copies: [])),
          try line(.init(kind: .photo, captureDate: nil, originals: [.init(role: .photo, path: movie.path, sha256: String(repeating: "a", count: 64))],
                         copies: [])),
          try line(.init(kind: .livePhoto, captureDate: nil, originals: [.init(role: .photo, path: still.path)], copies: [])),
          "{not json"].joined(separator: "\n") + "\n").write(to: manifest, atomically: true, encoding: .utf8)
    let before = try FileManager.default.contentsOfDirectory(atPath: archive.path).sorted()
    let stillBytes = try Data(contentsOf: still)

    let catalog = fixture.server.catalog
    let problems = ProblemLog()
    let checked = try await LibraryImport(catalog: catalog, dryRun: true).run(manifest: manifest) { problems.add($0) }
    #expect(checked == .init(items: 6, imported: 0, linked: 0, problems: 3, bytes: stillBytes.count + 6000 + 5000 + 5000))
    #expect(try await catalog.lookup([Fingerprint.sha256(of: stillCopy)]).isEmpty)

    let imported = try await LibraryImport(catalog: catalog).run(manifest: manifest) { problems.add($0) }
    #expect(imported.imported == 2 && imported.linked == 0 && imported.problems == 4)
    let messages = problems.lines.suffix(4).joined(separator: "\n")
    #expect(messages.contains("line 5: \(gone.path) is missing") && messages.contains("line 6: \(movie.path) no longer matches")
            && messages.contains("line 7: a Live Photo needs its paired video") && messages.contains("line 8: not a valid item"))
    // Running again only re-links the copies; the originals were left exactly as they were.
    let again = try await LibraryImport(catalog: catalog).run(manifest: manifest) { _ in }
    #expect(again.imported == 0 && again.linked == 2 && again.bytes == 0)
    #expect(try FileManager.default.contentsOfDirectory(atPath: archive.path).sorted() == before)
    #expect(try Data(contentsOf: still) == stillBytes)
    #expect(try FileManager.default.subpathsOfDirectory(atPath: fixture.directory.appendingPathComponent("data/originals").path).isEmpty)

    try await fixture.test { client, token in
        let stillID = try Fingerprint.sha256(of: still)
        let lookup = try await client.call("/api/v1/copies/lookup", .post, token: token, json: ServerAPI.CopyLookupRequest(sha256: [
            Fingerprint.sha256(of: stillCopy), Fingerprint.sha256(of: motionCopy).uppercased(), movieHash,
            String(repeating: "b", count: 64)])).decode(ServerAPI.CopyLookupResponse.self)
        let matches = Dictionary(uniqueKeysWithValues: lookup.matches.map { ($0.sha256, $0) })
        #expect(matches.count == 3)
        let stillMatch = try #require(matches[Fingerprint.sha256(of: stillCopy)])
        #expect(stillMatch.assetID == stillID && stillMatch.role == .photo && !stillMatch.isOriginal
                && stillMatch.originalsVerified && stillMatch.originalBytes == 11_000)
        #expect(matches[Fingerprint.sha256(of: motionCopy)]?.role == .pairedVideo)
        #expect(matches[movieHash]?.isOriginal == true && matches[movieHash]?.assetID == movieHash)
        #expect(try await client.call("/api/v1/copies/lookup", .post, token: token,
                                      json: ServerAPI.CopyLookupRequest(sha256: ["nope"])).status == .badRequest)
        #expect(try await client.call("/api/v1/copies/lookup", .post, token: token, json: ServerAPI.CopyLookupRequest(
            sha256: Array(repeating: movieHash, count: ServerAPI.CopyLookupRequest.maximumCount + 1))).status == .badRequest)
        #expect(try await client.call("/api/v1/copies/lookup", .post, json: ServerAPI.CopyLookupRequest(sha256: [])).status
                == .unauthorized)

        // The phone's copy is never taken for an original.
        let copy = ServerAPI.ResourceDescriptor(role: .photo, filename: "IMG_2144.JPG", size: stillCopy.count,
                                                sha256: Fingerprint.sha256(of: stillCopy))
        let refused = try await client.call("/api/v1/assets", .post, token: token,
                                            json: ServerAPI.RegisterAssetRequest(kind: .photo, captureDate: nil, resources: [copy]))
        let refusal = try refused.decode(ServerAPI.ErrorBody.self).error
        #expect(refused.status == .unprocessableContent && refusal.message.contains("of IMG_2144.HEIC"))

        // Checking an item hashes its originals again where they are.
        var verification = try await client.call("/api/v1/assets/\(stillID)/verify", .post, token: token)
            .decode(ServerAPI.Verification.self)
        #expect(verification.allVerified && verification.resources.count == 2)
        try (stillBytes + Data("x".utf8)).write(to: still)
        verification = try await client.call("/api/v1/assets/\(stillID)/verify", .post, token: token)
            .decode(ServerAPI.Verification.self)
        #expect(!verification.allVerified
                && verification.resources.first { $0.role == .photo }?.detail == "the original at \(still.path) is missing or changed")
        let status = try await client.call("/api/v1/assets/\(stillID)", token: token).decode(ServerAPI.AssetStatus.self)
        #expect(status.kind == .livePhoto && status.state == .imported)
    }
}

@Test func importCommandChecksItsArguments() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let photo = directory.appendingPathComponent("IMG_0001.JPG")
    try Data("photo".utf8).write(to: photo)
    let manifest = directory.appendingPathComponent("m.jsonl")
    try String(decoding: try ServerAPI.encoder.encode(ServerAPI.ImportItem(
        kind: .photo, captureDate: nil, originals: [.init(role: .photo, path: photo.path)], copies: [])), as: UTF8.self)
        .write(to: manifest, atomically: true, encoding: .utf8)
    let data = directory.appendingPathComponent("data").path
    func run(_ arguments: String...) async -> Int32 {
        await ServerCommand.run(commandLine: ["homespun-server"] + arguments + ["--data", data])
    }
    #expect(await run("import") == 2)
    #expect(await run("import", manifest.path, "--jobs", "0") == 2)
    #expect(await run("import", manifest.path, "--dry-run", "--jobs", "2") == 0)
    #expect(await run("import", directory.appendingPathComponent("missing.jsonl").path) == 1)
    #expect(await run("import", manifest.path) == 0)
}

@Test func pairCodesLastTenMinutesOrAsLongAsAsked() async throws {
    #expect(ServerCommand.pairingMinutes([]) == 10)
    #expect(ServerCommand.pairingMinutes(["--minutes", "180"]) == 180)
    for bad in [["--minutes"], ["--minutes", "0"], ["--minutes", "1441"], ["--minutes", "soon"]] {
        #expect(ServerCommand.pairingMinutes(bad) == nil, "\(bad)")
    }
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let data = directory.appendingPathComponent("data").path
    #expect(await ServerCommand.run(commandLine: ["homespun-server", "pair", "--minutes", "0", "--data", data]) == 2)
    #expect(await ServerCommand.run(commandLine: ["homespun-server", "pair", "--minutes", "180", "--data", data]) == 0)
    let server = try await HomespunServer(configuration: ServerConfiguration(dataDirectory: URL(fileURLWithPath: data)))
    #expect(server.pairingInstructions(code: "K7Q4-M9XT", minutes: 180).contains("expires in 180 minutes"))
}

final class ProblemLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func add(_ line: String) { lock.withLock { stored.append(line) } }
    var lines: [String] { lock.withLock { stored } }
}

@Test(.enabled(if: ffmpegAvailable)) func phoneBacksUpAnOriginalImportedInPlace() async throws {
    let fixture = try await Fixture()
    let media = try await Media.make(in: fixture.directory)
    // A manifest saved on Windows: byte order mark and CRLF line endings.
    let manifest = fixture.directory.appendingPathComponent("library.jsonl")
    let items = try [media.photo, media.movie].map { url in
        String(decoding: try ServerAPI.encoder.encode(ServerAPI.ImportItem(
            kind: url == media.movie ? .video : .photo, captureDate: nil,
            originals: [.init(role: url == media.movie ? .video : .photo, path: url.path)], copies: [])), as: UTF8.self)
    }
    try Data(("\u{FEFF}" + items.joined(separator: "\r\n") + "\r\n").utf8).write(to: manifest)
    let summary = try await LibraryImport(catalog: fixture.server.catalog).run(manifest: manifest) { _ in }
    #expect(summary.imported == 2 && summary.problems == 0)

    try await fixture.test { client, token in
        // The original is still on the phone and has no compact copy: backing it up makes one,
        // from the file where it is, with nothing to upload.
        let photo = try descriptor(.photo, media.photo)
        let registered = try await client.call("/api/v1/assets", .post, token: token,
                                               json: ServerAPI.RegisterAssetRequest(kind: .photo, captureDate: nil, resources: [photo]))
        #expect(try registered.decode(ServerAPI.AssetStatus.self).state == .queued)
        try await fixture.server.drainJobs()
        let ready = try await client.call("/api/v1/assets/\(photo.sha256)", token: token).decode(ServerAPI.AssetStatus.self)
        #expect(ready.state == .ready && ready.compact.first?.role == .photo, "\(ready.message ?? "")")
        #expect(try FileManager.default.subpathsOfDirectory(atPath: fixture.directory.appendingPathComponent("data/originals").path).isEmpty)

        // One that changed since the import is not compressed.
        let movie = try descriptor(.video, media.movie)
        try (Data(contentsOf: media.movie) + Data("x".utf8)).write(to: media.movie)
        _ = try await client.call("/api/v1/assets", .post, token: token,
                                  json: ServerAPI.RegisterAssetRequest(kind: .video, captureDate: nil, resources: [movie]))
        try await fixture.server.drainJobs()
        let failed = try await client.call("/api/v1/assets/\(movie.sha256)", token: token).decode(ServerAPI.AssetStatus.self)
        #expect(failed.state == .failed && failed.message?.contains("missing or changed") == true)
    }
}


// MARK: Originals folder

@Test(.enabled(if: ffmpegAvailable)) func originalsGoInAFolderPerPhoneAndMoveFromTheApp() async throws {
    let fixture = try await Fixture(originals: "Volume")
    let media = try await Media.make(in: fixture.directory)
    let volume = fixture.directory.appendingPathComponent("Volume"), moved = fixture.directory.appendingPathComponent("Moved")
    try await fixture.test { client, _ in
        // Two phones with the same name get their own folders.
        let token = try await fixture.pair(client)
        let photo = try descriptor(.photo, media.photo)
        _ = try await client.call("/api/v1/assets", .post, token: token, json: ServerAPI.RegisterAssetRequest(
            kind: .photo, captureDate: Date(timeIntervalSince1970: 1_714_592_096), resources: [photo]))
        _ = try await fixture.upload(client, token: token, asset: photo.sha256, role: .photo, file: media.photo)
        let stored = volume.appendingPathComponent("Test iPhone 2/2024/05/IMG_0001.JPG")
        #expect(try Data(contentsOf: stored) == Data(contentsOf: media.photo))
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("data/originals").path))

        var storage = try await client.call("/api/v1/storage", token: token).decode(ServerAPI.StorageInfo.self)
        #expect(storage.originalsFolder == volume.path && storage.deviceFolder == volume.appendingPathComponent("Test iPhone 2").path)
        #expect(storage.storedCount == 1 && storage.storedBytes == Int64(photo.size) && storage.move == nil)
        let locations = try await client.call("/api/v1/storage/locations", token: token).decode([ServerAPI.StorageLocation].self)
        #expect(locations.first { $0.isCurrent }?.path == volume.path)

        func move(_ path: String) async throws -> TestResponse {
            try await client.call("/api/v1/storage", .put, token: token, json: ServerAPI.MoveOriginalsRequest(originalsFolder: path))
        }
        let checkout = fixture.directory.appendingPathComponent("checkout")
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        try Data().write(to: checkout.appendingPathComponent("Package.swift"))
        for bad in ["relative/path", volume.path, fixture.directory.appendingPathComponent("data/inside").path,
                    fixture.directory.appendingPathComponent("no/such/disk").path, checkout.path] {
            #expect(try await move(bad).status == .unprocessableContent, "\(bad)")
        }

        // The same folder by another name is refused.
        let alias = fixture.directory.appendingPathComponent("Alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: volume)
        #expect(try await move(alias.path).status == .unprocessableContent)

        // An existing folder is fine, but a different file in the way stops the move and nothing is lost.
        let blocker = moved.appendingPathComponent("Test iPhone 2/2024/05/IMG_0001.JPG")
        try FileManager.default.createDirectory(at: blocker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("someone else's file".utf8).write(to: blocker)
        #expect(try await move(moved.path).status == .accepted)
        await fixture.server.mover.wait()
        storage = try await client.call("/api/v1/storage", token: token).decode(ServerAPI.StorageInfo.self)
        #expect(storage.originalsFolder == volume.path && storage.move?.state == .failed
                && storage.move?.message?.contains("A different file") == true)
        #expect(try Data(contentsOf: blocker) == Data("someone else's file".utf8) && FileManager.default.fileExists(atPath: stored.path))
        #expect(try await client.call("/api/v1/assets/\(photo.sha256)/verify", .post, token: token)
            .decode(ServerAPI.Verification.self).allVerified)
        try FileManager.default.removeItem(at: blocker)

        // While a move is under way, import --copy records nothing.
        try await fixture.server.catalog.setSetting(OriginalsMover.setting, "{}")
        let source = fixture.directory.appendingPathComponent("elsewhere.jpg")
        try Data("from elsewhere".utf8).write(to: source)
        let manifest = fixture.directory.appendingPathComponent("m.jsonl")
        try String(decoding: try ServerAPI.encoder.encode(ServerAPI.ImportItem(
            kind: .photo, captureDate: nil, originals: [.init(role: .photo, path: source.path)], copies: [])), as: UTF8.self)
            .write(to: manifest, atomically: true, encoding: .utf8)
        await #expect(throws: LibraryImport.Problem.self) {
            try await LibraryImport(catalog: fixture.server.catalog, copyInto: fixture.server.originals)
                .run(manifest: manifest) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: volume.appendingPathComponent("Camera Roll").path))
        try await fixture.server.catalog.setSetting(OriginalsMover.setting, nil)

        #expect(try await move(moved.path).status == .accepted)
        await fixture.server.mover.wait()
        storage = try await client.call("/api/v1/storage", token: token).decode(ServerAPI.StorageInfo.self)
        #expect(storage.originalsFolder == moved.path && storage.move?.state == .done && storage.move?.copied == 1)
        let movedFile = moved.appendingPathComponent("Test iPhone 2/2024/05/IMG_0001.JPG")
        #expect(try Data(contentsOf: movedFile) == Data(contentsOf: media.photo))
        #expect((try FileManager.default.attributesOfItem(atPath: movedFile.path)[.posixPermissions] as? NSNumber)?.intValue == 0o440)
        #expect(try Data(contentsOf: stored) == Data(contentsOf: media.photo))
        #expect(storage.move?.message?.contains("cleanup is pending") == true)
        #expect(try await client.call("/api/v1/assets/\(photo.sha256)/verify", .post, token: token)
            .decode(ServerAPI.Verification.self).allVerified)

        // New originals go to the new folder.
        let movie = try descriptor(.video, media.movie)
        _ = try await client.call("/api/v1/assets", .post, token: token,
                                  json: ServerAPI.RegisterAssetRequest(kind: .video, captureDate: nil, resources: [movie]))
        _ = try await fixture.upload(client, token: token, asset: movie.sha256, role: .video, file: media.movie)
        #expect(FileManager.default.fileExists(atPath: moved.appendingPathComponent("Test iPhone 2/undated/IMG_0002.MP4").path))
    }
}

@Test func theOriginalsFolderIsKeptOnceOriginalsAreInItAndAMissingDiskIsReported() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = try await Fixture(originals: "Volume", directory: directory)
    let source = directory.appendingPathComponent("photo.jpg")
    try Data("a photo".utf8).write(to: source)
    let manifest = directory.appendingPathComponent("m.jsonl")
    try String(decoding: try ServerAPI.encoder.encode(ServerAPI.ImportItem(
        kind: .photo, captureDate: nil, originals: [.init(role: .photo, path: source.path)], copies: [])), as: UTF8.self)
        .write(to: manifest, atomically: true, encoding: .utf8)
    #expect(try await LibraryImport(catalog: first.server.catalog, copyInto: first.server.originals).run(manifest: manifest) { _ in }
        .imported == 1)
    // With originals in it, another --originals doesn't move the folder (stored paths are relative to it).
    let second = try await Fixture(originals: "Other", directory: directory)
    #expect(await second.server.originals.root.path == directory.appendingPathComponent("Volume").path)
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("Other").path))
    // A catalog from before the folder was a setting keeps the data folder's.
    try await second.server.catalog.setSetting(OriginalsStore.setting, nil)
    try await second.server.catalog.setSetting("originals.legacy", "1")
    let legacy = try await Fixture(originals: "Other", directory: directory)
    #expect(await legacy.server.originals.root.path == directory.appendingPathComponent("data/originals").path)

    // A folder on a disk that isn't there isn't made (it would land on the startup disk).
    try await legacy.server.catalog.setSetting(OriginalsStore.setting, directory.appendingPathComponent("Unplugged/Homespun").path)
    let third = try await Fixture(directory: directory)
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("Unplugged").path))
    // A data folder whose disk isn't there isn't made either.
    var configuration = ServerConfiguration(dataDirectory: directory.appendingPathComponent("Gone/data"))
    configuration.originalsDirectory = nil
    await #expect(throws: Storage.UnsafeLocation.self) { _ = try await HomespunServer(configuration: configuration) }
    try await third.test { client, token in
        let report = try await client.call("/api/v1/setup", token: token).decode(ServerSetup.Report.self)
        #expect(report.checks.first { $0.id == "storage" }?.status == .problem)
        let photo = ServerAPI.ResourceDescriptor(role: .photo, filename: "a.jpg", size: 5, sha256: Fingerprint.sha256(of: Data("photo".utf8)))
        _ = try await client.call("/api/v1/assets", .post, token: token,
                                  json: ServerAPI.RegisterAssetRequest(kind: .photo, captureDate: nil, resources: [photo]))
        let upload = try await client.call("/api/v1/assets/\(photo.sha256)/resources/photo?offset=0", .put, token: token,
                                           body: Data("photo".utf8))
        #expect(upload.status == .serviceUnavailable)
    }
}

@Test func importCanCopyOriginalsIntoTheOriginalsFolder() async throws {
    let fixture = try await Fixture(originals: "Volume")
    let archive = fixture.directory.appendingPathComponent("archive", isDirectory: true)
    try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
    let still = archive.appendingPathComponent("IMG_2144.HEIC"), motion = archive.appendingPathComponent("IMG_2144.MOV")
    try Data(String(repeating: "still", count: 1000).utf8).write(to: still)
    try Data(String(repeating: "motion", count: 1000).utf8).write(to: motion)
    let other = archive.appendingPathComponent("IMG_3000.JPG")
    try Data(String(repeating: "other", count: 1000).utf8).write(to: other)
    let copyHash = Fingerprint.sha256(of: Data("compact".utf8))
    func line(_ item: ServerAPI.ImportItem) throws -> String { String(decoding: try ServerAPI.encoder.encode(item), as: UTF8.self) }
    let manifest = fixture.directory.appendingPathComponent("m.jsonl")
    try [try line(.init(kind: .livePhoto, captureDate: Date(timeIntervalSince1970: 1_636_061_270),
                        originals: [.init(role: .photo, path: still.path, sha1: Fingerprint.sha1(of: try Data(contentsOf: still))),
                                    .init(role: .pairedVideo, path: motion.path, sha256: try Fingerprint.sha256(of: motion))],
                        copies: [.init(role: .photo, sha256: copyHash)])),
         try line(.init(kind: .photo, captureDate: nil, originals: [.init(role: .photo, path: other.path,
                                                                         sha1: String(repeating: "0", count: 40))], copies: []))]
        .joined(separator: "\n").write(to: manifest, atomically: true, encoding: .utf8)
    let importer = LibraryImport(catalog: fixture.server.catalog, copyInto: fixture.server.originals)
    let problems = ProblemLog()
    let summary = try await importer.run(manifest: manifest) { problems.add($0) }
    #expect(summary.imported == 1 && summary.problems == 1 && problems.lines.last?.contains("recorded SHA-1") == true)

    let folder = fixture.directory.appendingPathComponent("Volume/Camera Roll/2021/11")
    #expect(try Set(FileManager.default.contentsOfDirectory(atPath: folder.path)) == ["IMG_2144.HEIC", "IMG_2144.MOV"])
    #expect(try Data(contentsOf: folder.appendingPathComponent("IMG_2144.HEIC")) == Data(contentsOf: still))
    // The sources are only read; nothing is left behind from the failed copy.
    #expect(try FileManager.default.contentsOfDirectory(atPath: archive.path).count == 3)
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.appendingPathComponent("Volume/.homespun-import").path).isEmpty)
    let resources = try await fixture.server.catalog.resources(try Fingerprint.sha256(of: still))
    #expect(resources.allSatisfy { $0.externalPath == nil && $0.storedPath?.hasPrefix("Camera Roll/2021/11/") == true })
    #expect(Set(resources.compactMap(\.importedFrom)) == [still.path, motion.path])

    // Again: nothing is copied twice.
    let again = try await importer.run(manifest: manifest) { _ in }
    #expect(again.linked == 1 && again.imported == 0)
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 2)

    // Copying an original the phone already backed up keeps the phone's.
    let relink = try line(.init(kind: .photo, captureDate: nil, originals: [.init(role: .photo, path: other.path)],
                                copies: [.init(role: .photo, sha256: copyHash)]))
    try await fixture.test { client, token in
        let photo = try descriptor(.photo, other)
        _ = try await client.call("/api/v1/assets", .post, token: token,
                                  json: ServerAPI.RegisterAssetRequest(kind: .photo, captureDate: nil, resources: [photo]))
        _ = try await fixture.upload(client, token: token, asset: photo.sha256, role: .photo, file: other)
        try relink.write(to: manifest, atomically: true, encoding: .utf8)
        let linked = try await importer.run(manifest: manifest) { _ in }
        #expect(linked.linked == 1)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("Volume/Camera Roll/undated").path))
    }
}

@Test func aMoveWhoseDiskIsMissingWaitsAndChangesNothing() async throws {
    let fixture = try await Fixture(originals: "Volume")
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let unplugged = fixture.directory.appendingPathComponent("Unplugged/Homespun")
    let plan = #"{"from":"\#(fixture.directory.appendingPathComponent("Volume").path)","to":"\#(unplugged.path)"}"#
    try await fixture.server.catalog.setSetting(OriginalsMover.setting, plan)
    await fixture.server.mover.resume()
    await fixture.server.mover.wait()
    let status = try #require(await fixture.server.mover.status)
    #expect(status.state == .failed && status.message?.contains("isn't there") == true)
    #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("Unplugged").path))
    #expect(try await fixture.server.catalog.setting(OriginalsMover.setting) == plan)
    #expect(await fixture.server.originals.root.path == fixture.directory.appendingPathComponent("Volume").path)
}

// MARK: Originals, devices and hardware for the app's redesign

@Test func hardwareIsDetectedOrSetByTheDockerImage() {
    let docker = HostPlatform.detectHardware(environment: ["HOMESPUN_HARDWARE_KIND": "container", "HOMESPUN_HARDWARE": "Synology DS923+"])
    #expect(docker == .init(kind: .container, model: "Synology DS923+"))
    let detected = HostPlatform.detectHardware(environment: [:])
    #if os(macOS)
    #expect([.desktop, .laptop].contains(detected.kind))
    #else
    #expect([.desktop, .laptop, .server, .container].contains(detected.kind))
    #endif
    #expect(Routes.byteRange("bytes=0-9", size: 100) == 0...9)
    #expect(Routes.byteRange("bytes=90-", size: 100) == 90...99)
    #expect(Routes.byteRange("bytes=-5", size: 100) == 95...99)
    #expect(Routes.byteRange("bytes=95-500", size: 100) == 95...99)
    #expect(Routes.byteRange("bytes=100-", size: 100) == nil && Routes.byteRange("bytes=5-1", size: 100) == nil)
    #expect(Routes.byteRange("bytes=0-1,4-5", size: 100) == nil && Routes.byteRange("items=0-1", size: 100) == nil)
}

@Test func selfCheckInADockerContainer() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let server = fixture.server
    var configuration = server.configuration
    configuration.host = "0.0.0.0"
    var checks = SetupChecks(configuration: configuration, storage: server.storage, immichState: server.immichState,
                             catalog: server.catalog)
    checks.hardware = .init(kind: .container, model: nil)
    // Docker, not systemd, starts it; and Bonjour needs the host's D-Bus mounted in.
    #expect(checks.service().status == .ok && checks.service().fix.isEmpty)
    checks.systemBus = fixture.directory.appendingPathComponent("no-bus").path
    #expect(checks.discovery().status == .warning && checks.discovery().detail.contains("/var/run/dbus"))
    checks.systemBus = server.storage.catalog.path
    #expect(!checks.discovery().detail.contains("/var/run/dbus"))
    // The app shows commands to run in the container, not the path inside it.
    let command = "docker exec homespun homespun-server"
    #expect(HostPlatform.serverCommand(environment: ["HOMESPUN_COMMAND": command]) == command)
}

@Test(.enabled(if: ffmpegAvailable)) func originalsStreamAndDevicesAreListed() async throws {
    let fixture = try await Fixture()
    let media = try await Media.make(in: fixture.directory)
    try await fixture.test { client, token in
        let options = try await client.call("/api/v1/pair/options").decode(ServerAPI.PairingOptions.self)
        #expect(options.platform != nil && options.hardware != nil && (options.freeBytes ?? 0) > 0)
        #expect(try await client.call("/api/v1/info", token: token).decode(ServerAPI.ServerInfo.self).hardware != nil)

        let photo = try descriptor(.photo, media.photo)
        _ = try await client.call("/api/v1/assets", .post, token: token,
                                  json: ServerAPI.RegisterAssetRequest(kind: .photo, captureDate: nil, resources: [photo]))
        let path = "/api/v1/assets/\(photo.sha256)/original/photo"
        #expect(try await client.call(path, token: token).status == .notFound)
        _ = try await fixture.upload(client, token: token, asset: photo.sha256, role: .photo, file: media.photo)
        let bytes = try Data(contentsOf: media.photo)
        let whole = try await client.call(path, token: token)
        #expect(whole.status == .ok && whole.data == bytes && whole.headers[.contentType] == "image/jpeg")
        #expect(whole.headers[.contentDisposition] == "attachment; filename=\"IMG_0001.JPG\"; filename*=UTF-8''IMG_0001.JPG")
        #expect(Routes.contentDisposition("Akshob’s photo.heic")
                == "attachment; filename=\"Akshob_s photo.heic\"; filename*=UTF-8''Akshob%E2%80%99s%20photo.heic")
        #expect(try await client.call(path).status == .unauthorized)
        var headers = HTTPFields()
        headers[.authorization] = "Bearer \(token)"
        headers[.range] = "bytes=10-19"
        let part = try await client.execute(uri: path, method: .get, headers: headers)
        #expect(part.status == .partialContent && Data(part.body.readableBytesView) == bytes[10...19])
        #expect(part.headers[.contentRange] == "bytes 10-19/\(bytes.count)")
        headers[.range] = "bytes=\(bytes.count)-"
        #expect(try await client.execute(uri: path, method: .get, headers: headers).status == .rangeNotSatisfiable)
        #expect(try await client.call("/api/v1/assets/\(photo.sha256)/original/video", token: token).status == .notFound)

        // Devices: this one and a second; removing the second stops it.
        let code = try await fixture.server.newPairingCode()
        let second = try await client.call("/api/v1/pair", .post, json: ServerAPI.PairRequest(code: code, deviceName: "iPad"))
            .decode(ServerAPI.PairResponse.self)
        let devices = try await client.call("/api/v1/devices", token: token).decode([ServerAPI.DeviceInfo].self)
        #expect(devices.count == 2 && devices.filter(\.isThisDevice).map(\.name) == ["Test iPhone"])
        #expect(Set(devices.compactMap(\.folder)) == ["Test iPhone", "iPad"])
        let other = try #require(devices.first { !$0.isThisDevice })
        #expect(try await client.call("/api/v1/devices/\(other.id)", .delete, token: token).status == .noContent)
        #expect(try await client.call("/api/v1/info", token: second.token).status == .unauthorized)
        #expect(try await client.call("/api/v1/devices/\(other.id)", .delete, token: token).status == .notFound)
    }
}

/// The installed server's saved settings never leak into a run with its own data folder: a test
/// server must not put originals in the real server's originals folder.
@Test func savedSettingsApplyOnlyToTheInstalledServer() {
    let saved = "HOMESPUN_DATA=/Volumes/Homespun/.homespun\nHOMESPUN_ORIGINALS=/Volumes/Homespun\nHOMESPUN_PORT=8787\n"
    // `pair` with nothing given finds the installed server.
    #expect(ServerCommand.applying(saved: saved, to: [:])
            == ["HOMESPUN_DATA": "/Volumes/Homespun/.homespun", "HOMESPUN_ORIGINALS": "/Volumes/Homespun", "HOMESPUN_PORT": "8787"])
    // The same data folder (written differently) is the installed server; what's given wins.
    #expect(ServerCommand.applying(saved: saved, to: ["HOMESPUN_DATA": "/Volumes/Homespun/.homespun/", "HOMESPUN_PORT": "9000"])
            == ["HOMESPUN_DATA": "/Volumes/Homespun/.homespun/", "HOMESPUN_ORIGINALS": "/Volumes/Homespun", "HOMESPUN_PORT": "9000"])
    // Another data folder is another server: nothing is borrowed.
    #expect(ServerCommand.applying(saved: saved, to: ["HOMESPUN_DATA": "/tmp/test-data"]) == ["HOMESPUN_DATA": "/tmp/test-data"])
}

/// In a container, originals may only move to a folder mounted from the host: anything else is
/// the container's own disk and disappears when it's recreated.
@Test func containerMovesOnlyToMountedFolders() throws {
    let mountinfo = """
        600 500 0:50 / / rw,relatime - overlay overlay rw
        601 600 0:52 / /proc rw - proc proc rw
        610 600 8:1 /volume1/docker/homespun/data /data rw - ext4 /dev/sda1 rw
        611 600 8:1 /volume1/photo/Homespun /originals rw - ext4 /dev/sda1 rw
        612 600 8:1 /volume1/photo /photos rw - ext4 /dev/sda1 rw
        613 600 8:1 /volume1/Photo\\040Library /photo\\040library rw - ext4 /dev/sda1 rw
        614 600 0:60 / /etc/hosts rw - ext4 /dev/sda1 rw
        """
    let mounts = ContainerMounts.read(mountinfo)
    #expect(mounts == ["/data", "/originals", "/photos", "/photo library"])
    #expect(ContainerMounts.isOnVolume("/photos/Homespun", mounts: mounts))
    #expect(ContainerMounts.isOnVolume("/photo library/Homespun", mounts: mounts))
    #expect(!ContainerMounts.isOnVolume("/tmp/Homespun", mounts: mounts))
    #expect(!ContainerMounts.isOnVolume("/photosx", mounts: mounts))

    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let current = root.appendingPathComponent("originals"), data = root.appendingPathComponent("data")
    try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
    let elsewhere = root.appendingPathComponent("elsewhere").path
    // Not a container: any folder will do. A container: only one on a mounted volume.
    #expect(throws: Never.self) {
        try OriginalsMover.validate(elsewhere, current: current, dataDirectory: data, container: false, mounts: [])
    }
    #expect(throws: (any Error).self) {
        try OriginalsMover.validate(elsewhere, current: current, dataDirectory: data, container: true, mounts: ["/volume"])
    }
    #expect(throws: Never.self) {
        try OriginalsMover.validate(elsewhere, current: current, dataDirectory: data, container: true, mounts: [root.path])
    }
}

/// Automatic mode backs a recent item up without a compact copy (`stored`); registering it again
/// with `compact` makes the copy, and only then do cloud copies start. A recent item removed on the
/// phone goes to the server's trash, comes back if it's backed up again, and is deleted after 30 days.
/// Anything with a compact copy stays when the phone removes it.
/// Edits all upload files with the same names (`FullSizeRender.heic`), so trashed items must never
/// share a path: each keeps its own bytes, restoring never overwrites, and a trashed file someone
/// deleted by hand is uploaded again.
@Test(.enabled(if: ffmpegAvailable)) func trashedItemsWithTheSameFileNamesKeepTheirOwnFiles() async throws {
    let fixture = try await Fixture(originals: "originals")
    let media = try await Media.make(in: fixture.directory)
    try await fixture.test { client, token in
        let date = Date(timeIntervalSince1970: 1_714_592_096)
        let original = try Data(contentsOf: media.photo)
        var files: [URL] = []
        for index in 0..<3 {
            let url = fixture.directory.appendingPathComponent("same-\(index).jpg")
            try (original + Data(repeating: UInt8(index + 1), count: 64)).write(to: url)
            files.append(url)
        }
        let photos = try files.map { try descriptor(.photo, $0, name: "IMG_0001.JPG") }
        func register(_ index: Int) async throws -> ServerAPI.AssetStatus {
            let request = ServerAPI.RegisterAssetRequest(kind: .photo, captureDate: date, resources: [photos[index]], compact: false)
            return try await client.call("/api/v1/assets", .post, token: token, json: request).decode(ServerAPI.AssetStatus.self)
        }
        func backUp(_ index: Int) async throws {
            _ = try await register(index)
            _ = try await fixture.upload(client, token: token, asset: photos[index].sha256, role: .photo, file: files[index])
            try await fixture.server.drainJobs()
        }
        func remove(_ index: Int) async throws -> ServerAPI.AssetState {
            try await client.call("/api/v1/assets/\(photos[index].sha256)/removed", .post, token: token)
                .decode(ServerAPI.AssetStatus.self).state
        }
        let originals = fixture.directory.appendingPathComponent("originals")
        let month = "Test iPhone/2024/05"
        func sha(_ path: String) throws -> String { try Fingerprint.digests(of: originals.appendingPathComponent(path)).sha256 }
        func trashed(_ index: Int) -> String { ".trash/\(photos[index].sha256)/\(month)/IMG_0001.JPG" }

        // A is backed up and cleaned up (not while its disk is away); B then gets the free name and
        // is cleaned up too.
        try await backUp(0)
        let away = fixture.directory.appendingPathComponent("away")
        try FileManager.default.moveItem(at: originals, to: away)
        let refused = try await client.call("/api/v1/assets/\(photos[0].sha256)/removed", .post, token: token)
        #expect(refused.status == .serviceUnavailable)
        try FileManager.default.moveItem(at: away, to: originals)
        #expect(try await remove(0) == .trashed)
        try await backUp(1)
        #expect(try sha("\(month)/IMG_0001.JPG") == photos[1].sha256)
        #expect(try await remove(1) == .trashed)
        #expect(try sha(trashed(0)) == photos[0].sha256 && sha(trashed(1)) == photos[1].sha256)

        // Both recovered: A gets its name back, B can't take it and gets a name of its own.
        #expect(try await register(0).state == .stored)
        #expect(try await register(1).state == .stored)
        #expect(try sha("\(month)/IMG_0001.JPG") == photos[0].sha256)
        let renamed = "\(month)/IMG_0001_\(photos[1].sha256.prefix(12)).JPG"
        #expect(try sha(renamed) == photos[1].sha256)
        let trash = originals.appendingPathComponent(".trash")
        #expect((try? FileManager.default.contentsOfDirectory(atPath: trash.path))?.isEmpty ?? true)

        // C's trashed file was deleted by hand: backing it up again asks for the file once more.
        try await backUp(2)
        #expect(try await remove(2) == .trashed)
        try FileManager.default.removeItem(at: trash.appendingPathComponent(photos[2].sha256))
        let again = try await register(2)
        #expect(again.state == .receiving && again.resources.first?.state == .missing)
        _ = try await fixture.upload(client, token: token, asset: photos[2].sha256, role: .photo, file: files[2])
        try await fixture.server.drainJobs()
        let status = try await client.call("/api/v1/assets/\(photos[2].sha256)", token: token).decode(ServerAPI.AssetStatus.self)
        #expect(status.state == .stored)
    }
}

@Test(.enabled(if: ffmpegAvailable)) func recentItemsWaitForTheirCompactCopyAndCleanedUpOnesGoToTheTrash() async throws {
    let fixture = try await Fixture(originals: "originals")
    let media = try await Media.make(in: fixture.directory)
    try await fixture.test { client, token in
        let photo = try descriptor(.photo, media.photo)
        let date = Date(timeIntervalSince1970: 1_714_592_096)
        func register(compact: Bool?) async throws -> ServerAPI.AssetStatus {
            let request = ServerAPI.RegisterAssetRequest(kind: .photo, captureDate: date, resources: [photo], compact: compact)
            return try await client.call("/api/v1/assets", .post, token: token, json: request).decode(ServerAPI.AssetStatus.self)
        }
        func status() async throws -> ServerAPI.AssetStatus {
            try await client.call("/api/v1/assets/\(photo.sha256)", token: token).decode(ServerAPI.AssetStatus.self)
        }
        let originals = fixture.directory.appendingPathComponent("originals")
        let kept = originals.appendingPathComponent("Test iPhone/2024/05/IMG_0001.JPG")
        let trashed = originals.appendingPathComponent(".trash/\(photo.sha256)/Test iPhone/2024/05/IMG_0001.JPG")

        // Backed up, no compact copy, no job.
        #expect(try await register(compact: false).state == .receiving)
        _ = try await fixture.upload(client, token: token, asset: photo.sha256, role: .photo, file: media.photo)
        try await fixture.server.drainJobs()
        var current = try await status()
        #expect(current.state == .stored && current.compact.isEmpty)
        #expect(FileManager.default.fileExists(atPath: kept.path))
        // Registering again as recent changes nothing.
        #expect(try await register(compact: false).state == .stored)

        // Removed on the phone: into the trash, out of the stored totals, with a date.
        let removed = try await client.call("/api/v1/assets/\(photo.sha256)/removed", .post, token: token)
            .decode(ServerAPI.AssetStatus.self)
        #expect(removed.state == .trashed)
        let until = try #require(removed.trashedUntil)
        #expect(abs(until.timeIntervalSinceNow - 30 * 86_400) < 120)
        #expect(!FileManager.default.fileExists(atPath: kept.path) && FileManager.default.fileExists(atPath: trashed.path))
        let storage = try await client.call("/api/v1/storage", token: token).decode(ServerAPI.StorageInfo.self)
        #expect(storage.storedCount == 0 && storage.trashCount == 1 && storage.trashBytes == Int64(photo.size))
        // Not yet: the trash keeps it 30 days.
        #expect(try await fixture.server.emptyTrash() == 0)

        // Recovered on the phone and backed up again: out of the trash, waiting again.
        #expect(try await register(compact: false).state == .stored)
        #expect(FileManager.default.fileExists(atPath: kept.path) && !FileManager.default.fileExists(atPath: trashed.path))

        // Its time came: the compact copy is made now.
        #expect(try await register(compact: true).state == .queued)
        try await fixture.server.drainJobs()
        current = try await status()
        #expect(current.state == .ready && !current.compact.isEmpty)
        #expect(try await client.call("/api/v1/assets/\(photo.sha256)/imported", .post, token: token).status == .ok)
        // Freeing up space removes the original on the phone on purpose: the server keeps it.
        let refused = try await client.call("/api/v1/assets/\(photo.sha256)/removed", .post, token: token)
        #expect(refused.status == .conflict)
        #expect(try refused.decode(ServerAPI.ErrorBody.self).error.code == ServerAPI.ErrorCode.keptOriginal)
        #expect(try await status().state == .imported && FileManager.default.fileExists(atPath: kept.path))

        // A second recent item, cleaned up on the phone, is deleted 30 days later.
        let video = try descriptor(.video, media.movie)
        let request = ServerAPI.RegisterAssetRequest(kind: .video, captureDate: date, resources: [video], compact: false)
        _ = try await client.call("/api/v1/assets", .post, token: token, json: request)
        _ = try await fixture.upload(client, token: token, asset: video.sha256, role: .video, file: media.movie)
        #expect(try await client.call("/api/v1/assets/\(video.sha256)/removed", .post, token: token)
            .decode(ServerAPI.AssetStatus.self).state == .trashed)
        #expect(try await fixture.server.emptyTrash(now: Date().addingTimeInterval(31 * 86_400)) == 1)
        #expect(try await client.call("/api/v1/assets/\(video.sha256)", token: token).status == .notFound)
        let left = try FileManager.default.subpathsOfDirectory(atPath: originals.appendingPathComponent(".trash").path)
            .filter { !$0.hasSuffix("/") && $0.contains(".") }
        #expect(left.isEmpty, "\(left)")
        #expect(FileManager.default.fileExists(atPath: kept.path))
    }
}

// MARK: Renaming a phone

/// A phone renames itself and its originals folder: the files (and a trashed item's) move with it,
/// stay downloadable and restorable, and the name can't clash with another phone or folder.
@Test(.enabled(if: ffmpegAvailable)) func aPhoneRenamesItselfAndItsOriginalsFolder() async throws {
    let fixture = try await Fixture(originals: "originals")
    let media = try await Media.make(in: fixture.directory)
    try await fixture.test { client, token in
        let date = Date(timeIntervalSince1970: 1_714_592_096)
        let originals = fixture.directory.appendingPathComponent("originals")
        let kept = try descriptor(.photo, media.photo)
        let recentFile = fixture.directory.appendingPathComponent("recent.jpg")
        try (try Data(contentsOf: media.photo) + Data(repeating: 7, count: 64)).write(to: recentFile)
        let recent = try descriptor(.photo, recentFile, name: "IMG_0002.JPG")
        for (resource, file) in [(kept, media.photo), (recent, recentFile)] {
            _ = try await client.call("/api/v1/assets", .post, token: token,
                                      json: ServerAPI.RegisterAssetRequest(kind: .photo, captureDate: date, resources: [resource],
                                                                           compact: false))
            _ = try await fixture.upload(client, token: token, asset: resource.sha256, role: .photo, file: file)
        }
        try await fixture.server.drainJobs()
        #expect(try await client.call("/api/v1/assets/\(recent.sha256)/removed", .post, token: token).status == .ok)
        let devices = try await client.call("/api/v1/devices", token: token).decode([ServerAPI.DeviceInfo].self)
        let me = try #require(devices.first(where: { $0.isThisDevice }))
        #expect(me.folder == "Test iPhone")
        func rename(_ name: String, id: String? = nil) async throws -> TestResponse {
            try await client.call("/api/v1/devices/\(id ?? me.id)", .patch, token: token, json: ServerAPI.RenameDeviceRequest(name: name))
        }
        func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: originals.appendingPathComponent(path).path) }

        // Renamed: the folder, its files and the trashed item's folder follow; nothing is left behind.
        let renamed = try await rename("  Akshob’s iPhone: Duo  ")
        #expect(renamed.status == .ok)
        let info = try renamed.decode(ServerAPI.DeviceInfo.self)
        #expect(info.name == "Akshob’s iPhone: Duo" && info.folder == "Akshob’s iPhone Duo")
        #expect(exists("Akshob’s iPhone Duo/2024/05/IMG_0001.JPG") && !exists("Test iPhone"))
        #expect(exists(".trash/\(recent.sha256)/Akshob’s iPhone Duo/2024/05/IMG_0002.JPG"))
        let resources = try await fixture.server.catalog.resources(kept.sha256)
        #expect(resources.first?.storedPath == "Akshob’s iPhone Duo/2024/05/IMG_0001.JPG")
        let original = try await client.call("/api/v1/assets/\(kept.sha256)/original/photo", token: token)
        let bytes = try Data(contentsOf: media.photo)
        #expect(original.status == .ok && original.data == bytes)
        let storage = try await client.call("/api/v1/storage", token: token).decode(ServerAPI.StorageInfo.self)
        #expect(storage.deviceFolder?.hasSuffix("/Akshob’s iPhone Duo") == true)
        // The trashed item, backed up again, comes back into the renamed folder.
        let again = try await client.call("/api/v1/assets", .post, token: token,
                                          json: ServerAPI.RegisterAssetRequest(kind: .photo, captureDate: date, resources: [recent],
                                                                               compact: false))
        #expect(try again.decode(ServerAPI.AssetStatus.self).state == .stored)
        #expect(exists("Akshob’s iPhone Duo/2024/05/IMG_0002.JPG") && !exists("Test iPhone"))

        // Only the letter case changes (case-insensitive disks too).
        #expect(try await rename("akshob’s iphone duo").status == .ok)
        #expect(try FileManager.default.contentsOfDirectory(atPath: originals.path).contains("akshob’s iphone duo"))
        #expect(exists("akshob’s iphone duo/2024/05/IMG_0001.JPG"))

        // Not another phone's name, nor a folder that's already there; not empty; not another phone.
        let code = try await fixture.server.newPairingCode()
        let other = try await client.call("/api/v1/pair", .post, json: ServerAPI.PairRequest(code: code, deviceName: "iPad"))
            .decode(ServerAPI.PairResponse.self)
        #expect(try await rename("IPAD").status == .conflict)
        try FileManager.default.createDirectory(at: originals.appendingPathComponent("Camera Roll"), withIntermediateDirectories: true)
        #expect(try await rename("Camera Roll").status == .conflict)
        #expect(try await rename("   ").status == .badRequest)
        #expect(try await rename("///").status == .badRequest)
        #expect(try await rename(String(repeating: "x", count: 65)).status == .badRequest)
        let all = try await fixture.server.catalog.devices()
        let otherID = try #require(all.first(where: { $0.name == "iPad" })?.id)
        #expect(try await rename("Mine", id: otherID).status == .forbidden)
        #expect(try await client.call("/api/v1/devices/\(otherID)", .patch, token: other.token,
                                      json: ServerAPI.RenameDeviceRequest(name: "iPad Pro")).status == .ok)
        #expect(exists("akshob’s iphone duo/2024/05/IMG_0001.JPG"))
    }
}

/// A server stopped mid-rename (folders moved, catalog not yet) puts the folders back at startup.
@Test func aRenameInterruptedBeforeTheCatalogChangedIsUndone() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let catalog = try Catalog(path: directory.appendingPathComponent("catalog.db").path)
    let root = directory.appendingPathComponent("originals", isDirectory: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("New/2024"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent(".trash/abc/New"), withIntermediateDirectories: true)
    let plan = DeviceRename.Plan(device: "d", from: "Old", to: "New", trash: [".trash/abc"], via: nil)
    try await catalog.setSetting(DeviceRename.journal, String(decoding: try JSONEncoder().encode(plan), as: UTF8.self))
    try await DeviceRename.recover(catalog: catalog, root: root)
    let fileManager = FileManager.default
    #expect(fileManager.fileExists(atPath: root.appendingPathComponent("Old/2024").path))
    #expect(fileManager.fileExists(atPath: root.appendingPathComponent(".trash/abc/Old").path))
    #expect(!fileManager.fileExists(atPath: root.appendingPathComponent("New").path))
    #expect(try await catalog.setting(DeviceRename.journal) == nil)
    #expect(DeviceRename.moved("Old/2024/05/a.jpg", from: "Old", to: "New") == "New/2024/05/a.jpg")
    #expect(DeviceRename.moved(".trash/abc/Old/2024/a.jpg", from: "Old", to: "New") == ".trash/abc/New/2024/a.jpg")
    #expect(DeviceRename.moved("Older/a.jpg", from: "Old", to: "New") == nil)
    #expect(Storage.folderName(" .Akshob’s iPhone. ") == "Akshob’s iPhone" && Storage.folderName("a/b:c") == "abc")
    #expect(Storage.folderName("Test iPhone") == "Test iPhone" && Storage.folderName("..") == "")
}

// MARK: Storage ownership, descriptor and retention regressions

private actor StorageTestGate {
    private var opened = false
    func open() { opened = true }
    func wait() async throws {
        while !opened { try await Task.sleep(for: .milliseconds(10)) }
    }
}

private func waitForAssetWaiter(_ id: String, catalog: Catalog) async throws {
    while await catalog.mutations.waiting[id, default: 0] == 0 {
        try await Task.sleep(for: .milliseconds(10))
    }
}

private actor PausedResourceBody {
    var bytes: ByteBuffer?
    let entered: StorageTestGate
    let resume: StorageTestGate
    init(bytes: ByteBuffer, entered: StorageTestGate, resume: StorageTestGate) {
        self.bytes = bytes
        self.entered = entered
        self.resume = resume
    }
    func next() async throws -> ByteBuffer? {
        guard let bytes else { return nil }
        self.bytes = nil
        await entered.open()
        try await resume.wait()
        return bytes
    }
}

private struct PauseMotionUpload: RouterMiddleware {
    let entered: StorageTestGate
    let resume: StorageTestGate
    func handle(_ request: Request, context: HomespunRequestContext,
                next: (Request, HomespunRequestContext) async throws -> Response) async throws -> Response {
        guard request.uri.path.hasSuffix("/resources/paired_video") else { return try await next(request, context) }
        let bytes = try await request.body.collect(upTo: 1 << 20)
        let paused = PausedResourceBody(bytes: bytes, entered: entered, resume: resume)
        var request = request
        request.body = RequestBody(asyncSequence: AsyncThrowingStream<ByteBuffer, any Error>(unfolding: {
            try await paused.next()
        }))
        return try await next(request, context)
    }
}

@Test(.timeLimit(.minutes(1))) func applicationOwnsRecoveryAndObserversCannotUndoALiveRename() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let server = fixture.server, root = await server.originals.root
    let old = root.appendingPathComponent("Old"), new = root.appendingPathComponent("New")
    try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
    let plan = DeviceRename.Plan(device: "interrupted", from: "Old", to: "New", trash: [], via: nil, hadFolder: true)
    let text = String(decoding: try JSONEncoder().encode(plan), as: UTF8.self)
    try await server.catalog.setSetting(DeviceRename.journal, text)
    // Application, not only the CLI run() entry point, recovers before admitting requests.
    try await server.application().test(.router) { _ in
        #expect(FileManager.default.fileExists(atPath: old.path))
        #expect(try await server.catalog.setting(DeviceRename.journal) == nil)
        #expect(throws: ServerOwnership.Busy.self) {
            _ = try ServerOwnership(dataDirectory: server.configuration.dataDirectory)
        }
        // The live rename window: disk changed, catalog/journal not committed yet.
        try await server.catalog.setSetting(DeviceRename.journal, text)
        try FileManager.default.moveItem(at: old, to: new)
        let observer = try await Fixture(directory: fixture.directory)
        _ = try await observer.server.newPairingCode()
        _ = try await observer.server.catalog.devices()
        _ = observer.server.fingerprint
        #expect(FileManager.default.fileExists(atPath: new.path))
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(try await server.catalog.setting(DeviceRename.journal) == text)
        await #expect(throws: ServerOwnership.Busy.self) {
            try await LibraryImport(catalog: observer.server.catalog)
                .run(manifest: fixture.directory.appendingPathComponent("unused.jsonl")) { _ in }
        }
    }
    // All workers, including the mover, are stopped before ownership is released.
    _ = try ServerOwnership(dataDirectory: server.configuration.dataDirectory)
}

@Test func observationalConstructionDoesNotReleaseLiveJobLeases() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let catalog = fixture.server.catalog
    let device = try await catalog.claimApprovedDevice(
        .init(id: UUID().uuidString, name: "Phone", createdAt: "", lastSeenAt: nil, revokedAt: nil),
        tokenHash: Pairing.hash("token"))
    let bytes = Data("original".utf8), hash = Fingerprint.sha256(of: bytes)
    let request = ServerAPI.RegisterAssetRequest(kind: .photo, captureDate: nil, resources: [
        .init(role: .photo, filename: "a.jpg", size: bytes.count, sha256: hash)
    ])
    _ = try await catalog.register(request, assetID: hash, device: device.id, initialState: .queued)
    try await catalog.enqueue("compress", assetID: hash)
    _ = try #require(try await catalog.claim(owner: "live", lease: 3600))
    let ownership = try ServerOwnership(dataDirectory: fixture.server.configuration.dataDirectory)
    defer { withExtendedLifetime(ownership) {} }
    _ = try await Fixture(directory: fixture.directory)
    #expect(try await catalog.jobStatus("compress", assetID: hash) == "leased")
}

@Test func renameRecoveryKeepsMissingMountMalformedAndCollisionJournals() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let catalog = try Catalog(path: directory.appendingPathComponent("catalog.db").path)
    let root = directory.appendingPathComponent("disconnected")
    let plan = DeviceRename.Plan(device: "d", from: "Old", to: "New", trash: [], via: nil, hadFolder: true)
    let text = String(decoding: try JSONEncoder().encode(plan), as: UTF8.self)
    try await catalog.setSetting(DeviceRename.journal, text)
    await #expect(throws: (any Error).self) { try await DeviceRename.recover(catalog: catalog, root: root) }
    #expect(try await catalog.setting(DeviceRename.journal) == text)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    // A connected but empty mount point is not evidence that recovery completed.
    await #expect(throws: (any Error).self) { try await DeviceRename.recover(catalog: catalog, root: root) }
    #expect(try await catalog.setting(DeviceRename.journal) == text)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Old"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("New"), withIntermediateDirectories: true)
    await #expect(throws: (any Error).self) { try await DeviceRename.recover(catalog: catalog, root: root) }
    #expect(try await catalog.setting(DeviceRename.journal) == text)
    try FileManager.default.removeItem(at: root.appendingPathComponent("Old"))
    try await DeviceRename.recover(catalog: catalog, root: root)
    #expect(try await catalog.setting(DeviceRename.journal) == nil)
    try await catalog.setSetting(DeviceRename.journal, "{malformed")
    await #expect(throws: (any Error).self) { try await DeviceRename.recover(catalog: catalog, root: root) }
    #expect(try await catalog.setting(DeviceRename.journal) == "{malformed")
}

@Test func originalsMutationIsExclusiveAndAStaleOwnerCannotReleaseItsSuccessor() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let store = fixture.server.originals
    let first = try await store.reserveMutation()
    try await store.makeExclusive(first)
    await #expect(throws: (any Error).self) { try await store.reserveMutation() }
    await #expect(throws: (any Error).self) {
        try await fixture.server.mover.start(to: fixture.directory.appendingPathComponent("Other").path)
    }
    await store.releaseMutation(first)
    let second = try await store.reserveMutation()
    await store.releaseMutation(first)
    await #expect(throws: (any Error).self) { try await store.reserveMutation() }
    await store.releaseMutation(second)
    let root = await store.root
    #expect(try await store.place { $0 } == root)
}

@Test(.timeLimit(.minutes(1))) func registrationCannotReplaceADescriptorBehindASuspendedUpload() async throws {
    let fixture = try await Fixture()
    let still = Data("still".utf8), motion1 = Data("old motion".utf8), motion2 = Data("replacement motion".utf8)
    let primary = ServerAPI.ResourceDescriptor(role: .photo, filename: "a.jpg", size: still.count, sha256: Fingerprint.sha256(of: still))
    let old = ServerAPI.ResourceDescriptor(role: .pairedVideo, filename: "a.mov", size: motion1.count, sha256: Fingerprint.sha256(of: motion1))
    let replacement = ServerAPI.ResourceDescriptor(role: .pairedVideo, filename: "a.mov", size: motion2.count,
                                                    sha256: Fingerprint.sha256(of: motion2))
    try await fixture.test { client, token in
        let id = primary.sha256, catalog = fixture.server.catalog
        _ = try await client.call("/api/v1/assets", .post, token: token, json: ServerAPI.RegisterAssetRequest(
            kind: .livePhoto, captureDate: nil, resources: [primary, old], compact: false))
        let expected = try #require(try await catalog.resources(id).first { $0.role == .pairedVideo })
        let generation = try #require(try await catalog.asset(id)).generation
        let entered = StorageTestGate(), resume = StorageTestGate()
        let router = Router(context: HomespunRequestContext.self)
        router.add(middleware: PauseMotionUpload(entered: entered, resume: resume))
        fixture.server.routes.add(to: router)
        try await Application(router: router).test(.router) { uploading in
            let upload = Task {
                try await uploading.call("/api/v1/assets/\(id)/resources/paired_video?offset=0",
                                         .put, token: token, body: motion1)
            }
            try await entered.wait()
            let register = Task {
                try await client.call("/api/v1/assets", .post, token: token, json: ServerAPI.RegisterAssetRequest(
                    kind: .livePhoto, captureDate: nil, resources: [primary, replacement], compact: false))
            }
            try await waitForAssetWaiter(id, catalog: catalog)
            #expect(try await catalog.resources(id).first { $0.role == .pairedVideo }?.sha256 == old.sha256)
            await resume.open()
            #expect(try await upload.value.status == .ok)
            #expect(try await register.value.status == .ok)
        }
        let current = try #require(try await catalog.resources(id).first { $0.role == .pairedVideo })
        #expect(current.sha256 == replacement.sha256 && current.state == .missing && current.storedPath == nil)
        // The independent CAS still refuses a stale completion, even if a future caller omits coordination.
        await #expect(throws: Catalog.StaleResource.self) {
            try await catalog.markResource(id, role: .pairedVideo, state: .verified,
                                           expected: expected, assetGeneration: generation)
        }
        #expect(try await catalog.resources(id).first { $0.role == .pairedVideo }?.state == .missing)
        #expect(try await catalog.storedOriginals().contains { $0.sha256 == old.sha256 })
        let device = try #require(try await catalog.devices().first)
        _ = try await catalog.register(.init(kind: .photo, captureDate: nil, resources: [primary], compact: false),
                                       assetID: id, device: device.id, initialState: .receiving)
        _ = try await catalog.register(.init(kind: .livePhoto, captureDate: nil, resources: [primary, old], compact: false),
                                       assetID: id, device: device.id, initialState: .receiving)
        // Even removing and re-adding the identical descriptor cannot revive an old completion.
        await #expect(throws: Catalog.StaleResource.self) {
            try await catalog.markResource(id, role: .pairedVideo, state: .verified,
                                           expected: expected, assetGeneration: generation)
        }
    }
}

@Test func supersededOriginalsRemainIndexedAccountedForRenamedAndMoved() async throws {
    let fixture = try await Fixture()
    try await fixture.test { client, token in
        let catalog = fixture.server.catalog
        let primaryBytes = Data("primary".utf8), oldBytes = Data("old secondary".utf8), newBytes = Data("new secondary".utf8)
        let photo = ServerAPI.ResourceDescriptor(role: .photo, filename: "a.jpg", size: primaryBytes.count,
                                                 sha256: Fingerprint.sha256(of: primaryBytes))
        func secondary(_ bytes: Data) -> ServerAPI.ResourceDescriptor {
            .init(role: .alternatePhoto, filename: "edit.jpg", size: bytes.count, sha256: Fingerprint.sha256(of: bytes))
        }
        func register(_ resources: [ServerAPI.ResourceDescriptor]) async throws {
            _ = try await client.call("/api/v1/assets", .post, token: token, json: ServerAPI.RegisterAssetRequest(
                kind: .photo, captureDate: nil, resources: resources, compact: false))
        }
        func upload(_ role: String, _ bytes: Data) async throws {
            #expect(try await client.call("/api/v1/assets/\(photo.sha256)/resources/\(role)?offset=0",
                                         .put, token: token, body: bytes).status == .ok)
        }
        try await register([photo, secondary(oldBytes)])
        try await upload("photo", primaryBytes)
        try await upload("alternate_photo", oldBytes)
        try await register([photo, secondary(newBytes)])
        try await upload("alternate_photo", newBytes)
        try await register([photo])
        let indexed = try await catalog.storedOriginals()
        #expect(indexed.count == 3 && Set(indexed.map(\.sha256)) == Set([photo.sha256, secondary(oldBytes).sha256, secondary(newBytes).sha256]))
        try await catalog.rememberCopies(photo.sha256, [.init(role: .alternatePhoto, sha256: secondary(oldBytes).sha256)])
        #expect(try await catalog.madeCopy(sha256: secondary(oldBytes).sha256) == nil)
        let info = try await client.call("/api/v1/storage", token: token).decode(ServerAPI.StorageInfo.self)
        #expect(info.storedBytes == Int64(primaryBytes.count + oldBytes.count + newBytes.count))
        let device = try #require(try await catalog.devices().first)
        #expect(try await client.call("/api/v1/devices/\(device.id)", .patch, token: token,
                                     json: ServerAPI.RenameDeviceRequest(name: "Renamed")).status == .ok)
        #expect(try await catalog.storedOriginals().allSatisfy { $0.path.hasPrefix("Renamed/") })
        let previousRoot = await fixture.server.originals.root
        let target = fixture.directory.appendingPathComponent("Moved")
        try await fixture.server.mover.start(to: target.path)
        await fixture.server.mover.wait()
        #expect(await fixture.server.mover.status?.state == .done)
        let reopened = try Catalog(path: fixture.server.storage.catalog.path)
        #expect(try await reopened.storedOriginals().count == 3)
        let previous = try #require(try await reopened.setting(OriginalsMover.previousRootsSetting))
        #expect(try JSONDecoder().decode([String].self, from: Data(previous.utf8)) == [previousRoot.path])
        for item in try await reopened.storedOriginals() {
            #expect(try Fingerprint.sha256(of: target.appendingPathComponent(item.path)) == item.sha256)
        }
    }
}

@Test(.timeLimit(.minutes(1))) func staleRemovalCannotTrashADownloadedPermanentBackupWithoutAnImportAck() async throws {
    let fixture = try await Fixture()
    try await fixture.test { client, token in
        let data = Data("original".utf8), id = Fingerprint.sha256(of: data), catalog = fixture.server.catalog
        let resource = ServerAPI.ResourceDescriptor(role: .photo, filename: "a.jpg", size: data.count, sha256: id)
        _ = try await client.call("/api/v1/assets", .post, token: token, json: ServerAPI.RegisterAssetRequest(
            kind: .photo, captureDate: nil, resources: [resource], compact: false))
        _ = try await client.call("/api/v1/assets/\(id)/resources/photo?offset=0", .put, token: token, body: data)
        let observed = try #require(try await catalog.asset(id))
        let resume = StorageTestGate()
        let staleRemoval = Task {
            try await resume.wait()
            try await Trash(catalog: catalog, originals: fixture.server.originals, storage: fixture.server.storage).remove(observed)
        }
        let code = try await fixture.server.newPairingCode()
        let other = try await client.call("/api/v1/pair", .post, json: ServerAPI.PairRequest(code: code, deviceName: "Other iPhone"))
            .decode(ServerAPI.PairResponse.self).token
        _ = try await client.call("/api/v1/assets", .post, token: other, json: ServerAPI.RegisterAssetRequest(
            kind: .photo, captureDate: nil, resources: [resource]))
        // A failed/lost imported acknowledgement cannot determine retention.
        #expect(try await client.call("/api/v1/assets/\(id)/imported", .post, token: other).status == .conflict)
        let compactBytes = Data("compact".utf8), directory = fixture.server.storage.compact(id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let compact = directory.appendingPathComponent("a.jpg")
        try compactBytes.write(to: compact)
        try await catalog.storeCompact(id, [.init(role: .photo, filename: "a.jpg", size: compactBytes.count,
            sha256: Fingerprint.sha256(of: compactBytes), path: fixture.server.storage.relative(compact))],
            deviceCompresses: [], state: .ready, message: nil)
        #expect(try await client.call("/api/v1/assets/\(id)/compact/photo", token: other).data == compactBytes)
        await resume.open()
        await #expect(throws: APIError.self) { try await staleRemoval.value }
        #expect(try await client.call("/api/v1/assets/\(id)/verify", .post, token: other)
            .decode(ServerAPI.Verification.self).allVerified)
        #expect(try await fixture.server.emptyTrash(now: Date().addingTimeInterval(31 * 86_400)) == 0)
        // A later explicit deferral also cannot revoke another request's permanent claim.
        _ = try await client.call("/api/v1/assets", .post, token: token, json: ServerAPI.RegisterAssetRequest(
            kind: .photo, captureDate: nil, resources: [resource], compact: false))
        #expect(try await client.call("/api/v1/assets/\(id)/removed", .post, token: token).status == .conflict)
        #expect(try await catalog.asset(id)?.permanent == true)
    }
}

@Test(.timeLimit(.minutes(1))) func expiredPurgeRechecksItsClaimAfterARestoreWins() async throws {
    let fixture = try await Fixture()
    try await fixture.test { client, token in
        let bytes = Data("deferred original".utf8), id = Fingerprint.sha256(of: bytes)
        let catalog = fixture.server.catalog
        _ = try await client.call("/api/v1/assets", .post, token: token, json: ServerAPI.RegisterAssetRequest(
            kind: .photo, captureDate: nil, resources: [.init(role: .photo, filename: "a.jpg", size: bytes.count, sha256: id)], compact: false))
        _ = try await client.call("/api/v1/assets/\(id)/resources/photo?offset=0", .put, token: token, body: bytes)
        #expect(try await client.call("/api/v1/assets/\(id)/verify", .post, token: token).status == .conflict)
        #expect(try await catalog.asset(id)?.permanent == false)
        _ = try await client.call("/api/v1/assets/\(id)/removed", .post, token: token)
        #expect(try await client.call("/api/v1/assets/\(id)/verify", .post, token: token).status == .conflict)
        let entered = StorageTestGate(), resume = StorageTestGate()
        let restore = Task {
            try await catalog.mutations.withClaim(id) {
                await entered.open()
                try await resume.wait()
                try await Trash(catalog: catalog, originals: fixture.server.originals, storage: fixture.server.storage).restoreClaimed(id)
            }
        }
        try await entered.wait()
        let purge = Task { try await fixture.server.emptyTrash(now: Date().addingTimeInterval(31 * 86_400)) }
        try await waitForAssetWaiter(id, catalog: catalog)
        await resume.open()
        try await restore.value
        #expect(try await purge.value == 0)
        #expect(try await catalog.asset(id)?.state == .stored)
        let path = try #require(try await catalog.resources(id).first?.storedPath)
        let url = try #require(await fixture.server.originals.url(path))
        #expect(try Data(contentsOf: url) == bytes)
    }
}

@Test func retentionMigrationDoesNotGuessLegacyDeferredIntent() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("legacy.db").path, old = try SQLiteDatabase(path: directory.appendingPathComponent("legacy.db").path)
    for migration in Catalog.migrations.prefix(10) { try old.executeScript(migration) }
    try old.execute("PRAGMA user_version = 10")
    let stored = String(repeating: "a", count: 64), trashed = String(repeating: "b", count: 64)
    for (id, state) in [(stored, "stored"), (trashed, "trashed")] {
        try old.execute("""
            INSERT INTO assets (id, kind, state, created_at, updated_at, hold_compact, trashed_at)
            VALUES (?, 'photo', ?, '2020-01-01T00:00:00Z', '2020-01-01T00:00:00Z', 1, ?)
            """, [.text(id), .text(state), state == "trashed" ? .text("2020-01-01T00:00:00Z") : .null])
    }
    let catalog = try Catalog(path: path)
    #expect(try await catalog.asset(stored)?.permanent == true)
    #expect(try await catalog.asset(trashed)?.permanent == true)
    #expect(try await catalog.trashed(before: Timestamp.string()).isEmpty)
    #expect(try await !catalog.proofEligible(trashed))
    #expect(try await catalog.status(trashed)?.trashedUntil == nil)
    #expect(try await catalog.status(trashed)?.message?.contains("will not expire") == true)
}

@Test func closingAdmissionKeepsTheFileLeaseUntilAdmittedRequestsExit() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let startup = ServingStartup()
    do {
        let ownership = try ServerOwnership(dataDirectory: fixture.server.configuration.dataDirectory)
        await startup.complete(.success(()), ownership: ownership)
    }
    do {
        let admitted = try await startup.admit()
        defer { withExtendedLifetime(admitted) {} }
        await startup.close()
        await #expect(throws: HTTPError.self) { try await startup.admit() }
        #expect(throws: ServerOwnership.Busy.self) {
            _ = try ServerOwnership(dataDirectory: fixture.server.configuration.dataDirectory)
        }
    }
    _ = try ServerOwnership(dataDirectory: fixture.server.configuration.dataDirectory)
}

@Test func interruptedTrashMoveKeepsItsJournalUntilTheDiskReturns() async throws {
    let fixture = try await Fixture()
    try await fixture.test { client, token in
        let bytes = Data("original".utf8), id = Fingerprint.sha256(of: bytes), catalog = fixture.server.catalog
        _ = try await client.call("/api/v1/assets", .post, token: token, json: ServerAPI.RegisterAssetRequest(
            kind: .photo, captureDate: nil, resources: [.init(role: .photo, filename: "a.jpg", size: bytes.count, sha256: id)], compact: false))
        _ = try await client.call("/api/v1/assets/\(id)/resources/photo?offset=0", .put, token: token, body: bytes)
        let resource = try #require(try await catalog.resources(id).first)
        let path = try #require(resource.storedPath), root = await fixture.server.originals.root
        let target = Trash.trashed(path, assetID: id)
        let plan = Trash.Plan(asset: id, generation: 0, action: .remove,
                              entries: [.init(role: .photo, from: path, to: target, sha256: id, size: bytes.count, copy: false)],
                              at: Timestamp.string())
        let text = String(decoding: try JSONEncoder().encode(plan), as: UTF8.self)
        try await catalog.saveTrashMutation(id, generation: 0, action: .remove, text: text)
        let destination = root.appendingPathComponent(target)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: root.appendingPathComponent(path), to: destination)
        let away = fixture.directory.appendingPathComponent("away")
        try FileManager.default.moveItem(at: root, to: away)
        let unavailable = Trash(catalog: catalog, originals: OriginalsStore(root: root), storage: fixture.server.storage)
        await #expect(throws: (any Error).self) { try await unavailable.recover() }
        #expect(try await catalog.setting(Trash.journal(id)) == text)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        try FileManager.default.moveItem(at: away, to: root)
        let restarted = Trash(catalog: catalog, originals: OriginalsStore(root: root), storage: fixture.server.storage)
        try await restarted.recover()
        #expect(try await catalog.setting(Trash.journal(id)) == nil)
        #expect(try await catalog.asset(id)?.state == .trashed)
        #expect(try await catalog.resources(id).first?.storedPath == target)
        #expect(try Data(contentsOf: destination) == bytes)
    }
}

@Test func purgingRefusesRestoreAndPreservesAnIndexedHistoricalReference() async throws {
    let fixture = try await Fixture()
    try await fixture.test { client, token in
        let bytes = Data("shared object".utf8), id = Fingerprint.sha256(of: bytes), catalog = fixture.server.catalog
        let request = ServerAPI.RegisterAssetRequest(kind: .photo, captureDate: nil,
            resources: [.init(role: .photo, filename: "a.jpg", size: bytes.count, sha256: id)], compact: false)
        _ = try await client.call("/api/v1/assets", .post, token: token, json: request)
        _ = try await client.call("/api/v1/assets/\(id)/resources/photo?offset=0", .put, token: token, body: bytes)
        _ = try await client.call("/api/v1/assets/\(id)/removed", .post, token: token)
        let path = try #require(try await catalog.resources(id).first?.storedPath)
        try await catalog.preserveSharedOriginal(id, role: .photo, path: path)
        let plan = Trash.Plan(asset: id, generation: 0, action: .purge,
                              entries: [.init(role: .photo, from: path, sha256: id, size: bytes.count, copy: false)])
        try await catalog.saveTrashMutation(id, generation: 0, action: .purge,
            text: String(decoding: try JSONEncoder().encode(plan), as: UTF8.self))
        #expect(try await client.call("/api/v1/assets", .post, token: token, json: request).status == .serviceUnavailable)
        #expect(try await client.call("/api/v1/assets/\(id)/verify", .post, token: token).status == .conflict)
        let restarted = OriginalsStore(root: await fixture.server.originals.root)
        try await Trash(catalog: catalog, originals: restarted, storage: fixture.server.storage).recover()
        #expect(try await catalog.asset(id) == nil)
        #expect(try await catalog.storedOriginals().contains { $0.path == path })
        let url = try #require(await fixture.server.originals.url(path))
        #expect(try Data(contentsOf: url) == bytes)
        #expect(try await catalog.trashTotals().bytes == Int64(bytes.count))
    }
}

@Test func caseOnlyRenameRecoveryHandlesBothIntermediateAndFinalNames() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let catalog = try Catalog(path: directory.appendingPathComponent("catalog.db").path)
    let root = directory.appendingPathComponent("originals")
    let plan = DeviceRename.Plan(device: "d", from: "Phone", to: "phone", trash: [],
                                  via: ".homespun-rename-test", hadFolder: true)
    let text = String(decoding: try JSONEncoder().encode(plan), as: UTF8.self)
    for interrupted in [plan.to, try #require(plan.via)] {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(interrupted), withIntermediateDirectories: true)
        try await catalog.setSetting(DeviceRename.journal, text)
        try await DeviceRename.recover(catalog: catalog, root: root)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == [plan.from])
        try FileManager.default.removeItem(at: root.appendingPathComponent(plan.from))
    }

    // MARK: Versioned foreground backup protocol

    private func backupTestRequest(_ client: some TestClientProtocol, token: String, data: Data,
                                   kind: ServerAPI.AssetKind = .photo, compact: Bool = false,
                                   retention: BackupAPI.RetentionPolicy = .permanent) async throws
        -> (BackupAPI.Request, BackupAPI.Receipt) {
        let capabilities = try await client.call("/api/v2/capabilities", token: token).decode(BackupAPI.Capabilities.self)
        let role: Role = kind == .video ? .video : .photo
        let request = BackupAPI.Request(operationID: UUID(), origin: capabilities.origin,
            manifest: .init(kind: kind, resources: [.init(role: role, filename: kind == .video ? "a.mp4" : "a.jpg",
                size: data.count, sha256: Fingerprint.sha256(of: data))]),
            profile: capabilities.recipe.profile, retention: retention, compact: compact)
        let response = try await client.call("/api/v2/backup-requests", .post, token: token, json: request)
        #expect(response.status == .created)
        return (request, try response.decode(BackupAPI.Receipt.self))
    }

    private func backupTestPatch(_ client: some TestClientProtocol, token: String, upload: UUID, offset: Int,
                                 data: Data) async throws -> TestResponse {
        var headers = HTTPFields()
        headers[.authorization] = "Bearer \(token)"
        headers[.contentType] = "application/offset+octet-stream"
        headers[BackupRoutes.offset] = String(offset)
        return try await client.execute(uri: "/api/v2/uploads/\(upload.uuidString)", method: .patch,
                                        headers: headers, body: ByteBuffer(bytes: data))
    }

    private func backupTestUpload(_ client: some TestClientProtocol, token: String, receipt: BackupAPI.Receipt,
                                  role: Role = .photo, data: Data) async throws -> BackupAPI.Receipt {
        let id = UUID()
        let response = try await client.call("/api/v2/uploads", .post, token: token,
            json: BackupAPI.UploadRequest(uploadID: id, requestID: receipt.requestID, version: receipt.version, role: role))
        #expect(response.status == .created)
        let admission = try response.decode(BackupAPI.UploadAdmission.self)
        #expect(admission.uploadProtocol == .foregroundOffset)
        for offset in stride(from: 0, to: data.count, by: Int(admission.maximumChunkBytes)) {
            let end = min(data.count, offset + Int(admission.maximumChunkBytes))
            #expect(try await backupTestPatch(client, token: token, upload: id, offset: offset, data: data[offset..<end]).status == .noContent)
        }
        let completed = try await client.call("/api/v2/uploads/\(id.uuidString)/complete", .post, token: token)
        #expect(completed.status == .ok)
        return try completed.decode(BackupAPI.Receipt.self)
    }

    @Test func versionedAdmissionIsIdempotentPrincipalScopedAndRetainsBeforeCompact() async throws {
        let fixture = try await Fixture()
        try await fixture.test { client, token in
            #expect(try await client.call("/api/v2/capabilities").status == .unauthorized)
            let caps = try await client.call("/api/v2/capabilities", token: token).decode(BackupAPI.Capabilities.self)
            #expect(caps.uploadProtocols == [.foregroundOffset])
            let (request, first) = try await backupTestRequest(client, token: token, data: Data("original".utf8))
            #expect(first.revision > 0 && first.retention == .pending && first.backup == .uploading)
            let replay = try await client.call("/api/v2/backup-requests", .post, token: token, json: request)
            #expect(replay.status == .ok && (try replay.decode(BackupAPI.Receipt.self)) == first)
            var different = request
            different.compact = true
            let conflict = try await client.call("/api/v2/backup-requests", .post, token: token, json: different)
            #expect(conflict.status == .conflict)
            #expect(try conflict.decode(ServerAPI.ErrorBody.self).error.code == BackupAPI.ErrorCode.idempotencyConflict)
            #expect(try await client.call("/api/v2/backup-requests?operation_id=\(request.operationID)", token: token)
                .decode(BackupAPI.Receipt.self) == first)
            let other = try await fixture.pair(client)
            #expect(try await client.call("/api/v2/backup-requests/\(first.requestID)", token: other).status == .notFound)
            #expect(try await client.call("/api/v2/uploads", .post, token: other,
                json: BackupAPI.UploadRequest(uploadID: UUID(), requestID: first.requestID, version: first.version, role: .photo)).status == .notFound)
            let second = try await client.call("/api/v2/backup-requests", .post, token: other, json: request)
                .decode(BackupAPI.Receipt.self)
            #expect(second.requestID != first.requestID && second.operationID == first.operationID && second.version == first.version)
            let retained = try await backupTestUpload(client, token: token, receipt: first, data: Data("original".utf8))
            #expect(retained.backup == .retained && retained.retention == .permanent && retained.derivative == nil)
            #expect(retained.revision > first.revision && retained.compact == .requested)
            let cancelled = try await client.call("/api/v2/backup-requests/\(first.requestID)/commands", .post, token: token,
                json: BackupAPI.Command(operationID: UUID(), version: first.version, action: .cancel)).decode(BackupAPI.Receipt.self)
            #expect(cancelled.backup == .retained && cancelled.retention == .permanent)
            let proof = try await client.call("/api/v2/assets/\(first.version.assetID)/versions/\(first.version.manifestID)/verify",
                .post, token: token, json: first.version).decode(BackupAPI.OriginalProof.self)
            #expect(proof.version == first.version && proof.claimID != nil && proof.retention == .permanent)
            #expect(try await client.call("/api/v1/assets/\(first.version.assetID)/verify", .post, token: token).status == .notFound)
        }
    }

    @Test func versionedOffsetsReconcileAfterRestartAndBadBytesNeverBecomeRetained() async throws {
        let fixture = try await Fixture()
        try await fixture.test { client, token in
            let bytes = Data("durable-original-bytes".utf8)
            let (_, receipt) = try await backupTestRequest(client, token: token, data: bytes)
            let uploadID = UUID(), id = uploadID.uuidString.lowercased()
            let admission = try await client.call("/api/v2/uploads", .post, token: token,
                json: BackupAPI.UploadRequest(uploadID: uploadID, requestID: receipt.requestID, version: receipt.version, role: .photo))
                .decode(BackupAPI.UploadAdmission.self)
            #expect(admission.maximumChunkBytes == Int64(fixture.server.configuration.maximumChunkBytes))
            #expect(try await backupTestPatch(client, token: token, upload: uploadID, offset: 0, data: bytes.prefix(4)).status == .noContent)
            let partial = BackupPublication.partial(id, storage: fixture.server.storage)
            let handle = try FileHandle(forWritingTo: partial)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("unacknowledged-tail".utf8))
            try handle.close()
            let restarted = try await Fixture(directory: fixture.directory)
            try await Application(router: restarted.server.testRouter()).test(.router) { live in
                let head = try await live.call("/api/v2/uploads/\(uploadID)", .head, token: token)
                #expect(head.status == .noContent && head.data.isEmpty)
                #expect(head.headers[BackupRoutes.offset] == "4" && head.headers[BackupRoutes.length] == String(bytes.count))
                #expect(try JobRunner.size(of: partial) == 4)
                #expect(try await backupTestPatch(live, token: token, upload: uploadID, offset: 0, data: bytes).status == .conflict)
                #expect(try await backupTestPatch(live, token: token, upload: uploadID, offset: 4, data: bytes.dropFirst(4)).status == .noContent)
                let complete = try await live.call("/api/v2/uploads/\(uploadID)/complete", .post, token: token).decode(BackupAPI.Receipt.self)
                #expect(complete.backup == .retained && complete.retention == .permanent)
                #expect(try await live.call("/api/v2/uploads/\(uploadID)/complete", .post, token: token)
                    .decode(BackupAPI.Receipt.self) == complete)
            }
            let bad = Data("different-original".utf8)
            let (_, attempt) = try await backupTestRequest(client, token: token, data: bad)
            let badUpload = UUID()
            _ = try await client.call("/api/v2/uploads", .post, token: token,
                json: BackupAPI.UploadRequest(uploadID: badUpload, requestID: attempt.requestID, version: attempt.version, role: .photo))
            _ = try await backupTestPatch(client, token: token, upload: badUpload, offset: 0, data: Data(repeating: 0, count: bad.count))
            #expect(try await client.call("/api/v2/uploads/\(badUpload)/complete", .post, token: token).status == .unprocessableContent)
            #expect(try await client.call("/api/v2/assets/\(attempt.version.assetID)/versions/\(attempt.version.manifestID)/verify",
                .post, token: token, json: attempt.version).status == .conflict)
            #expect(try await client.call("/api/v2/backup-requests/\(attempt.requestID)", token: token)
                .decode(BackupAPI.Receipt.self).retention == .pending)
            #expect(try await backupTestUpload(client, token: token, receipt: attempt, data: bad).retention == .permanent)
        }
    }

    @Test func versionedFeedSnapshotsAreConsistentAndReceiptRevisionsNeverRegress() async throws {
        let fixture = try await Fixture()
        try await fixture.test { client, token in
            var receipts: [BackupAPI.Receipt] = []
            for value in ["one", "two", "three"] {
                let (_, receipt) = try await backupTestRequest(client, token: token, data: Data(value.utf8))
                receipts.append(receipt)
            }
            let principal = try #require(try await fixture.server.catalog.device(tokenHash: Pairing.hash(token))).id
            let first = try await fixture.server.catalog.backupSnapshot(principal: principal, continuation: nil, limit: 1)
            let changed = try #require(receipts.first { $0.requestID != first.receipts.first?.requestID })
            let command = BackupAPI.Command(operationID: UUID(), version: changed.version, action: .pause)
            let newest = try await client.call("/api/v2/backup-requests/\(changed.requestID)/commands", .post, token: token, json: command)
                .decode(BackupAPI.Receipt.self)
            #expect(newest.revision > changed.revision)
            #expect(try await client.call("/api/v2/backup-requests/\(changed.requestID)/commands", .post, token: token, json: command)
                .decode(BackupAPI.Receipt.self) == newest)
            var snapshot = first.receipts, continuation = first.continuation
            while let page = continuation {
                let next = try await fixture.server.catalog.backupSnapshot(principal: principal, continuation: page, limit: 1)
                #expect(next.cursor == first.cursor)
                snapshot += next.receipts
                continuation = next.continuation
            }
            #expect(snapshot.first { $0.requestID == changed.requestID } == changed)
            let changes = try await fixture.server.catalog.backupChanges(principal: principal, after: first.cursor,
                epoch: changed.version.origin.historyEpoch, limit: 200)
            #expect(changes.changes.last?.receipt == newest && !changes.hasMore)
            #expect(try await client.call("/api/v2/backup-requests/\(changed.requestID)", token: token)
                .decode(BackupAPI.Receipt.self) == newest)
            let other = try await fixture.pair(client)
            let escaped = try await client.call("/api/v2/snapshot?continuation=\(try #require(first.continuation))", token: other)
            #expect(escaped.status == .conflict)
            let wakes = try await fixture.server.catalog.pendingBackupWakes()
            let wake = try #require(wakes.first { $0.principal == principal })
            try await fixture.server.catalog.acknowledgeBackupWake(principal: principal, sequence: wake.sequence - 1)
            #expect(try await fixture.server.catalog.pendingBackupWakes().contains { $0.principal == principal })
            try await fixture.server.catalog.acknowledgeBackupWake(principal: principal, sequence: wake.sequence)
            #expect(try await !fixture.server.catalog.pendingBackupWakes().contains { $0.principal == principal })
            let newOrigin = try await fixture.server.rotateBackupHistoryAfterRestore()
            #expect(newOrigin.serverID == changed.version.origin.serverID && newOrigin.historyEpoch != changed.version.origin.historyEpoch)
            #expect(try await client.call("/api/v2/changes?after=0&epoch=\(changed.version.origin.historyEpoch)", token: token).status == .conflict)
            #expect(try await client.call("/api/v2/backup-requests/\(changed.requestID)", token: token)
                .decode(BackupAPI.Receipt.self).revision > newest.revision)
        }
    }

    @Test func versionedPublicationRecoversAndOldManifestsSurviveMovesAndV1Edits() async throws {
        let fixture = try await Fixture()
        try await fixture.test { client, token in
            let bytes = Data("journaled-original".utf8)
            let (_, receipt) = try await backupTestRequest(client, token: token, data: bytes)
            let uploadID = UUID()
            _ = try await client.call("/api/v2/uploads", .post, token: token,
                json: BackupAPI.UploadRequest(uploadID: uploadID, requestID: receipt.requestID, version: receipt.version, role: .photo))
            _ = try await backupTestPatch(client, token: token, upload: uploadID, offset: 0, data: bytes)
            let principal = try #require(try await fixture.server.catalog.device(tokenHash: Pairing.hash(token))).id
            let upload = try await fixture.server.catalog.backupUpload(uploadID.uuidString.lowercased(), principal: principal)
            let root = await fixture.server.originals.root
            let path = "Test iPhone/versions/\(receipt.version.assetID)/\(receipt.version.manifestID)/photo-a.jpg"
            try await fixture.server.catalog.prepareBackupPublication(upload, path: path)
            let away = fixture.directory.appendingPathComponent("away")
            try FileManager.default.moveItem(at: root, to: away)
            let restarted = try await Fixture(directory: fixture.directory)
            #expect(!FileManager.default.fileExists(atPath: root.path))
            await #expect(throws: (any Error).self) { try await restarted.server.drainJobs() }
            #expect(try await restarted.server.catalog.hasBackupPublications())
            try FileManager.default.moveItem(at: away, to: root)
            try await restarted.server.drainJobs()
            #expect(try await !restarted.server.catalog.hasBackupPublications())
            #expect(try await restarted.server.catalog.backupReceipt(receipt.requestID.uuidString.lowercased(), principal: principal).retention == .permanent)
            let primary = ServerAPI.ResourceDescriptor(role: .photo, filename: "a.jpg", size: bytes.count, sha256: receipt.version.assetID)
            var edited = BackupAPI.Request(operationID: UUID(), origin: receipt.version.origin,
                manifest: .init(kind: .photo, resources: [primary,
                    .init(role: .alternatePhoto, filename: "edit.jpg", size: 3, sha256: Fingerprint.sha256(of: Data("new".utf8)))]),
                profile: testProfile, compact: false)
            let second = try await client.call("/api/v2/backup-requests", .post, token: token, json: edited).decode(BackupAPI.Receipt.self)
            #expect(second.version.manifestID != receipt.version.manifestID
                && second.version.descriptorGeneration > receipt.version.descriptorGeneration)
            _ = try await backupTestUpload(client, token: token, receipt: second, data: bytes)
            _ = try await backupTestUpload(client, token: token, receipt: second, role: .alternatePhoto, data: Data("new".utf8))
            edited.manifest.resources.removeLast()
            _ = try await client.call("/api/v1/assets", .post, token: token, json: ServerAPI.RegisterAssetRequest(
                kind: .photo, captureDate: nil, resources: edited.manifest.resources, compact: false))
            let device = try #require(try await fixture.server.catalog.devices().first)
            #expect(try await client.call("/api/v1/devices/\(device.id)", .patch, token: token,
                json: ServerAPI.RenameDeviceRequest(name: "Versioned Phone")).status == .ok)
            let moved = fixture.directory.appendingPathComponent("Moved")
            try await fixture.server.mover.start(to: moved.path)
            await fixture.server.mover.wait()
            #expect(await fixture.server.mover.status?.state == .done)
            for version in [receipt.version, second.version] {
                let proof = try await client.call("/api/v2/assets/\(version.assetID)/versions/\(version.manifestID)/verify",
                    .post, token: token, json: version).decode(BackupAPI.OriginalProof.self)
                #expect(proof.retention == .permanent && proof.version == version)
            }
            let source = try await client.call("/api/v2/assets/\(receipt.version.assetID)/versions/\(receipt.version.manifestID)/resources/photo?request_id=\(receipt.requestID)",
                                               token: token)
            #expect(source.status == .ok && source.data == bytes && source.headers[.eTag] == "\"\(receipt.version.assetID)\"")
            #expect(try await fixture.server.catalog.storedOriginals().count == 3)
        }
    }

    @Test(.enabled(if: ffmpegAvailable), .timeLimit(.minutes(2)))
    func versionedPhotoProgressesDuringVideoAndStaleWorkersCannotPublishOrAckAnotherConsumer() async throws {
        let fixture = try await Fixture()
        let media = try await Media.make(in: fixture.directory)
        try await fixture.test { client, token in
            let (_, photo) = try await backupTestRequest(client, token: token, data: Data(contentsOf: media.photo), compact: true)
            _ = try await backupTestUpload(client, token: token, receipt: photo, data: Data(contentsOf: media.photo))
            let (_, video) = try await backupTestRequest(client, token: token, data: Data(contentsOf: media.movie), kind: .video, compact: true)
            _ = try await backupTestUpload(client, token: token, receipt: video, role: .video, data: Data(contentsOf: media.movie))
            let old = try #require(try await fixture.server.catalog.claimBackupJob(lane: "video", owner: "old-video", lease: 90))
            let entered = StorageTestGate(), resume = StorageTestGate()
            let encoding = Task {
                try await fixture.server.budget.run(.video) {
                    await entered.open()
                    try await resume.wait()
                }
            }
            try await entered.wait()
            #expect(try await fixture.server.backupPhoto.runNext())
            let ready = try await client.call("/api/v2/backup-requests/\(photo.requestID)", token: token).decode(BackupAPI.Receipt.self)
            let derivative = try #require(ready.derivative), resource = try #require(derivative.resources.first)
            #expect(ready.compact == .ready)
            let uri = "/api/v2/derivatives/\(derivative.generationID)/resources/\(resource.role.rawValue)"
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.range] = "bytes=0-9"
            let part = try await client.execute(uri: uri, method: .get, headers: headers)
            #expect(part.status == .partialContent && part.data.count == 10 && part.headers[.contentLength] == "10")
            #expect(part.headers[.eTag] == "\"\(resource.sha256)\"")
            headers[.ifRange] = "\"another-generation\""
            #expect(try await client.execute(uri: uri, method: .get, headers: headers).status == .ok)
            headers[.ifRange] = part.headers[.eTag]
            headers[.range] = "bytes=\(resource.size)-"
            #expect(try await client.execute(uri: uri, method: .get, headers: headers).status == .rangeNotSatisfiable)
            let other = try await fixture.pair(client)
            #expect(try await client.call(uri, token: other).status == .notFound)
            let ack = BackupAPI.DeliveryAcknowledgement(deliveryID: UUID(), requestID: photo.requestID,
                generationID: derivative.generationID, version: photo.version)
            #expect(try await client.call("/api/v2/deliveries/\(ack.deliveryID)/ack", .post, token: other, json: ack).status == .notFound)
            let accounted = try await client.call("/api/v2/deliveries/\(ack.deliveryID)/ack", .post, token: token, json: ack)
                .decode(BackupAPI.Receipt.self)
            #expect(accounted.revision > ready.revision && accounted.retention == .permanent)
            #expect(try await client.call("/api/v2/deliveries/\(ack.deliveryID)/ack", .post, token: token, json: ack)
                .decode(BackupAPI.Receipt.self) == accounted)
            _ = try await client.call("/api/v2/backup-requests/\(video.requestID)/commands", .post, token: token,
                json: BackupAPI.Command(operationID: UUID(), version: video.version, action: .cancel))
            #expect(try await !fixture.server.catalog.heartbeatBackupJob(old))
            await #expect(throws: CancellationError.self) {
                try await fixture.server.catalog.publishBackupJob(old, outcome: .init(files: [], deviceCompresses: [], state: .held, message: nil),
                                                                  storage: fixture.server.storage)
            }
            await resume.open()
            try await encoding.value
            #expect(try await client.call("/api/v2/backup-requests/\(video.requestID)", token: token)
                .decode(BackupAPI.Receipt.self).retention == .permanent)
        }
    }

    @Test func versionedDeferredAndImmichRequestsNeverIssuePermanentProofs() async throws {
        let local = try await Fixture()
        try await local.test { client, token in
            let (_, deferred) = try await backupTestRequest(client, token: token, data: Data("deferred".utf8), retention: .deferred)
            let complete = try await backupTestUpload(client, token: token, receipt: deferred, data: Data("deferred".utf8))
            #expect(complete.backup == .retained && complete.retention == .deferred)
            #expect(try await client.call("/api/v2/assets/\(deferred.version.assetID)/versions/\(deferred.version.manifestID)/verify",
                .post, token: token, json: deferred.version).status == .conflict)
        }

        extension Catalog {
            func expireBackupLeaseForTest(_ job: BackupJob) throws {
                try database.execute("UPDATE backup_jobs SET expires_at = '2000-01-01T00:00:00Z' WHERE id = ?", [.text(job.id)])
            }

            func expireLegacyLeaseForTest(_ job: Job) throws {
                try database.execute("UPDATE jobs SET lease_expires_at = '2000-01-01T00:00:00Z' WHERE id = ?", [.integer(Int64(job.id))])
            }
        }

        @Test func reclaimedWorkerFencesRejectEveryStaleTransitionWithoutLosingRetention() async throws {
            let fixture = try await Fixture()
            try await fixture.test { client, token in
                let bytes = Data("fenced".utf8)
                let (_, receipt) = try await backupTestRequest(client, token: token, data: bytes, compact: true)
                _ = try await backupTestUpload(client, token: token, receipt: receipt, data: bytes)
                let catalog = fixture.server.catalog
                let old = try #require(try await catalog.claimBackupJob(lane: "photo", owner: "first"))
                try await catalog.expireBackupLeaseForTest(old)
                let replacement = try #require(try await catalog.claimBackupJob(lane: "photo", owner: "second"))
                #expect(replacement.fence > old.fence && replacement.output != old.output)
                #expect(try await !catalog.heartbeatBackupJob(old))
                try await catalog.failBackupJob(old, message: "stale", permanent: true)
                await #expect(throws: CancellationError.self) { try await catalog.postponeBackupJob(old) }
                await #expect(throws: CancellationError.self) {
                    try await catalog.publishBackupJob(old, outcome: .init(files: [], deviceCompresses: [], state: .held, message: "stale"),
                                                       storage: fixture.server.storage)
                }
                #expect(try await catalog.backupJobCurrent(replacement))
                try await catalog.publishBackupJob(replacement, outcome: .init(files: [], deviceCompresses: [], state: .held, message: "held"),
                                                   storage: fixture.server.storage)
                #expect(try await client.call("/api/v2/backup-requests/\(receipt.requestID)", token: token)
                    .decode(BackupAPI.Receipt.self).retention == .permanent)
                let descriptor = ServerAPI.ResourceDescriptor(role: .photo, filename: "legacy.jpg", size: bytes.count,
                                                               sha256: Fingerprint.sha256(of: bytes))
                _ = try await client.call("/api/v1/assets", .post, token: token,
                    json: ServerAPI.RegisterAssetRequest(kind: .photo, captureDate: nil, resources: [descriptor]))
                _ = try await client.call("/api/v1/assets/\(descriptor.sha256)/resources/photo?offset=0", .put, token: token, body: bytes)
                let first = try #require(try await catalog.claim(owner: "legacy-first", lease: 90))
                try await catalog.expireLegacyLeaseForTest(first)
                let second = try #require(try await catalog.claim(owner: "legacy-second", lease: 90))
                #expect(second.fence > first.fence)
                #expect(try await !catalog.heartbeatLegacyJob(first))
                await #expect(throws: CancellationError.self) { try await catalog.finish(first) }
                await #expect(throws: CancellationError.self) { try await catalog.fail(first, error: "stale") }
                await #expect(throws: CancellationError.self) { try await catalog.postpone(first, by: 1, reason: "stale") }
                await #expect(throws: CancellationError.self) {
                    try await catalog.storeCompact(first.assetID, [], deviceCompresses: [], state: .held, message: "stale", job: first)
                }
                #expect(try await catalog.legacyJobCurrent(second))
            }
        }

        @Test func versionedUploadAdmissionBackpressuresBeforeAllocatingOversizedResources() async throws {
            let fixture = try await Fixture()
            try await fixture.test { client, token in
                let caps = try await client.call("/api/v2/capabilities", token: token).decode(BackupAPI.Capabilities.self)
                let request = BackupAPI.Request(operationID: UUID(), origin: caps.origin,
                    manifest: .init(kind: .video, resources: [.init(role: .video, filename: "large.mp4",
                        size: Int(fixture.server.configuration.maximumStagingBytes + 1), sha256: String(repeating: "a", count: 64))]),
                    profile: caps.recipe.profile, compact: false)
                let receipt = try await client.call("/api/v2/backup-requests", .post, token: token, json: request)
                    .decode(BackupAPI.Receipt.self)
                let upload = try await client.call("/api/v2/uploads", .post, token: token, json: BackupAPI.UploadRequest(
                    uploadID: UUID(), requestID: receipt.requestID, version: receipt.version, role: .video))
                #expect(upload.status == .serviceUnavailable)
                #expect(try upload.decode(ServerAPI.ErrorBody.self).error.code == "storage_backpressure")
                #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.server.storage.staging.path).isEmpty)
            }

            @Test func rootMutationCannotMoveItsOwnCatalogAndOwnershipFile() async throws {
                let fixture = try await Fixture(originals: ".")
                try await fixture.test { client, _ in
                    let code = try await fixture.server.newPairingCode()
                    let device = try await client.call("/api/v1/pair", .post,
                        json: ServerAPI.PairRequest(code: code, deviceName: "data")).decode(ServerAPI.PairResponse.self)
                    let response = try await client.call("/api/v1/devices/\(device.deviceID)", .patch, token: device.token,
                                                         json: ServerAPI.RenameDeviceRequest(name: "Other"))
                    #expect(response.status == .serviceUnavailable)
                    #expect(FileManager.default.fileExists(atPath: fixture.server.storage.catalog.path))
                    #expect(try await fixture.server.catalog.setting(DeviceRename.journal) == nil)
                }

                @Test func versionedAdmissionProtectsAndReverifiesLegacyCandidatesInsteadOfTrustingV1Status() async throws {
                    let fixture = try await Fixture()
                    try await fixture.test { client, token in
                        let bytes = Data("legacy-reuse".utf8), hash = Fingerprint.sha256(of: bytes)
                        let descriptor = ServerAPI.ResourceDescriptor(role: .photo, filename: "old.jpg", size: bytes.count, sha256: hash)
                        _ = try await client.call("/api/v1/assets", .post, token: token,
                            json: ServerAPI.RegisterAssetRequest(kind: .photo, captureDate: nil, resources: [descriptor], compact: false))
                        _ = try await client.call("/api/v1/assets/\(hash)/resources/photo?offset=0", .put, token: token, body: bytes)
                        #expect(try await fixture.server.catalog.asset(hash)?.permanent == false)
                        let (_, receipt) = try await backupTestRequest(client, token: token, data: bytes)
                        #expect(receipt.backup == .uploading)
                        #expect(try await fixture.server.catalog.asset(hash)?.permanent == true)
                        #expect(try await client.call("/api/v1/assets/\(hash)/removed", .post, token: token).status == .conflict)
                        let adoption = BackupAdoption(catalog: fixture.server.catalog, storage: fixture.server.storage,
                            originals: fixture.server.originals, budget: fixture.server.budget, configuration: fixture.server.configuration)
                        let legacy = try #require(try await fixture.server.catalog.resources(hash).first?.storedPath)
                        let url = try #require(await fixture.server.originals.url(legacy))
                        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: url.path)
                        try Data(repeating: 0, count: bytes.count).write(to: url)
                        await #expect(throws: (any Error).self) { try await adoption.runNext() }
                        #expect(try await client.call("/api/v2/backup-requests/\(receipt.requestID)", token: token)
                            .decode(BackupAPI.Receipt.self).retention == .pending)
                        let retained = try await backupTestUpload(client, token: token, receipt: receipt, data: bytes)
                        #expect(retained.retention == .permanent && retained.backup == .retained)
                        #expect(try await fixture.server.catalog.storedOriginals().count == 2)
                        let proof = try await client.call("/api/v2/assets/\(receipt.version.assetID)/versions/\(receipt.version.manifestID)/verify",
                            .post, token: token, json: receipt.version).decode(BackupAPI.OriginalProof.self)
                        #expect(proof.retention == .permanent && proof.version == receipt.version)
                    }
                }

                @Test func serverStorageAccountingRejectsOverflowInsteadOfWrapping() throws {
                    #expect(try StorageBytes.sum([10, 20, 30]) == 60)
                    #expect(throws: APIError.self) { try StorageBytes.sum([Int.max, 1]) }
                    #expect(throws: APIError.self) { try StorageBytes.add(Int64.max, 1) }
                }

                @Test func permanentVersionedClaimQuarantinesAPlannedLegacyTrashMoveWithoutExpiry() async throws {
                    let fixture = try await Fixture()
                    try await fixture.test { client, token in
                        let bytes = Data("permanent-before-trash-commit".utf8), hash = Fingerprint.sha256(of: bytes)
                        _ = try await client.call("/api/v1/assets", .post, token: token, json: ServerAPI.RegisterAssetRequest(
                            kind: .photo, captureDate: nil, resources: [.init(role: .photo, filename: "a.jpg", size: bytes.count, sha256: hash)],
                            compact: false))
                        _ = try await client.call("/api/v1/assets/\(hash)/resources/photo?offset=0", .put, token: token, body: bytes)
                        let path = try #require(try await fixture.server.catalog.resources(hash).first?.storedPath)
                        let plan = Trash.Plan(asset: hash, generation: 0, action: .remove,
                            entries: [.init(role: .photo, from: path, to: Trash.trashed(path, assetID: hash), sha256: hash, size: bytes.count, copy: false)],
                            at: Timestamp.string())
                        try await fixture.server.catalog.saveTrashMutation(hash, generation: 0, action: .remove,
                            text: String(decoding: try JSONEncoder().encode(plan), as: UTF8.self))
                        let (_, receipt) = try await backupTestRequest(client, token: token, data: bytes)
                        #expect(try await fixture.server.emptyTrash(now: Date().addingTimeInterval(31 * 86_400)) == 0)
                        let legacy = try #require(try await fixture.server.catalog.asset(hash))
                        #expect(legacy.state == .trashed && legacy.permanent && legacy.trashedAt == nil)
                        #expect(try await fixture.server.catalog.setting(Trash.journal(hash)) == nil)
                        let adoption = BackupAdoption(catalog: fixture.server.catalog, storage: fixture.server.storage,
                            originals: fixture.server.originals, budget: fixture.server.budget, configuration: fixture.server.configuration)
                        #expect(try await adoption.runNext())
                        #expect(try await client.call("/api/v2/backup-requests/\(receipt.requestID)", token: token)
                            .decode(BackupAPI.Receipt.self).retention == .permanent)
                    }
                }
            }
        }
        let external = try await Fixture(immich: .init(url: URL(string: "http://127.0.0.1:1")!, apiKey: "synthetic-unused-key"))
        try await external.test { client, token in
            #expect(try await client.call("/api/v2/capabilities", token: token).decode(BackupAPI.Capabilities.self).uploadProtocols.isEmpty)
            let (_, blocked) = try await backupTestRequest(client, token: token, data: Data("external".utf8))
            #expect(blocked.backup == .blocked && blocked.retention == .external)
            #expect(try await client.call("/api/v2/uploads", .post, token: token,
                json: BackupAPI.UploadRequest(uploadID: UUID(), requestID: blocked.requestID, version: blocked.version, role: .photo)).status == .unprocessableContent)
            #expect(try await client.call("/api/v2/assets/\(blocked.version.assetID)/versions/\(blocked.version.manifestID)/verify",
                .post, token: token, json: blocked.version).status == .conflict)
        }
    }
}
