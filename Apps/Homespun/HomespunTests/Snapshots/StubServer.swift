// SPDX-License-Identifier: Apache-2.0
import CryptoKit
import Foundation
import HomespunCore
import Synchronization
@testable import Homespun

final class StubServer: @unchecked Sendable {
    static let baseURL = URL(string: "https://snapshot.invalid")!
    static let fingerprint = ServerKeyFingerprint(base64url: "IlypPJ-wE200U-L1DoKMtMQyrDczNQMel-ae_YH5OgU")!
    static let pins = ServerPins(pins: [fingerprint], source: "pair")
    static let platform = ServerSetup.Platform(os: .macOS, name: "macOS 27.2", packageManager: .homebrew)
    static let info = ServerAPI.ServerInfo(
        name: "Sample Computer", version: "1.0.0", mode: .files, profile: .standard,
        platform: platform, hardware: .init(kind: .desktop, model: "Mac mini"), freeBytes: 640_000_000_000)
    static let options = ServerAPI.PairingOptions(
        serverName: info.name, canApprove: true, pairCommand: "homespun-server pair",
        platform: platform, hardware: info.hardware, freeBytes: info.freeBytes, pairingVersion: 2, encrypted: true)

    struct Reply: Sendable {
        var data: Data
        var type = "application/json"
    }

    private struct Answers: Sendable {
        var replies: [String: Reply]
        var delegate: ServerTrustDelegate
        var unexpected: [String] = []
    }
    private static let answers = Mutex<[String: Answers]>([:])
    private static let header = "X-Homespun-Snapshot-World"
    private let id = UUID().uuidString
    let session: URLSession

    init(now: Date, original: Data) throws {
        var replies: [String: Reply] = [:]
        func json<Value: Encodable>(_ path: String, _ value: Value) throws {
            replies[path] = Reply(data: try ServerAPI.encoder.encode(value))
        }
        try json("/health", ServerAPI.Health(tls: true))
        try json("/api/v1/health", ServerAPI.Health(tls: true))
        try json("/api/v1/info", Self.info)
        try json("/api/v1/pair/options", Self.options)
        try json("/api/v1/setup", ServerSetup.Report(platform: Self.platform, checks: [
            .init(id: "storage", title: "Originals folder", status: .ok, detail: "Ready", fix: []),
        ]))
        try json("/api/v1/storage", ServerAPI.StorageInfo(
            originalsFolder: "/Originals", deviceFolder: "Sample iPhone", freeBytes: 640_000_000_000,
            capacityBytes: 1_000_000_000_000, storedCount: 48, storedBytes: 595_200_000, move: nil))
        try json("/api/v1/devices", [
            ServerAPI.DeviceInfo(id: "snapshot-device", name: "Sample iPhone", folder: "Sample iPhone",
                                 pairedAt: now.addingTimeInterval(-86_400 * 90), lastSeenAt: now, isThisDevice: true),
        ])
        replies["/api/v1/connectors"] = Reply(data: Data("[]".utf8))
        let hash = SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined()
        for number in FixtureCatalog.ready + [FixtureCatalog.freed] {
            let asset = Self.asset(number)
            let kind: ServerAPI.AssetKind = number % 5 == 0 ? .video : number % 5 == 1 ? .livePhoto : .photo
            var resources = [ServerAPI.ResourceStatus(
                role: kind == .video ? .video : .photo, sha256: hash, size: 12_400_000, state: .verified,
                receivedBytes: 12_400_000, verifiedAt: now)]
            if kind == .livePhoto {
                resources.append(.init(role: .pairedVideo, sha256: hash, size: 900_000, state: .verified,
                                        receivedBytes: 900_000, verifiedAt: now))
            }
            try json("/api/v1/assets/\(asset)", ServerAPI.AssetStatus(
                assetID: asset, kind: kind, state: .ready, message: nil, resources: resources,
                compact: [], deviceCompresses: []))
            replies["/api/v1/assets/\(asset)/original/photo"] = Reply(data: original, type: "image/jpeg")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SnapshotURLProtocol.self]
        configuration.httpAdditionalHeaders = [Self.header: id]
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 2
        let delegate = ServerTrustDelegate(policy: Self.pins.trust)
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        Self.answers.withLock { $0[id] = Answers(replies: replies, delegate: delegate) }
    }

    static func asset(_ number: Int) -> String { String(format: "asset-%03d", number) }

    func original(_ asset: String, role: ServerAPI.ResourceRole) async throws -> Data {
        let url = Self.baseURL.appendingPathComponent("api/v1/assets/\(asset)/original/\(role.rawValue)")
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw SnapshotFailure("Synthetic original is missing")
        }
        return data
    }

    func validate() throws {
        let unexpected = Self.answers.withLock { $0[id]?.unexpected ?? [] }
        guard unexpected.isEmpty else { throw SnapshotFailure("Unstubbed snapshot requests: \(unexpected.joined(separator: ", "))") }
    }

    func close() {
        session.invalidateAndCancel()
        Self.answers.withLock { $0[id] = nil }
    }

    fileprivate static func reply(to request: URLRequest) -> Reply? {
        guard let id = request.value(forHTTPHeaderField: header) else { return nil }
        return answers.withLock { worlds in
            guard worlds[id] != nil, let url = request.url else { return nil }
            if url.path == "/api/v1/health" {
                guard let trust = try? serverTrustFixture(), worlds[id]!.delegate.evaluate(trust) else {
                    worlds[id]?.unexpected.append("Synthetic certificate was rejected")
                    return nil
                }
            }
            if request.httpMethod == "GET", url.host == baseURL.host, let reply = worlds[id]?.replies[url.path] {
                return reply
            }
            worlds[id]?.unexpected.append("\(request.httpMethod ?? "?") \(url.path)")
            return nil
        }
    }
}

private final class SnapshotURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let reply = StubServer.reply(to: request), let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                             headerFields: ["Content-Type": reply.type]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
