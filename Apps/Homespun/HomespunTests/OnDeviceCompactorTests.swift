// SPDX-License-Identifier: Apache-2.0
import CoreLocation
import Foundation
import HomespunTestSupport
import Photos
import Testing
@testable import Homespun

/// Runs the on-phone pipeline against a simulator library that holds only synthetic media.
/// Grant access first: `xcrun simctl privacy <device> grant photos photos.homespun.app.dev`.
@Suite(.serialized) struct OnDeviceCompactorTests {
    static var authorized: Bool { PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized }

    private final class Box: @unchecked Sendable { var value: String? }

    private func createOriginal(_ resources: [(PHAssetResourceType, URL)], date: Date, favorite: Bool) async throws -> String {
        let box = Box()
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            for (type, url) in resources { request.addResource(with: type, fileURL: url, options: nil) }
            request.creationDate = date
            request.location = CLLocation(latitude: 37.33, longitude: -122.01)
            request.isFavorite = favorite
            box.value = request.placeholderForCreatedAsset?.localIdentifier
        }
        return try #require(box.value)
    }

    private func asset(_ identifier: String) throws -> PHAsset {
        try #require(PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject)
    }

    @Test(.enabled(if: authorized, "Photo library access was not granted to the test host"))
    func savesCompactCopiesBesideUntouchedOriginals() async throws {
        let directory = try Synthetic.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pairing = UUID().uuidString
        let still = directory.appendingPathComponent("IMG_0001.HEIC")
        let motion = directory.appendingPathComponent("IMG_0001.MOV")
        let photo = directory.appendingPathComponent("IMG_0002.JPG")
        let movie = directory.appendingPathComponent("IMG_0003.MOV")
        try Synthetic.photo(at: still, .init(type: .heic, contentIdentifier: pairing))
        try await Synthetic.video(at: motion, .init(width: 960, height: 720, frames: 30, bitrate: 12_000_000,
                                                    audioChannels: 1, liveIdentifier: pairing))
        try Synthetic.photo(at: photo, .init())
        try await Synthetic.video(at: movie, .init(width: 1920, height: 1080, frames: 20))

        let date = Date(timeIntervalSince1970: 1_714_592_096)
        let originals = [
            try await createOriginal([(.photo, still), (.pairedVideo, motion)], date: date, favorite: true),
            try await createOriginal([(.photo, photo)], date: date, favorite: false),
            try await createOriginal([(.video, movie)], date: date, favorite: false),
        ]
        #expect(try asset(originals[0]).mediaSubtypes.contains(.photoLive))

        let compactor = OnDeviceCompactor(ledger: CompactLedger(url: directory.appendingPathComponent("ledger.json")))
        for identifier in originals {
            let outcome = try await compactor.compact(identifier) { _ in }
            guard case .saved(let compactIdentifier, let before, let after) = outcome else {
                Issue.record("\(identifier): \(outcome)")
                continue
            }
            #expect(after < before)
            let original = try asset(identifier), compact = try asset(compactIdentifier)
            #expect(compact.mediaType == original.mediaType)
            #expect(compact.mediaSubtypes.contains(.photoLive) == original.mediaSubtypes.contains(.photoLive))
            #expect(compact.creationDate == date)
            #expect(compact.isFavorite == original.isFavorite)
            #expect(abs((compact.location?.coordinate.latitude ?? 0) - 37.33) < 0.0001)
            #expect(PhotoLibrary.isCompactCopy(compact))
            #expect(!PhotoLibrary.isCompactCopy(original))
            if compact.mediaType == .image {
                #expect(max(compact.pixelWidth, compact.pixelHeight) == 2048)
            }

            // Picking either item again does not save another copy.
            #expect(try await compactor.compact(identifier) { _ in } == .unchanged("Already has a compact copy"))
            #expect(try await compactor.compact(compactIdentifier) { _ in }
                    == .unchanged("This is a Homespun compact copy"))
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("Homespun")
        #expect((try? FileManager.default.contentsOfDirectory(atPath: work.path))?.isEmpty ?? true)
    }
}
