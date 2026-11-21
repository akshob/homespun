// SPDX-License-Identifier: Apache-2.0
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Synchronization
import Testing
import UniformTypeIdentifiers
@testable import Homespun

@Suite(.serialized) struct DemoDownloadTests {
    private struct Fixture: Sendable {
        let manifest: DemoDownloadManifest
        let jpeg: Data
        let folder: URL
        var downloader: DemoDownload {
            DemoDownload(base: URL(string: "https://demo-download.invalid/v1/demo/")!, code: "TESTTESTTESTTEST", folder: folder,
                         protocolClasses: [ReviewProtocol.self])
        }

        init() throws {
            folder = try DemoTestMedia.makeRoot()
            let image = DemoArt.render(width: 64, height: 48) { context in
                context.setFillColor(CGColor(gray: 0.4, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
            }
            let url = folder.appendingPathComponent("fixture.jpg")
            try DemoArt.writeImage(image, to: url, type: .jpeg, quality: 0.8, date: "2025-01-01T10:00:00+00:00")
            jpeg = try Data(contentsOf: url)
            let size = jpeg.count
            let hash = SHA256.hash(data: jpeg).map { String(format: "%02x", $0) }.joined()
            manifest = DemoDownloadManifest(version: 1, totalBytes: size * 16, files: (0..<16).map {
                .init(file: "demo-test-\($0).jpg", sha256: hash, size: size, kind: "photo",
                      width: 64, height: 48, date: "2025-01-01T10:00:00Z", category: "nature")
            })
        }

        func serve(corrupt: Bool = false) throws {
            let grant = try JSONSerialization.data(withJSONObject: [
                "manifest": JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest)),
                "token": "local-test-session", "expiresAt": Int(Date().timeIntervalSince1970) + 600,
            ])
            let jpeg = jpeg
            ReviewProtocol.handler.withLock { handler in
                handler = { request in
                    if request.httpMethod == "POST" { return (200, grant) }
                    return (200, corrupt ? Data(repeating: 0, count: jpeg.count) : jpeg)
                }
            }
            ReviewProtocol.requests.withLock { $0 = [] }
        }
    }

    @Test func parsesAndRejectsUnsafeManifests() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        let parsed = try JSONDecoder().decode(DemoDownloadManifest.self, from: JSONEncoder().encode(f.manifest))
        try parsed.validate()
        for field in ["path", "sha", "size", "dimensions", "total", "duplicates", "duplicate-identity"] {
            var bad = parsed
            switch field {
            case "path": bad.files[0].file = "../private.jpg"
            case "sha": bad.files[0].sha256 = "bad"
            case "size": bad.files[0].size = -1
            case "dimensions": bad.files[0].width = 9999
            case "total": bad.totalBytes = 1
            case "duplicate-identity": bad.files[0].file = bad.files[1].name + ".heic"
            default: bad.files[0] = bad.files[1]
            }
            #expect(throws: (any Error).self) { try bad.validate() }
        }
    }

    @Test func downloadsVerifiesResumesAndCarriesOnlyTheReviewCredential() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        try f.serve()
        let updates = Mutex<[(Int, Int)]>([])
        let files = try await f.downloader.run { done, total in updates.withLock { $0.append((done, total)) } }
        #expect(files.count == 16)
        #expect(files.allSatisfy { f.downloader.verified($0.file, at: $0.url) })
        #expect(updates.withLock { $0.last?.0 } == f.manifest.totalBytes)
        let first = ReviewProtocol.requests.withLock { $0 }
        #expect(first.count == 17)
        #expect(first.allSatisfy {
            $0.url?.host == "demo-download.invalid" && $0.url?.query == nil
                && $0.value(forHTTPHeaderField: "Cookie") == nil && $0.value(forHTTPHeaderField: "X-Homespun-Key") == nil
                && $0.value(forHTTPHeaderField: "User-Agent") == "Homespun"
        })
        #expect(first.filter { $0.httpMethod == "POST" }.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
        #expect(first.filter { $0.httpMethod == "GET" }.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer local-test-session"
        })
        _ = try await f.downloader.run { _, _ in }
        #expect(ReviewProtocol.requests.withLock { $0.count } == 18, "verified files should resume within a launch")
        try Data(repeating: 0, count: f.jpeg.count).write(to: files[0].url)
        _ = try await f.downloader.run { _, _ in }
        #expect(ReviewProtocol.requests.withLock { $0.count } == 20, "a corrupt resumed file must be replaced")
    }

    @Test func shaMismatchIsNeverPublished() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        try f.serve(corrupt: true)
        await #expect(throws: DemoDownload.Failure.integrity) { _ = try await f.downloader.run { _, _ in } }
        let contents = try FileManager.default.contentsOfDirectory(atPath: f.folder.path)
        #expect(!contents.contains { $0.hasPrefix("demo-") || $0.hasSuffix(".part") })
    }

    @Test func expiryMidDownloadRenewsSilentlyWithoutDownloadingVerifiedFilesAgain() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        let sessions = Mutex(0), requests = Mutex<[String: Int]>([:])
        let manifestData = try JSONEncoder().encode(f.manifest)
        ReviewProtocol.handler.withLock { handler in
            handler = { request in
                if request.httpMethod == "POST" {
                    let number = sessions.withLock { $0 += 1; return $0 }
                    return (200, try JSONSerialization.data(withJSONObject: [
                        "manifest": JSONSerialization.jsonObject(with: manifestData),
                        "token": "session-\(number)", "expiresAt": Int(Date().timeIntervalSince1970) + 3600,
                    ]))
                }
                let path = request.url!.lastPathComponent
                let count = requests.withLock { counts in
                    counts[path, default: 0] += 1
                    return counts.count
                }
                if count == 2, request.value(forHTTPHeaderField: "Authorization") == "Bearer session-1" {
                    return (403, Data())
                }
                return (200, f.jpeg)
            }
        }
        let files = try await f.downloader.run { _, _ in }
        #expect(files.count == 16 && sessions.withLock { $0 } == 2)
        #expect(requests.withLock { $0.values.sorted() } == Array(repeating: 1, count: 15) + [2])
    }

    @Test func onlyAnAuthorizedCodeIsSaved() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        let store = DemoReviewCodeStore(service: "photos.homespun.test.review.\(UUID().uuidString)")
        defer { try? store.remove() }
        var downloader = f.downloader
        downloader.codeStore = store
        ReviewProtocol.handler.withLock { $0 = { _ in (403, Data()) } }
        await #expect(throws: DemoDownload.Failure.code) { _ = try await downloader.run { _, _ in } }
        #expect(store.read() == nil)
        try f.serve()
        _ = try await downloader.run { _, _ in }
        #expect(store.read() == downloader.code)
    }

    @Test func cancellingKeepsVerifiedFilesAndResumesOnlyTheRemainingFiles() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        try f.serve()
        let (events, continuation) = AsyncStream<Int>.makeStream()
        let task = Task {
            try await f.downloader.run { done, _ in
                continuation.yield(done)
                if done > 0 { try? await Task.sleep(for: .milliseconds(100)) }
            }
        }
        for await done in events where done > 0 { task.cancel(); break }
        continuation.finish()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        let saved = f.manifest.files.filter { f.downloader.verified($0, at: f.folder.appendingPathComponent($0.file)) }.count
        #expect(saved > 0 && saved < 16)
        #expect(try !FileManager.default.contentsOfDirectory(atPath: f.folder.path).contains { $0.hasSuffix(".part") })
        let before = ReviewProtocol.requests.withLock { $0.count }
        _ = try await f.downloader.run { _, _ in }
        #expect(ReviewProtocol.requests.withLock { $0.count } - before == 17 - saved)
    }

    @Test func failedDownloadFallsBackToTheWholeDrawnLibrary() async throws {
        let full = try await DemoTestMedia.ready.value
        let root = try DemoTestMedia.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent(DemoMediaStore.folderName)
        try FileManager.default.copyItem(at: full, to: output)
        try FileManager.default.removeItem(at: output.appendingPathComponent("manifest.json"))
        ReviewProtocol.handler.withLock { $0 = { _ in throw URLError(.notConnectedToInternet) } }
        let updates = DemoTestMedia.Updates()
        let store = DemoMediaStore(root: root, download: {
            DemoDownload(base: URL(string: "https://demo-download.invalid/v1/demo/")!, code: "TEST", folder: $0,
                         protocolClasses: [ReviewProtocol.self])
        })
        _ = try await store.prepare { updates.append($0) }
        #expect(updates.all.contains { $0.phase == .downloading })
        #expect(updates.all.contains { $0.phase == .drawing && $0.fallback != nil })
        #expect(DemoSample.load(from: output).count == 30)
        #expect(await store.manifest()?.source == "drawn")
    }

    @Test func reviewCodeIsIsolatedInTheKeychain() throws {
        let store = DemoReviewCodeStore(service: "photos.homespun.test.review.\(UUID().uuidString)")
        defer { try? store.remove() }
        #expect(store.read() == nil)
        try store.save("test-test test-test")
        #expect(store.read() == "TESTTESTTESTTEST")
        #expect(DemoReviewCodeStore(service: store.service).read() == "TESTTESTTESTTEST")
        try store.save("OTHER")
        #expect(store.read() == "OTHER")
        try store.save("")
        #expect(store.read() == nil)
    }

    @Test func assemblingUsesOnlyReviewStillsAndKeepsBundledMotion() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        try f.serve()
        var photos = try await f.downloader.run { _, _ in }
        let output = f.folder.appendingPathComponent("assembled")
        let result = try await DemoMediaGenerator(bundled: DemoMediaStore.bundledFolder, output: output, limit: 2,
                                                  photos: photos).run { _ in }
        let samples = DemoSample.load(from: output)
        #expect(result.source == "reviewer-v1" && result.files.count == 48)
        #expect(samples.count == 21 && samples.filter { $0.name.hasPrefix("demo-") }.count == 16)
        #expect(samples.first?.width == 64 && samples.first?.date == "2025-01-01T10:00:00Z")
        #expect(samples.filter { $0.kind == "video" }.count == 3)
        #expect(samples.filter { $0.kind == "live_photo" }.count == 1)
        #expect(try Data(contentsOf: output.appendingPathComponent(photos[0].file.file)) == f.jpeg)
        try Data(repeating: 0, count: f.jpeg.count).write(to: output.appendingPathComponent(photos[0].file.file))
        let previouslyVerified = photos
        await #expect(throws: DemoDownload.Failure.integrity) {
            _ = try await DemoMediaGenerator(bundled: DemoMediaStore.bundledFolder, output: output, limit: 2,
                                            photos: previouslyVerified).run { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: output.appendingPathComponent("manifest.json").path))
        var changed = f.jpeg
        changed.append(0)
        try changed.write(to: photos[0].url)
        photos[0].file.size = changed.count
        photos[0].file.sha256 = SHA256.hash(data: changed).map { String(format: "%02x", $0) }.joined()
        _ = try await DemoMediaGenerator(bundled: DemoMediaStore.bundledFolder, output: output, limit: 2,
                                        photos: photos).run { _ in }
        #expect(try Data(contentsOf: output.appendingPathComponent(photos[0].file.file)) == changed,
                "a changed authenticated set must not reuse an earlier assembled original")
    }
}

private final class ReviewProtocol: URLProtocol, @unchecked Sendable {
    static let handler = Mutex<(@Sendable (URLRequest) throws -> (Int, Data))?>(nil)
    static let requests = Mutex<[URLRequest]>([])
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "demo-download.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.withLock { $0.append(request) }
        do {
            let handler = try #require(Self.handler.withLock { $0 })
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                           headerFields: ["Content-Length": "\(data.count)"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
