// SPDX-License-Identifier: Apache-2.0
import AVFoundation
import CoreLocation
import CryptoKit
import Foundation
import HomespunCore
import Photos

struct PhotoGeneration: Codable, Equatable, Sendable {
    struct Resource: Codable, Equatable, Sendable {
        var role: ServerAPI.ResourceRole
        var name: String
        var bytes: Int?
    }
    var identifier: String
    var modified: Date?
    var width: Int
    var height: Int
    var resources: [Resource]
}

/// This object, including its nil values, is authoritative library metadata, not an EXIF fallback.
struct BackupPhotoMetadata: Codable, Equatable, Sendable {
    var sourceID: String
    var kind: ServerAPI.AssetKind
    var creationDate: Date?
    var locationArchive: Data?
    var favorite: Bool
    var hidden: Bool
    var albums: [String]
    var generation: PhotoGeneration

    func location() throws -> CLLocation? {
        try locationArchive.map { try NSKeyedUnarchiver.unarchivedObject(ofClass: CLLocation.self, from: $0) }
            .flatMap { $0 }
    }
}

struct PreparedPhotoResource: Sendable {
    var fileID: UUID
    var url: URL
    var descriptor: ServerAPI.ResourceDescriptor
}

struct PreparedPhoto: Sendable {
    var metadata: BackupPhotoMetadata
    var resources: [PreparedPhotoResource]
    var manifest: BackupAPI.Manifest { .init(kind: metadata.kind, resources: resources.map(\.descriptor)) }
}

struct PhotosObservation: Codable, Equatable, Sendable {
    var token: Data?
    var baseline: Set<String>
    var restoring: Bool
    var requiresKnownIdentifier: Bool?
}

enum PhotosReconciliation: Sendable, Equatable {
    case unique(identifier: String, resources: [ServerAPI.ResourceDescriptor])
    case blocked(String)
}

struct PhotosCreationFailure: Error, LocalizedError, Sendable {
    var identifier: String
    var message: String
    var errorDescription: String? { message }
}

struct PhotosRemovalApproval: Codable, Equatable, Sendable {
    var original: PhotoGeneration
    var compact: PhotoGeneration
}

struct PhotosRemovalResult: Sendable {
    var submitted: Set<String>
    var invalidated: Set<String>
}

extension PhotoSource {
    func preparationBytes(_ id: String, mode: ServerAPI.StorageMode) throws -> Int {
        throw PhotoLibrary.Failure.unsupported("This library cannot prepare a durable backup.")
    }
    func prepareBackup(_ id: String, mode: ServerAPI.StorageMode, directory: URL, maximumBytes: Int,
                       progress: @escaping @Sendable (String) -> Void) async throws -> PreparedPhoto {
        throw PhotoLibrary.Failure.unsupported("This library cannot prepare a durable backup.")
    }
    func resourceFingerprints(_ id: String) async throws -> [ServerAPI.ResourceDescriptor] {
        throw PhotoLibrary.Failure.unsupported("This library cannot verify the item's complete resources.")
    }
    func sourceGeneration(_ id: String) throws -> PhotoGeneration {
        throw PhotoLibrary.Failure.unsupported("This library cannot reconcile a Photos generation.")
    }
    func backupMetadata(_ id: String) throws -> BackupPhotoMetadata {
        throw PhotoLibrary.Failure.unsupported("This library cannot capture authoritative metadata.")
    }
    func applyBackupMetadata(_ id: String, metadata: BackupPhotoMetadata) async throws {
        throw PhotoLibrary.Failure.unsupported("This library cannot reconcile saved metadata.")
    }
    func observePhotosEffect(restoring: Bool) throws -> PhotosObservation {
        throw PhotoLibrary.Failure.unsupported("This library cannot journal a Photos effect.")
    }
    func reconcilePhotosEffect(expected: [ServerAPI.ResourceDescriptor], observation: PhotosObservation,
                               createdIdentifier: String?) async throws -> PhotosReconciliation {
        .blocked("The earlier Photos action needs guided recovery. No additional copy was imported.")
    }
    func importCompact(_ files: [PreparedPhotoResource], metadata: BackupPhotoMetadata) async throws -> String {
        throw PhotoLibrary.Failure.unsupported("This library cannot save a compact copy.")
    }
    func restoreResources(_ files: [PreparedPhotoResource], metadata: BackupPhotoMetadata) async throws -> String {
        throw PhotoLibrary.Failure.unsupported("This library cannot restore an original.")
    }
    func removeApproved(_ approvals: [PhotosRemovalApproval]) async throws -> PhotosRemovalResult {
        throw PhotoLibrary.Failure.unsupported("This library cannot reconcile original removal.")
    }
    func keepApproved(_ approvals: [PhotosRemovalApproval]) async throws -> PhotosRemovalResult {
        throw PhotoLibrary.Failure.unsupported("This library cannot reconcile keeping originals.")
    }
}

extension PhotoKitSource {
    func preparationBytes(_ id: String, mode: ServerAPI.StorageMode) throws -> Int {
        guard let asset = PhotoLibrary.asset(id) else { throw PhotoLibrary.Failure.notFound }
        return try Self.total(try ServerCompactor.resources(of: asset, mode: mode))
    }

    func prepareBackup(_ id: String, mode: ServerAPI.StorageMode, directory: URL, maximumBytes: Int,
                       progress: @escaping @Sendable (String) -> Void) async throws -> PreparedPhoto {
        try Task.checkCancellation()
        guard let asset = PhotoLibrary.asset(id), let kind = PhotoLibrary.kind(of: asset) else {
            throw PhotoLibrary.Failure.notFound
        }
        let held = try ServerCompactor.resources(of: asset, mode: mode)
        let expected = try Self.total(held)
        guard expected <= maximumBytes else { throw PhotoLibrary.Failure.unsupported("This item needs more protected backup space.") }
        let generation = try sourceGeneration(id)
        let metadata = BackupPhotoMetadata(sourceID: id, kind: kind.api, creationDate: asset.creationDate,
            locationArchive: try asset.location.map { try NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) },
            favorite: asset.isFavorite, hidden: asset.isHidden, albums: PhotoLibrary.userAlbums(containing: asset), generation: generation)
        var resources: [PreparedPhotoResource] = []
        var allocated: [URL] = []
        do {
            for resource in held {
                try Task.checkCancellation()
                let fileID = UUID()
                let file = directory.appendingPathComponent(fileID.uuidString)
                allocated.append(file)
                progress("Reading")
                let result = try await PhotoResourceReader.read(resource, file: file,
                                                                maximumBytes: try Self.bytes(resource))
                resources.append(.init(fileID: fileID, url: file, descriptor: .init(
                    role: PhotoLibrary.role(of: resource.type), filename: resource.originalFilename,
                    size: result.bytes, sha256: result.sha256, sha1: result.sha1)))
            }
            guard try sourceGeneration(id) == generation else {
                throw PhotoLibrary.Failure.unsupported("This item changed while it was being prepared. It will need a fresh backup.")
            }
            let prepared = PreparedPhoto(metadata: metadata, resources: resources)
            _ = try prepared.manifest.validated()
            return prepared
        } catch {
            for file in allocated { try? FileManager.default.removeItem(at: file) }
            throw error
        }
    }

    func resourceFingerprints(_ id: String) async throws -> [ServerAPI.ResourceDescriptor] {
        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: options).firstObject else {
            throw PhotoLibrary.Failure.notFound
        }
        let resources = try ServerCompactor.resources(of: asset, mode: .files)
        let before = try sourceGeneration(id)
        var fingerprints: [ServerAPI.ResourceDescriptor] = []
        for resource in resources {
            let result = try await PhotoResourceReader.read(resource, file: nil, maximumBytes: try Self.bytes(resource))
            fingerprints.append(.init(role: PhotoLibrary.role(of: resource.type), filename: resource.originalFilename,
                                      size: result.bytes, sha256: result.sha256, sha1: result.sha1))
        }
        guard try sourceGeneration(id) == before else {
            throw PhotoLibrary.Failure.verificationFailed("the item's resources changed while they were checked")
        }
        return fingerprints
    }

    func sourceGeneration(_ id: String) throws -> PhotoGeneration {
        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: options).firstObject else {
            throw PhotoLibrary.Failure.notFound
        }

        return .init(identifier: id, modified: asset.modificationDate, width: asset.pixelWidth, height: asset.pixelHeight,
                     resources: PHAssetResource.assetResources(for: asset).map {
                         .init(role: PhotoLibrary.role(of: $0.type), name: $0.originalFilename, bytes: try? Self.bytes($0))
                     }.sorted { $0.role.rawValue < $1.role.rawValue })
    }

    func backupMetadata(_ id: String) throws -> BackupPhotoMetadata {
        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: options).firstObject,
              let kind = PhotoLibrary.kind(of: asset) else { throw PhotoLibrary.Failure.notFound }
        return .init(sourceID: id, kind: kind.api, creationDate: asset.creationDate,
            locationArchive: try asset.location.map { try NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) },
            favorite: asset.isFavorite, hidden: asset.isHidden, albums: PhotoLibrary.userAlbums(containing: asset),
            generation: try sourceGeneration(id))
    }

    func applyBackupMetadata(_ id: String, metadata: BackupPhotoMetadata) async throws {
        try await Self.applyMetadata(id, metadata: metadata)
    }

    func observePhotosEffect(restoring: Bool) throws -> PhotosObservation {
        guard authorization().allowsReading else { throw PhotoLibrary.Failure.notFound }
        let token = authorization() == .authorized ? changeToken() : nil
        return .init(token: token, baseline: [], restoring: restoring, requiresKnownIdentifier: token == nil)
    }

    func reconcilePhotosEffect(expected: [ServerAPI.ResourceDescriptor], observation: PhotosObservation,
                               createdIdentifier: String?) async throws -> PhotosReconciliation {
        guard authorization().allowsReading else { return .blocked("Allow Photos access before checking the earlier import.") }
        if let createdIdentifier {
            guard existing([createdIdentifier], includeHidden: true).contains(createdIdentifier) else {
                return .blocked("The previously created item isn't visible. It may still exist; no duplicate was imported.")
            }
            let actual = try await resourceFingerprints(createdIdentifier)
            return Self.sameResources(expected, actual)
                ? .unique(identifier: createdIdentifier, resources: actual)
                : .blocked("The previously created item's complete resources don't match. Its original has been kept.")
        }
        guard authorization() == .authorized else {
            return .blocked("Full Photos access is needed to reconcile an import whose identifier wasn't recorded.")
        }
        guard observation.requiresKnownIdentifier != true else {
            return .blocked("Photos history wasn't available for this creation. Its outcome needs guided recovery; no duplicate was imported.")
        }
        let candidates: Set<String>
        if let token = observation.token {
            let changes = inserted(since: token)
            guard changes.read else { return .blocked("Photos history couldn't be read. The earlier creation needs recovery.") }
            candidates = changes.ids
        } else {
            candidates = (observation.restoring ? Set(allIdentifiers()) : albumMembers()).subtracting(observation.baseline)
        }
        var matches: [(String, [ServerAPI.ResourceDescriptor])] = []
        for id in candidates.sorted() {
            try Task.checkCancellation()
            let actual = try await resourceFingerprints(id)
            if Self.sameResources(expected, actual) { matches.append((id, actual)) }
            if matches.count > 1 { return .blocked("More than one complete matching copy was found. Keep every candidate and review them in Photos.") }
        }
        guard let match = matches.first else {
            return .blocked("No unique complete copy was found. An earlier Photos action may have succeeded; automatic re-import is paused.")
        }
        return .unique(identifier: match.0, resources: match.1)
    }

    func importCompact(_ files: [PreparedPhotoResource], metadata: BackupPhotoMetadata) async throws -> String {
        try await PhotoResourceHandoff.use(files) { resources in
            let location = try metadata.location()
            var plan = PhotoLibrary.ImportPlan(creationDate: metadata.creationDate, location: location,
                                              isFavorite: metadata.favorite, isHidden: metadata.hidden)
            plan.resources = try resources.map { file in
                guard let type = PhotoLibrary.type(for: file.descriptor.role) else {
                    throw PhotoLibrary.Failure.unsupported("This compact copy contains an unsupported Photos role.")
                }
                return (type, file.url)
            }
            plan.originalFilenames = Dictionary(uniqueKeysWithValues: resources.map { ($0.url, $0.descriptor.filename) })
            let id = try await PhotoLibrary.save(plan)
            do { try await Self.applyMetadata(id, metadata: metadata) }
            catch { throw PhotosCreationFailure(identifier: id, message: error.localizedDescription) }
            return id
        }
    }

    func restoreResources(_ files: [PreparedPhotoResource], metadata: BackupPhotoMetadata) async throws -> String {
        try await PhotoResourceHandoff.use(files) { resources in
            try await PhotoLibrary.restore(resources.map { ($0.descriptor.role, $0.url) }, favorite: metadata.favorite,
                                           hidden: metadata.hidden, albums: metadata.albums,
                                           metadata: .library(creationDate: metadata.creationDate, location: try metadata.location()),
                                           filenames: Dictionary(uniqueKeysWithValues: resources.map { ($0.url, $0.descriptor.filename) }),
                                           shouldMoveFile: false)
        }
    }

    func removeApproved(_ approvals: [PhotosRemovalApproval]) async throws -> PhotosRemovalResult {
        try await deleteApproved(approvals, compact: false)
    }

    func keepApproved(_ approvals: [PhotosRemovalApproval]) async throws -> PhotosRemovalResult {
        try await deleteApproved(approvals, compact: true)
    }

    private func deleteApproved(_ approvals: [PhotosRemovalApproval], compact: Bool) async throws -> PhotosRemovalResult {
        try Task.checkCancellation()
        var valid: [PHAsset] = [], invalid = Set<String>()
        let originals = PHFetchOptions()
        originals.includeHiddenAssets = false
        for approval in approvals {
            let id = approval.original.identifier
            guard (try? sourceGeneration(id)) == approval.original,
                  (try? sourceGeneration(approval.compact.identifier)) == approval.compact,
                  PHAsset.fetchAssets(withLocalIdentifiers: [id], options: originals).firstObject != nil,
                  let asset = PHAsset.fetchAssets(withLocalIdentifiers: [compact ? approval.compact.identifier : id],
                                                   options: nil).firstObject else {
                invalid.insert(id)
                continue
            }
            valid.append(asset)
        }
        guard !valid.isEmpty else { return .init(submitted: [], invalidated: invalid) }
        let ids = Set(valid.map(\.localIdentifier)), assets = Assets(assets: valid as NSArray)
        try Task.checkCancellation()
        try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.deleteAssets(assets.assets) }
        return .init(submitted: ids, invalidated: invalid)
    }

    private struct Assets: @unchecked Sendable { let assets: NSArray }
    private struct Albums: @unchecked Sendable { let values: PHFetchResult<PHAssetCollection> }

    private static func applyMetadata(_ id: String, metadata: BackupPhotoMetadata) async throws {
        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: options).firstObject else {
            throw PhotoLibrary.Failure.notFound
        }
        let held = Unchecked(value: asset), location = Unchecked(value: try metadata.location())
        let albums = Albums(values: PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: metadata.albums, options: nil))
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetChangeRequest(for: held.value)
            request.creationDate = metadata.creationDate
            request.location = location.value
            request.isFavorite = metadata.favorite
            request.isHidden = metadata.hidden
            albums.values.enumerateObjects { album, _, _ in
                PHAssetCollectionChangeRequest(for: album)?.addAssets([held.value] as NSArray)
            }
        }
    }

    private static func bytes(_ resource: PHAssetResource) throws -> Int {
        guard let size = (resource.value(forKey: "fileSize") as? NSNumber)?.intValue, size > 0 else {
            throw PhotoLibrary.Failure.unsupported("Photos hasn't provided a positive resource size. This item is waiting, not skipped.")
        }
        return size
    }

    private static func total(_ resources: [PHAssetResource]) throws -> Int {
        try resources.reduce(0) { total, resource in
            let (next, overflow) = try total.addingReportingOverflow(bytes(resource))
            guard !overflow else { throw BackupAPI.ValidationError.invalidManifest }
            return next
        }
    }

    static func sameResources(_ left: [ServerAPI.ResourceDescriptor], _ right: [ServerAPI.ResourceDescriptor]) -> Bool {
        guard !left.isEmpty, left.count == right.count, Set(left.map(\.role)).count == left.count,
              Set(right.map(\.role)).count == right.count else { return false }
        return left.allSatisfy { expected in
            expected.size > 0 && right.contains {
                $0.role == expected.role && $0.size == expected.size && $0.sha256.lowercased() == expected.sha256.lowercased()
            }
        }
    }
}

/// PhotoKit's resource request is owned until one terminal result; both export growth and memory
/// are bounded, and cancellation closes the writer before its task can be joined.
private final class PhotoResourceReader: @unchecked Sendable {
    struct Digest: Sendable { var bytes: Int; var sha256: String; var sha1: String }
    private let lock = NSLock()
    private let maximum: Int
    private var hash = SHA256()
    private var legacyHash = Insecure.SHA1()
    private var bytes = 0
    private var handle: FileHandle?
    private var pending: CheckedContinuation<Digest, Error>?
    private var request: PHAssetResourceDataRequestID?
    private var finished = false
    private var failure: Error?

    private init(file: URL?, maximum: Int) throws {
        guard maximum > 0 else { throw BackupAPI.ValidationError.invalidManifest }
        self.maximum = maximum
        if let file {
            guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [
                .posixPermissions: 0o600, .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
            ]) else { throw CocoaError(.fileWriteUnknown) }
            try BackupFiles.protect(file)
            handle = try FileHandle(forWritingTo: file)
        }
    }

    static func read(_ resource: PHAssetResource, file: URL?, maximumBytes: Int) async throws -> Digest {
        let reader = try PhotoResourceReader(file: file, maximum: maximumBytes)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard reader.begin(continuation) else { return }
                let request = PHAssetResourceManager.default().requestData(for: resource, options: options) {
                    reader.receive($0)
                } completionHandler: { reader.complete($0) }
                reader.install(request)
            }
        } onCancel: { reader.complete(CancellationError()) }
    }

    private func begin(_ continuation: CheckedContinuation<Digest, Error>) -> Bool {
        lock.lock()
        let error = failure
        if !finished { pending = continuation }
        let begin = !finished
        lock.unlock()
        if !begin { continuation.resume(throwing: error ?? CancellationError()) }
        return begin
    }

    private func install(_ id: PHAssetResourceDataRequestID) {
        lock.lock()
        let cancel = finished && failure != nil
        if !finished { request = id }
        lock.unlock()
        if cancel { PHAssetResourceManager.default().cancelDataRequest(id) }
    }

    private func receive(_ data: Data) {
        lock.lock()
        guard !finished, failure == nil else { lock.unlock(); return }
        do {
            guard data.count <= maximum - bytes else { throw BackupAPI.ValidationError.invalidManifest }
            try handle?.write(contentsOf: data)
            hash.update(data: data)
            legacyHash.update(data: data)
            bytes += data.count
            lock.unlock()
        } catch {
            failure = error
            lock.unlock()
            complete(error)
        }
    }

    private func complete(_ error: Error?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        failure = failure ?? error
        do { try handle?.close() } catch { failure = failure ?? error }
        handle = nil
        let pending = pending, request = request, failure = failure
        self.pending = nil
        self.request = nil
        let digest = Digest(bytes: bytes, sha256: hash.finalize().map { String(format: "%02x", $0) }.joined(),
                            sha1: legacyHash.finalize().map { String(format: "%02x", $0) }.joined())
        lock.unlock()
        if let failure {
            if let request { PHAssetResourceManager.default().cancelDataRequest(request) }
            pending?.resume(throwing: failure)
        } else if digest.bytes == maximum {
            pending?.resume(returning: digest)
        } else {
            pending?.resume(throwing: BackupAPI.ValidationError.invalidManifest)
        }
    }
}
