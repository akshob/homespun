// SPDX-License-Identifier: Apache-2.0
import Foundation
import HomespunCore

struct DemoDownloadManifest: Codable, Sendable, Equatable {
    var version: Int
    var totalBytes: Int
    var files: [File]

    struct File: Codable, Sendable, Equatable {
        var file: String
        var sha256: String
        var size: Int
        var kind: String
        var width: Int
        var height: Int
        var date: String
        var category: String
        var name: String { String(file.dropLast((file as NSString).pathExtension.count + 1)) }
    }

    func validate() throws {
        guard version == 1, files.count == 16, Set(files.map(\.file)).count == files.count,
              totalBytes > 0, totalBytes <= 64 << 20 else { throw DemoDownload.Failure.manifest }
        var total = 0
        for file in files {
            guard file.file.range(of: #"^demo-[a-z0-9-]+\.(heic|jpg)$"#, options: .regularExpression) != nil,
                  file.sha256.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil,
                  file.kind == "photo", file.size > 0, file.size <= 8 << 20,
                  (1...4032).contains(file.width), (1...4032).contains(file.height),
                  ISO8601DateFormatter().date(from: file.date) != nil,
                  file.category.range(of: #"^[a-z-]{1,40}$"#, options: .regularExpression) != nil
            else { throw DemoDownload.Failure.manifest }
            total += file.size
        }
        guard total == totalBytes else { throw DemoDownload.Failure.manifest }
    }
}

struct DemoDownloadedPhoto: Sendable {
    var file: DemoDownloadManifest.File
    var url: URL
}

struct DemoDownload: Sendable {
    enum Failure: Error, Equatable {
        case manifest, integrity, unavailable, code
    }

    struct Session: Decodable {
        var manifest: DemoDownloadManifest
        var token: String
        var expiresAt: Int
    }

    var base: URL
    var code: String
    var folder: URL
    var protocolClasses: [AnyClass]? = nil
    var timeout: TimeInterval = 15

    static func configured(folder: URL) -> DemoDownload? {
        let arguments = ProcessInfo.processInfo.arguments
        #if DEBUG
        guard !arguments.contains("-demoMediaDraw"),
              let flag = arguments.firstIndex(of: "-demoMediaBase"), arguments.indices.contains(flag + 1),
              let base = URL(string: arguments[flag + 1]),
              ["127.0.0.1", "localhost", "::1"].contains(base.host ?? "")
        else { return nil }
        #else
        let base = URL(string: "https://telemetry.homespun.photos/v1/demo/")!
        #endif
        guard let code = DemoReviewCodeStore().read(), !code.isEmpty else { return nil }
        return DemoDownload(base: base, code: code, folder: folder)
    }

    func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = 120
        config.allowsConstrainedNetworkAccess = false
        config.httpAdditionalHeaders = ["User-Agent": "Homespun"]
        config.protocolClasses = protocolClasses
        return config
    }

    func run(progress: @escaping @Sendable (Int, Int) async -> Void) async throws -> [DemoDownloadedPhoto] {
        let session = URLSession(configuration: configuration(), delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return try await withTaskCancellationHandler {
            try await download(using: session, progress: progress)
        } onCancel: { session.invalidateAndCancel() }
    }

    private func download(using session: URLSession, progress: @Sendable (Int, Int) async -> Void) async throws -> [DemoDownloadedPhoto] {
        try Task.checkCancellation()
        var request = URLRequest(url: base.appendingPathComponent("session"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["code": code])
        let (body, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw Failure.unavailable }
        if response.statusCode == 403 { throw Failure.code }
        guard response.statusCode == 200 else { throw Failure.unavailable }
        var data = Data()
        for try await byte in body {
            guard data.count < 32_768 else { throw Failure.manifest }
            data.append(byte)
        }
        let grant = try JSONDecoder().decode(Session.self, from: data)
        try grant.manifest.validate()
        guard !grant.token.isEmpty, grant.token.utf8.count <= 256, !grant.token.contains(where: \.isWhitespace),
              grant.expiresAt > Int(Date().timeIntervalSince1970),
              grant.expiresAt <= Int(Date().timeIntervalSince1970) + 900 else { throw Failure.manifest }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var directory = folder
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        var done = 0
        var photos: [DemoDownloadedPhoto] = []
        await progress(done, grant.manifest.totalBytes)
        for file in grant.manifest.files.sorted(by: { $0.size > $1.size }) {
            try Task.checkCancellation()
            let destination = folder.appendingPathComponent(file.file)
            if !verified(file, at: destination) {
                let completed = done
                var last: Error = Failure.unavailable
                for attempt in 0..<3 {
                    do {
                        try await fetch(file, token: grant.token, session: session, destination: destination) { bytes in
                            await progress(completed + bytes, grant.manifest.totalBytes)
                        }
                        last = Failure.unavailable
                        break
                    } catch {
                        try Task.checkCancellation()
                        last = error
                        if let failure = error as? Failure, failure != .integrity { throw error }
                        if attempt == 2 { throw error }
                        try await Task.sleep(for: attempt == 0 ? .milliseconds(500) : .seconds(2))
                    }
                }
                guard verified(file, at: destination) else { throw last }
            }
            done += file.size
            photos.append(.init(file: file, url: destination))
            await progress(done, grant.manifest.totalBytes)
        }
        return photos.sorted { $0.file.file < $1.file.file }
    }

    func verified(_ file: DemoDownloadManifest.File, at url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) == file.size
            && (try? Fingerprint.sha256(of: url)) == file.sha256
    }

    private func fetch(_ file: DemoDownloadManifest.File, token: String, session: URLSession, destination: URL,
                       progress: @Sendable (Int) async -> Void) async throws {
        let part = destination.appendingPathExtension("part")
        try? FileManager.default.removeItem(at: part)
        defer { try? FileManager.default.removeItem(at: part) }
        var request = URLRequest(url: base.appendingPathComponent("files").appendingPathComponent(file.file))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (stream, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.expectedContentLength == -1 || response.expectedContentLength == file.size else { throw Failure.unavailable }
        FileManager.default.createFile(atPath: part.path, contents: nil)
        let handle = try FileHandle(forWritingTo: part)
        defer { try? handle.close() }
        var buffer = Data(), received = 0
        buffer.reserveCapacity(65_536)
        for try await byte in stream {
            received += 1
            guard received <= file.size else { throw Failure.integrity }
            buffer.append(byte)
            if buffer.count == 65_536 {
                try Task.checkCancellation()
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
                await progress(received)
            }
        }
        try handle.write(contentsOf: buffer)
        try handle.close()
        try Task.checkCancellation()
        guard verified(file, at: part) else { throw Failure.integrity }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: part, to: destination)
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
