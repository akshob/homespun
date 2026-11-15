// SPDX-License-Identifier: Apache-2.0
import Observation
import Photos
import SwiftUI

/// What a photo in the grid shows about its backup.
enum Badge: Equatable, Sendable {
    /// Only on this iPhone.
    case none
    /// A compact copy; its original is on the server and no longer on this iPhone.
    case backedUp
    /// A compact copy; its original is still on this iPhone (and on the server if `canFree`).
    case originalOnPhone
    /// A Homespun compact copy whose original this iPhone knows nothing more about.
    case compactCopy
    case waiting, working, kept, failed
    /// Backed up; its compact copy comes when it's old enough (automatic mode keeps recent items).
    case copyLater

    /// Stable text for VoiceOver, the badge guide, filters and UI tests (DESIGN §10.2).
    var label: String {
        switch self {
        case .none: "Not backed up"
        case .backedUp: "Original at home"
        case .originalOnPhone: "Ready to free up"
        case .compactCopy: "Compact copy"
        case .waiting: "Waiting"
        case .working: "Backing up"
        case .kept: "Kept as is"
        case .failed: "Needs attention"
        case .copyLater: "Backed up"
        }
    }

    var explanation: String {
        switch self {
        case .none: "Only on this iPhone. Back it up to keep the original at home and a compact copy here."
        case .backedUp: "A compact copy. The full-quality original is at home on your server, not on this iPhone."
        case .originalOnPhone: "Backed up, and the original is still on this iPhone too. Free up space to remove it."
        case .compactCopy: "A Homespun compact copy."
        case .waiting: "Waiting to be backed up."
        case .working: "Being backed up."
        case .kept: "Kept as is: it couldn't be made smaller, so the original stays."
        case .failed: "Something needs your attention. See Activity."
        case .copyLater: "The original is safe at home. Its compact copy comes once it's older, so photos you delete "
            + "before then never come back."
        }
    }

    /// Shapes carry the meaning, not only colour.
    var symbol: String? {
        switch self {
        case .none: nil
        case .backedUp: "checkmark.circle.fill"
        case .originalOnPhone: "circle.lefthalf.filled"
        case .compactCopy: "square.on.square"
        case .waiting: "clock"
        case .working: "arrow.up.circle"
        case .kept: "equal.circle"
        case .failed: "exclamationmark.triangle.fill"
        case .copyLater: "checkmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .backedUp, .copyLater: Theme.BadgeColor.teal
        case .originalOnPhone: Theme.BadgeColor.amber
        case .failed: Theme.BadgeColor.red
        case .working: Theme.BadgeColor.accent
        default: Theme.BadgeColor.grey
        }
    }
}

/// The grid's contents, worked out from the library, the ledger, the Homespun album, and the
/// current job. Pure, so it can be tested without a photo library.
struct LibraryState: Equatable {
    struct Cell: Identifiable, Equatable {
        /// The asset shown: the compact copy when there is one.
        var id: String
        var badge: Badge
        /// The original this compact copy stands for, if known.
        var original: String?
        /// The original is still on this iPhone and its server copy can be checked for removal.
        var canFree: Bool
        /// When automatic mode makes the compact copy of an item backed up without one (`.copyLater`);
        /// nil for a favorite that keeps its original.
        var compactAfter: Date? = nil
    }

    /// The Filter menu's states (DESIGN 02·1.2); its symbols match the badges.
    enum Filter: String, CaseIterable, Identifiable {
        case all, notBackedUp, copyLater, readyToFree, atHome, needsAttention
        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: "All Items"
            case .notBackedUp: "Not Backed Up"
            case .readyToFree: "Ready to Free Up"
            case .atHome: "Original at Home"
            case .needsAttention: "Needs Attention"
            case .copyLater: "Compact Copy Later"
            }
        }

        var symbol: String {
            switch self {
            case .all: "photo.on.rectangle"
            case .notBackedUp: "circle.dashed"
            case .readyToFree: "circle.lefthalf.filled"
            case .atHome: "checkmark.circle.fill"
            case .needsAttention: "exclamationmark.triangle"
            case .copyLater: "checkmark.circle"
            }
        }
    }

    var cells: [Cell] = [] { didSet { reindex() } }
    /// Where each cell is, so a grid cell finds its current state by id.
    private(set) var positions: [String: Int] = [:]

    init(cells: [Cell] = []) {
        self.cells = cells
        reindex()
    }

    func cell(_ id: String) -> Cell? { positions[id].map { cells[$0] } }

    private mutating func reindex() {
        positions = Dictionary(cells.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// `library` in display order (oldest first). An original backed up with a compact copy in
    /// the library is hidden; the copy is shown with a badge saying where the original is. (A
    /// copy made on this iPhone by the old on-phone mode doesn't hide its original, which still
    /// needs backing up.)
    /// `backedUp`: items backed up without a compact copy yet, with when it's due (nil: never, a kept favorite).
    init(library: [String], ledger: [String: CompactLedger.Entry], album: Set<String>, job: [String: CompactJob.State],
         backedUp: [String: Date?] = [:]) {
        let present = Set(library)
        var originalOf: [String: String] = [:]
        var hidden = Set<String>(), unbackedCopies = Set<String>()
        for (original, entry) in ledger where present.contains(entry.compactIdentifier) {
            guard entry.serverAssetID != nil else {
                unbackedCopies.insert(entry.compactIdentifier)
                continue
            }
            originalOf[entry.compactIdentifier] = original
            hidden.insert(original)
        }
        cells = library.compactMap { id in
            guard !hidden.contains(id) else { return nil }
            if let original = originalOf[id] {
                if present.contains(original) {
                    return Cell(id: id, badge: .originalOnPhone, original: original, canFree: true)
                }
                return Cell(id: id, badge: .backedUp, original: original, canFree: false)
            }
            if album.contains(id) || unbackedCopies.contains(id) {
                return Cell(id: id, badge: .compactCopy, original: nil, canFree: false)
            }
            let badge: Badge = switch job[id] {
            case .waiting?: .waiting
            case .working?: .working
            case .failed?: .failed
            case .unchanged?: .kept
            case .notYet?: .none
            case .backedUp?: .copyLater
            case .saved?, nil: backedUp[id] != nil ? .copyLater : .none
            }
            return Cell(id: id, badge: badge, original: nil, canFree: false, compactAfter: backedUp[id] ?? nil)
        }
        reindex()
    }

    func cells(_ filter: Filter) -> [Cell] {
        filter == .all ? cells : cells.filter { $0.matches(filter) }
    }

    func count(_ filter: Filter) -> Int {
        filter == .all ? cells.count : cells.reduce(0) { $0 + ($1.matches(filter) ? 1 : 0) }
    }
}

extension LibraryState.Cell {
    /// Has no copy on the server yet (including items being worked on).
    var isNotBackedUp: Bool {
        switch badge {
        case .none, .waiting, .working, .kept, .failed: true
        case .originalOnPhone: !canFree
        case .backedUp, .compactCopy, .copyLater: false
        }
    }

    /// Can be selected to back up (for an item backed up without a compact copy: to make it now).
    var canCompact: Bool { [.none, .kept, .failed, .copyLater].contains(badge) }

    func matches(_ filter: LibraryState.Filter) -> Bool {
        switch filter {
        case .all: true
        case .notBackedUp: isNotBackedUp && badge != .failed
        case .readyToFree: canFree
        case .atHome: badge == .backedUp
        case .needsAttention: badge == .failed
        case .copyLater: badge == .copyLater
        }
    }
}

/// Every photo and video in the library, oldest first like Photos, kept up to date. Photos
/// changes are applied incrementally where PhotoKit allows, so large libraries stay smooth.
@MainActor @Observable
final class LibraryModel: NSObject, PHPhotoLibraryChangeObserver {
    private(set) var state = LibraryState()
    private(set) var count = 0
    private var assets: PHFetchResult<PHAsset>?
    private var albumAssets: PHFetchResult<PHAsset>?
    private var index: [String: Int] = [:]
    private var library: [String] = []
    private var album = Set<String>()
    private var observing = false
    private var pendingNotice: Task<Void, Never>?
    let thumbnails = PHCachingImageManager()

    /// Set by the screen to recompute badges after the library changed.
    var onChange: (@MainActor () -> Void)?

    func asset(_ id: String) -> PHAsset? {
        guard let assets, let position = index[id], position < assets.count else { return nil }
        return assets.object(at: position)
    }

    /// Reads the whole library (at launch, or when access changes).
    func reload() {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite).allowsReading else {
            assets = nil
            albumAssets = nil
            library = []
            index = [:]
            album = []
            count = 0
            return
        }
        if !observing {
            PHPhotoLibrary.shared().register(self)
            observing = true
        }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        options.predicate = NSPredicate(format: "mediaType == %d OR mediaType == %d",
                                        PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        let fetched = PHAsset.fetchAssets(with: options)
        setAssets(fetched, ids: nil)
        readMonths(fetched)
        albumAssets = PhotoLibrary.albumAssets()
        album = Set(Self.identifiers(albumAssets))
    }

    /// Works out the badges again (after the ledger or the job changed).
    func update(ledger: [String: CompactLedger.Entry], job: [String: CompactJob.State], backedUp: [String: Date?] = [:]) {
        let new = LibraryState(library: library, ledger: ledger, album: album, job: job, backedUp: backedUp)
        if new != state { state = new }
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in self.apply(changeInstance) }
    }

    private func apply(_ change: PHChange) {
        var changed = false
        if let assets, let details = change.changeDetails(for: assets) {
            setAssets(details.fetchResultAfterChanges, ids: Self.applying(details, to: library))
            if details.hasIncrementalChanges {
                for asset in details.insertedObjects + details.changedObjects {
                    months[asset.localIdentifier] = Self.monthKey(asset.creationDate)
                }
                monthsVersion += 1
            } else {
                readMonths(details.fetchResultAfterChanges)
            }
            changed = true
        }
        if let albumAssets, let details = change.changeDetails(for: albumAssets) {
            self.albumAssets = details.fetchResultAfterChanges
            if details.hasIncrementalChanges {
                album.subtract(details.removedObjects.map(\.localIdentifier))
                album.formUnion(details.insertedObjects.map(\.localIdentifier))
            } else {
                album = Set(Self.identifiers(details.fetchResultAfterChanges))
            }
            changed = true
        } else if albumAssets == nil, changed, let created = PhotoLibrary.albumAssets() {
            // The album was just created by the first import.
            albumAssets = created
            album = Set(Self.identifiers(created))
        }
        guard changed else { return }
        // A batch of imports or removals sends many changes; recompute badges once for them.
        pendingNotice?.cancel()
        pendingNotice = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            onChange?()
        }
    }

    /// Photos, videos or Live Photos only (the Filter menu's second part).
    enum Media: String, CaseIterable, Identifiable {
        case all, photos, videos, livePhotos
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: "Photos and Videos"
            case .photos: "Photos"
            case .videos: "Videos"
            case .livePhotos: "Live Photos"
            }
        }
        var symbol: String {
            switch self {
            case .all: "square.grid.2x2"
            case .photos: "photo"
            case .videos: "video"
            case .livePhotos: "livephoto"
            }
        }
    }

    @ObservationIgnored private var mediaCache: [Media: Set<String>] = [:]
    /// Each item's capture month (year × 12 + month - 1), read in the background after a reload.
    @ObservationIgnored private var months: [String: Int] = [:]
    /// Bumped when `months` changes, so the grid regroups.
    private(set) var monthsVersion = 0

    func month(of id: String) -> Int? { months[id] }

    nonisolated static func monthKey(_ date: Date?) -> Int? {
        guard let date else { return nil }
        let parts = Calendar.current.dateComponents([.year, .month], from: date)
        guard let year = parts.year, let month = parts.month else { return nil }
        return year * 12 + month - 1
    }

    private struct FetchBox: @unchecked Sendable { let result: PHFetchResult<PHAsset> }

    private func readMonths(_ fetched: PHFetchResult<PHAsset>) {
        let box = FetchBox(result: fetched)
        Task {
            let found = await Task.detached(priority: .utility) {
                var found: [String: Int] = [:]
                found.reserveCapacity(box.result.count)
                box.result.enumerateObjects { asset, _, _ in
                    if let key = LibraryModel.monthKey(asset.creationDate) { found[asset.localIdentifier] = key }
                }
                return found
            }.value
            months = found
            monthsVersion += 1
        }
    }

    /// Items created after a date (for "new since the last backup").
    func identifiers(createdAfter date: Date) -> Set<String> {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "creationDate > %@", date as NSDate)
        return Set(Self.identifiers(PHAsset.fetchAssets(with: options)))
    }

    /// The items of one kind, read once and kept until the library changes.
    func identifiers(_ media: Media) -> Set<String>? {
        guard media != .all else { return nil }
        if let cached = mediaCache[media] { return cached }
        let options = PHFetchOptions()
        options.predicate = switch media {
        case .videos: NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
        case .livePhotos: NSPredicate(format: "mediaType == %d AND (mediaSubtypes & %d) != 0", PHAssetMediaType.image.rawValue,
                                      PHAssetMediaSubtype.photoLive.rawValue)
        default: NSPredicate(format: "mediaType == %d AND (mediaSubtypes & %d) == 0", PHAssetMediaType.image.rawValue,
                             PHAssetMediaSubtype.photoLive.rawValue)
        }
        let found = Set(Self.identifiers(PHAsset.fetchAssets(with: options)))
        mediaCache[media] = found
        return found
    }

    private func setAssets(_ fetched: PHFetchResult<PHAsset>, ids: [String]?) {
        let ids = ids ?? Self.identifiers(fetched)
        mediaCache = [:]
        assets = fetched
        library = ids
        index = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        count = ids.count
    }

    /// The identifiers after an incremental change, or `nil` to read them all again.
    private static func applying(_ details: PHFetchResultChangeDetails<PHAsset>, to ids: [String]) -> [String]? {
        guard details.hasIncrementalChanges, !details.hasMoves else { return nil }
        let after = details.fetchResultAfterChanges
        var result = ids
        if let removed = details.removedIndexes, !removed.isEmpty {
            result = result.enumerated().filter { !removed.contains($0.offset) }.map(\.element)
        }
        if let inserted = details.insertedIndexes, !inserted.isEmpty {
            guard inserted.count < 500 else { return nil }
            for position in inserted {
                guard position <= result.count else { return nil }
                result.insert(after.object(at: position).localIdentifier, at: position)
            }
        }
        return result.count == after.count ? result : nil
    }

    private static func identifiers(_ fetched: PHFetchResult<PHAsset>?) -> [String] {
        var ids: [String] = []
        ids.reserveCapacity(fetched?.count ?? 0)
        fetched?.enumerateObjects { asset, _, _ in ids.append(asset.localIdentifier) }
        return ids
    }
}

extension PHAuthorizationStatus {
    var allowsReading: Bool { self == .authorized || self == .limited }
}

/// One photo in the grid: thumbnail, badge, selection, and video length or Live Photo mark.
/// Select mode and what's selected. Cells read it themselves, so a change redraws them directly:
/// a lazy grid doesn't reliably rebuild cells when a value passed down to them changes.
@MainActor @Observable
final class GridSelection {
    var active = false
    var ids = Set<String>()
}

struct GridCell: View {
    /// What the grid had when it laid this cell out; the cell reads its current state from `library`
    /// itself, so a new badge shows at once (a lazy grid doesn't reliably rebuild a cell when a
    /// value passed down to it changes).
    let initial: LibraryState.Cell
    let library: LibraryModel
    let selection: GridSelection
    var serverName = "your server"
    @State private var image: UIImage?
    @State private var request: PHImageRequestID?
    @Environment(\.dynamicTypeSize) private var typeSize

    private var cell: LibraryState.Cell { library.state.cell(initial.id) ?? initial }
    private var asset: PHAsset? { library.asset(initial.id) }
    private var manager: PHCachingImageManager { library.thumbnails }
    private var selecting: Bool { selection.active }
    private var selected: Bool { selection.active && selection.ids.contains(initial.id) }

    var body: some View {
        let selected = selected
        return Theme.fill
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
            .clipped()
            .overlay(alignment: .bottomLeading) { mediaMark }
            .overlay(alignment: .topTrailing) { BadgeView(badge: cell.badge, size: typeSize.isAccessibilitySize ? 28 : 20).padding(6) }
            .overlay { if selected { Color.white.opacity(0.2) } }
            .overlay(alignment: .bottomTrailing) { if selecting { selectionMark(selected).padding(6) } }
            .contentShape(Rectangle())
            .onAppear(perform: load)
            .onDisappear {
                if let request { manager.cancelImageRequest(request) }
                request = nil
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityName)
            .accessibilityValue(cell.badge.spoken(server: serverName, compactAfter: cell.compactAfter))
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityIdentifier("asset")
    }

    @ViewBuilder private func selectionMark(_ selected: Bool) -> some View {
        if selected {
            Image(systemName: "checkmark.circle.fill").symbolRenderingMode(.palette)
                .foregroundStyle(.white, Theme.BadgeColor.accent).font(.title3)
                .background(Circle().fill(.white).padding(2))
        } else if cell.canCompact || cell.canFree {
            Circle().strokeBorder(.white, lineWidth: 1.5).frame(width: 22, height: 22).shadow(radius: 1)
        }
    }

    @ViewBuilder private var mediaMark: some View {
        if let asset {
            if asset.mediaType == .video {
                Text(Duration.seconds(asset.duration.rounded()).formatted(.time(pattern: .minuteSecond)))
                    .font(.caption2.weight(.semibold)).foregroundStyle(.white).shadow(radius: 2)
                    .padding(4)
            } else if asset.mediaSubtypes.contains(.photoLive) {
                Image(systemName: "livephoto").font(.caption2).foregroundStyle(.white).shadow(radius: 2).padding(4)
            }
        }
    }

    private var accessibilityName: String {
        guard let asset else { return "Item" }
        let kind = asset.mediaType == .video ? "Video" : asset.mediaSubtypes.contains(.photoLive) ? "Live Photo" : "Photo"
        guard let date = asset.creationDate else { return kind }
        return "\(kind), \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    private func load() {
        guard image == nil, request == nil, let asset else { return }
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        let side = 120 * UIScreen.main.scale
        request = manager.requestImage(for: asset, targetSize: CGSize(width: side, height: side),
                                       contentMode: .aspectFill, options: options) { result, _ in
            MainActor.assumeIsolated { if let result { image = result } }
        }
    }
}

/// A badge on a white halo: palette symbols that differ by shape, so meaning never rests on colour.
struct BadgeView: View {
    let badge: Badge
    var size: CGFloat = 20

    var body: some View {
        if badge == .working {
            ProgressView().controlSize(.mini).tint(Theme.BadgeColor.accent)
                .frame(width: size, height: size).background(Circle().fill(.white))
                .shadow(color: .black.opacity(0.25), radius: 1)
        } else if let symbol = badge.symbol {
            Image(systemName: symbol)
                .symbolRenderingMode(.palette)
                .foregroundStyle(badge.color, badge.color.opacity(0.25))
                .font(.system(size: size * 0.8, weight: .semibold))
                .frame(width: size, height: size)
                .background(Circle().fill(.white).padding(-1.5))
                .shadow(color: .black.opacity(0.25), radius: 1)
                .contentTransition(.symbolEffect(.replace))
        }
    }
}

extension Badge {
    /// The cell's VoiceOver value: the badge plus where the original is (DESIGN §10.2).
    func spoken(server: String, compactAfter: Date? = nil) -> String {
        switch self {
        case .originalOnPhone: "Ready to free up. Original on \(server)."
        case .backedUp: "Original at home on \(server)."
        case .copyLater: "Backed up. Original on \(server); " + Self.compactLater(compactAfter) + "."
        default: label
        }
    }

    /// "compact copy after December 15", or for a kept favorite, "favorites keep their original".
    static func compactLater(_ date: Date?) -> String {
        guard let date else { return "favorites keep their original" }
        return date <= Date() ? "compact copy on the next run"
            : "compact copy after " + date.formatted(.dateTime.month(.wide).day())
    }
}

/// What each badge means.
struct BadgeLegendView: View {
    var serverName = "your server"
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach([Badge.none, .copyLater, .originalOnPhone, .backedUp, .waiting, .working, .failed, .kept, .compactCopy],
                        id: \.label) { badge in
                    HStack(alignment: .top, spacing: 14) {
                        Group {
                            if badge == .none {
                                Circle().stroke(.secondary, style: StrokeStyle(lineWidth: 1, dash: [3])).frame(width: 24, height: 24)
                            } else {
                                BadgeView(badge: badge, size: 24)
                            }
                        }
                        .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(badge.label).font(.headline)
                            Text(badge.explanation).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .navigationTitle("Badges")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

extension String {
    /// The same text with its first letter capitalised ("compact copy…" → "Compact copy…").
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
