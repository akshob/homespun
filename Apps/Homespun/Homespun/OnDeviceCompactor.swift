// SPDX-License-Identifier: Apache-2.0
import CoreLocation
import Foundation
import HomespunCore
import HomespunMedia
import Photos

/// On-phone mode: compresses library items with Apple's encoders and saves the compact copies
/// to the "Homespun" album with the original's date, location, favorite, and hidden state.
///
/// Originals are never modified or deleted here. Without a server copy, `DeletionGate` cannot
/// allow deletion, so on-phone mode only adds compact copies.
struct OnDeviceCompactor: Sendable {
    static let albumTitle = "Homespun"

    enum Outcome: Equatable, Sendable {
        case saved(compactIdentifier: String, originalBytes: Int, compactBytes: Int)
        /// Nothing was saved; the reason is shown to the user.
        case unchanged(String)
    }

    enum Failure: LocalizedError {
        case notFound
        case unsupported(String)
        case missingResource(String)
        case livePhotoInvalid(String)
        case importFailed(String)

        var errorDescription: String? {
            switch self {
            case .notFound: "The item is no longer in the library, or Homespun has limited access."
            case .unsupported(let kind): "\(kind) items are not supported."
            case .missingResource(let name): "The \(name) could not be found."
            case .livePhotoInvalid(let reason): "The compact Live Photo did not validate (\(reason))."
            case .importFailed(let reason): "Saving to Photos failed (\(reason))."
            }
        }
    }

    enum Kind: Sendable {
        case photo, livePhoto, video

        var symbol: String {
            switch self {
            case .photo: "photo"
            case .livePhoto: "livephoto"
            case .video: "video"
            }
        }
    }

    var profile: CompressionProfile = .standard
    var ledger: CompactLedger
    var workRoot = FileManager.default.temporaryDirectory.appendingPathComponent("Homespun", isDirectory: true)

    /// File name and kind for display, or nil if the item cannot be fetched.
    static func describe(_ localIdentifier: String) -> (name: String, kind: Kind)? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject,
              let kind = kind(of: asset) else { return nil }
        let resources = PHAssetResource.assetResources(for: asset)
        let name = resources.first { [.photo, .video].contains($0.type) }?.originalFilename
            ?? resources.first?.originalFilename ?? "Item"
        return (name, kind)
    }

    private static func kind(of asset: PHAsset) -> Kind? {
        switch asset.mediaType {
        case .image: asset.mediaSubtypes.contains(.photoLive) ? .livePhoto : .photo
        case .video: .video
        default: nil
        }
    }

    func compact(_ localIdentifier: String, progress: @escaping @Sendable (String) -> Void) async throws -> Outcome {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject else {
            throw Failure.notFound
        }
        guard let kind = Self.kind(of: asset) else { throw Failure.unsupported("Audio") }
        if let existing = await ledger.compactIdentifier(for: localIdentifier),
           PHAsset.fetchAssets(withLocalIdentifiers: [existing], options: nil).count > 0 {
            return .unchanged("Already has a compact copy")
        }
        if Self.isCompactCopy(asset) { return .unchanged("This is a Homespun compact copy") }

        let work = workRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let originals = work.appendingPathComponent("original", isDirectory: true)
        let compacts = work.appendingPathComponent("compact", isDirectory: true)
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: compacts, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        // The current version (with the user's edits, such as a Portrait blur or a crop) is what
        // the compact copy should look like.
        let resources = PHAssetResource.assetResources(for: asset)
        func current(_ edited: PHAssetResourceType, _ original: PHAssetResourceType) -> PHAssetResource? {
            resources.first { $0.type == edited } ?? resources.first { $0.type == original }
        }
        let stem = ((resources.first { [.photo, .video].contains($0.type) }?.originalFilename ?? "Homespun")
            as NSString).deletingPathExtension

        var plan = ImportPlan(asset: asset)
        let originalBytes: Int, compactBytes: Int
        switch kind {
        case .photo:
            guard let still = current(.fullSizePhoto, .photo) else { throw Failure.missingResource("photo") }
            let source = try await export(still, to: originals, progress: progress)
            originalBytes = try Self.size(of: source)
            progress("Compressing")
            let photo = try ImageIOPhotoCompressor(profile: profile)
                .compress(input: source, output: compacts.appendingPathComponent("\(stem).jpg"))
            guard photo.mode == .compressed else { return .unchanged("Already compact") }
            plan.resources = [(.photo, photo.url)]
            compactBytes = photo.size

        case .livePhoto:
            guard let still = current(.fullSizePhoto, .photo) else { throw Failure.missingResource("photo") }
            guard let motion = current(.fullSizePairedVideo, .pairedVideo) else {
                throw Failure.missingResource("Live Photo motion")
            }
            let stillSource = try await export(still, to: originals, progress: progress)
            let motionSource = try await export(motion, to: originals, progress: progress)
            originalBytes = try Self.size(of: stillSource) + Self.size(of: motionSource)
            progress("Compressing")
            let photo = try ImageIOPhotoCompressor(profile: profile)
                .compress(input: stillSource, output: compacts.appendingPathComponent("\(stem).jpg"))
            let motionOutput = compacts.appendingPathComponent("\(stem).mov")
            let video = try await LivePhotoMotionCompressor(profile: profile)
                .compress(input: motionSource, output: motionOutput)
            guard photo.mode == .compressed || video.mode == .transcoded else { return .unchanged("Already compact") }
            progress("Checking Live Photo")
            if case .invalid(let reason) = await LivePhotoValidator.validate(photo: photo.url, video: motionOutput) {
                throw Failure.livePhotoInvalid(reason)
            }
            plan.resources = [(.photo, photo.url), (.pairedVideo, motionOutput)]
            compactBytes = photo.size + video.size

        case .video:
            guard let movie = current(.fullSizeVideo, .video) else { throw Failure.missingResource("video") }
            let source = try await export(movie, to: originals, progress: progress)
            originalBytes = try Self.size(of: source)
            progress("Compressing")
            let output = compacts.appendingPathComponent("\(stem).mov")
            let video = try await AVFoundationVideoCompressor(profile: profile).compress(input: source, output: output)
            switch video.mode {
            case .transcoded:
                plan.resources = [(.video, output)]
                compactBytes = video.size
            case .originalKeptNotSmaller: return .unchanged("Already compact")
            case .originalKeptHeld: return .unchanged("Kept as is: " + Self.describe(heldReasons: video.heldReasons))
            }
        }

        guard compactBytes < originalBytes else { return .unchanged("Already compact") }

        progress("Saving")
        let album = try await Self.album()
        let identifier = try await Self.save(plan, to: album)
        try await ledger.record(original: localIdentifier, compact: identifier,
                                originalBytes: originalBytes, compactBytes: compactBytes)
        return .saved(compactIdentifier: identifier, originalBytes: originalBytes, compactBytes: compactBytes)
    }

    private func export(_ resource: PHAssetResource, to directory: URL,
                        progress: @escaping @Sendable (String) -> Void) async throws -> URL {
        let url = directory.appendingPathComponent(resource.originalFilename)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        options.progressHandler = { fraction in progress("Downloading \(Int(fraction * 100))%") }
        progress("Reading")
        try await PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options)
        return url
    }

    private static func size(of url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
    }

    static func describe(heldReasons: [String]) -> String {
        let names = [
            "hdr": "HDR video", "dolby_vision": "Dolby Vision", "high_frame_rate": "high frame rate",
            "spatial_audio": "spatial audio", "multichannel_audio": "multichannel audio",
        ]
        return heldReasons.map { names[$0] ?? $0 }.joined(separator: ", ")
    }

    // MARK: Photo library

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

    private final class IdentifierBox: @unchecked Sendable {
        var value: String?
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

    private static func save(_ plan: ImportPlan, to album: AlbumReference) async throws -> String {
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
}
