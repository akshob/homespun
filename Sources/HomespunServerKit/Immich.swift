// SPDX-License-Identifier: AGPL-3.0-only
import AsyncHTTPClient
import Foundation
import HomespunCore
import NIOCore
import NIOHTTP1

/// Read-only access to an Immich server. The API key needs only `asset.read` and
/// `asset.download`; Homespun never uploads, changes, or deletes Immich assets.
struct ImmichClient: Sendable {
    struct Asset: Decodable, Equatable, Sendable {
        var id: String
        /// Base64 SHA-1 of the original file.
        var checksum: String
        var isTrashed: Bool
        var livePhotoVideoId: String?
        var originalFileName: String?
        var type: String?
    }

    struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    let configuration: ImmichConfiguration
    var client: HTTPClient = .shared

    static func base64(sha1Hex: String) -> String? {
        guard Validation.isSHA1(sha1Hex) else { return nil }
        var bytes: [UInt8] = []
        var index = sha1Hex.startIndex
        while index < sha1Hex.endIndex {
            let next = sha1Hex.index(index, offsetBy: 2)
            bytes.append(UInt8(sha1Hex[index..<next], radix: 16)!)
            index = next
        }
        return Data(bytes).base64EncodedString()
    }

    private func request(_ path: String, method: HTTPMethod = .GET, json: [String: Any]? = nil) throws -> HTTPClientRequest {
        let base = configuration.url.absoluteString.hasSuffix("/")
            ? String(configuration.url.absoluteString.dropLast()) : configuration.url.absoluteString
        var request = HTTPClientRequest(url: base + "/api" + path)
        request.method = method
        request.headers.add(name: "x-api-key", value: configuration.apiKey)
        request.headers.add(name: "Accept", value: "application/json")
        if let json {
            request.headers.add(name: "Content-Type", value: "application/json")
            request.body = .bytes(ByteBuffer(bytes: try JSONSerialization.data(withJSONObject: json)))
        }
        return request
    }

    private func send(_ request: HTTPClientRequest) async throws -> (HTTPResponseStatus, Data) {
        let response = try await client.execute(request, timeout: .seconds(60))
        let body = try await response.body.collect(upTo: 16 << 20)
        return (response.status, Data(body.readableBytesView))
    }

    /// Non-trashed assets in the key owner's library whose original has this SHA-1.
    func assets(sha1Hex: String) async throws -> [Asset] {
        guard let checksum = Self.base64(sha1Hex: sha1Hex) else { throw Failure(description: "bad SHA-1") }
        struct Page: Decodable { var items: [Asset] }
        struct Results: Decodable { var assets: Page }
        var found: [Asset] = []
        // Archived assets are not in the default search.
        for visibility in [nil, "archive"] as [String?] {
            var body: [String: Any] = ["checksum": checksum, "withDeleted": false, "size": 50]
            if let visibility { body["visibility"] = visibility }
            let (status, data) = try await send(try request("/search/metadata", method: .POST, json: body))
            guard status == .ok else { throw Failure(description: "Immich search returned \(status.code)") }
            found += try JSONDecoder().decode(Results.self, from: data).assets.items
        }
        return found.filter { !$0.isTrashed && $0.checksum == checksum }
    }

    func asset(id: String) async throws -> Asset? {
        guard UUID(uuidString: id) != nil else { throw Failure(description: "bad Immich asset ID") }
        let (status, data) = try await send(try request("/assets/\(id)"))
        if status == .notFound || status == .badRequest { return nil }
        guard status == .ok else { throw Failure(description: "Immich asset lookup returned \(status.code)") }
        return try JSONDecoder().decode(Asset.self, from: data)
    }

    /// Streams the original file to `destination`.
    func downloadOriginal(id: String, to destination: URL) async throws {
        guard UUID(uuidString: id) != nil else { throw Failure(description: "bad Immich asset ID") }
        let response = try await client.execute(try request("/assets/\(id)/original"), timeout: .hours(2))
        guard response.status == .ok else { throw Failure(description: "Immich download returned \(response.status.code)") }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw Failure(description: "cannot create \(destination.lastPathComponent)") }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        for try await buffer in response.body {
            try handle.write(contentsOf: Data(buffer.readableBytesView))
        }
        try handle.synchronize()
    }

    /// Whether an Immich server answers at the URL.
    func ping() async throws -> Bool {
        let response = try await client.execute(try request("/server/ping"), timeout: .seconds(10))
        return response.status == .ok
    }

    /// The API key's permissions, or nil if Immich rejects the key.
    func keyPermissions() async throws -> [String]? {
        struct Key: Decodable { var permissions: [String] }
        let (status, data) = try await send(try request("/api-keys/me"))
        guard status == .ok else { return nil }
        return try JSONDecoder().decode(Key.self, from: data).permissions
    }

    /// Whether Immich still holds this original, untrashed and with the same SHA-1.
    func stillHolds(id: String, sha1Hex: String) async throws -> (Bool, String?) {
        guard let asset = try await asset(id: id) else { return (false, "not in Immich any more") }
        if asset.isTrashed { return (false, "in the Immich trash") }
        guard asset.checksum == Self.base64(sha1Hex: sha1Hex) else { return (false, "Immich checksum changed") }
        return (true, nil)
    }
}
