// SPDX-License-Identifier: Apache-2.0
import CoreGraphics
import Foundation
import HomespunCore
import ImageIO
import Synchronization
import Testing
import UniformTypeIdentifiers
@testable import Homespun

enum DemoTestMedia {
    static let seconds = Mutex(0.0)
    static let ready: Task<URL, Error> = Task.detached {
        let start = ContinuousClock.now
        let root = try makeRoot()
        let folder = try await DemoMediaStore(root: root).prepare { _ in }
        let elapsed = ContinuousClock.now - start
        let duration = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        seconds.withLock { $0 = duration }
        print("PERF DemoTestMedia: drew the whole library in \(String(format: "%.3f", duration)) seconds")
        return folder
    }

    static func makeRoot() throws -> URL {
        let root = URL.applicationSupportDirectory.appendingPathComponent("Demo Media Tests/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    final class Updates: Sendable {
        private let values = Mutex<[DemoMediaStore.Progress]>([])
        func append(_ value: DemoMediaStore.Progress) { values.withLock { $0.append(value) } }
        var all: [DemoMediaStore.Progress] { values.withLock { $0 } }
    }
}

@Suite(.serialized) struct DemoMediaTests {
    // Captured with ImageIO/CoreGraphics from the old bundled pictures before removing them.
    static let golden: [String: UInt64] = [
        "IMG_0102": 0xD171F1B53572B8F9, "IMG_0105": 0xBB3B75272FDB9565, "IMG_0109": 0xC3C3E3A912526993,
        "IMG_0215": 0xD878B8B858B99C13, "IMG_0219": 0xCEB871B9F95CBC9A, "IMG_0224": 0xE3C5E5E7E668E645,
        "IMG_0231": 0xE3F5F176F6F0F276, "IMG_0238": 0xE6E6E6E666E2E54C, "IMG_0301": 0x78B8B8C2F455D922,
        "IMG_0305": 0xD8587A5CD9B89A27, "IMG_0309": 0xFAFA787830DA7926, "IMG_0352": 0x6CEB8DE8F0F0955D,
        "IMG_0358": 0x70F0949545919191, "IMG_0361": 0xE0E1A373B2959595, "IMG_0420": 0xC2C2C2CACACDA915,
        "IMG_0428": 0xC86766041348AA6A, "IMG_0510": 0xB02DE40F0FD13664, "IMG_0514": 0xE6C6C1E3D9C6BCF2,
        "IMG_0517": 0x4181C2CF0CD5B39C, "IMG_0519": 0xE4CDDC0E0FA6C9B4, "IMG_0640": 0x32F0F1B38D73B2B9,
        "IMG_0644": 0x9933714C52B8B1F0, "IMG_0651": 0x7878788F1CB6276A, "IMG_0655": 0xAA55F0D4CCF09A56,
        "IMG_0941": 0x6C9CDC1CA0F1F000, "IMG_0944": 0x7170F173B822F085, "IMG_0950": 0x3C98FC3C6DBC9C4B,
        "IMG_0958": 0x507E961C3C3C2C00, "IMG_0973": 0x46C6C1F306B2C9AD, "IMG_0978": 0xF0C1C3363499928A,
    ]

    @Test func drawingIsDeterministic() throws {
        let folder = try DemoTestMedia.makeRoot()
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["IMG_0517", "IMG_0361", "IMG_0958"] {
            let recipe = try #require(DemoArt.recipes.first { $0.name == name })
            func picture() -> CGImage {
                if recipe.kind == .screenshot { return DemoArt.scaled(DemoArt.screenshot(), maxEdge: 328) }
                return DemoArt.render(width: 504, height: 378) {
                    DemoArt.draw(recipe.scene!, in: $0, width: 504, height: 378)
                    DemoArt.grain($0, width: 504, height: 378, seed: recipe.scene!.seed)
                }
            }
            let first = picture(), second = picture()
            let firstPixels = try #require(first.dataProvider?.data) as Data
            let secondPixels = try #require(second.dataProvider?.data) as Data
            #expect(firstPixels == secondPixels, "\(name): pixels differ")
            let a = folder.appendingPathComponent("a"), b = folder.appendingPathComponent("b")
            let type: UTType = DemoServer.writesHEIC ? .heic : .jpeg
            try DemoArt.writeImage(first, to: a, type: type, quality: 0.6, date: recipe.date)
            try DemoArt.writeImage(second, to: b, type: type, quality: 0.6, date: recipe.date)
            #expect(try Data(contentsOf: a) == Data(contentsOf: b), "\(name): encoded bytes differ")
        }
    }

    @Test func regeneratingGivesTheSameBytes() async throws {
        let full = try await DemoTestMedia.ready.value
        let shared = try JSONDecoder().decode(DemoMediaManifest.self, from: Data(contentsOf: full.appendingPathComponent("manifest.json")))
        let a = try DemoTestMedia.makeRoot(), b = try DemoTestMedia.makeRoot()
        defer {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }
        let only: Set<String> = ["IMG_0102", "IMG_0105", "IMG_0958"]
        let first = try await DemoMediaGenerator(bundled: DemoMediaStore.bundledFolder, output: a, limit: 2, only: only).run { _ in }
        let second = try await DemoMediaGenerator(bundled: DemoMediaStore.bundledFolder, output: b, limit: 1, only: only).run { _ in }
        #expect(first == second)
        for (path, file) in first.files { #expect(shared.files[path] == file, "\(path)") }
    }

    @Test func drawingsMatchTodaysPictures() async throws {
        let folder = try await DemoTestMedia.ready.value
        for (name, golden) in Self.golden {
            let actual = try Self.dHash(folder.appendingPathComponent("thumbs/\(name).JPG"))
            #expect((actual ^ golden).nonzeroBitCount <= 12, "\(name): \(String(actual, radix: 16))")
        }
    }

    @Test func drawsTheWholeLibrary() async throws {
        let folder = try await DemoTestMedia.ready.value
        let samples = DemoSample.load(from: folder)
        #expect(samples.count == 30)
        #expect(samples.map(\.name) == DemoArt.recipes.map(\.name))
        let manager = FileManager.default
        #expect(try folder.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        let names = try manager.contentsOfDirectory(atPath: folder.path)
        let photos = samples.filter { $0.kind == "photo" && $0.screenshot != true }
        #expect(photos.count == 25)
        #expect(photos.filter { $0.files["photo"]?.hasSuffix(".HEIC") == true }.count == (DemoServer.writesHEIC ? 17 : 0))
        #expect(photos.filter { $0.files["photo"]?.hasSuffix(".JPG") == true }.count == (DemoServer.writesHEIC ? 8 : 25))
        #expect(names.filter { $0.hasSuffix(".MOV") }.count == 4)
        #expect(names.filter { $0.hasSuffix(".PNG") }.count == 1)
        #expect(names.filter { $0.hasSuffix(".HEIC") || $0.hasSuffix(".JPG") }.count == 26)
        #expect(try manager.contentsOfDirectory(atPath: folder.appendingPathComponent("compact").path).count == 5)
        #expect(try manager.contentsOfDirectory(atPath: folder.appendingPathComponent("thumbs").path).count == 30)
        let manifest = try JSONDecoder().decode(DemoMediaManifest.self, from: Data(contentsOf: folder.appendingPathComponent("manifest.json")))
        #expect(manifest.version == DemoArt.version && manifest.files.count == 66)
        for sample in samples {
            let thumb = try properties(folder.appendingPathComponent(try #require(sample.thumbnail)))
            #expect(min(thumb[kCGImagePropertyPixelWidth] as? Int ?? 0, thumb[kCGImagePropertyPixelHeight] as? Int ?? 0) == 360)
            if let photo = sample.files["photo"] {
                let image = try properties(folder.appendingPathComponent(photo))
                #expect(image[kCGImagePropertyPixelWidth] as? Int == sample.width)
                #expect(image[kCGImagePropertyPixelHeight] as? Int == sample.height)
                let exif = try #require(image[kCGImagePropertyExifDictionary] as? [CFString: Any])
                #expect(exif[kCGImagePropertyExifDateTimeOriginal] as? String == DemoArt.dateParts(sample.date).exif)
                if sample.screenshot == true { #expect(exif[kCGImagePropertyExifUserComment] as? String == "Screenshot") }
            }
        }
        for path in Self.bundledFiles {
            #expect(try Data(contentsOf: folder.appendingPathComponent(path))
                    == Data(contentsOf: DemoMediaStore.bundledFolder.appendingPathComponent(path)), "\(path): changed while cloning")
        }
        for (path, file) in manifest.files {
            let url = folder.appendingPathComponent(path)
            #expect(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize == file.bytes)
            #expect(try Fingerprint.sha256(of: url) == file.sha256)
        }
    }

    @Test func drawingTakesLessThanABudget() async throws {
        _ = try await DemoTestMedia.ready.value
        let seconds = DemoTestMedia.seconds.withLock { $0 }
        print("PERF Demo media generation: \(String(format: "%.3f", seconds)) seconds (Debug simulator; 120 s sanity ceiling)")
        #expect(seconds > 0 && seconds < 120, "demo media took \(seconds) seconds")
    }

    @Test func readyFolderIsReusedWithinALaunch() async throws {
        let ready = try await DemoTestMedia.ready.value
        let store = DemoMediaStore(root: ready.deletingLastPathComponent())
        let manifest = ready.appendingPathComponent("manifest.json")
        let before = try manifest.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let updates = DemoTestMedia.Updates(), start = ContinuousClock.now
        let again = try await store.prepare { updates.append($0) }
        #expect(again == ready && ContinuousClock.now - start < .milliseconds(500))
        #expect(updates.all.isEmpty)
        #expect(try manifest.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == before)
    }

    @Test func missingFilesAreDrawnAgain() async throws {
        let ready = try await DemoTestMedia.ready.value, root = try DemoTestMedia.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DemoMediaStore(root: root)
        try FileManager.default.copyItem(at: ready, to: store.folder)
        let samples = DemoSample.load(from: store.folder)
        let photo = try #require(samples.first?.files["photo"])
        let untouched = store.folder.appendingPathComponent(try #require(samples[2].files["photo"]))
        let before = try untouched.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        try FileManager.default.removeItem(at: store.folder.appendingPathComponent(photo))
        try FileManager.default.removeItem(at: store.folder.appendingPathComponent("thumbs/IMG_0105.JPG"))
        #expect(await store.readyFolder() == nil)
        let updates = DemoTestMedia.Updates()
        _ = try await store.prepare { updates.append($0) }
        #expect(try #require(updates.all.first).fraction > 0.9)
        #expect(updates.all.last?.done == 30 && updates.all.count == 3)
        #expect(await store.readyFolder() == store.folder)
        #expect(try untouched.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == before)
    }

    @Test func concurrentPreparationSharesTheSameDrawing() async throws {
        let ready = try await DemoTestMedia.ready.value, root = try DemoTestMedia.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DemoMediaStore(root: root)
        try FileManager.default.copyItem(at: ready, to: store.folder)
        try FileManager.default.removeItem(at: store.folder.appendingPathComponent("thumbs/IMG_0224.JPG"))
        let updates = DemoTestMedia.Updates()
        async let first = store.prepare {
            updates.append($0)
            try? await Task.sleep(for: .milliseconds(50))
        }
        async let second = store.prepare { updates.append($0) }
        let (a, b) = try await (first, second)
        #expect(a == b && a == store.folder)
        #expect(updates.all.count == 2, "more than one generation reported progress")
        #expect(await store.readyFolder() == store.folder)
    }

    @Test func launchDeletesTheLastLaunchsFolder() async throws {
        let root = try DemoTestMedia.makeRoot(), store = DemoMediaStore(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await DemoMediaGenerator(bundled: DemoMediaStore.bundledFolder, output: store.folder, limit: 1,
                                        only: ["IMG_0224"]).run { _ in }
        DemoMediaStore.purgeAtLaunch(root: root)
        #expect(!FileManager.default.fileExists(atPath: store.folder.path))
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while try FileManager.default.contentsOfDirectory(atPath: root.path).contains(where: { $0.contains(".old-") }),
              ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @MainActor @Test func leavingTheDemoKeepsItsMedia() async throws {
        let ready = try await DemoTestMedia.ready.value
        let manifest = ready.appendingPathComponent("manifest.json")
        let before = try Data(contentsOf: manifest)
        try FileManager.default.createDirectory(at: DemoMode.folder, withIntermediateDirectories: true)
        try Data("demo".utf8).write(to: DemoMode.folder.appendingPathComponent("library.json"))
        DemoMode.wipe()
        #expect(!FileManager.default.fileExists(atPath: DemoMode.folder.path))
        #expect(try Data(contentsOf: manifest) == before)
    }

    @Test func resumingRequiresTheSameMediaIdentity() throws {
        let root = try DemoTestMedia.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let saved = root.appendingPathComponent("media.json"), drawn = root.appendingPathComponent("manifest.json")
        var manifest = DemoMediaManifest(version: DemoArt.version, files: ["photo.JPG": .init(bytes: 10, sha256: "first")])
        let encoder = JSONEncoder()
        try encoder.encode(manifest).write(to: drawn)
        #expect(!DemoMode.canResume(media: root, state: root), "an earlier demo with no media manifest must restart")
        try encoder.encode(manifest).write(to: saved)
        #expect(DemoMode.canResume(media: root, state: root))
        manifest.files["photo.JPG"]?.sha256 = "changed"
        try encoder.encode(manifest).write(to: drawn)
        #expect(!DemoMode.canResume(media: root, state: root), "a different encoder must not reuse the ledger's hashes")
    }

    @Test func notEnoughSpaceIsReported() async throws {
        let root = try DemoTestMedia.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DemoMediaStore(root: root, freeSpace: { 10_000_000 })
        await #expect(throws: DemoMediaStore.Failure.diskFull(neededBytes: DemoMediaStore.neededBytes)) {
            _ = try await store.prepare { _ in }
        }
    }

    @Test func lowMemoryIsReported() async throws {
        let root = try DemoTestMedia.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DemoMediaStore(root: root, freeSpace: { .max }, availableMemory: { 100 << 20 })
        await #expect(throws: DemoMediaStore.Failure.lowMemory) { _ = try await store.prepare { _ in } }
        #expect(DemoMediaStore.limit(cores: 6, available: 8 << 30) == 5)
        #expect(DemoMediaStore.limit(cores: 6, available: 500 << 20) == 2)
        #expect(DemoMediaStore.limit(cores: 2, available: 8 << 30) == 1)
    }

    @Test func cancellingStopsDrawing() async throws {
        let root = try DemoTestMedia.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DemoMediaStore(root: root, freeSpace: { .max }, availableMemory: { 8 << 30 }, cores: 2)
        let (events, continuation) = AsyncStream<DemoMediaStore.Progress>.makeStream()
        let task = Task {
            try await store.prepare {
                continuation.yield($0)
                if $0.done > 0 { try? await Task.sleep(for: .milliseconds(100)) }
            }
        }
        for await progress in events where progress.done > 0 { task.cancel(); break }
        continuation.finish()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(!FileManager.default.fileExists(atPath: store.folder.appendingPathComponent("manifest.json").path))
        let files = FileManager.default.enumerator(at: store.folder, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
        #expect(!files.contains { $0.pathExtension == "part" })
        let updates = DemoTestMedia.Updates()
        _ = try await store.prepare { updates.append($0) }
        #expect(try #require(updates.all.first).done > 0, "retry discarded completed drawings")
        #expect(await store.readyFolder() != nil)
    }

    private func properties(_ url: URL) throws -> [CFString: Any] {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    static let bundledFiles: Set<String> = [
        "IMG_0224.MOV", "IMG_0514.MOV", "IMG_0973.MOV", "IMG_0950.HEIC", "IMG_0950.MOV",
        "compact/IMG_0224.MOV", "compact/IMG_0514.MOV", "compact/IMG_0973.MOV", "compact/IMG_0950.HEIC", "compact/IMG_0950.MOV",
    ]

    @Test func bundledMediaFitsTheBudget() throws {
        let bundle = DemoMediaStore.bundledFolder
        let enumerator = try #require(FileManager.default.enumerator(
            at: bundle, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]))
        var files: Set<String> = [], bytes = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { continue }
            files.insert(String(url.path.dropFirst(bundle.path.count + 1)))
            bytes += values.fileSize ?? 0
        }
        #expect(files == Self.bundledFiles.union(["README.md"]), "only the unchanged videos, Live Photo and compacts belong in the bundle")
        #expect(bytes <= 5_000_000, "bundled demo media is \(bytes) bytes")
    }

    static func dHash(_ url: URL) throws -> UInt64 {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let width = image.width, height = image.height
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                            bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        var sums = [Int](repeating: 0, count: 72), counts = sums
        for y in 0..<height {
            for x in 0..<width {
                let cell = (y * 8 / height) * 9 + x * 9 / width
                sums[cell] += Int(pixels[y * width + x])
                counts[cell] += 1
            }
        }
        let cells = zip(sums, counts).map { Double($0) / Double($1) }
        var hash: UInt64 = 0
        for y in 0..<8 {
            for x in 0..<8 { hash = (hash << 1) | (cells[y * 9 + x] < cells[y * 9 + x + 1] ? 1 : 0) }
        }
        return hash
    }
}
