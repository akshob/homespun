// SPDX-License-Identifier: Apache-2.0
import Observation
import HomespunCore
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
    case waiting, working, kept, failed, processing, recovery
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
        case .processing: "Compact copy in progress"
        case .recovery: "Backup needs recovery"
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
        case .kept: "Kept as is: the original stays on this iPhone. See Details for why."
        case .failed: "Something needs your attention. See Activity."
        case .processing: "The original is backed up. Its compact copy is being made on your server or saved to this iPhone."
        case .recovery: "Reconnect the known original server or recover the earlier mapping. This item is not ready to remove."
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
        case .processing: "gearshape.2"
        case .recovery: "questionmark.folder"
        case .copyLater: "checkmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .backedUp, .copyLater, .processing: Theme.BadgeColor.teal
        case .recovery: Theme.BadgeColor.amber
        case .originalOnPhone: Theme.BadgeColor.amber
        case .failed: Theme.BadgeColor.red
        case .working: Theme.BadgeColor.accent
        default: Theme.BadgeColor.grey
        }
    }
}

/// The grid's contents, worked out from the library, the ledger, the Homespun album, and the
/// current job. Pure and `Sendable`, so it's built off the main thread and tested without a photo
/// library. Counts per filter are kept with it (the views read them often; 35,000 cells are too
/// many to count on every redraw).
struct LibraryState: Equatable, Sendable {
    struct Cell: Identifiable, Equatable, Sendable {
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
        var serverName: String? = nil
        var serverOrigin: BackupAPI.Origin? = nil
    }

    /// The Filter menu's states (DESIGN 02·1.2); its symbols match the badges.
    enum Filter: String, CaseIterable, Identifiable, Sendable {
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

    private(set) var cells: [Cell] = []
    /// Where each cell is, so a grid cell finds its current state by id.
    private(set) var positions: [String: Int] = [:]
    private var counts: [Filter: Int] = [:]
    /// Items backed up without a compact copy yet, with when it's due (kept for job updates).
    private var backedUp: [String: Date?] = [:]
    private var compactInProgress = Set<String>()
    /// Changes whenever the cells do, so views can tell states apart without comparing every cell.
    private(set) var version = 0

    init(cells: [Cell] = []) {
        self.cells = cells
        reindex()
    }

    func cell(_ id: String) -> Cell? { positions[id].map { cells[$0] } }

    private mutating func reindex() {
        var positions: [String: Int] = [:]
        positions.reserveCapacity(cells.count)
        var counts: [Filter: Int] = [:]
        for (index, cell) in cells.enumerated() {
            if positions[cell.id] == nil { positions[cell.id] = index }
            for filter in Filter.allCases where filter != .all && cell.matches(filter) { counts[filter, default: 0] += 1 }
        }
        counts[.all] = cells.count
        self.positions = positions
        self.counts = counts
    }

    static func == (lhs: LibraryState, rhs: LibraryState) -> Bool { lhs.cells == rhs.cells }

    /// `library` in display order (oldest first). An original backed up with a compact copy in
    /// the library is hidden; the copy is shown with a badge saying where the original is. (A
    /// copy made on this iPhone by the old on-phone mode doesn't hide its original, which still
    /// needs backing up.)
    /// `backedUp`: items backed up without a compact copy yet, with when it's due (nil: never, a kept favorite).
    init(library: [String], ledger: [String: CompactLedger.Entry], album: Set<String>, job: [String: CompactJob.State],
         backedUp: [String: Date?] = [:], origin: BackupAPI.Origin? = nil, recovering: Set<String> = [],
         pendingImports: Set<String> = [], compactInProgress: Set<String> = []) {
        let present = Set(library)
        var originalOf: [String: String] = [:]
        var records: [String: CompactLedger.Entry] = [:]
        var hidden = Set<String>(), unbackedCopies = Set<String>()
        for (original, entry) in ledger where present.contains(entry.compactIdentifier) {
            guard entry.serverAssetID != nil else {
                unbackedCopies.insert(entry.compactIdentifier)
                continue
            }
            originalOf[entry.compactIdentifier] = original
            records[entry.compactIdentifier] = entry
            hidden.insert(original)
        }
        var cells: [Cell] = []
        cells.reserveCapacity(library.count)
        for id in library where !hidden.contains(id) {
            // Keep the original in place while this process verifies its newly created copy.
            if pendingImports.contains(id), originalOf[id] == nil { continue }
            if let original = originalOf[id] {
                let entry = records[id]!
                let accessible = entry.verifiedCompact && origin != nil && entry.origin == origin
                cells.append(Cell(id: id, badge: accessible ? (present.contains(original) ? .originalOnPhone : .backedUp) : .recovery,
                                  original: original, canFree: accessible && present.contains(original),
                                  serverName: entry.serverName, serverOrigin: entry.origin))
            } else if album.contains(id) || unbackedCopies.contains(id) {
                cells.append(Cell(id: id, badge: .compactCopy, original: nil, canFree: false))
            } else {
                let badge = recovering.contains(id) && job[id]?.isOpen != true ? Badge.recovery
                    : Self.badge(job: job[id], backedUp: backedUp[id] != nil, inProgress: compactInProgress.contains(id))
                cells.append(Cell(id: id, badge: badge, original: nil,
                                  canFree: false, compactAfter: backedUp[id] ?? nil))
            }
        }
        self.cells = cells
        self.backedUp = backedUp
        self.compactInProgress = compactInProgress
        reindex()
    }

    /// The badge of an item with no compact copy, from the job and whether it's backed up.
    static func badge(job: CompactJob.State?, backedUp: Bool, inProgress: Bool = false) -> Badge {
        switch job {
        case .waiting?: .waiting
        case .working?: inProgress ? .processing : .working
        case .failed?: .failed
        case .unchanged?: .kept
        case .notYet?: .none
        case .backedUp?: .copyLater
        case .processing?: .processing
        case .saved?, nil: backedUp ? .copyLater : .none
        }
    }

    /// Applies job changes to the cells they concern (nil: the item left the job), keeping the
    /// counts. Items whose badge comes from a compact copy aren't the job's to change.
    @discardableResult
    mutating func apply(job changes: [String: CompactJob.State?], compactInProgress: Set<String>? = nil) -> [String] {
        if let compactInProgress { self.compactInProgress = compactInProgress }
        var changed: [String] = []
        for (id, state) in changes {
            // The ledger rebuild that follows replaces a saved item with its compact copy.
            if case .saved? = state { continue }
            guard let index = positions[id] else { continue }
            let cell = cells[index]
            guard cell.original == nil, cell.badge != .compactCopy else { continue }
            let badge = Self.badge(job: state, backedUp: backedUp[id] != nil, inProgress: self.compactInProgress.contains(id))
            guard badge != cell.badge else { continue }
            for filter in Filter.allCases where filter != .all && cell.matches(filter) { counts[filter, default: 0] -= 1 }
            cells[index].badge = badge
            for filter in Filter.allCases where filter != .all && cells[index].matches(filter) { counts[filter, default: 0] += 1 }
            changed.append(id)
        }
        if !changed.isEmpty { version &+= 1 }
        return changed
    }

    /// Includes removed originals as well as their newly shown compact copies.
    func changedIDs(from previous: LibraryState) -> Set<String>? {
        guard !previous.cells.isEmpty else { return nil }
        var changed = Set<String>()
        for cell in cells where previous.cell(cell.id) != cell {
            changed.insert(cell.id)
            if changed.count > 500 { return nil }
        }
        for cell in previous.cells where positions[cell.id] == nil {
            changed.insert(cell.id)
            if changed.count > 500 { return nil }
        }
        return changed
    }

    /// Takes the version of the state it replaces plus one, so a view keyed on it always updates.
    mutating func follow(_ previous: LibraryState) { version = previous.version &+ 1 }

    func cells(_ filter: Filter) -> [Cell] {
        filter == .all ? cells : cells.filter { $0.matches(filter) }
    }

    func count(_ filter: Filter) -> Int { counts[filter] ?? 0 }
}

extension LibraryState.Cell {
    /// A compact copy whose original is at home and not on this iPhone: Restore Original brings it back.
    var canRestore: Bool { badge == .backedUp }

    /// Has no copy on the server yet (including items being worked on).
    var isNotBackedUp: Bool {
        switch badge {
        case .none, .waiting, .working, .kept, .failed: true
        case .originalOnPhone: !canFree
        case .backedUp, .compactCopy, .copyLater, .processing, .recovery: false
        }
    }

    /// Can be selected to back up (for an item backed up without a compact copy: to make it now).
    var canCompact: Bool { [.none, .kept, .failed, .copyLater].contains(badge) || badge == .recovery && original == nil }

    func matches(_ filter: LibraryState.Filter) -> Bool {
        switch filter {
        case .all: true
        case .notBackedUp: isNotBackedUp && badge != .failed
        case .readyToFree: canFree
        case .atHome: badge == .backedUp
        case .needsAttention: badge == .failed || badge == .recovery
        case .copyLater: badge == .copyLater
        }
    }
}

/// What a grid cell says about its item besides the thumbnail (its kind, a video's length, the date
/// VoiceOver reads), read with the library in the background so cells never ask PhotoKit while
/// scrolling.
struct MediaInfo: Sendable, Equatable {
    enum Kind: UInt8, Sendable { case photo, livePhoto, video }
    var kind: Kind
    /// A video's length in whole seconds.
    var seconds: Int32
    var created: Date?

    init(kind: Kind, seconds: Int32, created: Date?) {
        self.kind = kind
        self.seconds = seconds
        self.created = created
    }

    init(_ asset: PHAsset) {
        kind = asset.mediaType == .video ? .video : asset.mediaSubtypes.contains(.photoLive) ? .livePhoto : .photo
        seconds = kind == .video ? Int32(clamping: Int(asset.duration.rounded())) : 0
        created = asset.creationDate
    }
}

/// What the grid needs of the whole library (each item's identifier in order, month and media info),
/// kept on disk so the next launch shows the grid at once instead of after reading every item from
/// Photos (a second or more for 35,000). Checked against Photos' count and a few identifiers before
/// use, then confirmed by a full read in the background.
struct LibrarySnapshot: Sendable, Equatable {
    var ids: [String]
    var months: [String: Int]
    var media: [String: MediaInfo]

    static let url = URL.cachesDirectory.appendingPathComponent("Homespun/library-snapshot.plist")

    /// Whether this is the fetch's contents, as far as a few spot checks can tell.
    func matches(_ fetched: PHFetchResult<PHAsset>) -> Bool {
        guard fetched.count == ids.count else { return false }
        guard !ids.isEmpty else { return true }
        return Set([0, ids.count / 4, ids.count / 2, ids.count * 3 / 4, ids.count - 1]).allSatisfy {
            fetched.object(at: $0).localIdentifier == ids[$0]
        }
    }

    func write(to url: URL = Self.url) throws {
        var months: [Int32] = [], kinds: [UInt8] = [], seconds: [Int32] = [], created: [Double] = []
        months.reserveCapacity(ids.count)
        kinds.reserveCapacity(ids.count)
        seconds.reserveCapacity(ids.count)
        created.reserveCapacity(ids.count)
        for id in ids {
            months.append(self.months[id].map { Int32(clamping: $0) } ?? -1)
            let info = media[id]
            kinds.append(info?.kind.rawValue ?? .max)
            seconds.append(info?.seconds ?? 0)
            created.append(info?.created?.timeIntervalSinceReferenceDate ?? .nan)
        }
        let plist: [String: Any] = [
            "version": 1, "ids": Data(ids.joined(separator: "\n").utf8), "months": Self.bytes(months),
            "kinds": Data(kinds), "seconds": Self.bytes(seconds), "created": Self.bytes(created),
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    static func read(from url: URL = Self.url) -> LibrarySnapshot? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              plist["version"] as? Int == 1, let joined = plist["ids"] as? Data,
              let monthData = plist["months"] as? Data, let kindData = plist["kinds"] as? Data,
              let secondData = plist["seconds"] as? Data, let createdData = plist["created"] as? Data else { return nil }
        let ids = joined.isEmpty ? [] : String(decoding: joined, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        let months: [Int32] = values(monthData), seconds: [Int32] = values(secondData), created: [Double] = values(createdData)
        let kinds = [UInt8](kindData)
        guard [months.count, seconds.count, created.count, kinds.count].allSatisfy({ $0 == ids.count }) else { return nil }
        var snapshot = LibrarySnapshot(ids: ids, months: [:], media: [:])
        snapshot.months.reserveCapacity(ids.count)
        snapshot.media.reserveCapacity(ids.count)
        for (position, id) in ids.enumerated() {
            if months[position] >= 0 { snapshot.months[id] = Int(months[position]) }
            if let kind = MediaInfo.Kind(rawValue: kinds[position]) {
                let date = created[position].isNaN ? nil : Date(timeIntervalSinceReferenceDate: created[position])
                snapshot.media[id] = MediaInfo(kind: kind, seconds: seconds[position], created: date)
            }
        }
        return snapshot
    }

    private static func bytes<T: BitwiseCopyable>(_ values: [T]) -> Data { values.withUnsafeBytes { Data($0) } }

    private static func values<T: BitwiseCopyable>(_ data: Data) -> [T] {
        data.withUnsafeBytes { raw in
            (0..<raw.count / MemoryLayout<T>.stride).map { raw.loadUnaligned(fromByteOffset: $0 * MemoryLayout<T>.stride, as: T.self) }
        }
    }
}

/// The library's fetch result and where each item is in it, for reading assets off the main thread
/// (fetch results are immutable, and faulting their objects in reads Photos' database).
struct AssetSource: @unchecked Sendable {
    let result: PHFetchResult<PHAsset>?
    let index: [String: Int]

    func asset(_ id: String) -> PHAsset? {
        guard let result, let position = index[id], position < result.count else { return nil }
        return result.object(at: position)
    }

    func assets(_ ids: some Sequence<String>) -> [PHAsset] {
        guard let result else { return [] }
        let positions = IndexSet(ids.compactMap { index[$0] }.filter { $0 < result.count })
        return positions.isEmpty ? [] : result.objects(at: positions)
    }
}

/// Lets go of a large value (a library's worth of cells, identifiers and dictionaries) in the
/// background: freeing tens of thousands of strings takes milliseconds, which on the main thread
/// would be a dropped frame.
func releaseInBackground<Value: Sendable>(_ value: consuming Value) {
    let value = Unchecked(value: value)
    Task.detached(priority: .background) { withExtendedLifetime(value) {} }
}

/// A PhotoKit object handed between threads (PHAsset and the image manager are thread-safe).
struct Unchecked<Value>: @unchecked Sendable {
    let value: Value
}

/// Every photo and video in the library, oldest first like Photos, kept up to date. Reading the
/// library (35,000 items take a second or more) and working out badges happen off the main thread;
/// Photos changes are applied incrementally where PhotoKit allows, and job changes touch only the
/// cells they concern, so large libraries stay smooth.
@MainActor @Observable
final class LibraryModel: NSObject, PHPhotoLibraryChangeObserver {
    private(set) var state = LibraryState()
    private(set) var count = 0
    @ObservationIgnored private var assets: PHFetchResult<PHAsset>?
    @ObservationIgnored private var albumAssets: PHFetchResult<PHAsset>?
    @ObservationIgnored private var index: [String: Int] = [:]
    /// The fetch result for reading assets in the background.
    @ObservationIgnored private(set) var source = AssetSource(result: nil, index: [:])
    /// Each item's kind, length and date, read with the library.
    @ObservationIgnored private var media: [String: MediaInfo] = [:]
    @ObservationIgnored private var library: [String] = []
    @ObservationIgnored private var album = Set<String>()
    @ObservationIgnored private var observing = false
    @ObservationIgnored private var retired = false
    @ObservationIgnored private var catalogObservation: CatalogObservation?
    @ObservationIgnored private var changedIDs: Set<String>? = []
    private(set) var contentVersion = 0
    @ObservationIgnored private var contentRevisions: [String: Int] = [:]

    func changedContent(since version: Int) -> Set<String> {
        Set(contentRevisions.compactMap { $0.value > version ? $0.key : nil })
    }

    func contentRevision(_ id: String) -> Int { contentRevisions[id, default: 0] }

    func invalidateContent(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        contentVersion &+= 1
        for id in ids { contentRevisions[id] = contentVersion }
    }

    func takeChangedIDs() -> Set<String>? {
        defer { changedIDs = [] }
        return changedIDs
    }
    /// The latest inputs, so job changes can be applied and the state rebuilt without them.
    @ObservationIgnored private var inputs = Inputs()
    @ObservationIgnored private var building: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    /// The library has been read at least once and its badges worked out (or access isn't granted).
    /// The grid waits for this: shown empty first, it would open at the top instead of the newest.
    private(set) var loaded = false
    @ObservationIgnored private var libraryRead = false
    let thumbnails = PHCachingImageManager()
    /// Where the items come from when it isn't Photos (the demo's sample photos); nil: Photos.
    let catalog: (any ItemCatalog)?

    init(catalog: (any ItemCatalog)? = nil) {
        self.catalog = catalog
        super.init()
    }

    struct Inputs: Sendable {
        var ledger: [String: CompactLedger.Entry] = [:]
        var job: [String: CompactJob.State] = [:]
        var backedUp: [String: Date?] = [:]
        var origin: BackupAPI.Origin?
        var recovering: Set<String> = []
        var pendingImports: Set<String> = []
        var compactInProgress: Set<String> = []
    }

    /// Set by the screen to recompute badges after the library changed.
    var onChange: (@MainActor () -> Void)?

    func asset(_ id: String) -> PHAsset? { source.asset(id) }

    /// The item shown in the grid, for the viewer.
    func item(_ id: String) -> (any LibraryItem)? {
        if let catalog { return catalog.item(id) }
        return source.asset(id)
    }

    /// The item's kind, length and date (nil until the library is read).
    func info(_ id: String) -> MediaInfo? { media[id] }

    /// A small thumbnail for a list or a sheet (not the grid): delivered once or twice as it gets sharper.
    func requestThumbnail(_ id: String, side: CGFloat, deliver: @escaping @MainActor (UIImage) -> Void) async {
        if let catalog {
            if let image = await catalog.thumbnail(id, side: side * 3) { deliver(image) }
            return
        }
        guard let asset = PhotoLibrary.asset(id) else { return }
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true
        let size = CGSize(width: side * 3, height: side * 3)
        thumbnails.requestImage(for: asset, targetSize: size, contentMode: .aspectFill, options: options) { result, _ in
            MainActor.assumeIsolated { if let result { deliver(result) } }
        }
    }

    private struct Loaded: @unchecked Sendable {
        let assets: PHFetchResult<PHAsset>
        let ids: [String]
        let months: [String: Int]
        let media: [String: MediaInfo]
        /// From the snapshot on disk: a full read in the background confirms it.
        let fromSnapshot: Bool
        let albumAssets: PHFetchResult<PHAsset>?
        let album: Set<String>
    }

    /// Reads the whole library (at launch, or when access changes) in the background.
    func reload() async {
        guard !retired else { return }
        if let catalog {
            await read(catalog)
            return
        }
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite).allowsReading else {
            assets = nil
            albumAssets = nil
            library = []
            index = [:]
            source = AssetSource(result: nil, index: [:])
            media = [:]
            album = []
            count = 0
            months = [:]
            loaded = true
            return
        }
        if !observing {
            PHPhotoLibrary.shared().register(self)
            observing = true
        }
        PerfMonitor.signposter.emitEvent("LibraryReloadStart")
        let loaded = await Task.detached(priority: .userInitiated) { () -> Loaded in
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
            options.predicate = NSPredicate(format: "mediaType == %d OR mediaType == %d",
                                            PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
            let fetched = PHAsset.fetchAssets(with: options)
            let albumAssets = PhotoLibrary.albumAssets()
            let album = Set(LibraryModel.identifiers(albumAssets))
            if let snapshot = LibrarySnapshot.read(), snapshot.matches(fetched) {
                return Loaded(assets: fetched, ids: snapshot.ids, months: snapshot.months, media: snapshot.media,
                              fromSnapshot: true, albumAssets: albumAssets, album: album)
            }
            let (ids, months, media) = LibraryModel.describe(fetched)
            try? LibrarySnapshot(ids: ids, months: months, media: media).write()
            return Loaded(assets: fetched, ids: ids, months: months, media: media, fromSnapshot: false,
                          albumAssets: albumAssets, album: album)
        }.value
        setAssets(loaded.assets, ids: loaded.ids)
        months = loaded.months
        media = loaded.media
        monthsVersion += 1
        albumAssets = loaded.albumAssets
        album = loaded.album
        libraryRead = true
        await rebuild()
        // Not awaited: the grid is up meanwhile.
        if loaded.fromSnapshot {
            let fetched = loaded.assets
            Task { await confirm(fetched) }
        }
    }

    /// Reads a catalog's items (they're few), and again whenever they change.
    private func read(_ catalog: any ItemCatalog) async {
        if !observing {
            observing = true
            catalogObservation = catalog.observe { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, let catalog = self.catalog else { return }
                    await self.readAgain(catalog)
                }
            }
        }

        let contents = await Task.detached(priority: .userInitiated) { catalog.contents() }.value
        apply(contents)
        libraryRead = true
        await rebuild()
    }

    func stopObserving() {
        retired = true
        generation &+= 1
        building?.cancel()
        catalogObservation?.cancel()
        catalogObservation = nil
        if observing, catalog == nil { PHPhotoLibrary.shared().unregisterChangeObserver(self) }
        observing = false
    }

    isolated deinit {
        if observing, catalog == nil { PHPhotoLibrary.shared().unregisterChangeObserver(self) }
    }

    private func readAgain(_ catalog: any ItemCatalog) async {
        guard !retired else { return }
        let contents = await Task.detached(priority: .userInitiated) { catalog.contents() }.value
        guard !retired else { return }
        apply(contents)
        changedContents()
    }

    private func apply(_ contents: LibraryContents) {
        mediaCache = [:]
        library = contents.ids
        var index: [String: Int] = [:]
        for (position, id) in contents.ids.enumerated() where index[id] == nil { index[id] = position }
        self.index = index
        count = contents.ids.count
        // New/removed identifiers are picked up by the state rebuild. Only an existing item's
        // changed month needs to regroup the old state before that.
        let regrouped = contents.months.contains { id, month in months[id].map { $0 != month } ?? false }
        months = contents.months
        if regrouped { monthsVersion += 1 }
        media = contents.media
        album = contents.album
    }

    /// Reads every item of the fetch the grid shows from the snapshot (in the background, at low
    /// priority) and takes what Photos says if anything differs.
    private func confirm(_ fetched: PHFetchResult<PHAsset>) async {
        let box = FetchBox(result: fetched), shown = LibrarySnapshot(ids: library, months: months, media: media)
        let read = await Task.detached(priority: .utility) { () -> LibrarySnapshot? in
            let (ids, months, media) = LibraryModel.describe(box.result)
            let read = LibrarySnapshot(ids: ids, months: months, media: media)
            guard read != shown else { return nil }
            try? read.write()
            return read
        }.value
        // Photos changed meanwhile: the change observer has the newer contents already.
        guard let read, assets === fetched else { return }
        AppLog.app.info("library snapshot was stale; using Photos' contents")
        setAssets(fetched, ids: read.ids)
        months = read.months
        media = read.media
        monthsVersion += 1
        await rebuild()
    }

    /// Writes the library's current contents for the next launch (after Photos changes), a little
    /// after the last change.
    private func saveSnapshot() {
        guard catalog == nil else { return }
        snapshotSave?.cancel()
        let snapshot = LibrarySnapshot(ids: library, months: months, media: media)
        snapshotSave = Task.detached(priority: .background) {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            try? snapshot.write()
        }
    }

    @ObservationIgnored private var snapshotSave: Task<Void, Never>?

    /// Works out the badges again (after the ledger or the job changed), in the background.
    func update(ledger: [String: CompactLedger.Entry], job: [String: CompactJob.State], backedUp: [String: Date?] = [:],
                origin: BackupAPI.Origin? = nil, recovering: Set<String> = [], pendingImports: Set<String> = [],
                compactInProgress: Set<String> = []) async {
        inputs = Inputs(ledger: ledger, job: job, backedUp: backedUp, origin: origin, recovering: recovering,
                        pendingImports: pendingImports, compactInProgress: compactInProgress)
        await rebuild()
    }

    /// Builds the state from the current library and inputs; a newer rebuild supersedes it.
    private func rebuild() async {
        generation &+= 1
        let mine = generation
        let library = library, album = album, inputs = inputs, previous = state, read = libraryRead
        let signpost = PerfMonitor.signposter.beginInterval("BuildState")
        RenderProbe.count("library.buildState")
        let built = await Task.detached(priority: .userInitiated) { () -> (LibraryState, Set<String>?)? in
            var new = LibraryState(library: library, ledger: inputs.ledger, album: album, job: inputs.job,
                                   backedUp: inputs.backedUp, origin: inputs.origin, recovering: inputs.recovering,
                                   pendingImports: inputs.pendingImports, compactInProgress: inputs.compactInProgress)
            guard new != previous else { return nil }
            new.follow(previous)
            return (new, new.changedIDs(from: previous))
        }.value
        PerfMonitor.signposter.endInterval("BuildState", signpost)
        guard mine == generation else { return }
        if let (built, diff) = built {
            let old = state
            if let diff { changedIDs?.formUnion(diff) } else { changedIDs = nil }
            state = built
            releaseInBackground(old)
        }
        if read, !loaded { loaded = true }
    }

    /// The job changed these items (nil: they left it): their badges change at once; the ledger
    /// (a finished item's compact copy) follows in a rebuild.
    func apply(job changes: [String: CompactJob.State?], compactInProgress: Set<String> = []) {
        guard !changes.isEmpty else { return }
        generation &+= 1
        for (id, value) in changes { inputs.job[id] = value }
        inputs.compactInProgress = compactInProgress
        let changed = state.apply(job: changes, compactInProgress: compactInProgress)
        changedIDs?.formUnion(changed)
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in self.apply(changeInstance) }
    }

    /// Photos changed. Small changes are applied here; anything else (moves, big imports, a sync)
    /// is read again in the background, since reading 35,000 items on the main thread freezes it.
    private func apply(_ change: PHChange) {
        var changed = false
        if let assets, let details = change.changeDetails(for: assets) {
            let after = details.fetchResultAfterChanges
            invalidateContent(Set(details.changedObjects.map(\.localIdentifier)))
            mediaCache = [:]
            if !rereading, let ids = Self.applying(details, to: library) {
                setAssets(after, ids: ids)
                var monthsChanged = false
                for asset in details.removedObjects {
                    months[asset.localIdentifier] = nil
                    media[asset.localIdentifier] = nil
                }
                for asset in details.insertedObjects + details.changedObjects {
                    let month = Self.monthKey(asset.creationDate)
                    if index[asset.localIdentifier] != nil, media[asset.localIdentifier] != nil,
                       months[asset.localIdentifier] != month { monthsChanged = true }
                    months[asset.localIdentifier] = month
                    media[asset.localIdentifier] = MediaInfo(asset)
                }
                if monthsChanged { monthsVersion += 1 }
                changed = true
            } else {
                reread(after)
            }
        }
        if let albumAssets, let details = change.changeDetails(for: albumAssets) {
            self.albumAssets = details.fetchResultAfterChanges
            if details.hasIncrementalChanges {
                album.subtract(details.removedObjects.map(\.localIdentifier))
                album.formUnion(details.insertedObjects.map(\.localIdentifier))
                changed = true
            } else {
                rereadAlbum(details.fetchResultAfterChanges)
            }
        } else if albumAssets == nil, changed, let created = PhotoLibrary.albumAssets() {
            // The album was just created by the first import.
            albumAssets = created
            album = Set(Self.identifiers(created))
        }
        if changed { changedContents() }
    }

    /// The badges follow, once for a batch of imports or removals (they send many changes), and
    /// the snapshot for the next launch is written.
    private func changedContents() {
        guard !retired else { return }
        saveSnapshot()
        onChange?()
    }

    /// A full read is under way: changes meanwhile start another (only the latest is applied).
    @ObservationIgnored private var rereading = false

    private func reread(_ fetched: PHFetchResult<PHAsset>) {
        // Further changes are worked out against this result; the grid keeps the one it has
        // (`source`, with its identifiers) until the read is done.
        assets = fetched
        rereading = true
        let box = FetchBox(result: fetched)
        Task {
            let read = await Task.detached(priority: .userInitiated) { LibraryModel.describe(box.result) }.value
            guard assets === fetched else { return }
            rereading = false
            setAssets(fetched, ids: read.ids)
            months = read.months
            media = read.media
            monthsVersion += 1
            changedContents()
        }
    }

    private func rereadAlbum(_ fetched: PHFetchResult<PHAsset>) {
        let box = FetchBox(result: fetched)
        Task {
            let ids = await Task.detached(priority: .userInitiated) { Set(LibraryModel.identifiers(box.result)) }.value
            guard albumAssets === fetched else { return }
            album = ids
            changedContents()
        }
    }

    /// Photos, videos or Live Photos only (the Filter menu's second part).
    enum Media: String, CaseIterable, Identifiable, Sendable {
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
    /// Each item's capture month (year × 12 + month - 1), read with the library.
    @ObservationIgnored private var months: [String: Int] = [:]
    /// Bumped when `months` changes, so the grid regroups.
    private(set) var monthsVersion = 0

    func month(of id: String) -> Int? { months[id] }

    /// Each item's month and media info, in one pass over the library (off the main thread).
    nonisolated static func describe(_ fetched: PHFetchResult<PHAsset>)
        -> (ids: [String], months: [String: Int], media: [String: MediaInfo]) {
        var ids: [String] = [], months: [String: Int] = [:], media: [String: MediaInfo] = [:]
        ids.reserveCapacity(fetched.count)
        months.reserveCapacity(fetched.count)
        media.reserveCapacity(fetched.count)
        fetched.enumerateObjects { asset, _, _ in
            let id = asset.localIdentifier
            ids.append(id)
            let info = MediaInfo(asset)
            media[id] = info
            if let key = monthKey(info.created) { months[id] = key }
        }
        return (ids, months, media)
    }

    nonisolated static func monthKey(_ date: Date?) -> Int? {
        guard let date else { return nil }
        let parts = Calendar.current.dateComponents([.year, .month], from: date)
        guard let year = parts.year, let month = parts.month else { return nil }
        return year * 12 + month - 1
    }

    private struct FetchBox: @unchecked Sendable { let result: PHFetchResult<PHAsset> }

    /// Items created after a date (for "new since the last backup"), read in the background.
    func identifiers(createdAfter date: Date) async -> Set<String> {
        if catalog != nil { return Set(media.filter { ($0.value.created ?? .distantPast) > date }.keys) }
        return await Task.detached(priority: .utility) {
            let options = PHFetchOptions()
            options.predicate = NSPredicate(format: "creationDate > %@", date as NSDate)
            return Set(LibraryModel.identifiers(PHAsset.fetchAssets(with: options)))
        }.value
    }

    /// The items of one kind, read once in the background and kept until the library changes.
    func identifiers(_ media: Media) async -> Set<String>? {
        guard media != .all else { return nil }
        if let cached = mediaCache[media] { return cached }
        if catalog != nil {
            let kind: MediaInfo.Kind = switch media {
            case .videos: .video
            case .livePhotos: .livePhoto
            default: .photo
            }
            let found = Set(self.media.filter { $0.value.kind == kind }.keys)
            mediaCache[media] = found
            return found
        }
        let found = await Task.detached(priority: .userInitiated) {
            let options = PHFetchOptions()
            options.predicate = switch media {
            case .videos: NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
            case .livePhotos: NSPredicate(format: "mediaType == %d AND (mediaSubtypes & %d) != 0", PHAssetMediaType.image.rawValue,
                                          PHAssetMediaSubtype.photoLive.rawValue)
            default: NSPredicate(format: "mediaType == %d AND (mediaSubtypes & %d) == 0", PHAssetMediaType.image.rawValue,
                                 PHAssetMediaSubtype.photoLive.rawValue)
            }
            return Set(LibraryModel.identifiers(PHAsset.fetchAssets(with: options)))
        }.value
        mediaCache[media] = found
        return found
    }

    /// The months of these items, for grouping off the main thread.
    var monthsSnapshot: [String: Int] { months }

    private func setAssets(_ fetched: PHFetchResult<PHAsset>, ids: [String]) {
        mediaCache = [:]
        assets = fetched
        library = ids
        var index: [String: Int] = [:]
        index.reserveCapacity(ids.count)
        for (position, id) in ids.enumerated() where index[id] == nil { index[id] = position }
        self.index = index
        source = AssetSource(result: fetched, index: index)
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

    nonisolated static func identifiers(_ fetched: PHFetchResult<PHAsset>?) -> [String] {
        var ids: [String] = []
        ids.reserveCapacity(fetched?.count ?? 0)
        fetched?.enumerateObjects { asset, _, _ in ids.append(asset.localIdentifier) }
        return ids
    }
}

/// What the grid shows for one filter: the cells in order, grouped by capture month, with each
/// month's counts. Built off the main thread whenever the state, the filter or the months change.
struct GridData: Sendable {
    struct Section: Identifiable, Sendable {
        /// The month (year × 12 + month - 1), 0 for undated; unique among the sections.
        var id: Int
        /// The month itself (`id` differs when a month appears twice).
        var month: Int
        var range: Range<Int>
        /// Items in it not backed up yet.
        var open: Int
    }

    var cells: [LibraryState.Cell] = []
    var sections: [Section] = []
    var ids: [String] = []
    /// Where each cell is in `cells` (drag-to-select).
    var positions: [String: Int] = [:]
    /// What Select All selects: everything that can be backed up or freed.
    var selectable: Set<String> = []
    var stateVersion = -1

    init() {}

    init(state: LibraryState, filter: LibraryState.Filter, media: Set<String>?, months: [String: Int]) {
        var cells = filter == .all ? state.cells : state.cells.filter { $0.matches(filter) }
        if let media { cells = cells.filter { media.contains($0.id) } }
        var sections: [Section] = []
        var positions: [String: Int] = [:]
        positions.reserveCapacity(cells.count)
        var selectable = Set<String>()
        var ids: [String] = []
        ids.reserveCapacity(cells.count)
        var start = 0, open = 0
        var key = cells.first.flatMap { months[$0.id] } ?? 0
        for (index, cell) in cells.enumerated() {
            let month = months[cell.id] ?? key
            if month != key, index > 0 {
                sections.append(Section(id: key, month: key, range: start..<index, open: open))
                start = index
                open = 0
            }
            key = month
            if cell.isNotBackedUp { open += 1 }
            // Under Original at Home, what can be restored; elsewhere, what can be backed up or freed.
            if filter == .atHome ? cell.canRestore : cell.canCompact || cell.canFree { selectable.insert(cell.id) }
            positions[cell.id] = index
            ids.append(cell.id)
        }
        if !cells.isEmpty { sections.append(Section(id: key, month: key, range: start..<cells.count, open: open)) }
        // A month seen twice (an undated item between) keeps the sections apart with distinct ids.
        var seen = Set<Int>()
        for index in sections.indices where !seen.insert(sections[index].id).inserted {
            sections[index].id = -(index + 1)
        }
        self.cells = cells
        self.sections = sections
        self.ids = ids
        self.positions = positions
        self.selectable = selectable
        stateVersion = state.version
    }
}

extension PHAuthorizationStatus {
    var allowsReading: Bool { self == .authorized || self == .limited }
}

/// Select mode and what's selected.
@MainActor @Observable
final class GridSelection {
    var active = false
    var ids = Set<String>() { didSet { version &+= 1 } }
    /// Bumped on every change, for work keyed to the selection (cheaper than comparing sets).
    private(set) var version = 0
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

    /// "compact copy after December 15", for a kept favorite "favorites keep their original", and
    /// for one kept with Keep Original (`distantFuture`) "kept full size on this iPhone".
    static func compactLater(_ date: Date?) -> String {
        guard let date else { return "favorites keep their original" }
        if date == .distantFuture { return "kept full size on this iPhone" }
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
