// SPDX-License-Identifier: AGPL-3.0-only
import AsyncHTTPClient
import Foundation
import HomespunCore
import NIOCore
import NIOHTTP1

/// Copies originals to the user's OneDrive, into Homespun's own app folder
/// (`Apps/Homespun/<folder>/YYYY/MM`). It asks only for that folder
/// (`Files.ReadWrite.AppFolder`), so it can't see or change anything else in OneDrive.
/// Signs in with a code shown in the app (OAuth device code flow); the server keeps the
/// refresh token in its catalog. Each upload is checked against OneDrive's QuickXorHash.
struct OneDriveConnector: Connector {
    /// Homespun's Microsoft app registration (public client; not a secret).
    static let defaultClientID = "f9367d8a-eb99-4b0a-9949-411707fad72e"
    static let scope = "Files.ReadWrite.AppFolder User.Read offline_access"

    let id = "onedrive"
    let name = "OneDrive"
    let summary = "Copies each original to your OneDrive, in Apps › Homespun. Homespun can see only that folder."
    var fields: [ServerAPI.ConnectorField] {
        [.init(key: "folder", label: "Folder", help: "Inside Apps › Homespun in your OneDrive.", placeholder: "Photos")]
    }
    var signsIn: Bool { true }

    let clientID: String
    /// `https://login.microsoftonline.com/common` (work, school, and personal accounts).
    let authority: URL
    let graph: URL
    let tokens = TokenCache()
    var http: HTTPClient = .shared
    /// Upload chunks must be multiples of 320 KiB.
    var chunkSize = 32 * 320 * 1024

    init(clientID: String?, authority: URL = URL(string: "https://login.microsoftonline.com/common")!,
         graph: URL = URL(string: "https://graph.microsoft.com/v1.0")!) {
        self.clientID = (clientID?.isEmpty == false ? clientID : nil) ?? Self.defaultClientID
        self.authority = authority
        self.graph = graph
    }

    actor TokenCache {
        private var access: (token: String, expires: Date)?
        func current() -> String? { access.flatMap { $0.expires > Date() ? $0.token : nil } }
        func store(_ token: String, lifetime: Int) {
            access = (token, Date().addingTimeInterval(TimeInterval(max(lifetime - 120, 30))))
        }
        func clear() { access = nil }
    }

    // MARK: Connector

    func check(_ context: ConnectorContext) async throws -> String? {
        try requireClientID()
        guard try await context.value("_refresh_token") != nil else { throw ConnectorError.failed("Sign in to OneDrive first.") }
        let account = try await self.account(context)
        _ = try await graphJSON(context, "GET", "/me/drive/special/approot")
        return account
    }

    func beginSignIn(_ context: ConnectorContext) async throws -> ServerAPI.ConnectorSignIn {
        try requireClientID()
        let response = try await form(authority.appendingPathComponent("oauth2/v2.0/devicecode"),
                                      ["client_id": clientID, "scope": Self.scope])
        guard let device = response["device_code"] as? String, let code = response["user_code"] as? String,
              let url = response["verification_uri"] as? String else {
            throw ConnectorError.failed(Self.errorMessage(response) ?? "Microsoft didn't start the sign-in.")
        }
        let lifetime = response["expires_in"] as? Int ?? 900
        try await context.set(["_device_code": device,
                               "_device_expires": Timestamp.string(Date().addingTimeInterval(TimeInterval(lifetime)))])
        return .init(userCode: code, url: url,
                     message: "Open the Microsoft page, enter this code, and sign in to the OneDrive to copy to.",
                     expiresIn: lifetime)
    }

    func pollSignIn(_ context: ConnectorContext) async throws -> ServerAPI.ConnectorSignInStatus {
        guard let device = try await context.value("_device_code"),
              let expires = Timestamp.date(try await context.value("_device_expires")), expires > Date() else {
            return .init(state: .failed, message: "The sign-in code expired. Try again.")
        }
        let response = try await form(authority.appendingPathComponent("oauth2/v2.0/token"), [
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code", "client_id": clientID, "device_code": device,
        ])
        if let error = response["error"] as? String {
            switch error {
            case "authorization_pending", "slow_down": return .init(state: .waiting)
            case "authorization_declined": return try await finish(context, .init(state: .failed, message: "Sign-in was declined."))
            case "expired_token":
                return try await finish(context, .init(state: .failed, message: "The sign-in code expired. Try again."))
            default: return try await finish(context, .init(state: .failed, message: Self.errorMessage(response) ?? error))
            }
        }
        try await store(response, context)
        try await context.set(["_device_code": nil, "_device_expires": nil])
        return .init(state: .done, account: try await account(context))
    }

    private func finish(_ context: ConnectorContext, _ status: ServerAPI.ConnectorSignInStatus) async throws
        -> ServerAPI.ConnectorSignInStatus {
        try await context.set(["_device_code": nil, "_device_expires": nil])
        return status
    }

    func copy(_ item: ConnectorItem, context: ConnectorContext) async throws -> String? {
        var folder = Self.folder(try await context.value("folder"), date: item.captureDate)
        if let version = item.immutableManifestID {
            guard Validation.isSHA256(version) else { throw ConnectorError.failed("Invalid immutable manifest identity.") }
            folder += "/Versions/" + version
        }
        let primary = item.file(item.kind == .video ? .video : .photo)
        let stem = ((primary?.filename ?? item.assetID) as NSString).deletingPathExtension
        var placed: [String] = []
        for file in item.files {
            if item.immutableManifestID != nil {
                guard Validation.isSHA256(file.sha256), file.size > 0 else { throw ConnectorError.failed("Invalid immutable resource.") }
                let name = file.role.rawValue + "-" + file.sha256 + "-" + String(Storage.sanitized(file.filename).prefix(120))
                placed.append(try await uploadImmutable(file, to: folder + "/" + name, captureDate: item.captureDate, context: context))
            } else {
                let name = Self.name(for: file, stem: stem)
                placed.append(try await upload(file, to: folder + "/" + name, captureDate: item.captureDate, context: context))
            }
        }
        return placed.first.map { ($0 as NSString).deletingLastPathComponent }
    }

    // MARK: Uploading

    /// Uploads one file (resumable session, so any size), then checks OneDrive's hash.
    /// If the name is taken by the same bytes, that copy counts; otherwise OneDrive renames.
    private func upload(_ file: ConnectorItem.File, to path: String, captureDate: Date?, context: ConnectorContext)
        async throws -> String {
        try await upload(file, to: path, captureDate: captureDate, context: context, immutable: false)
    }

    private func uploadImmutable(_ file: ConnectorItem.File, to path: String, captureDate: Date?, context: ConnectorContext) async throws -> String {
        do { return try await upload(file, to: path, captureDate: captureDate, context: context, immutable: true) }
        catch let failure as HTTPFailure where [409, 412].contains(failure.status) {
            let hash = try await detached { try QuickXorHash.of(file: file.url) }
            if let existing = try await item(at: path, context), Self.matches(existing, size: file.size, hash: hash) { return path }
            throw ConnectorError.failed("An immutable cloud object collides; existing bytes were not overwritten.")
        }
    }

    private func upload(_ file: ConnectorItem.File, to path: String, captureDate: Date?, context: ConnectorContext,
                        immutable: Bool) async throws -> String {
        let hash = try await detached { try QuickXorHash.of(file: file.url) }
        if let existing = try await item(at: path, context) {
            if Self.matches(existing, size: file.size, hash: hash) { return path }
            if immutable { throw ConnectorError.failed("An immutable cloud object changed; existing bytes were not overwritten.") }
        }
        var item: [String: Any] = ["@microsoft.graph.conflictBehavior": immutable ? "fail" : "rename"]
        if let captureDate {
            let date = Timestamp.string(captureDate)
            item["fileSystemInfo"] = ["createdDateTime": date, "lastModifiedDateTime": date]
        }
        let session = try await graphJSON(context, "POST", "/me/drive/special/approot:/\(Self.encode(path)):/createUploadSession",
                                          body: ["item": item])
        guard let uploadURL = session["uploadUrl"] as? String else { throw ConnectorError.failed("OneDrive didn't start the upload.") }

        let handle = try FileHandle(forReadingFrom: file.url)
        defer { try? handle.close() }
        var offset = 0
        var result: [String: Any]?
        while offset < file.size {
            try handle.seek(toOffset: UInt64(offset))
            guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else {
                throw ConnectorError.failed("The original changed while uploading.")
            }
            var request = HTTPClientRequest(url: uploadURL)
            request.method = .PUT
            request.headers.add(name: "Content-Length", value: String(chunk.count))
            request.headers.add(name: "Content-Range", value: "bytes \(offset)-\(offset + chunk.count - 1)/\(file.size)")
            request.body = .bytes(ByteBuffer(bytes: chunk))
            let response = try await http.execute(request, timeout: .seconds(300))
            let body = try await response.body.collect(upTo: 1 << 20)
            switch response.status.code {
            case 200, 201: result = try Self.object(body)
            case 202: break
            case 429, 503: throw ConnectorError.retryLater("OneDrive is busy; trying again later.", after: Self.retryAfter(response))
            default: throw HTTPFailure(status: Int(response.status.code), body: String(buffer: body))
            }
            offset += chunk.count
        }
        guard let result, let name = result["name"] as? String else { throw ConnectorError.failed("OneDrive didn't confirm the upload.") }
        let placed = (path as NSString).deletingLastPathComponent + "/" + name
        guard Self.matches(result, size: file.size, hash: hash) else {
            throw ConnectorError.failed("OneDrive's copy of \(file.filename) doesn't match the original.")
        }
        return placed
    }

    private func item(at path: String, _ context: ConnectorContext) async throws -> [String: Any]? {
        do {
            return try await graphJSON(context, "GET", "/me/drive/special/approot:/\(Self.encode(path))")
        } catch let failure as HTTPFailure where failure.status == 404 {
            return nil
        }
    }

    static func matches(_ item: [String: Any], size: Int, hash: String) -> Bool {
        let hashes = (item["file"] as? [String: Any])?["hashes"] as? [String: Any]
        return (item["size"] as? Int) == size && (hashes?["quickXorHash"] as? String) == hash
    }

    /// `<folder>/YYYY/MM`, or `<folder>/Undated`.
    static func folder(_ setting: String?, date: Date?) -> String {
        let cleaned = (setting ?? "").split(separator: "/").filter { $0 != "." && $0 != ".." }
            .map { Storage.sanitized(String($0)) }.filter { !$0.isEmpty }
        let base = cleaned.isEmpty ? "Photos" : cleaned.joined(separator: "/")
        guard let date else { return base + "/Undated" }
        let parts = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: date)
        return base + String(format: "/%04d/%02d", parts.year ?? 0, parts.month ?? 0)
    }

    /// The original, its motion, and its video keep their names; other files (edits) are
    /// named after the original so they sort next to it.
    static func name(for file: ConnectorItem.File, stem: String) -> String {
        let safe = Storage.sanitized(file.filename)
        guard ![.photo, .video, .pairedVideo].contains(file.role) else { return safe }
        let ext = (safe as NSString).pathExtension
        return "\(stem)-\(file.role.rawValue)" + (ext.isEmpty ? "" : ".\(ext)")
    }

    static func encode(_ path: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: ":#?")
        return path.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
            .joined(separator: "/")
    }

    // MARK: Accounts and tokens

    private func requireClientID() throws {
        guard !clientID.isEmpty else {
            throw ConnectorError.failed("This server has no Microsoft app ID for OneDrive yet (HOMESPUN_ONEDRIVE_CLIENT_ID).")
        }
    }

    private func account(_ context: ConnectorContext) async throws -> String? {
        let me = try await graphJSON(context, "GET", "/me")
        return (me["userPrincipalName"] as? String) ?? (me["mail"] as? String) ?? (me["displayName"] as? String)
    }

    private func store(_ response: [String: Any], _ context: ConnectorContext) async throws {
        guard let access = response["access_token"] as? String else {
            throw ConnectorError.failed(Self.errorMessage(response) ?? "Microsoft didn't sign in.")
        }
        await tokens.store(access, lifetime: response["expires_in"] as? Int ?? 3600)
        if let refresh = response["refresh_token"] as? String { try await context.set(["_refresh_token": refresh]) }
    }

    private func accessToken(_ context: ConnectorContext) async throws -> String {
        if let token = await tokens.current() { return token }
        guard let refresh = try await context.value("_refresh_token") else { throw ConnectorError.failed("Sign in to OneDrive again.") }
        let response = try await form(authority.appendingPathComponent("oauth2/v2.0/token"), [
            "grant_type": "refresh_token", "client_id": clientID, "refresh_token": refresh, "scope": Self.scope,
        ])
        if response["error"] as? String == "invalid_grant" {
            try await context.set(["_refresh_token": nil])
            throw ConnectorError.failed("OneDrive signed Homespun out. Sign in again in the app.")
        }
        try await store(response, context)
        guard let token = await tokens.current() else { throw ConnectorError.failed("Microsoft didn't sign in.") }
        return token
    }

    // MARK: HTTP

    struct HTTPFailure: Error, CustomStringConvertible {
        var status: Int
        var body: String
        var description: String {
            let message = (try? OneDriveConnector.object(ByteBuffer(string: body))).flatMap(OneDriveConnector.errorMessage)
            return "OneDrive answered \(status)" + (message.map { ": \($0)" } ?? "")
        }
    }

    private func graphJSON(_ context: ConnectorContext, _ method: String, _ path: String, body: [String: Any]? = nil,
                           retried: Bool = false) async throws -> [String: Any] {
        var request = HTTPClientRequest(url: graph.absoluteString + path)
        request.method = HTTPMethod(rawValue: method)
        request.headers.add(name: "Authorization", value: "Bearer \(try await accessToken(context))")
        request.headers.add(name: "Accept", value: "application/json")
        if let body {
            request.headers.add(name: "Content-Type", value: "application/json")
            request.body = .bytes(ByteBuffer(bytes: try JSONSerialization.data(withJSONObject: body)))
        }
        let response = try await http.execute(request, timeout: .seconds(60))
        let data = try await response.body.collect(upTo: 4 << 20)
        switch response.status.code {
        case 200...299: return try Self.object(data)
        case 401 where !retried:
            await tokens.clear()
            return try await graphJSON(context, method, path, body: body, retried: true)
        case 401, 403: throw ConnectorError.failed("OneDrive didn't allow it. Sign in again in the app.")
        case 429, 503: throw ConnectorError.retryLater("OneDrive is busy; trying again later.", after: Self.retryAfter(response))
        case 507: throw ConnectorError.retryLater("Your OneDrive is full.", after: 6 * 3600)
        default: throw HTTPFailure(status: Int(response.status.code), body: String(buffer: data))
        }
    }

    /// Posts a form to Microsoft's sign-in service. Returns its JSON, including `error`.
    private func form(_ url: URL, _ fields: [String: String]) async throws -> [String: Any] {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = fields.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
        var request = HTTPClientRequest(url: url.absoluteString)
        request.method = .POST
        request.headers.add(name: "Content-Type", value: "application/x-www-form-urlencoded")
        request.headers.add(name: "Accept", value: "application/json")
        request.body = .bytes(ByteBuffer(string: body))
        let response = try await http.execute(request, timeout: .seconds(30))
        let data = try await response.body.collect(upTo: 1 << 20)
        if response.status.code >= 500 { throw HTTPFailure(status: Int(response.status.code), body: String(buffer: data)) }
        return try Self.object(data)
    }

    static func object(_ buffer: ByteBuffer) throws -> [String: Any] {
        guard buffer.readableBytes > 0 else { return [:] }
        return (try JSONSerialization.jsonObject(with: Data(buffer.readableBytesView)) as? [String: Any]) ?? [:]
    }

    static func errorMessage(_ object: [String: Any]) -> String? {
        if let description = object["error_description"] as? String {
            return description.components(separatedBy: "\r\n").first ?? description
        }
        return ((object["error"] as? [String: Any])?["message"] as? String) ?? (object["error"] as? String)
    }

    static func retryAfter(_ response: HTTPClientResponse) -> TimeInterval {
        response.headers.first(name: "Retry-After").flatMap(TimeInterval.init).map { max($0, 30) } ?? 300
    }
}
