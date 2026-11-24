// SPDX-License-Identifier: Apache-2.0
import AVFoundation
import CryptoKit
import HomespunCore
import Photos
import Synchronization
import UIKit

/// One photo or video as Homespun's screens see it: from Photos on this iPhone (`PHAsset`), or one
/// of the demo's sample photos (`DemoItem`).
protocol LibraryItem: AnyObject {
    var localIdentifier: String { get }
    var creationDate: Date? { get }
    var pixelWidth: Int { get }
    var pixelHeight: Int { get }
    /// A video's length, in seconds.
    var duration: TimeInterval { get }
    var isFavorite: Bool { get }
    var isHidden: Bool { get }
    /// Photo, Live Photo or video (nil for anything else).
    var itemKind: PhotoLibrary.Kind? { get }
    /// Edited in Photos (its edits wouldn't carry over to another item).
    var isEdited: Bool { get }
    /// Size, format and dimensions, and the size of a Live Photo's motion.
    func mediaFacts() -> (main: MediaFacts, motion: Int?)
    /// One image (`size` nil: full size; `fast`: whatever is quickest).
    @MainActor func image(size: CGSize?, fast: Bool) async -> UIImage?
    @MainActor func livePhoto(size: CGSize) async -> PHLivePhoto?
    @MainActor func playerItem() async -> Result<AVPlayerItem, Error>
    @MainActor func player() async -> AVPlayer?
}

extension PHAsset: LibraryItem {
    var itemKind: PhotoLibrary.Kind? { PhotoLibrary.kind(of: self) }
    var isEdited: Bool { PhotoLibrary.isEdited(self) }
    func mediaFacts() -> (main: MediaFacts, motion: Int?) { ItemMedia.facts(self) }
    @MainActor func image(size: CGSize?, fast: Bool) async -> UIImage? { await ItemMedia.image(self, size: size, fast: fast) }
    @MainActor func livePhoto(size: CGSize) async -> PHLivePhoto? { await ItemMedia.livePhoto(self, size: size) }
    @MainActor func playerItem() async -> Result<AVPlayerItem, Error> { await ItemMedia.playerItem(self) }
    @MainActor func player() async -> AVPlayer? { await ItemMedia.player(self) }
}

/// What the backup engine and the screens need to know about an item without loading it.
struct ItemSummary: Sendable, Equatable {
    var created: Date?
    var kind: PhotoLibrary.Kind?
    var favorite = false
}

/// The photo library Homespun works on: Photos on this iPhone (`PhotoKitSource`), or the demo's
/// sample photos (`DemoLibrary`), which never touches Photos. Everything outside the Library grid's
/// own reading (`LibraryModel`) goes through it.
protocol PhotoSource: Sendable {
    /// Whether Homespun may read the library.
    func authorization() -> PHAuthorizationStatus
    /// Asks for access (Photos shows its question).
    func requestAuthorization() async -> PHAuthorizationStatus
    func item(_ id: String) -> (any LibraryItem)?
    /// Dates, kinds and favorites of these items, in one read (missing items are left out).
    func summaries(_ ids: [String]) -> [String: ItemSummary]
    /// File name and kind for display, or nil if the item cannot be found.
    func describe(_ id: String) -> (name: String, kind: PhotoLibrary.Kind)?
    /// Which of these items are still in the library (`includeHidden`: hidden ones count).
    func existing(_ ids: [String], includeHidden: Bool) -> Set<String>
    /// About how many bytes these items take (sampled for large sets).
    func estimatedBytes(_ ids: [String], sample: Int) -> (bytes: Int, exact: Bool)
    /// Every photo and video.
    func allIdentifiers() -> [String]
    /// The items in the Homespun album.
    func albumMembers() -> Set<String>
    func addToAlbum(_ ids: [String]) async throws
    /// The SHA-256 of each item's photo, motion and video (Find Compact Copies).
    func copyHashes(_ ids: [String]) async -> [String: CopyFinder.Hashed]
    /// Deletes these items; the person is asked first, and saying no throws. Nothing to delete is fine.
    func delete(_ ids: [String]) async throws
    /// Sizes by kind and what isn't backed up (setup's first task).
    func measure(excluding backedUp: Set<String>) -> LibraryMeasure.Result
    func preparationBytes(_ id: String, mode: ServerAPI.StorageMode) throws -> Int
    func prepareBackup(_ id: String, mode: ServerAPI.StorageMode, directory: URL, maximumBytes: Int,
                       progress: @escaping @Sendable (String) -> Void) async throws -> PreparedPhoto
    func resourceFingerprints(_ id: String) async throws -> [ServerAPI.ResourceDescriptor]
    func sourceGeneration(_ id: String) throws -> PhotoGeneration
    func backupMetadata(_ id: String) throws -> BackupPhotoMetadata
    func applyBackupMetadata(_ id: String, metadata: BackupPhotoMetadata) async throws
    func observePhotosEffect(restoring: Bool) throws -> PhotosObservation
    func reconcilePhotosEffect(expected: [ServerAPI.ResourceDescriptor], observation: PhotosObservation,
                               createdIdentifier: String?) async throws -> PhotosReconciliation
    func importCompact(_ files: [PreparedPhotoResource], metadata: BackupPhotoMetadata) async throws -> String
    func restoreResources(_ files: [PreparedPhotoResource], metadata: BackupPhotoMetadata) async throws -> String
    func removeApproved(_ approvals: [PhotosRemovalApproval]) async throws -> PhotosRemovalResult
    func keepApproved(_ approvals: [PhotosRemovalApproval]) async throws -> PhotosRemovalResult

    // Automatic mode: where the library's history is now, and what changed since.
    func changeToken() -> Data?
    /// Items added since `token`; `read` false if the changes couldn't be read.
    func inserted(since token: Data?) -> (ids: Set<String>, read: Bool)
    /// Items deleted since `token`; `read` false if the changes couldn't be read.
    func deleted(since token: Data?) -> (ids: Set<String>, read: Bool)
    /// Photos and videos created since `since`, and `also` wherever their dates fall.
    func candidates(since: Date, also: [String]) -> [AutomaticCandidate]

    // The engine's three jobs for this library: backing up, freeing up space, restoring originals.
    func compactor(client: ServerClient, mode: ServerAPI.StorageMode, profile: CompressionProfile,
                   ledger: CompactLedger) -> any Compacting
    func remover(client: ServerClient, mode: ServerAPI.StorageMode, ledger: CompactLedger) -> any RemovingOriginals
    func restorer(client: ServerClient, ledger: CompactLedger) -> any RestoringOriginals
}

/// A library that lists its own items (the demo's), which `LibraryModel` reads instead of Photos.
protocol ItemCatalog: PhotoSource, AnyObject {
    /// Every item, oldest first, with what the grid shows about each.
    func contents() -> LibraryContents
    /// A square thumbnail about `side` pixels across.
    func thumbnail(_ id: String, side: CGFloat) async -> UIImage?
    /// Called (on any thread) after items come or go.
    func observe(_ changed: @escaping @Sendable () -> Void) -> CatalogObservation
}

final class CatalogObservation: Sendable {
    private let cancellation: Synchronization.Mutex<(@Sendable () -> Void)?>

    init(_ cancel: @escaping @Sendable () -> Void) {
        cancellation = .init(cancel)
    }

    func cancel() {
        let cancel = cancellation.withLock { action in
            defer { action = nil }
            return action
        }
        cancel?()
    }

    deinit { cancel() }
}

/// What the grid reads from a library: identifiers in order, months, media info, and the album.
struct LibraryContents: Sendable {
    var ids: [String] = []
    var months: [String: Int] = [:]
    var media: [String: MediaInfo] = [:]
    var album: Set<String> = []
}

/// Free Up Space: checks originals again and removes them (`OriginalRemover`).
protocol RemovingOriginals: Sendable {
    func candidates(only: Set<String>?) async throws -> [(original: String, entry: CompactLedger.Entry)]
    func removeEligible(limit: Int?, only: Set<String>?,
                        progress: @escaping @Sendable (String) -> Void) async throws -> OriginalRemover.Report
}

extension RemovingOriginals {
    func candidates() async throws -> [(original: String, entry: CompactLedger.Entry)] { try await candidates(only: nil) }
}

/// Restore Original: brings originals back from the server (`OriginalRestorer`).
protocol RestoringOriginals: Sendable {
    func restore(_ items: [OriginalRestorer.Item],
                 progress: @escaping @Sendable (OriginalRestorer.Progress) -> Void) async -> OriginalRestorer.Report
}

extension OriginalRemover: RemovingOriginals {}
extension OriginalRestorer: RestoringOriginals {}

/// Photos on this iPhone, through PhotoKit.
struct PhotoKitSource: PhotoSource {
    func authorization() -> PHAuthorizationStatus { PHPhotoLibrary.authorizationStatus(for: .readWrite) }

    func requestAuthorization() async -> PHAuthorizationStatus { await PHPhotoLibrary.requestAuthorization(for: .readWrite) }

    func item(_ id: String) -> (any LibraryItem)? { PhotoLibrary.asset(id) }

    func summaries(_ ids: [String]) -> [String: ItemSummary] {
        var found: [String: ItemSummary] = [:]
        PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil).enumerateObjects { asset, _, _ in
            found[asset.localIdentifier] = ItemSummary(created: asset.creationDate, kind: PhotoLibrary.kind(of: asset),
                                                       favorite: asset.isFavorite)
        }
        return found
    }

    func describe(_ id: String) -> (name: String, kind: PhotoLibrary.Kind)? { PhotoLibrary.describe(id) }

    func existing(_ ids: [String], includeHidden: Bool) -> Set<String> {
        PhotoLibrary.existing(ids, includeHidden: includeHidden)
    }

    func estimatedBytes(_ ids: [String], sample: Int) -> (bytes: Int, exact: Bool) {
        PhotoLibrary.estimatedBytes(ids, sample: sample)
    }

    func allIdentifiers() -> [String] { PhotoLibrary.allIdentifiers() }

    func albumMembers() -> Set<String> { PhotoLibrary.albumMembers() }

    func addToAlbum(_ ids: [String]) async throws { try await PhotoLibrary.addToAlbum(ids) }

    func delete(_ ids: [String]) async throws {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        guard assets.count > 0 else { return }
        try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.deleteAssets(assets) }
    }

    func measure(excluding backedUp: Set<String>) -> LibraryMeasure.Result {
        let album = PhotoLibrary.albumMembers()
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "mediaType == %d OR mediaType == %d",
                                        PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        var photos: [String] = [], live: [String] = [], videos: [String] = []
        var candidates: [FirstTask.Candidate] = []
        PHAsset.fetchAssets(with: options).enumerateObjects { asset, _, _ in
            let id = asset.localIdentifier
            guard !album.contains(id), let kind = PhotoLibrary.kind(of: asset) else { return }
            switch kind {
            case .photo: photos.append(id)
            case .livePhoto: live.append(id)
            case .video: videos.append(id)
            }
            guard !backedUp.contains(id) else { return }
            candidates.append(.init(id: id, isVideo: kind == .video, duration: asset.duration,
                                    isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot)))
        }
        func group(_ ids: [String]) -> FirstTask.Estimate.Group {
            .init(count: ids.count, bytes: Int64(PhotoLibrary.estimatedBytes(ids, sample: 200).bytes))
        }
        return LibraryMeasure.Result(estimate: .init(photos: group(photos), livePhotos: group(live), videos: group(videos)),
                                     candidates: candidates)
    }

    // MARK: Automatic mode

    func changeToken() -> Data? { Self.archive(PHPhotoLibrary.shared().currentChangeToken) }

    func inserted(since token: Data?) -> (ids: Set<String>, read: Bool) {
        guard let token = token.flatMap(Self.unarchive) else { return ([], true) }
        var ids = Set<String>()
        do {
            for change in try PHPhotoLibrary.shared().fetchPersistentChanges(since: token) {
                ids.formUnion(try change.changeDetails(for: .asset).insertedLocalIdentifiers)
            }
            return (ids, true)
        } catch let error as PHPhotosError where error.code == .persistentChangeTokenExpired {
            return ([], true)
        } catch {
            return ([], false)
        }
    }

    func deleted(since token: Data?) -> (ids: Set<String>, read: Bool) {
        guard let token = token.flatMap(Self.unarchive) else { return ([], true) }
        var ids = Set<String>()
        do {
            for change in try PHPhotoLibrary.shared().fetchPersistentChanges(since: token) {
                ids.formUnion(try change.changeDetails(for: .asset).deletedLocalIdentifiers)
            }
            return (ids, true)
        } catch let error as PHPhotosError where error.code == .persistentChangeTokenExpired {
            return ([], true)
        } catch {
            return ([], false)
        }
    }

    func candidates(since: Date, also: [String]) -> [AutomaticCandidate] {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "(mediaType == %d OR mediaType == %d) AND creationDate >= %@",
                                        PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue, since as NSDate)
        var assets: [AutomaticCandidate] = []
        var seen = Set<String>()
        PHAsset.fetchAssets(with: options).enumerateObjects { asset, _, _ in
            assets.append(AutomaticCandidate(id: asset.localIdentifier, created: asset.creationDate, favorite: asset.isFavorite))
            seen.insert(asset.localIdentifier)
        }
        let late = also.filter { !seen.contains($0) }
        if !late.isEmpty {
            PHAsset.fetchAssets(withLocalIdentifiers: late, options: nil).enumerateObjects { asset, _, _ in
                if [.image, .video].contains(asset.mediaType) {
                    assets.append(AutomaticCandidate(id: asset.localIdentifier, created: asset.creationDate,
                                                     favorite: asset.isFavorite))
                }
            }
        }
        return assets
    }

    private static func archive(_ token: PHPersistentChangeToken) -> Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
    }

    private static func unarchive(_ data: Data) -> PHPersistentChangeToken? {
        try? NSKeyedUnarchiver.unarchivedObject(ofClass: PHPersistentChangeToken.self, from: data)
    }

    // MARK: Engines

    func compactor(client: ServerClient, mode: ServerAPI.StorageMode, profile: CompressionProfile,
                   ledger: CompactLedger) -> any Compacting {
        ServerCompactor(client: client, mode: mode, profile: profile, ledger: ledger)
    }

    func remover(client: ServerClient, mode: ServerAPI.StorageMode, ledger: CompactLedger) -> any RemovingOriginals {
        OriginalRemover(client: client, mode: mode, ledger: ledger)
    }

    func restorer(client: ServerClient, ledger: CompactLedger) -> any RestoringOriginals {
        OriginalRestorer(client: client, ledger: ledger)
    }

    // MARK: Find Compact Copies

    /// The SHA-256 of each item's photo, motion, and video, read from this iPhone only; items
    /// without such files here (only in iCloud, say) are left out.
    func copyHashes(_ ids: [String]) async -> [String: CopyFinder.Hashed] {
        await Self.hash(ids)
    }

    static func hash(_ identifiers: [String], concurrently: Int = 4) async -> [String: CopyFinder.Hashed] {
        await withTaskGroup(of: (String, CopyFinder.Hashed?).self) { group in
            var results: [String: CopyFinder.Hashed] = [:], next = 0
            func addNext() {
                guard next < identifiers.count else { return }
                let id = identifiers[next]
                next += 1
                group.addTask { (id, try? await hash(id)) }
            }
            for _ in 0..<concurrently { addNext() }
            while let (id, hashed) = await group.next() {
                if let hashed { results[id] = hashed }
                addNext()
            }
            return results
        }
    }

    private static func hash(_ identifier: String) async throws -> CopyFinder.Hashed? {
        guard let asset = PhotoLibrary.asset(identifier) else { return nil }
        let resources = PHAssetResource.assetResources(for: asset)
            .filter { CopyMatching.roles.contains(PhotoLibrary.role(of: $0.type)) }
        guard !resources.isEmpty else { return nil }
        var hashed = CopyFinder.Hashed(hashes: [:], bytes: 0)
        for resource in resources {
            let (sha256, size) = try await digest(resource)
            hashed.hashes[PhotoLibrary.role(of: resource.type)] = sha256
            hashed.bytes += size
        }
        return hashed
    }

    private final class Digest: @unchecked Sendable {
        var hash = SHA256()
        var size = 0
    }

    private static func digest(_ resource: PHAssetResource) async throws -> (String, Int) {
        let digest = Digest()
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().requestData(for: resource, options: options) { data in
                digest.hash.update(data: data)
                digest.size += data.count
            } completionHandler: { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        return (digest.hash.finalize().map { String(format: "%02x", $0) }.joined(), digest.size)
    }
}
