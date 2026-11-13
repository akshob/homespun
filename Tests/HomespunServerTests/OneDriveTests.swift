// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import HTTPTypes
import HomespunCore
import Hummingbird
import HummingbirdTesting
import NIOCore
import Testing
@testable import HomespunServerKit

@Test func quickXorHashMatchesRclone() {
    // `rclone hashsum quickxor --base64` of bytes (i * 7 + 3) % 251, converted from URL-safe base64.
    let expected = [0: "AAAAAAAAAAAAAAAAAAAAAAAAAAA=", 1: "AwAAAAAAAAAAAAAAAQAAAAAAAAA=", 6: "A1BABDDwARMAAAAABgAAAAAAAAA=",
                    159: "vnAtdECewbZ-9jHWrTLgoJ92DmI=", 160: "vnAtdECewbZ-9jHWkjLgoJ92Dmw=",
                    161: "yXAtdECewbZ-9jHWkzLgoJ92Dmw=", 1000: "XwCwWw-SPjp9D8-NCRe-PKCPYvw=",
                    100_000: "bC4C0YWwhdKXl9c5pkpdtk7DhRE=", 5_000_003: "VnhrxcDSTdqHyVhuMI-M3zUQTKg="]
    for (count, urlSafe) in expected {
        let data = Data((0..<count).map { UInt8(($0 * 7 + 3) % 251) })
        let want = urlSafe.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        var whole = QuickXorHash()
        whole.update(data)
        #expect(whole.base64 == want, "\(count) bytes")
        // Fed in uneven pieces, as files are read.
        var pieces = QuickXorHash()
        var offset = 0, step = 1
        while offset < count {
            let end = min(count, offset + step)
            pieces.update(data[offset..<end])
            offset = end
            step = step * 3 + 7
        }
        #expect(pieces.base64 == want, "\(count) bytes in pieces")
    }
}

/// Microsoft's sign-in service and Graph, just enough for the OneDrive connector.
final class FakeMicrosoft: @unchecked Sendable {
    let lock = NSLock()
    var base = ""
    var pendingPolls = 1
    var valid: Set<String> = []
    var refreshTokens: Set<String> = []
    var refreshes = 0
    var files: [String: (data: Data, created: String?)] = [:]
    var sessions: [String: (path: String, data: Data, created: String?)] = [:]
    var uploads = 0
    var corrupt = false

    func item(_ name: String, _ data: Data, created: String?) -> [String: Any] {
        var hash = QuickXorHash()
        hash.update(data)
        var item: [String: Any] = ["name": name, "size": data.count,
                                   "file": ["hashes": ["quickXorHash": corrupt ? "AAAA" : hash.base64]]]
        if let created { item["fileSystemInfo"] = ["createdDateTime": created] }
        return item
    }

    func router() -> Router<BasicRequestContext> {
        let router = Router()
        let handle: @Sendable (Request, BasicRequestContext) async throws -> Response = { request, _ in
            let body = Data(try await request.body.collect(upTo: 64 << 20).readableBytesView)
            return self.lock.withLock { self.respond(request, body) }
        }
        router.get("**", use: handle)
        router.post("**", use: handle)
        router.put("**", use: handle)
        return router
    }

    private func json(_ object: Any, _ status: HTTPResponse.Status = .ok) -> Response {
        Response(status: status, headers: [.contentType: "application/json"],
                 body: .init(byteBuffer: ByteBuffer(bytes: try! JSONSerialization.data(withJSONObject: object))))
    }

    private func respond(_ request: Request, _ body: Data) -> Response {
        let path = request.uri.path.removingPercentEncoding ?? request.uri.path
        let form: [String: String] = !path.contains("/oauth2/") ? [:] : Dictionary(String(decoding: body, as: UTF8.self).split(separator: "&").map {
            let pair = $0.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? "" }
            return (pair[0], pair.count > 1 ? pair[1] : "")
        }, uniquingKeysWith: { first, _ in first })
        if path.hasSuffix("/oauth2/v2.0/devicecode") {
            guard form["client_id"] == "test-client", form["scope"]?.contains("Files.ReadWrite.AppFolder") == true else {
                return json(["error": "invalid_client"], .badRequest)
            }
            return json(["device_code": "device-1", "user_code": "ABCD-1234",
                         "verification_uri": "https://microsoft.com/devicelogin", "expires_in": 900, "interval": 5])
        }
        if path.hasSuffix("/oauth2/v2.0/token") {
            switch form["grant_type"] {
            case "urn:ietf:params:oauth:grant-type:device_code":
                guard form["device_code"] == "device-1" else { return json(["error": "bad_verification_code"], .badRequest) }
                if pendingPolls > 0 {
                    pendingPolls -= 1
                    return json(["error": "authorization_pending"], .badRequest)
                }
                valid.insert("access-1")
                refreshTokens.insert("refresh-1")
                return json(["access_token": "access-1", "refresh_token": "refresh-1", "expires_in": 3600])
            case "refresh_token":
                guard let token = form["refresh_token"], refreshTokens.remove(token) != nil else {
                    return json(["error": "invalid_grant", "error_description": "The refresh token was revoked."], .badRequest)
                }
                refreshes += 1
                valid.insert("access-\(refreshes + 1)")
                refreshTokens.insert("refresh-\(refreshes + 1)")
                return json(["access_token": "access-\(refreshes + 1)", "refresh_token": "refresh-\(refreshes + 1)",
                             "expires_in": 3600])
            default:
                return json(["error": "unsupported_grant_type"], .badRequest)
            }
        }
        if path.hasPrefix("/upload/") {
            let id = String(path.dropFirst("/upload/".count))
            guard request.headers[.authorization] == nil, var session = sessions[id],
                  let range = request.headers[HTTPField.Name("Content-Range")!],
                  let match = range.wholeMatch(of: /bytes (\d+)-(\d+)\/(\d+)/),
                  Int(match.1) == session.data.count, Int(match.2)! - Int(match.1)! + 1 == body.count else {
                return json(["error": ["message": "bad upload request"]], .badRequest)
            }
            let total = Int(match.3)!
            session.data += body
            guard session.data.count == total else {
                // Every chunk but the last must be a multiple of 320 KiB.
                guard body.count % (320 * 1024) == 0 else { return json(["error": ["message": "bad chunk size"]], .badRequest) }
                sessions[id] = session
                return json(["nextExpectedRanges": ["\(session.data.count)-"]], .accepted)
            }
            sessions[id] = nil
            uploads += 1
            var name = (session.path as NSString).lastPathComponent
            let folder = (session.path as NSString).deletingLastPathComponent
            var copy = 1
            while files[folder + "/" + name] != nil {
                let stem = ((session.path as NSString).lastPathComponent as NSString).deletingPathExtension
                name = "\(stem) \(copy).\((session.path as NSString).pathExtension)"
                copy += 1
            }
            files[folder + "/" + name] = (session.data, session.created)
            return json(item(name, session.data, created: session.created), .created)
        }
        guard path.hasPrefix("/v1.0/") else { return json(["error": ["message": "not found"]], .notFound) }
        guard let auth = request.headers[.authorization], auth.hasPrefix("Bearer "), valid.contains(String(auth.dropFirst(7))) else {
            return json(["error": ["code": "InvalidAuthenticationToken", "message": "Access token has expired."]], .unauthorized)
        }
        let route = String(path.dropFirst("/v1.0".count))
        if route == "/me" { return json(["userPrincipalName": "alex@example.com", "displayName": "Alex"]) }
        if route == "/me/drive/special/approot" { return json(["id": "approot", "name": "Homespun"]) }
        let prefix = "/me/drive/special/approot:/"
        guard route.hasPrefix(prefix) else { return json(["error": ["message": "not found"]], .notFound) }
        let rest = String(route.dropFirst(prefix.count))
        if rest.hasSuffix(":/createUploadSession") {
            let itemPath = String(rest.dropLast(":/createUploadSession".count))
            let item = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["item"] as? [String: Any]
            guard item?["@microsoft.graph.conflictBehavior"] as? String == "rename" else {
                return json(["error": ["message": "expected rename"]], .badRequest)
            }
            let created = (item?["fileSystemInfo"] as? [String: Any])?["createdDateTime"] as? String
            let id = UUID().uuidString
            sessions[id] = (itemPath, Data(), created)
            return json(["uploadUrl": "\(base)/upload/\(id)"])
        }
        guard let file = files[rest] else { return json(["error": ["code": "itemNotFound", "message": "not found"]], .notFound) }
        return json(item((rest as NSString).lastPathComponent, file.data, created: file.created))
    }
}

@Test(.enabled(if: ffmpegAvailable)) func oneDriveSignsInUploadsAndChecksCopies() async throws {
    let microsoft = FakeMicrosoft()
    try await Application(router: microsoft.router(), configuration: .init(address: .hostname("localhost", port: 0)))
        .test(.live) { microsoftClient in
            let base = "http://localhost:\(microsoftClient.port!)"
            microsoft.lock.withLock { microsoft.base = base }
            var onedrive = OneDriveConnector(clientID: "test-client", authority: URL(string: base + "/common")!,
                                             graph: URL(string: base + "/v1.0")!)
            onedrive.chunkSize = 320 * 1024
            let fixture = try await Fixture(connectors: [onedrive])
            let media = try await Media.make(in: fixture.directory)
            try await fixture.test { client, token in
                func info() async throws -> ServerAPI.ConnectorInfo {
                    try #require(try await client.call("/api/v1/connectors", token: token)
                        .decode([ServerAPI.ConnectorInfo].self).first { $0.id == "onedrive" })
                }
                func update(_ body: ServerAPI.ConnectorUpdate) async throws -> TestResponse {
                    try await client.call("/api/v1/connectors/onedrive", .put, token: token, json: body)
                }
                func add(_ url: URL, name: String) async throws -> String {
                    let resource = try descriptor(.photo, url, name: name)
                    _ = try await client.call("/api/v1/assets", .post, token: token, json: ServerAPI.RegisterAssetRequest(
                        kind: .photo, captureDate: Date(timeIntervalSince1970: 1_714_592_096), resources: [resource]))
                    _ = try await fixture.upload(client, token: token, asset: resource.sha256, role: .photo, file: url)
                    try await fixture.server.drainJobs()
                    return resource.sha256
                }

                #expect(try await info().signsIn)
                let early = try await update(.init(enabled: true))
                #expect(early.status == .unprocessableContent && String(decoding: early.data, as: UTF8.self).contains("Sign in"))

                // Sign in with a code shown in the app; the server keeps the tokens.
                let challenge = try await client.call("/api/v1/connectors/onedrive/sign-in", .post, token: token)
                    .decode(ServerAPI.ConnectorSignIn.self)
                #expect(challenge.userCode == "ABCD-1234" && challenge.url == "https://microsoft.com/devicelogin")
                func poll() async throws -> ServerAPI.ConnectorSignInStatus {
                    try await client.call("/api/v1/connectors/onedrive/sign-in", token: token).decode(ServerAPI.ConnectorSignInStatus.self)
                }
                #expect(try await poll().state == .waiting)
                #expect(try await poll() == .init(state: .done, account: "alex@example.com"))
                let listed = try await client.call("/api/v1/connectors", token: token)
                #expect(!String(decoding: listed.data, as: UTF8.self).contains("refresh-1"))

                // An expired access token is renewed with the refresh token.
                microsoft.lock.withLock { _ = microsoft.valid.remove("access-1") }
                let enabled = try await update(.init(enabled: true, settings: ["folder": "Family/../Photos"]))
                #expect(enabled.status == .ok)
                #expect(try enabled.decode(ServerAPI.ConnectorInfo.self).account == "alex@example.com")
                #expect(microsoft.lock.withLock { microsoft.refreshes } == 1)

                // Uploaded in chunks into a dated folder, then checked against OneDrive's hash.
                let photo = try Data(contentsOf: media.photo) + Data(count: 700_000)
                let big = fixture.directory.appendingPathComponent("big.jpg")
                try photo.write(to: big)
                let first = try await add(big, name: "IMG_0001.JPG")
                let stored = try #require(microsoft.lock.withLock { microsoft.files["Family/Photos/2024/05/IMG_0001.JPG"] })
                #expect(stored.data == photo && stored.created?.hasPrefix("2024-05-01") == true)
                #expect(try await info().counts == .init(copied: 1))

                // Another original with the same name gets its own copy; the same bytes aren't uploaded twice.
                let other = fixture.directory.appendingPathComponent("other.jpg")
                try (photo + Data("another".utf8)).write(to: other)
                _ = try await add(other, name: "IMG_0001.JPG")
                #expect(microsoft.lock.withLock { microsoft.files["Family/Photos/2024/05/IMG_0001 1.JPG"] } != nil)
                try await fixture.server.catalog.setCopyState(first, connector: "onedrive", state: "failed")
                #expect(try await update(.init(copyExisting: true)).status == .ok)
                try await fixture.server.drainJobs()
                #expect(microsoft.lock.withLock { microsoft.uploads } == 2)
                #expect(try await info().counts == .init(copied: 2))

                // A copy that doesn't match is a failure, not a copy.
                microsoft.lock.withLock { microsoft.corrupt = true }
                let third = fixture.directory.appendingPathComponent("third.jpg")
                try (photo + Data("third".utf8)).write(to: third)
                _ = try await add(third, name: "IMG_0003.JPG")
                var status = try await info()
                #expect(status.counts == .init(copied: 2, failed: 1) && status.message?.contains("doesn't match") == true)

                // Signed out on Microsoft's side: the app is asked to sign in again.
                microsoft.lock.withLock {
                    microsoft.corrupt = false
                    microsoft.valid.removeAll()
                    microsoft.refreshTokens.removeAll()
                }
                let fourth = fixture.directory.appendingPathComponent("fourth.jpg")
                try (photo + Data("fourth".utf8)).write(to: fourth)
                _ = try await add(fourth, name: "IMG_0004.JPG")
                status = try await info()
                #expect(status.counts.failed == 2 && status.message?.contains("Sign in again") == true)
            }
        }
}

@Test func oneDriveFoldersAndNames() {
    let date = Date(timeIntervalSince1970: 1_714_592_096)
    #expect(OneDriveConnector.folder(nil, date: date) == "Photos/2024/05")
    #expect(OneDriveConnector.folder("/../Our Photos//x/", date: nil) == "Our Photos/x/Undated")
    let edit = ConnectorItem.File(role: .fullSizePhoto, url: URL(fileURLWithPath: "/x"), filename: "FullSizeRender.jpg",
                                  size: 1, sha256: "")
    #expect(OneDriveConnector.name(for: edit, stem: "IMG_0001") == "IMG_0001-full_size_photo.jpg")
    #expect(OneDriveConnector.encode("Photos/2024/05/IMG 0001#1.JPG") == "Photos/2024/05/IMG%200001%231.JPG")
}
