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

    /// Stable text for VoiceOver and UI tests.
    var label: String {
        switch self {
        case .none: "Not backed up"
        case .backedUp: "Backed up"
        case .originalOnPhone: "Original still on this iPhone"
        case .compactCopy: "Compact copy"
        case .waiting: "Waiting"
        case .working: "Working"
        case .kept: "Kept as is"
        case .failed: "Failed"
        }
    }

    var explanation: String {
        switch self {
        case .none: "Only on this iPhone. Select it to back it up and make a compact copy."
        case .backedUp: "A compact copy. The full-quality original is on your server, not on this iPhone."
        case .originalOnPhone: "A compact copy. The original is still on this iPhone too; free up space to remove it."
        case .compactCopy: "A Homespun compact copy."
        case .waiting: "Waiting to be compacted."
        case .working: "Being backed up and compacted."
        case .kept: "Kept as is, for example because it couldn't be made smaller."
        case .failed: "Something went wrong; see Activity."
        }
    }

    var symbol: String? {
        switch self {
        case .none: nil
        case .backedUp: "checkmark"
        case .originalOnPhone: "square.on.square"
        case .compactCopy: "arrow.down.right.and.arrow.up.left"
        case .waiting: "clock"
        case .working: nil
        case .kept: "equal"
        case .failed: "exclamationmark"
        }
    }

    var color: Color {
        switch self {
        case .backedUp: .green
        case .originalOnPhone: .orange
        case .failed: .red
        default: .gray
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
    }

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", notBackedUp = "Not backed up", backedUp = "Backed up"
        var id: String { rawValue }
    }

    var cells: [Cell] = []

    init(cells: [Cell] = []) { self.cells = cells }

    /// `library` in display order (oldest first). An original backed up with a compact copy in
    /// the library is hidden; the copy is shown with a badge saying where the original is. (A
    /// copy made on this iPhone by the old on-phone mode doesn't hide its original, which still
    /// needs backing up.)
    init(library: [String], ledger: [String: CompactLedger.Entry], album: Set<String>, job: [String: CompactJob.State]) {
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
            case .saved?, nil: .none
            }
            return Cell(id: id, badge: badge, original: nil, canFree: false)
        }
    }

    func cells(_ filter: Filter) -> [Cell] {
        switch filter {
        case .all: cells
        case .notBackedUp: cells.filter(\.isNotBackedUp)
        case .backedUp: cells.filter { !$0.isNotBackedUp }
        }
    }
}

extension LibraryState.Cell {
    /// Has no copy on the server yet (including items being worked on).
    var isNotBackedUp: Bool {
        switch badge {
        case .none, .waiting, .working, .kept, .failed: true
        case .originalOnPhone: !canFree
        case .backedUp, .compactCopy: false
        }
    }

    /// Can be selected to compact.
    var canCompact: Bool { [.none, .kept, .failed].contains(badge) }
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
        setAssets(PHAsset.fetchAssets(with: options), ids: nil)
        albumAssets = PhotoLibrary.albumAssets()
        album = Set(Self.identifiers(albumAssets))
    }

    /// Works out the badges again (after the ledger or the job changed).
    func update(ledger: [String: CompactLedger.Entry], job: [String: CompactJob.State]) {
        let new = LibraryState(library: library, ledger: ledger, album: album, job: job)
        if new != state { state = new }
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in self.apply(changeInstance) }
    }

    private func apply(_ change: PHChange) {
        var changed = false
        if let assets, let details = change.changeDetails(for: assets) {
            setAssets(details.fetchResultAfterChanges, ids: Self.applying(details, to: library))
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

    private func setAssets(_ fetched: PHFetchResult<PHAsset>, ids: [String]?) {
        let ids = ids ?? Self.identifiers(fetched)
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
struct GridCell: View {
    let cell: LibraryState.Cell
    let asset: PHAsset?
    let manager: PHCachingImageManager
    let selected: Bool
    @State private var image: UIImage?
    @State private var request: PHImageRequestID?

    var body: some View {
        Color(.secondarySystemFill)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
            .clipped()
            .overlay(alignment: .bottomLeading) { mediaMark }
            .overlay(alignment: .bottomTrailing) { badge.padding(4) }
            .overlay { if selected { Color.white.opacity(0.25) } }
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette).foregroundStyle(.white, .blue)
                        .font(.title3).padding(4)
                }
            }
            .contentShape(Rectangle())
            .onAppear(perform: load)
            .onDisappear {
                if let request { manager.cancelImageRequest(request) }
                request = nil
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityName)
            .accessibilityValue(cell.badge.label)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityIdentifier("asset")
    }

    @ViewBuilder private var badge: some View {
        if cell.badge == .working {
            ProgressView().controlSize(.mini).tint(.white)
                .frame(width: 20, height: 20).background(Circle().fill(.black.opacity(0.55)))
        } else if let symbol = cell.badge.symbol {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(cell.badge.color))
                .overlay(Circle().stroke(.white, lineWidth: 1.5))
                .shadow(radius: 1)
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

/// What each badge means.
struct BadgeLegendView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach([Badge.backedUp, .originalOnPhone, .none, .working, .kept, .failed, .compactCopy], id: \.label) { badge in
                    HStack(alignment: .top, spacing: 14) {
                        Group {
                            if let symbol = badge.symbol {
                                Image(systemName: symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                                    .frame(width: 24, height: 24).background(Circle().fill(badge.color))
                            } else if badge == .working {
                                ProgressView().frame(width: 24, height: 24)
                            } else {
                                Circle().stroke(.secondary, style: StrokeStyle(lineWidth: 1, dash: [3])).frame(width: 24, height: 24)
                            }
                        }
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
