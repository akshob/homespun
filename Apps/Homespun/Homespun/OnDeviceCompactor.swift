// SPDX-License-Identifier: Apache-2.0
import Foundation
import HomespunCore
import HomespunMedia
import Photos

/// On-phone mode: compresses library items with Apple's encoders and saves the compact copies
/// to the "Homespun" album with the original's date, location, favorite, and hidden state.
///
/// Originals are never modified or deleted here. Without a server copy, `DeletionGate` cannot
/// allow deletion, so on-phone mode only adds compact copies.
struct OnDeviceCompactor: Compacting {
    var profile: CompressionProfile = .standard
    var ledger: CompactLedger

    func compact(_ localIdentifier: String, progress: @escaping @Sendable (String) -> Void) async throws -> CompactOutcome {
        guard let asset = PhotoLibrary.asset(localIdentifier) else { throw PhotoLibrary.Failure.notFound }
        guard let kind = PhotoLibrary.kind(of: asset) else { throw PhotoLibrary.Failure.unsupported("Audio items are not supported.") }
        if let reason = await PhotoLibrary.skipReason(for: asset, ledger: ledger) { return .unchanged(reason) }

        let work = try PhotoLibrary.workDirectory()
        let originals = work.appendingPathComponent("original", isDirectory: true)
        let compacts = work.appendingPathComponent("compact", isDirectory: true)
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: compacts, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        // The current version (with the user's edits, such as a Portrait blur or a crop) is what
        // the compact copy should look like.
        let resources = PHAssetResource.assetResources(for: asset)
        let stem = PhotoLibrary.baseName(resources)
        var plan = PhotoLibrary.ImportPlan(asset: asset)
        let originalBytes: Int, compactBytes: Int
        progress("Reading")
        switch kind {
        case .photo:
            guard let still = PhotoLibrary.current(resources, .fullSizePhoto, .photo) else {
                throw PhotoLibrary.Failure.missingResource("photo")
            }
            let source = try await PhotoLibrary.export(still, to: originals, progress: progress)
            originalBytes = try PhotoLibrary.size(of: source)
            progress("Compressing")
            let photo = try ImageIOPhotoCompressor(profile: profile)
                .compress(input: source, output: compacts.appendingPathComponent("\(stem).jpg"))
            guard photo.mode == .compressed else { return .unchanged("Already compact") }
            plan.resources = [(.photo, photo.url)]
            compactBytes = photo.size

        case .livePhoto:
            guard let still = PhotoLibrary.current(resources, .fullSizePhoto, .photo) else {
                throw PhotoLibrary.Failure.missingResource("photo")
            }
            guard let motion = PhotoLibrary.current(resources, .fullSizePairedVideo, .pairedVideo) else {
                throw PhotoLibrary.Failure.missingResource("Live Photo motion")
            }
            let stillSource = try await PhotoLibrary.export(still, to: originals, progress: progress)
            let motionSource = try await PhotoLibrary.export(motion, to: originals, progress: progress)
            originalBytes = try PhotoLibrary.size(of: stillSource) + PhotoLibrary.size(of: motionSource)
            progress("Compressing")
            let photo = try ImageIOPhotoCompressor(profile: profile)
                .compress(input: stillSource, output: compacts.appendingPathComponent("\(stem).jpg"))
            let motionOutput = compacts.appendingPathComponent("\(stem).mov")
            let video = try await LivePhotoMotionCompressor(profile: profile)
                .compress(input: motionSource, output: motionOutput)
            guard photo.mode == .compressed || video.mode == .transcoded else { return .unchanged("Already compact") }
            progress("Checking Live Photo")
            if case .invalid(let reason) = await LivePhotoValidator.validate(photo: photo.url, video: motionOutput) {
                throw PhotoLibrary.Failure.livePhotoInvalid(reason)
            }
            plan.resources = [(.photo, photo.url), (.pairedVideo, motionOutput)]
            compactBytes = photo.size + video.size

        case .video:
            guard let movie = PhotoLibrary.current(resources, .fullSizeVideo, .video) else {
                throw PhotoLibrary.Failure.missingResource("video")
            }
            let source = try await PhotoLibrary.export(movie, to: originals, progress: progress)
            originalBytes = try PhotoLibrary.size(of: source)
            progress("Compressing")
            let output = compacts.appendingPathComponent("\(stem).mov")
            let video = try await AVFoundationVideoCompressor(profile: profile).compress(input: source, output: output)
            switch video.mode {
            case .transcoded:
                plan.resources = [(.video, output)]
                compactBytes = video.size
            case .originalKeptNotSmaller: return .unchanged("Already compact")
            case .originalKeptHeld:
                return .unchanged("Kept as is: " + PhotoLibrary.describe(heldReasons: video.heldReasons))
            }
        }
        guard compactBytes < originalBytes else { return .unchanged("Already compact") }

        progress("Saving")
        let identifier = try await PhotoLibrary.save(plan)
        try await ledger.record(original: localIdentifier, compact: identifier,
                                originalBytes: originalBytes, compactBytes: compactBytes)
        return .saved(compactIdentifier: identifier, originalBytes: originalBytes, compactBytes: compactBytes)
    }
}
