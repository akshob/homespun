// SPDX-License-Identifier: Apache-2.0
import CoreLocation
import Foundation
import HomespunCore
import Photos

/// What happened to one picked item.
enum CompactOutcome: Equatable, Sendable {
    case saved(compactIdentifier: String, originalBytes: Int, compactBytes: Int)
    /// Nothing was saved; the reason is shown to the user.
    case unchanged(String)
    /// Not done yet, for a reason that may pass (for example, not in Immich yet). Try again later.
    case notYet(String)
    /// Backed up; the compact copy comes later (a recent item, for automatic mode).
    case backedUp(originalBytes: Int)
}

/// Makes and saves a compact copy of one library item, or (`compactNow` false) only backs its
/// originals up.
protocol Compacting: Sendable {
    func compact(_ localIdentifier: String, compactNow: Bool,
                 progress: @escaping @Sendable (String) -> Void) async throws -> CompactOutcome
}

extension Compacting {
    func compact(_ localIdentifier: String, progress: @escaping @Sendable (String) -> Void) async throws -> CompactOutcome {
        try await compact(localIdentifier, compactNow: true, progress: progress)
    }
}

/// PhotoKit work shared by on-phone and server modes.
enum PhotoLibrary {
    static let albumTitle = "Homespun"

    enum Failure: LocalizedError {
        case notFound
        case unsupported(String)
        case missingResource(String)
        case livePhotoInvalid(String)
        case importFailed(String)
        case restoreMetadata(identifier: String, message: String)
        case verificationFailed(String)

        var errorDescription: String? {
            switch self {
            case .notFound: "The item is no longer in the library, or Homespun has limited access."
            case .unsupported(let reason): reason
            case .missingResource(let name): "The \(name) could not be found."
            case .livePhotoInvalid(let reason): "The compact Live Photo did not validate (\(reason))."
            case .importFailed(let reason): "Saving to Photos failed (\(reason))."
            case .restoreMetadata(_, let reason):
                "The original was added to Photos, but its date or place couldn't be restored (\(reason)). Its compact copy wasn't removed."
            case .verificationFailed(let reason): "A downloaded file did not match (\(reason))."
            }
        }
    }

    enum Kind: Sendable, Equatable {
        case photo, livePhoto, video

        var name: String {
            switch self {
            case .photo: "Photo"
            case .livePhoto: "Live Photo"
            case .video: "Video"
            }
        }

        var symbol: String {
            switch self {
            case .photo: "photo"
            case .livePhoto: "livephoto"
            case .video: "video"
            }
        }

        var api: ServerAPI.AssetKind {
            switch self {
            case .photo: .photo
            case .livePhoto: .livePhoto
            case .video: .video
            }
        }
    }

    static func asset(_ localIdentifier: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject
    }

    /// Oldest capture first, like the Photos library, so copies are also added to Photos in
    /// capture order. Items without a date keep their order, after the dated ones.
    static func chronological(_ localIdentifiers: [String]) -> [String] {
        var dates: [String: Date] = [:]
        PHAsset.fetchAssets(withLocalIdentifiers: localIdentifiers, options: nil).enumerateObjects { asset, _, _ in
            dates[asset.localIdentifier] = asset.creationDate
        }
        return chronological(localIdentifiers, dates: dates)
    }

    static func chronological(_ identifiers: [String], dates: [String: Date]) -> [String] {
        identifiers.enumerated().sorted { a, b in
            switch (dates[a.element], dates[b.element]) {
            case let (x?, y?) where x != y: x < y
            case (_?, nil): true
            case (nil, _?): false
            default: a.offset < b.offset
            }
        }.map(\.element)
    }

    static func kind(of asset: PHAsset) -> Kind? {
        switch asset.mediaType {
        case .image: asset.mediaSubtypes.contains(.photoLive) ? .livePhoto : .photo
        case .video: .video
        default: nil
        }
    }

    /// File name and kind for display, or nil if the item cannot be fetched.
    static func describe(_ localIdentifier: String) -> (name: String, kind: Kind)? {
        guard let asset = asset(localIdentifier), let kind = kind(of: asset) else { return nil }
        let resources = PHAssetResource.assetResources(for: asset)
        let name = resources.first { [.photo, .video].contains($0.type) }?.originalFilename
            ?? resources.first?.originalFilename ?? "Item"
        return (name, kind)
    }

    static func baseName(_ resources: [PHAssetResource]) -> String {
        ((resources.first { [.photo, .video].contains($0.type) }?.originalFilename ?? "Homespun") as NSString)
            .deletingPathExtension
    }

    /// The current version of a resource: the edited render when there is one.
    static func current(_ resources: [PHAssetResource], _ edited: PHAssetResourceType,
                        _ original: PHAssetResourceType) -> PHAssetResource? {
        resources.first { $0.type == edited } ?? resources.first { $0.type == original }
    }

    static func role(of type: PHAssetResourceType) -> ServerAPI.ResourceRole {
        switch type {
        case .photo: .photo
        case .video: .video
        case .audio: .audio
        case .alternatePhoto: .alternatePhoto
        case .fullSizePhoto: .fullSizePhoto
        case .fullSizeVideo: .fullSizeVideo
        case .pairedVideo: .pairedVideo
        case .fullSizePairedVideo: .fullSizePairedVideo
        case .adjustmentData: .adjustmentData
        case .adjustmentBasePhoto: .adjustmentBasePhoto
        case .adjustmentBaseVideo: .adjustmentBaseVideo
        case .adjustmentBasePairedVideo: .adjustmentBasePairedVideo
        case .photoProxy: .photoProxy
        default: .other
        }
    }

    /// Copies one resource's bytes out of the library (downloading from iCloud if needed).
    static func export(_ resource: PHAssetResource, to directory: URL, name: String? = nil,
                       progress: @escaping @Sendable (String) -> Void) async throws -> URL {
        let url = directory.appendingPathComponent(name ?? resource.originalFilename)
        try? FileManager.default.removeItem(at: url)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        options.progressHandler = { fraction in progress("Downloading from iCloud \(Int(fraction * 100))%") }
        try await PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options)
        return url
    }

    static func size(of url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
    }

    /// A per-item work folder in the app's temporary directory.
    static func workDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Homespun/\(UUID().uuidString)",
                                                                                isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Saving

    /// What to create, captured up front because PhotoKit change blocks must be Sendable.
    struct ImportPlan: @unchecked Sendable {
        var resources: [(PHAssetResourceType, URL)] = []
        var creationDate: Date?
        var location: CLLocation?
        var isFavorite: Bool
        var isHidden: Bool

        init(asset: PHAsset) {
            creationDate = asset.creationDate
            location = asset.location
            isFavorite = asset.isFavorite
            isHidden = asset.isHidden
        }
    }

    private struct AlbumReference: @unchecked Sendable { let collection: PHAssetCollection }

    private final class IdentifierBox: @unchecked Sendable { var value: String? }

    /// Which of these items are still in the library, in one fetch. `includeHidden`: hidden items
    /// count as there (they are, the person only hid them).
    static func existing(_ localIdentifiers: [String], includeHidden: Bool = false) -> Set<String> {
        guard !localIdentifiers.isEmpty else { return [] }
        var found = Set<String>()
        let options = PHFetchOptions()
        options.includeHiddenAssets = includeHidden
        PHAsset.fetchAssets(withLocalIdentifiers: localIdentifiers, options: options).enumerateObjects { asset, _, _ in
            found.insert(asset.localIdentifier)
        }
        return found
    }

    /// About how many bytes these items' files take on this iPhone. Large sets are sampled (reading
    /// each item's file list is slow), so the answer is an estimate there.
    static func estimatedBytes(_ localIdentifiers: [String], sample: Int = 300) -> (bytes: Int, exact: Bool) {
        guard !localIdentifiers.isEmpty else { return (0, true) }
        let step = max(1, localIdentifiers.count / sample)
        let chosen = stride(from: 0, to: localIdentifiers.count, by: step).map { localIdentifiers[$0] }
        var total = 0
        PHAsset.fetchAssets(withLocalIdentifiers: chosen, options: nil).enumerateObjects { asset, _, _ in
            for resource in PHAssetResource.assetResources(for: asset) {
                total += (resource.value(forKey: "fileSize") as? Int) ?? 0
            }
        }
        guard step > 1 else { return (total, true) }
        return (Int(Double(total) / Double(chosen.count) * Double(localIdentifiers.count)), false)
    }

    /// Every photo and video in the library.
    static func allIdentifiers() -> [String] {
        let result = PHAsset.fetchAssets(with: nil)
        var identifiers: [String] = []
        identifiers.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in identifiers.append(asset.localIdentifier) }
        return identifiers
    }

    private struct AssetsReference: @unchecked Sendable { let assets: PHFetchResult<PHAsset> }

    /// Adds items to the Homespun album, creating it if needed.
    static func addToAlbum(_ localIdentifiers: [String]) async throws {
        guard !localIdentifiers.isEmpty else { return }
        let album = try await album()
        let found = AssetsReference(assets: PHAsset.fetchAssets(withLocalIdentifiers: localIdentifiers, options: nil))
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCollectionChangeRequest(for: album.collection)?.addAssets(found.assets)
        }
    }

    /// The identifiers of the items in the Homespun album.
    static func albumMembers() -> Set<String> {
        var members = Set<String>()
        albumAssets()?.enumerateObjects { asset, _, _ in members.insert(asset.localIdentifier) }
        return members
    }

    /// The items in the Homespun album, or `nil` if there is no album yet.
    static func albumAssets() -> PHFetchResult<PHAsset>? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title == %@", albumTitle)
        guard let album = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular,
                                                                 options: options).firstObject else { return nil }
        return PHAsset.fetchAssets(in: album, options: nil)
    }

    static func isCompactCopy(_ asset: PHAsset) -> Bool {
        var found = false
        PHAssetCollection.fetchAssetCollectionsContaining(asset, with: .album, options: nil)
            .enumerateObjects { collection, _, stop in
                if collection.localizedTitle == albumTitle {
                    found = true
                    stop.pointee = true
                }
            }
        return found
    }

    private static func album() async throws -> AlbumReference {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title == %@", albumTitle)
        if let existing = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular,
                                                                  options: options).firstObject {
            return AlbumReference(collection: existing)
        }
        let box = IdentifierBox()
        try await PHPhotoLibrary.shared().performChanges {
            box.value = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: albumTitle)
                .placeholderForCreatedAssetCollection.localIdentifier
        }
        guard let identifier = box.value, let created = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [identifier], options: nil).firstObject else {
            throw Failure.importFailed("could not create the \(albumTitle) album")
        }
        return AlbumReference(collection: created)
    }

    /// The resource type a file of `role` is added back to Photos as (Restore Original); nil for
    /// one Photos makes itself.
    static func type(for role: ServerAPI.ResourceRole) -> PHAssetResourceType? {
        switch role {
        case .photo: .photo
        case .video: .video
        case .audio: .audio
        case .pairedVideo: .pairedVideo
        case .alternatePhoto: .alternatePhoto
        case .fullSizePhoto: .fullSizePhoto
        case .fullSizeVideo: .fullSizeVideo
        case .fullSizePairedVideo: .fullSizePairedVideo
        case .adjustmentData: .adjustmentData
        case .adjustmentBasePhoto: .adjustmentBasePhoto
        case .adjustmentBaseVideo: .adjustmentBaseVideo
        case .adjustmentBasePairedVideo: .adjustmentBasePairedVideo
        case .photoProxy, .other: nil
        }
    }

    /// The person's own albums an item is in (not Homespun's), to put a restored original in them too.
    static func userAlbums(containing asset: PHAsset) -> [String] {
        var albums: [String] = []
        PHAssetCollection.fetchAssetCollectionsContaining(asset, with: .album, options: nil).enumerateObjects { album, _, _ in
            if album.assetCollectionSubtype == .albumRegular, album.localizedTitle != albumTitle, album.canPerform(.addContent) {
                albums.append(album.localIdentifier)
            }
        }
        return albums
    }

    /// Whether the person edited this item in Photos (its edits wouldn't carry over to another).
    static func isEdited(_ asset: PHAsset) -> Bool {
        PHAssetResource.assetResources(for: asset).contains { $0.type == .adjustmentData }
    }

    /// Library metadata is authoritative, including a date or location explicitly cleared in Photos.
    enum RestoreMetadata: @unchecked Sendable {
        case embedded
        case library(creationDate: Date?, location: CLLocation?)

        init(compact: PHAsset?) {
            if let compact {
                self = .library(creationDate: compact.creationDate, location: compact.location)
            } else {
                self = .embedded
            }
        }
    }

    /// Adds the original bytes with the compact copy's library attributes and albums.
    static func restore(_ files: [(role: ServerAPI.ResourceRole, url: URL)], favorite: Bool, hidden: Bool,
                        albums: [String], metadata: RestoreMetadata) async throws -> String {
        let typed = files.compactMap { file in type(for: file.role).map { (type: $0, url: file.url) } }
        guard !typed.isEmpty else { throw Failure.importFailed("nothing to add") }
        let collections = AlbumsReference(albums: PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: albums,
                                                                                          options: nil))
        let box = IdentifierBox()
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                for file in typed {
                    let options = PHAssetResourceCreationOptions()
                    options.originalFilename = file.url.lastPathComponent
                    options.shouldMoveFile = true
                    request.addResource(with: file.type, fileURL: file.url, options: options)
                }
                if case .library(let date, let location) = metadata {
                    request.creationDate = date
                    request.location = location
                }
                request.isFavorite = favorite
                request.isHidden = hidden
                guard let placeholder = request.placeholderForCreatedAsset else { return }
                box.value = placeholder.localIdentifier
                collections.albums.enumerateObjects { album, _, _ in
                    PHAssetCollectionChangeRequest(for: album)?.addAssets([placeholder] as NSArray)
                }
            }
        } catch {
            throw Failure.importFailed(error.localizedDescription)
        }
        guard let identifier = box.value else { throw Failure.importFailed("no asset was created") }
        // Clear nil values after creation too: Photos can initialize them from embedded file metadata.
        if case .library(let date, let location) = metadata {
            let options = PHFetchOptions()
            options.includeHiddenAssets = true
            guard let restored = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: options).firstObject else {
                throw Failure.restoreMetadata(identifier: identifier, message: "the restored item could not be read")
            }
            let reference = UncheckedAsset(asset: restored)
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    let request = PHAssetChangeRequest(for: reference.asset)
                    request.creationDate = date
                    request.location = location
                }
            } catch {
                throw Failure.restoreMetadata(identifier: identifier, message: error.localizedDescription)
            }
        }
        return identifier
    }

    private struct UncheckedAsset: @unchecked Sendable { let asset: PHAsset }

    private struct AlbumsReference: @unchecked Sendable { let albums: PHFetchResult<PHAssetCollection> }

    /// Creates the compact asset in the Homespun album and returns its local identifier.
    static func save(_ plan: ImportPlan) async throws -> String {
        let album = try await album()
        let box = IdentifierBox()
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                for (type, url) in plan.resources {
                    let options = PHAssetResourceCreationOptions()
                    options.originalFilename = url.lastPathComponent
                    request.addResource(with: type, fileURL: url, options: options)
                }
                request.creationDate = plan.creationDate
                request.location = plan.location
                request.isFavorite = plan.isFavorite
                request.isHidden = plan.isHidden
                guard let placeholder = request.placeholderForCreatedAsset else { return }
                box.value = placeholder.localIdentifier
                PHAssetCollectionChangeRequest(for: album.collection)?.addAssets([placeholder] as NSArray)
            }
        } catch {
            throw Failure.importFailed(error.localizedDescription)
        }
        guard let identifier = box.value else { throw Failure.importFailed("no asset was created") }
        return identifier
    }

    /// Skips items already backed up with a compact copy, and compact copies themselves (known
    /// to this iPhone, or in the Homespun album). The server also refuses copies it made.
    /// (A copy made on this iPhone by the old on-phone mode doesn't count: the original still
    /// needs backing up.)
    static func skipReason(for asset: PHAsset, ledger: CompactLedger) async -> String? {
        if let entry = await ledger.entry(for: asset.localIdentifier), entry.serverAssetID != nil,
           self.asset(entry.compactIdentifier) != nil {
            return "Already has a compact copy"
        }
        if await ledger.isCompactCopy(asset.localIdentifier) || isCompactCopy(asset) {
            return "This is a Homespun compact copy"
        }
        return nil
    }

    static func describe(heldReasons: [String]) -> String {
        let names = [
            "hdr": "HDR video", "dolby_vision": "Dolby Vision", "high_frame_rate": "high frame rate",
            "spatial_audio": "spatial audio", "multichannel_audio": "multichannel audio",
        ]
        return heldReasons.map { names[$0] ?? $0 }.joined(separator: ", ")
    }
}
