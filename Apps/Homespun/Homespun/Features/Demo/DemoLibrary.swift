// SPDX-License-Identifier: Apache-2.0
import AVFoundation
import Foundation
import HomespunCore
import ImageIO
import Photos
import Synchronization
import UIKit
import UniformTypeIdentifiers

/// One of the demo's sample photos and videos, listed by DemoMedia in its launch-scoped folder.
struct DemoSample: Codable, Sendable, Equatable {
    var name: String
    /// "photo", "live_photo" or "video".
    var kind: String
    var date: String
    var width: Int
    var height: Int
    var seconds: Double?
    var favorite: Bool?
    var screenshot: Bool?
    /// Its files by role ("photo", "paired_video", "video").
    var files: [String: String]
    /// The compact copy that comes with the app (videos and the Live Photo); photos' are made by shrinking.
    var compact: [String: String]?
    /// A small picture for the grid, of it and of its compact copy.
    var thumbnail: String?

    var id: String { "demo:" + name }
    var itemKind: PhotoLibrary.Kind { kind == "video" ? .video : kind == "live_photo" ? .livePhoto : .photo }

    static func load(from folder: URL) -> [DemoSample] {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("samples.json")) else { return [] }
        return (try? JSONDecoder().decode([DemoSample].self, from: data)) ?? []
    }

    var created: Date? { ISO8601DateFormatter().date(from: date) }

    func urls(in folder: URL) -> [ServerAPI.ResourceRole: URL] {
        Dictionary(uniqueKeysWithValues: files.compactMap { role, file in
            ServerAPI.ResourceRole(rawValue: role).map { ($0, folder.appendingPathComponent(file)) }
        })
    }

    func compactURLs(in folder: URL) -> [ServerAPI.ResourceRole: URL]? {
        compact.map { files in
            Dictionary(uniqueKeysWithValues: files.compactMap { role, file in
                ServerAPI.ResourceRole(rawValue: role).map { ($0, folder.appendingPathComponent(file)) }
            })
        }
    }
}

/// A photo or video in the demo's library: a sample, or a compact copy the demo made of one.
final class DemoItem: LibraryItem, Sendable {
    let localIdentifier: String
    let creationDate: Date?
    let pixelWidth: Int
    let pixelHeight: Int
    let duration: TimeInterval
    let isFavorite: Bool
    let isScreenshot: Bool
    let kind: PhotoLibrary.Kind
    let files: [ServerAPI.ResourceRole: URL]
    /// The grid's small picture (the sample's, for its compact copy too).
    let thumbnail: URL?

    var isHidden: Bool { false }
    var itemKind: PhotoLibrary.Kind? { kind }
    var isEdited: Bool { false }

    init(id: String, created: Date?, width: Int, height: Int, duration: TimeInterval, favorite: Bool, screenshot: Bool,
         kind: PhotoLibrary.Kind, files: [ServerAPI.ResourceRole: URL], thumbnail: URL?) {
        localIdentifier = id
        creationDate = created
        pixelWidth = width
        pixelHeight = height
        self.duration = duration
        isFavorite = favorite
        isScreenshot = screenshot
        self.kind = kind
        self.files = files
        self.thumbnail = thumbnail
    }

    /// The photo, or the video.
    var main: URL { files[.video] ?? files[.photo] ?? files.values.first! }
    var motion: URL? { files[.pairedVideo] }
    /// "IMG_0102.HEIC", as Photos would name it.
    var name: String { main.lastPathComponent }

    func mediaFacts() -> (main: MediaFacts, motion: Int?) {
        let type = UTType(filenameExtension: main.pathExtension)?.identifier
        return (MediaFacts(bytes: Self.size(main), format: MediaFacts.format(uti: type), width: pixelWidth, height: pixelHeight),
                motion.flatMap(Self.size))
    }

    static func size(_ url: URL) -> Int? { (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize }

    @MainActor func image(size: CGSize?, fast: Bool) async -> UIImage? {
        let edge = size.map { Int(max($0.width, $0.height).rounded(.up)) } ?? max(pixelWidth, pixelHeight)
        return await DemoPictures.image(of: self, maxEdge: fast ? min(edge, 512) : edge, from: main)
    }

    @MainActor func livePhoto(size: CGSize) async -> PHLivePhoto? {
        guard let motion else { return nil }
        return await ItemMedia.PhotoRequest<Unchecked<PHLivePhoto?>>.value(
            cancelled: Unchecked(value: nil), cancel: { PHLivePhoto.cancelRequest(withRequestID: $0) }
        ) { finish in
            PHLivePhoto.request(withResourceFileURLs: [files[.photo] ?? main, motion], placeholderImage: nil, targetSize: size,
                                contentMode: .aspectFit) { photo, info in
                if (info[PHLivePhotoInfoIsDegradedKey] as? Bool) == true, photo != nil { return }
                finish(Unchecked(value: photo))
            }
        }.value
    }

    @MainActor func player() async -> AVPlayer? { AVPlayer(url: main) }
    @MainActor func playerItem() async -> Result<AVPlayerItem, Error> { .success(AVPlayerItem(url: main)) }

}

/// Pictures of the demo's items, decoded off the main thread a couple at a time (so a screen of them
/// never starves the app) and kept for a while.
enum DemoPictures {
    private static let decoding = Limiter(2)
    private static let generation = Mutex(0)
    nonisolated(unsafe) private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 64 << 20
        return cache
    }()

    /// `file`: the item's own (a video's first frame), or its grid picture.
    static func image(of item: DemoItem, maxEdge: Int, from file: URL) async -> UIImage? {
        let mine = generation.withLock { $0 }
        let key = "\(file.path)@\(maxEdge)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let main = file, video = file.pathExtension.uppercased() == "MOV"
        await decoding.acquire()
        defer { Task { await decoding.release() } }
        guard !Task.isCancelled else { return nil }
        let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            let picture: CGImage?
            if video {
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: main))
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: maxEdge, height: maxEdge)
                picture = try? await generator.image(at: .zero).image
            } else if let source = CGImageSourceCreateWithURL(main as CFURL, nil) {
                picture = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true, kCGImageSourceThumbnailMaxPixelSize: maxEdge,
                ] as CFDictionary)
            } else {
                picture = nil
            }
            return picture.map(UIImage.init(cgImage:))
        }.value
        generation.withLock { current in
            if current == mine, let image {
                cache.setObject(image, forKey: key, cost: Int(image.size.width * image.size.height * 4))
            }
        }
        return image
    }

    static func forget() {
        generation.withLock {
            $0 &+= 1
            cache.removeAllObjects()
        }
    }

    /// At most `count` at once; the rest wait their turn.
    actor Limiter {
        private var free: Int
        private var waiting: [CheckedContinuation<Void, Never>] = []
        init(_ count: Int) { free = count }

        func acquire() async {
            if free > 0 {
                free -= 1
                return
            }
            await withCheckedContinuation { waiting.append($0) }
        }

        func release() {
            if waiting.isEmpty { free += 1 } else { waiting.removeFirst().resume() }
        }
    }
}

/// The demo's photo library: the generated photos and cloned videos and Live Photo, and the compact
/// copies the demo makes of them, kept in the demo's folder. It stands in for Photos everywhere
/// (`PhotoSource`, `ItemCatalog`) and never reads or changes the person's own library. Deleting
/// asks with an in-app question that says it's pretend, and removes only from the demo.
final class DemoLibrary: ItemCatalog, Sendable {
    /// A compact copy the demo saved.
    struct Copy: Codable, Equatable, Sendable {
        var id: String
        var original: String
        /// Its files in the library folder, by role.
        var files: [String: String]
        var width: Int
        var height: Int
    }

    struct State: Codable, Equatable, Sendable {
        /// Originals freed up: out of the demo's library, as if in Recently Deleted.
        var removed: Set<String> = []
        var copies: [String: Copy] = [:]
        var made = 0
    }

    /// The question iOS would ask before deleting, answered by the person (or a test).
    struct Question: Sendable, Equatable {
        var title: String
        var message: String
        var confirm: String
    }

    let folder: URL
    let samples: [DemoSample]
    private let media: URL
    private let state: Mutex<State>
    private let observers = Mutex<[UUID: @Sendable () -> Void]>([:])
    private let ask: @Sendable (Question) async -> Bool
    /// Each sample's main file's SHA-256, worked out when first needed.
    private let hashes = Mutex<[String: String]?>(nil)
    private let retired = Mutex(false)
    var isRetired: Bool { retired.withLock { $0 } }

    func retire() { retired.withLock { $0 = true } }

    func whileActive<Value>(_ body: () throws -> Value) throws -> Value {
        try retired.withLock {
            guard !$0 else { throw CancellationError() }
            return try body()
        }
    }

    init(folder: URL, media: URL, ask: @escaping @Sendable (Question) async -> Bool) {
        self.folder = folder
        self.media = media
        self.ask = ask
        samples = DemoSample.load(from: media)
        let decoder = JSONDecoder()
        state = Mutex((try? decoder.decode(State.self, from: Data(contentsOf: folder.appendingPathComponent("library.json")))) ?? State())
    }

    var snapshot: State { state.withLock { $0 } }

    @discardableResult
    private func change(_ body: (inout State) -> Void) -> Bool {
        let changed = retired.withLock { retired -> Bool in
            guard !retired else { return false }
            let saved = state.withLock { state -> State in
                body(&state)
                return state
            }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? JSONEncoder().encode(saved).write(to: folder.appendingPathComponent("library.json"), options: .atomic)
            return true
        }
        if changed { for observer in observers.withLock({ Array($0.values) }) { observer() } }
        return changed
    }

    func observe(_ changed: @escaping @Sendable () -> Void) -> CatalogObservation {
        let id = UUID()
        observers.withLock { $0[id] = changed }
        return CatalogObservation { [weak self] in self?.observers.withLock { $0[id] = nil } }
    }

    // MARK: Items

    private func sample(_ id: String) -> DemoSample? { samples.first { $0.id == id } }

    /// The items in the library now: samples not freed up, and the compact copies.
    private func present(_ state: State) -> [DemoItem] {
        samples.filter { !state.removed.contains($0.id) }.map(item) + state.copies.values.compactMap { item($0) }
    }

    private func item(_ sample: DemoSample) -> DemoItem {
        DemoItem(id: sample.id, created: sample.created, width: sample.width, height: sample.height, duration: sample.seconds ?? 0,
                 favorite: sample.favorite ?? false, screenshot: sample.screenshot ?? false, kind: sample.itemKind,
                 files: sample.urls(in: media), thumbnail: sample.thumbnail.map { media.appendingPathComponent($0) })
    }

    private func item(_ copy: Copy) -> DemoItem? {
        guard let sample = sample(copy.original) else { return nil }
        let files = Dictionary(uniqueKeysWithValues: copy.files.compactMap { role, file in
            ServerAPI.ResourceRole(rawValue: role).map { ($0, folder.appendingPathComponent(file)) }
        })
        return DemoItem(id: copy.id, created: sample.created, width: copy.width, height: copy.height, duration: sample.seconds ?? 0,
                        favorite: sample.favorite ?? false, screenshot: false, kind: sample.itemKind, files: files,
                        thumbnail: sample.thumbnail.map { media.appendingPathComponent($0) })
    }

    func demoItem(_ id: String) -> DemoItem? {
        let state = snapshot
        if let copy = state.copies[id] { return item(copy) }
        guard let sample = sample(id), !state.removed.contains(id) else { return nil }
        return item(sample)
    }

    func isCopy(_ id: String) -> Bool { snapshot.copies[id] != nil }

    /// The bundled compact copy of the sample whose main file has this SHA-256 (the demo's server sends it).
    func bundledCompact(sha256: String) -> [ServerAPI.ResourceRole: URL]? {
        let known = hashes.withLock { cached -> [String: String] in
            if let cached { return cached }
            var found: [String: String] = [:]
            for sample in samples where sample.compact != nil {
                if let main = item(sample).files[sample.itemKind == .video ? .video : .photo],
                   let hash = try? Fingerprint.sha256(of: main) { found[hash] = sample.id }
            }
            cached = found
            return found
        }
        return known[sha256.lowercased()].flatMap(sample)?.compactURLs(in: media)
    }

    // MARK: Changes

    /// Saves a compact copy of `original` from these downloaded files (moved into the library).
    func addCompactCopy(of original: String, files: [ServerAPI.ResourceRole: URL]) async throws -> String {
        guard !isRetired else { throw CancellationError() }
        let number = state.withLock { state -> Int in
            state.made += 1
            return state.made
        }
        let id = "demo-copy:\(original.dropFirst("demo:".count))/\(number)"
        let place = folder.appendingPathComponent("copies/\(number)", isDirectory: true)
        try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
        var names: [String: String] = [:]
        for (role, url) in files {
            let destination = place.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: url, to: destination)
            names[role.rawValue] = "copies/\(number)/\(url.lastPathComponent)"
        }
        let main = place.appendingPathComponent(((files[.video] ?? files[.photo])?.lastPathComponent) ?? "")
        let size = await Self.dimensions(of: main)
        guard change({ $0.copies[id] = Copy(id: id, original: original, files: names, width: size.width, height: size.height) })
        else { throw CancellationError() }
        return id
    }

    /// Brings a freed-up original back (Restore Original); it keeps its identifier.
    func restore(_ original: String) -> String? {
        guard sample(original) != nil else { return nil }
        guard change({ $0.removed.remove(original) }) else { return nil }
        return original
    }

    private static func dimensions(of url: URL) async -> (width: Int, height: Int) {
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int {
            let upright = (properties[kCGImagePropertyOrientation] as? Int ?? 1) >= 5
            return upright ? (height, width) : (width, height)
        }
        guard let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first,
              let (natural, transform) = try? await track.load(.naturalSize, .preferredTransform) else { return (0, 0) }
        let upright = natural.applying(transform)
        return (Int(abs(upright.width).rounded()), Int(abs(upright.height).rounded()))
    }

    // MARK: PhotoSource

    func authorization() -> PHAuthorizationStatus { .authorized }

    func requestAuthorization() async -> PHAuthorizationStatus { .authorized }

    func item(_ id: String) -> (any LibraryItem)? { demoItem(id) }

    func summaries(_ ids: [String]) -> [String: ItemSummary] {
        var found: [String: ItemSummary] = [:]
        for id in ids {
            guard let item = demoItem(id) else { continue }
            found[id] = ItemSummary(created: item.creationDate, kind: item.kind, favorite: item.isFavorite)
        }
        return found
    }

    func describe(_ id: String) -> (name: String, kind: PhotoLibrary.Kind)? {
        demoItem(id).map { ($0.name, $0.kind) }
    }

    func existing(_ ids: [String], includeHidden: Bool) -> Set<String> {
        let present = Set(present(snapshot).map(\.localIdentifier))
        return Set(ids.filter(present.contains))
    }

    func estimatedBytes(_ ids: [String], sample: Int) -> (bytes: Int, exact: Bool) {
        (ids.compactMap(demoItem).reduce(0) { total, item in total + item.files.values.reduce(0) { $0 + (DemoItem.size($1) ?? 0) } }, true)
    }

    func allIdentifiers() -> [String] { contents().ids }

    func albumMembers() -> Set<String> { Set(snapshot.copies.keys) }

    func addToAlbum(_ ids: [String]) async throws {}

    func copyHashes(_ ids: [String]) async -> [String: CopyFinder.Hashed] {
        var hashed: [String: CopyFinder.Hashed] = [:]
        for id in ids {
            guard let item = demoItem(id) else { continue }
            var entry = CopyFinder.Hashed(hashes: [:], bytes: 0)
            for (role, url) in item.files where CopyMatching.roles.contains(role) {
                guard let digests = try? Fingerprint.digests(of: url) else { continue }
                entry.hashes[role] = digests.sha256
                entry.bytes += digests.size
            }
            if !entry.hashes.isEmpty { hashed[id] = entry }
        }
        return hashed
    }

    /// Asks as iOS would (saying it's pretend), then takes the items out of the demo's library. Saying
    /// no throws, as Photos does.
    func delete(_ ids: [String]) async throws {
        guard !isRetired else { throw CancellationError() }
        let items = ids.compactMap(demoItem)
        guard !items.isEmpty else { return }
        guard await ask(Self.question(deleting: items)) else { throw PHPhotosError(.userCancelled) }
        let gone = Set(items.map(\.localIdentifier))
        let changed = change { state in
            for id in gone {
                if let copy = state.copies.removeValue(forKey: id) {
                    for file in copy.files.values { try? FileManager.default.removeItem(at: self.folder.appendingPathComponent(file)) }
                } else {
                    state.removed.insert(id)
                }
                if !changed { throw CancellationError() }
            }
        }
    }

    static func question(deleting items: [DemoItem]) -> Question {
        let videos = items.filter { $0.kind == .video }.count, photos = items.count - videos
        let what = switch (photos, videos) {
        case (_, 0): photos == 1 ? "this photo" : "\(photos) photos"
        case (0, _): videos == 1 ? "this video" : "\(videos) videos"
        default: "\(items.count) items"
        }
        // Worded as the demo's own question (not iOS's), so it never passes for a system alert.
        return Question(title: "Delete \(what)?",
                        message: "This is the demo, so nothing is deleted. With your own photos, iOS asks this before anything "
                            + "is removed, and deleted items stay in Recently Deleted for 30 days.",
                        confirm: "Delete")
    }

    func measure(excluding backedUp: Set<String>) -> LibraryMeasure.Result {
        let state = snapshot
        let items = samples.filter { !state.removed.contains($0.id) }.map(item)
            .sorted { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
        func group(_ kind: PhotoLibrary.Kind) -> FirstTask.Estimate.Group {
            let ids = items.filter { $0.kind == kind }.map(\.localIdentifier)
            return .init(count: ids.count, bytes: Int64(estimatedBytes(ids, sample: 0).bytes))
        }
        let candidates = items.filter { !backedUp.contains($0.localIdentifier) }.map {
            FirstTask.Candidate(id: $0.localIdentifier, isVideo: $0.kind == .video, duration: $0.duration, isScreenshot: $0.isScreenshot)
        }
        return LibraryMeasure.Result(estimate: .init(photos: group(.photo), livePhotos: group(.livePhoto), videos: group(.video)),
                                     candidates: candidates)
    }

    // Automatic mode: the demo's library doesn't change by itself, so there's nothing new to read.

    func changeToken() -> Data? { Data("demo".utf8) }

    func inserted(since token: Data?) -> (ids: Set<String>, read: Bool) { ([], true) }

    func deleted(since token: Data?) -> (ids: Set<String>, read: Bool) { ([], true) }

    func candidates(since: Date, also: [String]) -> [AutomaticCandidate] {
        let wanted = Set(also), state = snapshot
        return samples.filter { !state.removed.contains($0.id) }.map(item)
            .filter { ($0.creationDate ?? .distantPast) >= since || wanted.contains($0.localIdentifier) }
            .map { AutomaticCandidate(id: $0.localIdentifier, created: $0.creationDate, favorite: $0.isFavorite) }
    }

    // MARK: Engines

    func compactor(client: ServerClient, mode: ServerAPI.StorageMode, profile: CompressionProfile,
                   ledger: CompactLedger) -> any Compacting {
        DemoCompactor(client: client, library: self, ledger: ledger)
    }

    func remover(client: ServerClient, mode: ServerAPI.StorageMode, ledger: CompactLedger) -> any RemovingOriginals {
        DemoRemover(client: client, library: self, ledger: ledger)
    }

    func restorer(client: ServerClient, ledger: CompactLedger) -> any RestoringOriginals {
        DemoRestorer(client: client, library: self, ledger: ledger)
    }

    // MARK: ItemCatalog

    func contents() -> LibraryContents {
        let state = snapshot
        let items = present(state).sorted { a, b in
            switch (a.creationDate, b.creationDate) {
            case let (x?, y?) where x != y: x < y
            default: a.localIdentifier < b.localIdentifier
            }
        }
        var contents = LibraryContents()
        contents.ids = items.map(\.localIdentifier)
        for item in items {
            let kind: MediaInfo.Kind = switch item.kind {
            case .photo: .photo
            case .livePhoto: .livePhoto
            case .video: .video
            }
            contents.media[item.localIdentifier] = MediaInfo(kind: kind, seconds: Int32(item.duration.rounded()), created: item.creationDate)
            if let month = LibraryModel.monthKey(item.creationDate) { contents.months[item.localIdentifier] = month }
        }
        contents.album = Set(state.copies.keys)
        return contents
    }

    func thumbnail(_ id: String, side: CGFloat) async -> UIImage? {
        guard let item = demoItem(id) else { return nil }
        // Square cells crop the picture: its short edge fills the side (the grid picture is 360 px across).
        let long = Double(max(item.pixelWidth, item.pixelHeight)), short = Double(max(min(item.pixelWidth, item.pixelHeight), 1))
        let edge = Int((side * long / short).rounded(.up))
        guard let small = item.thumbnail else { return await DemoPictures.image(of: item, maxEdge: edge, from: item.main) }
        return await DemoPictures.image(of: item, maxEdge: min(edge, Int((360 * long / short).rounded())), from: small)
    }
}
