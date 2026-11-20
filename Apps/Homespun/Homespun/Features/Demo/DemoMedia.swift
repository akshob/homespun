// SPDX-License-Identifier: Apache-2.0
import CoreGraphics
import Foundation
import HomespunCore
import ImageIO
import os
import Synchronization
import UniformTypeIdentifiers

/// Media lasts for this process, including backgrounding and leaving the demo. Only a cold launch
/// purges it; Application Support cannot be evicted while the app is in the background.
actor DemoMediaStore {
    static let shared = DemoMediaStore(root: .applicationSupportDirectory)
    nonisolated static let folderName = "Homespun Demo Media"
    nonisolated static var bundledFolder: URL { Bundle.main.bundleURL.appendingPathComponent("Demo", isDirectory: true) }
    nonisolated static let neededBytes: Int64 = 160 << 20
    nonisolated let folder: URL

    enum Failure: Error, Equatable, Sendable {
        case diskFull(neededBytes: Int64)
        case lowMemory
        case failed(String)

        var title: String {
            switch self {
            case .diskFull: "Not enough space for the demo"
            default: "The demo couldn't start"
            }
        }

        var message: String {
            switch self {
            case .diskFull: "The demo needs about 160 MB free on this iPhone. Free up some space, then try again."
            case .lowMemory: "This iPhone is short of memory right now. Close some apps, then try again."
            case .failed: "Something went wrong drawing the sample photos. Try again."
            }
        }
    }

    struct Progress: Sendable, Equatable {
        enum Phase: String, Sendable { case drawing, downloading, assembling }
        var done: Int
        var total: Int
        var fraction: Double
        var phase: Phase = .drawing
        var fallback: String? = nil
    }

    private let bundled: URL
    private let freeSpace: @Sendable () -> Int64?
    private let availableMemory: @Sendable () -> Int
    private let cores: Int
    private let download: @Sendable (URL) -> DemoDownload?
    private let concurrency = Mutex(1)
    private var flight: (id: UUID, task: Task<URL, Error>)?

    init(root: URL, bundled: URL = bundledFolder,
         freeSpace: @escaping @Sendable () -> Int64? = DemoMediaStore.systemFreeSpace,
         availableMemory: @escaping @Sendable () -> Int = DemoMediaStore.systemAvailableMemory,
         cores: Int = ProcessInfo.processInfo.activeProcessorCount,
         download: @escaping @Sendable (URL) -> DemoDownload? = DemoDownload.configured) {
        folder = root.appendingPathComponent(Self.folderName, isDirectory: true)
        self.bundled = bundled
        self.freeSpace = freeSpace
        self.availableMemory = availableMemory
        self.cores = cores
        self.download = download
    }

    nonisolated static func systemFreeSpace() -> Int64? {
        (try? URL.applicationSupportDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    nonisolated static func systemAvailableMemory() -> Int {
        #if targetEnvironment(simulator)
        // The simulator doesn't report a usable per-app jetsam memory budget.
        Int(clamping: ProcessInfo.processInfo.physicalMemory)
        #else
        Int(clamping: os_proc_available_memory())
        #endif
    }

    nonisolated static func limit(cores: Int, available: Int) -> Int {
        max(1, min(cores - 1, 5, (available - (200 << 20)) / (120 << 20)))
    }

    func lowerLimit() { concurrency.withLock { $0 = 1 } }

    func reset() throws {
        guard flight == nil else { throw CancellationError() }
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
        DemoPictures.forget()
    }

    /// Rename first so launch never waits for the previous process's files to be deleted.
    nonisolated static func purgeAtLaunch(root: URL = .applicationSupportDirectory) {
        let folder = root.appendingPathComponent(folderName, isDirectory: true)
        let old = root.appendingPathComponent("\(folderName).old-\(UUID().uuidString)", isDirectory: true)
        do {
            if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.moveItem(at: folder, to: old) }
        } catch {
            // If renaming fails, don't let an earlier launch's files pass the ready check.
            try? FileManager.default.removeItem(at: folder.appendingPathComponent("manifest.json"))
        }
        Task.detached(priority: .utility) {
            let siblings = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            for url in siblings where url.lastPathComponent.hasPrefix("\(folderName).old-") {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    func manifest() -> DemoMediaManifest? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
              let manifest = try? JSONDecoder().decode(DemoMediaManifest.self, from: data),
              manifest.version == DemoArt.version else { return nil }
        let samples = DemoSample.load(from: folder)
        let expectedCount: Int
        if manifest.source == "reviewer-v1" {
            let fixed = Set(DemoArt.recipes.filter { $0.kind != .photo }.map(\.name))
            guard samples.count == 21, Set(samples.map(\.name)).count == 21,
                  fixed.isSubset(of: Set(samples.map(\.name))),
                  samples.filter({ $0.name.hasPrefix("demo-") && $0.kind == "photo" }).count == 16 else { return nil }
            expectedCount = 48
        } else {
            guard manifest.source == nil || manifest.source == "drawn",
                  samples.map(\.name) == DemoArt.recipes.map(\.name) else { return nil }
            expectedCount = 66
        }
        let paths = Set(samples.flatMap { Array($0.files.values) + Array(($0.compact ?? [:]).values) + [$0.thumbnail].compactMap { $0 } })
        guard paths == Set(manifest.files.keys), manifest.files.count == expectedCount,
              paths.allSatisfy({ !$0.hasPrefix("/") && !$0.split(separator: "/").contains("..") }),
              manifest.files.allSatisfy({ path, file in
                  (try? folder.appendingPathComponent(path).resourceValues(forKeys: [.fileSizeKey]).fileSize) == file.bytes
              }) else { return nil }
        return manifest
    }

    func readyFolder() -> URL? { manifest() == nil ? nil : folder }

    /// Single-flight, and cancellable even though the drawing task runs off the actor's executor.
    func prepare(progress: @escaping @Sendable (Progress) async -> Void) async throws -> URL {
        try Task.checkCancellation()
        let pending: (id: UUID, task: Task<URL, Error>)
        if let flight {
            pending = flight
        } else {
            if let ready = readyFolder() { return ready }
            if let free = freeSpace(), free < Self.neededBytes { throw Failure.diskFull(neededBytes: Self.neededBytes) }
            let available = availableMemory()
            guard available >= 320 << 20 else { throw Failure.lowMemory }
            let limit = Self.limit(cores: cores, available: available)
            concurrency.withLock { $0 = limit }
            let generator = DemoMediaGenerator(bundled: bundled, output: folder, limit: limit)
            let download = download(folder.appendingPathComponent("downloads", isDirectory: true))
            let freeSpace = freeSpace
            let id = UUID()
            let task = Task.detached(priority: .userInitiated) { [self] in
                do {
                    var fallback: String?
                    if let download {
                        do {
                            await progress(.init(done: 0, total: 0, fraction: 0, phase: .downloading))
                            let photos = try await download.run { bytes, total in
                                await progress(.init(done: bytes, total: total, fraction: 0.9 * Double(bytes) / Double(total),
                                                     phase: .downloading))
                            }
                            var assembling = generator
                            assembling.photos = photos
                            _ = try await assembling.run(currentLimit: { self.concurrency.withLock { $0 } }) { value in
                                var value = value
                                value.phase = .assembling
                                value.fraction = 0.9 + value.fraction * 0.1
                                await progress(value)
                            }
                            try Task.checkCancellation()
                            return generator.output
                        } catch {
                            try Task.checkCancellation()
                            fallback = "The review photos couldn't be downloaded, so Homespun is drawing sample photos instead."
                        }
                    }
                    let note = fallback
                    _ = try await generator.run(currentLimit: { self.concurrency.withLock { $0 } }) { value in
                        var value = value
                        value.fallback = note
                        await progress(value)
                    }
                    try Task.checkCancellation()
                    return generator.output
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    try Task.checkCancellation()
                    if let free = freeSpace(), free < Self.neededBytes { throw Failure.diskFull(neededBytes: Self.neededBytes) }
                    Logger(subsystem: "photos.homespun.app", category: "Demo")
                        .error("Couldn't draw demo media: \(String(describing: error), privacy: .private)")
                    throw Failure.failed(String(describing: error))
                }
            }
            pending = (id, task)
            flight = pending
        }
        defer { if flight?.id == pending.id { flight = nil } }
        return try await withTaskCancellationHandler {
            let folder = try await pending.task.value
            try Task.checkCancellation()
            return folder
        } onCancel: {
            pending.task.cancel()
        }
    }
}

struct DemoMediaManifest: Codable, Equatable, Sendable {
    var version: Int
    var files: [String: File]
    var source: String? = nil
    struct File: Codable, Equatable, Sendable {
        var bytes: Int
        var sha256: String
    }
}

struct DemoMediaGenerator: Sendable {
    let bundled: URL
    let output: URL
    var limit: Int
    var only: Set<String>? = nil
    var photos: [DemoDownloadedPhoto]? = nil

    private var recipes: [DemoArt.Recipe] {
        guard let photos else { return DemoArt.recipes }
        return photos.map {
            DemoArt.Recipe(name: $0.file.name, kind: .photo, date: $0.file.date, scene: nil,
                           portrait: $0.file.height > $0.file.width, heic: $0.file.file.hasSuffix(".heic"))
        } + DemoArt.recipes.filter { $0.kind != .photo }
    }

    private struct Job: Sendable {
        let recipe: DemoArt.Recipe
        var weight: Double {
            switch recipe.kind {
            case .photo: 1
            case .screenshot: 0.6
            default: 0.1
            }
        }
    }

    func run(currentLimit: @Sendable () -> Int = { .max },
             progress: @Sendable (DemoMediaStore.Progress) async -> Void) async throws -> DemoMediaManifest {
        let start = ContinuousClock.now
        let interval = PerfMonitor.signposter.beginInterval("DemoMediaDraw", id: PerfMonitor.signposter.makeSignpostID())
        defer { PerfMonitor.signposter.endInterval("DemoMediaDraw", interval) }
        try Task.checkCancellation()
        let manager = FileManager.default
        try manager.createDirectory(at: output, withIntermediateDirectories: true)
        var folder = output
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        // A cancelled or failed attempt must never leave drawn originals in a review-photo set.
        let source = photos == nil ? "drawn" : "reviewer-v1"
        let sourceURL = output.appendingPathComponent("source.txt")
        if (try? String(contentsOf: sourceURL, encoding: .utf8)) != source {
            for url in try manager.contentsOfDirectory(at: output, includingPropertiesForKeys: nil)
                where url.lastPathComponent != "downloads" {
                try manager.removeItem(at: url)
            }
        }
        try Data(source.utf8).write(to: sourceURL, options: .atomic)
        let manifestURL = output.appendingPathComponent("manifest.json")
        if let data = try? Data(contentsOf: manifestURL),
           let previous = try? JSONDecoder().decode(DemoMediaManifest.self, from: data), previous.version != DemoArt.version {
            try manager.removeItem(at: output)
            try manager.createDirectory(at: output, withIntermediateDirectories: true)
            try folder.setResourceValues(values)
        }
        try? manager.removeItem(at: manifestURL)
        for name in ["compact", "thumbs"] {
            try manager.createDirectory(at: output.appendingPathComponent(name, isDirectory: true), withIntermediateDirectories: true)
        }
        let recipes = recipes.filter { only?.contains($0.name) ?? true }
        for recipe in recipes where recipe.bundled {
            let entry = entry(for: recipe)
            for path in Array(entry.files.values) + Array((entry.compact ?? [:]).values) {
                try Task.checkCancellation()
                let source = bundled.appendingPathComponent(path), destination = output.appendingPathComponent(path)
                let bytes = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize
                if (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) == bytes { continue }
                try publish(path) { try manager.copyItem(at: source, to: $0) }
            }
        }
        let jobs = recipes.map { Job(recipe: $0) }.sorted { $0.weight > $1.weight }
        let totalWeight = jobs.reduce(0) { $0 + $1.weight }
        let skipped = jobs.filter { complete($0.recipe) }
        var done = skipped.count, weight = skipped.reduce(0) { $0 + $1.weight }
        await progress(.init(done: done, total: jobs.count, fraction: totalWeight == 0 ? 1 : weight / totalWeight))
        try Task.checkCancellation()
        var remaining = jobs.filter { !complete($0.recipe) }.makeIterator()
        try await withThrowingTaskGroup(of: Double.self) { group in
            var running = 0
            func fill() {
                while running < max(1, min(limit, currentLimit())), let job = remaining.next() {
                    running += 1
                    group.addTask(priority: .userInitiated) {
                        try Task.checkCancellation()
                        try autoreleasepool { try draw(job.recipe) }
                        return job.weight
                    }
                }
            }
            fill()
            while let finished = try await group.next() {
                running -= 1
                done += 1
                weight += finished
                await progress(.init(done: done, total: jobs.count, fraction: min(1, weight / totalWeight)))
                try Task.checkCancellation()
                fill()
            }
        }
        try Task.checkCancellation()
        let entries = recipes.map { entry(for: $0) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(entries).write(to: output.appendingPathComponent("samples.json"), options: .atomic)
        var files: [String: DemoMediaManifest.File] = [:]
        for entry in entries {
            let paths = Array(entry.files.values) + Array((entry.compact ?? [:]).values) + [entry.thumbnail].compactMap { $0 }
            for path in paths {
                try Task.checkCancellation()
                let url = output.appendingPathComponent(path)
                let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                files[path] = .init(bytes: bytes, sha256: try Fingerprint.sha256(of: url))
            }
        }
        try Task.checkCancellation()
        let manifest = DemoMediaManifest(version: DemoArt.version, files: files, source: source)
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
        let elapsed = ContinuousClock.now - start
        let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        Logger(subsystem: "photos.homespun.app", category: "Demo")
            .info("Drew the demo's media: \(files.count) files in \(ms) ms, \(self.limit) at once")
        return manifest
    }

    private func entry(for recipe: DemoArt.Recipe) -> DemoArt.Entry {
        var files: [String: String], compact: [String: String]?
        switch recipe.kind {
        case .photo:
            if let photo = photos?.first(where: { $0.file.name == recipe.name }) {
                return DemoArt.Entry(name: recipe.name, kind: "photo", date: photo.file.date,
                                     width: photo.file.width, height: photo.file.height,
                                     files: ["photo": photo.file.file], thumbnail: "thumbs/\(recipe.name).JPG")
            }
            let jpeg = recipe.name + ".JPG"
            let usesJPEG = !recipe.heic || FileManager.default.fileExists(atPath: output.appendingPathComponent(jpeg).path)
            files = ["photo": recipe.name + (usesJPEG ? ".JPG" : ".HEIC")]
        case .screenshot: files = ["photo": recipe.name + ".PNG"]
        case .video:
            files = ["video": recipe.name + ".MOV"]
            compact = files.mapValues { "compact/" + $0 }
        case .livePhoto:
            files = ["photo": recipe.name + ".HEIC", "paired_video": recipe.name + ".MOV"]
            compact = files.mapValues { "compact/" + $0 }
        }
        return DemoArt.Entry(name: recipe.name, kind: recipe.kind == .screenshot ? "photo" : recipe.kind.rawValue,
                             date: recipe.date, width: recipe.size.width, height: recipe.size.height,
                             seconds: recipe.bundled ? recipe.seconds : nil, favorite: recipe.favorite ? true : nil,
                             screenshot: recipe.kind == .screenshot ? true : nil, files: files, compact: compact,
                             thumbnail: "thumbs/\(recipe.name).JPG")
    }

    private func exists(_ path: String) -> Bool {
        ((try? output.appendingPathComponent(path).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0
    }

    private func complete(_ recipe: DemoArt.Recipe) -> Bool {
        let entry = entry(for: recipe)
        return entry.files.values.allSatisfy(exists) && exists(entry.thumbnail!)
    }

    private func draw(_ recipe: DemoArt.Recipe) throws {
        let thumbnail = "thumbs/\(recipe.name).JPG"
        let image: CGImage
        if let photo = photos?.first(where: { $0.file.name == recipe.name }) {
            if !exists(photo.file.file) {
                try publish(photo.file.file) { try FileManager.default.copyItem(at: photo.url, to: $0) }
            }
            guard let source = CGImageSourceCreateWithURL(photo.url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  properties[kCGImagePropertyPixelWidth] as? Int == photo.file.width,
                  properties[kCGImagePropertyPixelHeight] as? Int == photo.file.height,
                  let still = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: Int(ceil(Double(DemoArt.thumbShortEdge)
                        * Double(max(photo.file.width, photo.file.height)) / Double(min(photo.file.width, photo.file.height)))),
                  ] as CFDictionary) else { throw CocoaError(.fileReadCorruptFile) }
            if !exists(thumbnail) {
                try write(DemoArt.thumbnail(of: still), path: thumbnail, type: .jpeg, quality: DemoArt.thumbQuality, date: nil)
            }
            return
        }
        switch recipe.kind {
        case .photo:
            image = DemoArt.photo(recipe)
            if !entry(for: recipe).files.values.allSatisfy(exists) {
                if recipe.heic {
                    do {
                        try write(image, path: recipe.name + ".HEIC", type: .heic, quality: DemoArt.heicQuality, date: recipe.date)
                    } catch {
                        try Task.checkCancellation()
                        try write(image, path: recipe.name + ".JPG", type: .jpeg, quality: DemoArt.jpegQuality, date: recipe.date)
                    }
                } else {
                    try write(image, path: recipe.name + ".JPG", type: .jpeg, quality: DemoArt.jpegQuality, date: recipe.date)
                }
            }
        case .screenshot:
            image = DemoArt.screenshot()
            if !exists(recipe.name + ".PNG") {
                try write(image, path: recipe.name + ".PNG", type: .png, quality: 1, date: recipe.date, screenshot: true)
            }
        case .video:
            image = DemoArt.videoThumbnail(recipe)
        case .livePhoto:
            guard let source = CGImageSourceCreateWithURL(output.appendingPathComponent(recipe.name + ".HEIC") as CFURL, nil),
                  let still = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: 480,
                  ] as CFDictionary) else { throw CocoaError(.fileReadCorruptFile) }
            image = still
        }
        try Task.checkCancellation()
        if !exists(thumbnail) {
            try write(DemoArt.thumbnail(of: image), path: thumbnail, type: .jpeg, quality: DemoArt.thumbQuality, date: nil)
        }
    }

    private func write(_ image: CGImage, path: String, type: UTType, quality: Double, date: String?,
                       screenshot: Bool = false) throws {
        try publish(path) {
            try DemoArt.writeImage(image, to: $0, type: type, quality: quality, date: date, screenshot: screenshot)
        }
    }

    private func publish(_ path: String, _ body: (URL) throws -> Void) throws {
        let destination = output.appendingPathComponent(path), part = output.appendingPathComponent(path + ".part")
        try? FileManager.default.removeItem(at: part)
        defer { try? FileManager.default.removeItem(at: part) }
        try body(part)
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: part, to: destination)
    }
}
