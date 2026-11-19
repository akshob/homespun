// SPDX-License-Identifier: Apache-2.0
import AVFoundation
import HomespunCore
import Photos
import UIKit
@testable import Homespun

final class FixtureItem: Homespun.LibraryItem, @unchecked Sendable {
    let localIdentifier: String
    let creationDate: Date?
    let pixelWidth: Int
    let pixelHeight: Int
    let duration: TimeInterval
    let isFavorite: Bool
    let isHidden = false
    let isEdited = false
    let itemKind: PhotoLibrary.Kind?
    let poster: UIImage
    let number: Int
    let isCompact: Bool

    init(id: String, number: Int, date: Date, kind: PhotoLibrary.Kind, compact: Bool, poster: UIImage) {
        localIdentifier = id
        self.number = number
        creationDate = date
        itemKind = kind
        isCompact = compact
        pixelWidth = kind == .video ? (compact ? 1280 : 1920) : (compact ? 2048 : 4032)
        pixelHeight = kind == .video ? (compact ? 720 : 1080) : (compact ? 1536 : 3024)
        duration = kind == .video ? TimeInterval(30 + number % 130) : 0
        isFavorite = number.isMultiple(of: 9)
        self.poster = poster
    }

    func mediaFacts() -> (main: MediaFacts, motion: Int?) {
        (MediaFacts(bytes: isCompact ? 2_300_000 : 12_400_000, format: itemKind == .video ? "MOV" : "JPEG",
                    width: pixelWidth, height: pixelHeight), itemKind == .livePhoto ? 900_000 : nil)
    }
    @MainActor func image(size: CGSize?, fast: Bool) async -> UIImage? { poster }
    @MainActor func livePhoto(size: CGSize) async -> PHLivePhoto? { nil }
    @MainActor func playerItem() async -> Result<AVPlayerItem, Error> {
        .failure(SnapshotFailure("Snapshot videos use their synthetic poster frame"))
    }
    @MainActor func player() async -> AVPlayer? { nil }
}

final class FixtureCatalog: ItemCatalog, @unchecked Sendable {
    static let ready = [72, 73, 74, 75, 91]
    static let freed = 92
    static func original(_ number: Int) -> String { String(format: "original-%03d", number) }
    static func compact(_ number: Int) -> String { String(format: "compact-%03d", number) }

    let items: [String: FixtureItem]
    let visible: [String]
    private let access: PHAuthorizationStatus
    @MainActor private static var posters: [String: UIImage] = [:]

    @MainActor init(count: Int = 96, access: PHAuthorizationStatus = .authorized) {
        self.access = access
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let beginning = calendar.date(from: DateComponents(year: 2025, month: 1, day: 1, hour: 10))!
        var items: [String: FixtureItem] = [:], visible: [String] = []
        for number in 0..<count {
            let month = min(17, number / 4)
            let hour = number < 68 ? number % 4 : number - 68
            let date = calendar.date(byAdding: .hour, value: hour * 3,
                                     to: calendar.date(byAdding: .month, value: month, to: beginning)!)!
            let kind: PhotoLibrary.Kind = number % 5 == 0 ? .video : number % 5 == 1 ? .livePhoto : .photo
            let id = Self.original(number)
            items[id] = FixtureItem(id: id, number: number, date: date, kind: kind, compact: false,
                                     poster: Self.poster(number, kind: kind, compact: false))
            if number != Self.freed { visible.append(id) }
            if Self.ready.contains(number) || number == Self.freed {
                let id = Self.compact(number)
                items[id] = FixtureItem(id: id, number: number, date: date, kind: kind, compact: true,
                                         poster: Self.poster(number, kind: kind, compact: true))
                visible.append(id)
            }
        }
        self.items = items
        self.visible = visible.sorted {
            let a = items[$0]!, b = items[$1]!
            if a.creationDate != b.creationDate { return a.creationDate! < b.creationDate! }
            return a.localIdentifier < b.localIdentifier
        }
    }

    func contents() -> LibraryContents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var contents = LibraryContents()
        contents.ids = visible
        for id in visible {
            guard let item = items[id], let date = item.creationDate else { continue }
            let parts = calendar.dateComponents([.year, .month], from: date)
            contents.months[id] = (parts.year ?? 0) * 12 + (parts.month ?? 1) - 1
            let kind: MediaInfo.Kind = item.itemKind == .video ? .video : item.itemKind == .livePhoto ? .livePhoto : .photo
            contents.media[id] = MediaInfo(kind: kind, seconds: Int32(item.duration), created: date)
            if item.isCompact { contents.album.insert(id) }
        }
        return contents
    }

    func thumbnail(_ id: String, side: CGFloat) async -> UIImage? { items[id]?.poster }
    func observe(_ changed: @escaping @Sendable () -> Void) {}
    func authorization() -> PHAuthorizationStatus { access }
    func requestAuthorization() async -> PHAuthorizationStatus { access }
    func item(_ id: String) -> (any Homespun.LibraryItem)? { visible.contains(id) ? items[id] : nil }
    func summaries(_ ids: [String]) -> [String: ItemSummary] {
        Dictionary(uniqueKeysWithValues: ids.compactMap { id in
            guard visible.contains(id), let item = items[id] else { return nil }
            return (id, ItemSummary(created: item.creationDate, kind: item.itemKind, favorite: item.isFavorite))
        })
    }
    func describe(_ id: String) -> (name: String, kind: PhotoLibrary.Kind)? {
        guard let item = items[id], let kind = item.itemKind else { return nil }
        return (String(format: "Sample_%03d.%@", item.number, kind == .video ? "MOV" : "JPG"), kind)
    }
    func existing(_ ids: [String], includeHidden: Bool) -> Set<String> { Set(ids).intersection(visible) }
    func estimatedBytes(_ ids: [String], sample: Int) -> (bytes: Int, exact: Bool) {
        (ids.compactMap { items[$0]?.mediaFacts().main.bytes }.reduce(0, +), true)
    }
    func allIdentifiers() -> [String] { visible }
    func albumMembers() -> Set<String> { Set(visible.filter { items[$0]?.isCompact == true }) }
    func addToAlbum(_ ids: [String]) async throws { throw SnapshotFailure("Snapshot library is read-only") }
    func copyHashes(_ ids: [String]) async -> [String: CopyFinder.Hashed] { [:] }
    func delete(_ ids: [String]) async throws { throw SnapshotFailure("Snapshot library is read-only") }
    func changeToken() -> Data? { nil }
    func inserted(since token: Data?) -> (ids: Set<String>, read: Bool) { ([], true) }
    func deleted(since token: Data?) -> (ids: Set<String>, read: Bool) { ([], true) }
    func candidates(since: Date, also: [String]) -> [AutomaticCandidate] { [] }

    func measure(excluding backedUp: Set<String>) -> LibraryMeasure.Result {
        let summaries = summaries(visible.filter { !backedUp.contains($0) && items[$0]?.isCompact != true })
        func group(_ kind: PhotoLibrary.Kind) -> FirstTask.Estimate.Group {
            let count = summaries.values.count { $0.kind == kind }
            return .init(count: count, bytes: Int64(count) * 12_400_000)
        }
        return .init(estimate: .init(photos: group(.photo), livePhotos: group(.livePhoto), videos: group(.video)),
                     candidates: visible.compactMap { id in
                         guard let item = items[id], summaries[id] != nil else { return nil }
                         return .init(id: id, isVideo: item.itemKind == .video, duration: item.duration, isScreenshot: false)
                     })
    }

    func compactor(client: ServerClient, mode: ServerAPI.StorageMode, profile: CompressionProfile,
                   ledger: CompactLedger) -> any Compacting { DisabledCompactor() }
    func remover(client: ServerClient, mode: ServerAPI.StorageMode, ledger: CompactLedger) -> any RemovingOriginals {
        FixtureRemover(catalog: self, ledger: ledger)
    }
    func restorer(client: ServerClient, ledger: CompactLedger) -> any RestoringOriginals { DisabledRestorer() }

    @MainActor private static func poster(_ number: Int, kind: PhotoLibrary.Kind, compact: Bool) -> UIImage {
        let key = "\(number)-\(compact)"
        if let image = posters[key] { return image }
        let colors: [(CGFloat, CGFloat, CGFloat)] = [
            (0.18, 0.43, 0.65), (0.25, 0.56, 0.42), (0.62, 0.35, 0.37), (0.60, 0.46, 0.22),
            (0.42, 0.38, 0.64), (0.23, 0.52, 0.57),
        ]
        let color = colors[number % colors.count], factor: CGFloat = compact ? 0.88 : 1
        let size = CGSize(width: 240, height: kind == .video ? 135 : 180)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(red: color.0 * factor, green: color.1 * factor, blue: color.2 * factor, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let text = "\(number + 1)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 48, weight: .bold), .foregroundColor: UIColor.white,
            ]
            let measured = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: (size.width - measured.width) / 2, y: (size.height - measured.height) / 2),
                      withAttributes: attributes)
        }
        posters[key] = image
        return image
    }

    private struct DisabledCompactor: Compacting {
        func compact(_ id: String, compactNow: Bool, progress: @escaping @Sendable (String) -> Void) async throws -> CompactOutcome {
            throw SnapshotFailure("Snapshot library does not run backup jobs")
        }
    }

    private struct FixtureRemover: RemovingOriginals {
        let catalog: FixtureCatalog
        let ledger: CompactLedger
        func candidates(only: Set<String>?) async -> [(original: String, entry: CompactLedger.Entry)] {
            await ledger.serverBacked().filter {
                catalog.item($0.original) != nil && (only?.contains($0.original) ?? true)
            }.sorted { $0.original < $1.original }
        }
        func removeEligible(limit: Int?, only: Set<String>?,
                            progress: @escaping @Sendable (String) -> Void) async throws -> OriginalRemover.Report {
            throw SnapshotFailure("Snapshot library never removes originals")
        }
    }

    private struct DisabledRestorer: RestoringOriginals {
        func restore(_ items: [OriginalRestorer.Item],
                     progress: @escaping @Sendable (OriginalRestorer.Progress) -> Void) async -> OriginalRestorer.Report {
            .init(problems: ["Snapshot library never restores files"])
        }
    }
}
