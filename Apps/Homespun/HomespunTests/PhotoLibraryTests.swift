// SPDX-License-Identifier: Apache-2.0
import CoreLocation
import Foundation
import HomespunCore
import HomespunTestSupport
import ImageIO
import Photos
import Testing
import UniformTypeIdentifiers
@testable import Homespun

/// Saves compact copies the way the server path does, on a simulator library that holds only
/// synthetic media. Grant access first: `xcrun simctl privacy <device> grant photos photos.homespun.app.dev`.
@Suite(.serialized) struct PhotoLibraryTests {
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

    private func opaquePhotoInputs(type: UTType, fileExtension suffix: String) throws
        -> (directory: URL, workspace: BackupFiles, resource: PreparedPhotoResource) {
        let directory = try Synthetic.directory()
        var prepared = false
        defer { if !prepared { try? FileManager.default.removeItem(at: directory) } }
        let workspace = BackupFiles(root: directory.appendingPathComponent("Backup"))
        try workspace.prepare()
        let operation = UUID()
        _ = try workspace.prepareStaging(operationID: operation)
        let opaqueID = UUID()
        let opaque = workspace.stagedFile(operationID: operation, fileID: opaqueID)
        try Synthetic.photo(at: opaque, .init(type: type, width: 192, height: 128))
        try BackupFiles.protect(opaque)
        let expected = try Fingerprint.digests(of: opaque)
        let descriptor = ServerAPI.ResourceDescriptor(role: .photo, filename: "declared." + suffix,
                                                       size: expected.size, sha256: expected.sha256, sha1: expected.sha1)
        let source = try #require(CGImageSourceCreateWithURL(opaque as CFURL, nil))
        let actualType = try #require(CGImageSourceGetType(source)) as String
        #expect(actualType == type.identifier && CGImageSourceGetStatus(source) == .statusComplete)
        prepared = true
        return (directory, workspace, .init(fileID: opaqueID, url: opaque, descriptor: descriptor))
    }

    private func opaqueMetadata(_ resource: PreparedPhotoResource) -> BackupPhotoMetadata {
        .init(sourceID: "synthetic-opaque-photo", kind: .photo, creationDate: Date(timeIntervalSince1970: 1_100_000_000),
              locationArchive: nil, favorite: true, hidden: false, albums: [],
              generation: .init(identifier: "synthetic-opaque-photo", modified: nil, width: 192, height: 128,
                                resources: [.init(role: .photo, name: resource.descriptor.filename, bytes: resource.descriptor.size)]))
    }

    @Test(.enabled(if: authorized, "Photo library access was not granted to the test host"))
    func opaqueUUIDCompactImportKeepsVerifiedBytesAndDeclaredType() async throws {
        let photos = PhotoKitSource()
        for (type, suffix) in [(UTType.jpeg, "jpg"), (UTType.heic, "heic")] {
            let inputs = try opaquePhotoInputs(type: type, fileExtension: suffix)
            defer { try? FileManager.default.removeItem(at: inputs.directory) }
            let resource = inputs.resource
            let identifier = try await photos.importCompact([resource], metadata: opaqueMetadata(resource))
            let actual = try await photos.resourceFingerprints(identifier)
            #expect(BackupValidation.matches([resource.descriptor], actual))
            let imported = try asset(identifier)
            #expect(imported.isFavorite && PhotoLibrary.isCompactCopy(imported))
            #expect(PHAssetResource.assetResources(for: imported).first?.originalFilename == resource.descriptor.filename)
            let retained = try Fingerprint.digests(of: resource.url)
            #expect(retained.sha256 == resource.descriptor.sha256 && retained.size == resource.descriptor.size)
            #expect(try PhotoResourceHandoff.orphans(in: inputs.workspace.staging).isEmpty)
        }
    }

    @Test(.enabled(if: authorized, "Photo library access was not granted to the test host"))
    func opaqueUUIDRestoreKeepsVerifiedBytesAndDeclaredName() async throws {
        let photos = PhotoKitSource()
        for (type, suffix) in [(UTType.jpeg, "jpg"), (UTType.heic, "heic")] {
            let inputs = try opaquePhotoInputs(type: type, fileExtension: suffix)
            defer { try? FileManager.default.removeItem(at: inputs.directory) }
            let resource = inputs.resource
            let identifier = try await photos.restoreResources([resource], metadata: opaqueMetadata(resource))
            let actual = try await photos.resourceFingerprints(identifier)
            #expect(BackupValidation.matches([resource.descriptor], actual))
            let restored = try asset(identifier)
            #expect(restored.creationDate == opaqueMetadata(resource).creationDate && restored.location == nil)
            #expect(PHAssetResource.assetResources(for: restored).first?.originalFilename == resource.descriptor.filename)
            let retained = try Fingerprint.digests(of: resource.url)
            #expect(retained.sha256 == resource.descriptor.sha256 && retained.size == resource.descriptor.size)
            #expect(try PhotoResourceHandoff.orphans(in: inputs.workspace.staging).isEmpty)
        }
    }

    @Test(.enabled(if: authorized, "Photo library access was not granted to the test host"))
    func opaqueUUIDLivePhotoImportAndRestorePreserveBothResources() async throws {
        let directory = try Synthetic.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = BackupFiles(root: directory.appendingPathComponent("Backup"))
        try workspace.prepare()
        let operation = UUID(), stillID = UUID(), motionID = UUID(), pairing = UUID().uuidString
        _ = try workspace.prepareStaging(operationID: operation)
        let still = workspace.stagedFile(operationID: operation, fileID: stillID)
        let motion = workspace.stagedFile(operationID: operation, fileID: motionID)
        try Synthetic.photo(at: still, .init(type: .heic, width: 320, height: 240, contentIdentifier: pairing))
        try await Synthetic.video(at: motion, .init(width: 320, height: 240, frames: 12, audioChannels: 1, liveIdentifier: pairing))
        let resources = try [(stillID, ServerAPI.ResourceRole.photo, still, "declared.HEIC"),
                             (motionID, ServerAPI.ResourceRole.pairedVideo, motion, "declared.MOV")].map { id, role, url, name in
            try BackupFiles.protect(url)
            let digest = try Fingerprint.digests(of: url)
            return PreparedPhotoResource(fileID: id, url: url,
                descriptor: .init(role: role, filename: name, size: digest.size, sha256: digest.sha256, sha1: digest.sha1))
        }
        var metadata = opaqueMetadata(resources[0])
        metadata.kind = .livePhoto
        metadata.generation.width = 320; metadata.generation.height = 240
        metadata.generation.resources = resources.map { .init(role: $0.descriptor.role, name: $0.descriptor.filename, bytes: $0.descriptor.size) }
        let photos = PhotoKitSource()
        for restore in [false, true] {
            let identifier: String
            if restore { identifier = try await photos.restoreResources(resources, metadata: metadata) }
            else { identifier = try await photos.importCompact(resources, metadata: metadata) }
            #expect(try asset(identifier).mediaSubtypes.contains(.photoLive))
            let actual = try await photos.resourceFingerprints(identifier)
            #expect(BackupValidation.matches(resources.map(\.descriptor), actual))
            for resource in resources {
                let retained = try Fingerprint.digests(of: resource.url)
                #expect(retained.sha256 == resource.descriptor.sha256 && retained.size == resource.descriptor.size)
            }
            #expect(try PhotoResourceHandoff.orphans(in: workspace.staging).isEmpty)
        }
    }

    @Test(.enabled(if: authorized, "Photo library access was not granted to the test host"))
    func compactCopiesKeepTheOriginalsDetails() async throws {
        let directory = try Synthetic.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        func file(_ name: String) -> URL { directory.appendingPathComponent(name) }
        // Copies in their own folder: the file system ignores case (IMG_0002.JPG is IMG_0002.jpg).
        func copy(_ name: String) -> URL { directory.appendingPathComponent("compact/" + name) }
        try FileManager.default.createDirectory(at: copy(""), withIntermediateDirectories: true)
        let pairing = UUID().uuidString, compactPairing = pairing
        try Synthetic.photo(at: file("IMG_0001.HEIC"), .init(type: .heic, contentIdentifier: pairing))
        try await Synthetic.video(at: file("IMG_0001.MOV"), .init(width: 960, height: 720, frames: 30, bitrate: 12_000_000,
                                                                  audioChannels: 1, liveIdentifier: pairing))
        try Synthetic.photo(at: file("IMG_0002.JPG"), .init())
        // What the server sends back: smaller files, the Live pair still sharing its identifier.
        try Synthetic.photo(at: copy("IMG_0001.jpg"), .init(width: 2048, height: 1536, quality: 0.8,
                                                            contentIdentifier: compactPairing))
        try await Synthetic.video(at: copy("IMG_0001.mov"), .init(width: 640, height: 480, frames: 30, bitrate: 2_000_000,
                                                                  audioChannels: 1, liveIdentifier: compactPairing))
        try Synthetic.photo(at: copy("IMG_0002.jpg"), .init(width: 2048, height: 1536, quality: 0.8))

        let date = Date(timeIntervalSince1970: 1_714_592_096)
        let live = try await createOriginal([(.photo, file("IMG_0001.HEIC")), (.pairedVideo, file("IMG_0001.MOV"))],
                                            date: date, favorite: true)
        let photo = try await createOriginal([(.photo, file("IMG_0002.JPG"))], date: date, favorite: false)
        #expect(try asset(live).mediaSubtypes.contains(.photoLive))

        let copies: [(String, [(PHAssetResourceType, URL)])] = [
            (live, [(.photo, copy("IMG_0001.jpg")), (.pairedVideo, copy("IMG_0001.mov"))]),
            (photo, [(.photo, copy("IMG_0002.jpg"))]),
        ]
        for (identifier, resources) in copies {
            let original = try asset(identifier)
            var plan = PhotoLibrary.ImportPlan(asset: original)
            plan.resources = resources
            let compact = try asset(try await PhotoLibrary.save(plan))
            #expect(compact.mediaType == original.mediaType)
            #expect(compact.mediaSubtypes.contains(.photoLive) == original.mediaSubtypes.contains(.photoLive))
            #expect(compact.creationDate == date && compact.isFavorite == original.isFavorite)
            #expect(abs((compact.location?.coordinate.latitude ?? 0) - 37.33) < 0.0001)
            #expect(PhotoLibrary.isCompactCopy(compact) && !PhotoLibrary.isCompactCopy(original))
            #expect(PhotoLibrary.albumMembers().contains(compact.localIdentifier))
        }
    }

    /// Restore Original: a Live Photo's files go back into Photos byte for byte, with the compact
    /// copy's favorite and its place in the person's own albums (not Homespun's).
    @Test(.enabled(if: authorized, "Photo library access was not granted to the test host"))
    func restoredOriginalsAreTheSameBytesWithTheCopysChoices() async throws {
        let directory = try Synthetic.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pairing = UUID().uuidString
        let photo = directory.appendingPathComponent("photo/IMG_0042.HEIC"), motion = directory.appendingPathComponent("paired_video/IMG_0042.MOV")
        for url in [photo, motion] { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) }
        try Synthetic.photo(at: photo, .init(type: .heic, contentIdentifier: pairing))
        try await Synthetic.video(at: motion, .init(width: 960, height: 720, frames: 30, bitrate: 8_000_000, audioChannels: 1,
                                                    liveIdentifier: pairing))
        let expected = [ServerAPI.ResourceRole.photo: try Fingerprint.sha256(of: photo), .pairedVideo: try Fingerprint.sha256(of: motion)]
        // One of the person's albums the compact copy was in.
        let box = Box()
        try await PHPhotoLibrary.shared().performChanges {
            box.value = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: "Trip \(UUID().uuidString.prefix(4))")
                .placeholderForCreatedAssetCollection.localIdentifier
        }
        let album = try #require(box.value)

        let adjustedDate = Date(timeIntervalSince1970: 1_200_000_000)
        let restored = try asset(try await PhotoLibrary.restore([(.photo, photo), (.pairedVideo, motion)], favorite: true, hidden: false,
                                                                 albums: [album],
                                                                 metadata: .library(creationDate: adjustedDate,
                                                                                    location: CLLocation(latitude: 48, longitude: 2))))
        #expect(restored.mediaSubtypes.contains(.photoLive) && restored.isFavorite && !restored.isHidden)
        #expect(PhotoLibrary.userAlbums(containing: restored) == [album])
        #expect(!PhotoLibrary.albumMembers().contains(restored.localIdentifier))
        #expect(restored.creationDate == adjustedDate)
        #expect(abs((restored.location?.coordinate.latitude ?? 0) - 48) < 0.0001)
        let names = PHAssetResource.assetResources(for: restored).map(\.originalFilename)
        #expect(names.contains("IMG_0042.HEIC") && names.contains("IMG_0042.MOV"))
        let check = try Synthetic.directory()
        defer { try? FileManager.default.removeItem(at: check) }
        let held = try await ServerCompactor.export(PHAssetResource.assetResources(for: restored), to: check) { _ in }
        #expect(Dictionary(held.map { ($0.role, $0.descriptor.sha256) }, uniquingKeysWith: { a, _ in a }) == expected)
        #expect(!PhotoLibrary.isEdited(restored))
    }

    @Test(.enabled(if: authorized, "Photo library access was not granted to the test host"))
    func restoreDoesNotResurrectClearedLibraryLocation() async throws {
        let directory = try Synthetic.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("located.jpg")
        try Synthetic.photo(at: file, .init())
        let expected = try Fingerprint.sha256(of: file)
        let date = Date(timeIntervalSince1970: 1_000_000_000)
        let restored = try asset(try await PhotoLibrary.restore([(.photo, file)], favorite: false, hidden: false, albums: [],
                                                                 metadata: .library(creationDate: date, location: nil)))
        #expect(restored.location == nil && restored.creationDate == date)
        let check = directory.appendingPathComponent("check")
        try FileManager.default.createDirectory(at: check, withIntermediateDirectories: true)
        let held = try await ServerCompactor.export(PHAssetResource.assetResources(for: restored), to: check) { _ in }
        #expect(held.first?.descriptor.sha256 == expected)
    }

    @Test(.enabled(if: authorized, "Photo library access was not granted to the test host"))
    func metadataFreeRestorationUsesTheLibraryDateAndLocation() async throws {
        let directory = try Synthetic.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("undated.png")
        let destination = try #require(CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, Synthetic.texture(width: 128, height: 96), nil)
        try #require(CGImageDestinationFinalize(destination))
        let date = Date(timeIntervalSince1970: 1_100_000_000)
        let restored = try asset(try await PhotoLibrary.restore([(.photo, file)], favorite: true, hidden: false, albums: [],
                                                                 metadata: .library(creationDate: date,
                                                                                    location: CLLocation(latitude: -33.8, longitude: 151.2))))
        #expect(restored.creationDate == date && restored.isFavorite)
        #expect(abs((restored.location?.coordinate.latitude ?? 0) + 33.8) < 0.0001)
    }
}

@Test func pickedItemsAreQueuedOldestFirst() {
    let dates = ["2011": Date(timeIntervalSince1970: 1_300_000_000), "2009": Date(timeIntervalSince1970: 1_255_000_000),
                 "2018": Date(timeIntervalSince1970: 1_522_000_000), "same": Date(timeIntervalSince1970: 1_300_000_000)]
    // The picker lists newest first; ties and undated items keep the picker's order.
    #expect(PhotoLibrary.chronological(["2018", "undated", "2011", "same", "2009"], dates: dates)
            == ["2009", "2011", "same", "2018", "undated"])
}

@Test func legacyGridRelationshipsDoNotPretendToHaveCurrentServerProof() {
    func entry(_ compact: String, server: Bool) -> CompactLedger.Entry {
        .init(compactIdentifier: compact, originalBytes: 100, compactBytes: 10, savedAt: Date(),
              serverAssetID: server ? "sha-\(compact)" : nil)
    }

    let ledger = ["orig-kept": entry("copy-kept", server: true),      // original still on the phone
                  "orig-removed": entry("copy-removed", server: true), // original removed after backup
                  "orig-device": entry("copy-device", server: false),  // made on the phone only
                  "orig-gone": entry("copy-missing", server: true)]    // copy deleted by the user
    let library = ["orig-kept", "copy-kept", "copy-removed", "orig-device", "copy-device", "orig-gone",
                   "album-only", "plain", "busy", "broken"]
    let state = LibraryState(library: library, ledger: ledger, album: ["album-only", "copy-kept"],
                             job: ["busy": .working("Uploading"), "broken": .failed("x"), "plain": .saved(originalBytes: 1, compactBytes: 1)])
    let badges = Dictionary(uniqueKeysWithValues: state.cells.map { ($0.id, $0.badge) })
    // A backed-up original with its copy in the library is shown as the copy. An old on-phone
    // copy doesn't hide its original, which can still be backed up.
    #expect(state.cells.map(\.id) == ["copy-kept", "copy-removed", "orig-device", "copy-device", "orig-gone", "album-only",
                                      "plain", "busy", "broken"])
    #expect(badges == ["copy-kept": .recovery, "copy-removed": .recovery, "orig-device": .none,
                       "copy-device": .compactCopy, "orig-gone": .none, "album-only": .compactCopy, "plain": .none,
                       "busy": .working, "broken": .failed])
    let kept = state.cells[0], device = state.cells[2]
    #expect(!kept.canFree && !kept.canRestore && kept.original == "orig-kept" && device.canCompact && !device.canFree)
    // The Filter menu: needing attention is its own filter, and copies with no known original
    // show only under All Items.
    #expect(state.cells(.notBackedUp).map(\.id) == ["orig-device", "orig-gone", "plain", "busy"])
    #expect(state.cells(.readyToFree).isEmpty)
    #expect(state.cells(.atHome).isEmpty)
    #expect(state.cells(.needsAttention).map(\.id) == ["copy-kept", "copy-removed", "broken"])
    #expect(LibraryState.Filter.allCases.map { state.count($0) } == [9, 4, 0, 0, 0, 3])
}

@Test func readyBadgesRequireTheMatchingOriginAndNonPurgeEligibleProof() {
    let origin = BackupAPI.Origin(serverID: "home", historyEpoch: "history")
    let hash = Fingerprint.sha256(of: Data("original".utf8))
    let version = BackupAPI.Version(origin: origin, assetID: hash, manifestID: hash, descriptorGeneration: 1, recipeID: hash)
    var entry = CompactLedger.Entry(compactIdentifier: "copy", originalBytes: 100, compactBytes: 10,
        savedAt: Date(), serverAssetID: hash, origin: origin, version: version, requestID: UUID(),
        compactResources: [.init(role: .photo, filename: "copy.heic", size: 10, sha256: hash)], retention: .permanent)
    func cell(_ active: BackupAPI.Origin) -> LibraryState.Cell {
        LibraryState(library: ["original", "copy"], ledger: ["original": entry], album: [], job: [:], origin: active).cells[0]
    }
    #expect(cell(origin).canFree)
    let foreign = cell(.init(serverID: "other", historyEpoch: "history"))
    #expect(foreign.badge == .recovery && !foreign.canFree && !foreign.canRestore)
    entry.retention = .deferred
    #expect(!cell(origin).canFree)
    entry.retention = .external
    #expect(!cell(origin).canFree)
    entry.externalVerification = .fullResourceScrub
    #expect(cell(origin).canFree)
}


/// The library snapshot (shown at launch before Photos is read) comes back as written: missing
/// months and media info stay missing, a video keeps its length, an undated item stays undated.
@Test func librarySnapshotRoundTrips() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("snapshot-\(UUID().uuidString).plist")
    defer { try? FileManager.default.removeItem(at: url) }
    let date = Date(timeIntervalSinceReferenceDate: 700_000_000.25)
    let snapshot = LibrarySnapshot(ids: ["a/L0/001", "b/L0/001", "c/L0/001", "d/L0/001"],
                                   months: ["a/L0/001": 24_300, "c/L0/001": 24_301],
                                   media: ["a/L0/001": .init(kind: .photo, seconds: 0, created: date),
                                           "b/L0/001": .init(kind: .video, seconds: 95, created: date),
                                           "c/L0/001": .init(kind: .livePhoto, seconds: 0, created: nil)])
    try snapshot.write(to: url)
    #expect(LibrarySnapshot.read(from: url) == snapshot)
    try LibrarySnapshot(ids: [], months: [:], media: [:]).write(to: url)
    #expect(LibrarySnapshot.read(from: url)?.ids == [])
    try Data("not a plist".utf8).write(to: url)
    #expect(LibrarySnapshot.read(from: url) == nil)
}
