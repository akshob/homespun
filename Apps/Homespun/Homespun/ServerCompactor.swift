// SPDX-License-Identifier: Apache-2.0
import Foundation
import HomespunCore
import HomespunMedia
import Photos

/// Server modes: the server stores (or finds in Immich) the originals and makes the compact
/// copies; the phone compresses only Live Photo motion, which needs AVFoundation.
struct ServerCompactor: Compacting {
    let client: ServerClient
    let mode: ServerAPI.StorageMode
    var profile: CompressionProfile = .standard
    let ledger: CompactLedger
    var pollInterval: Duration = .seconds(1)

    /// The resources the server must hold before an original may be removed. Files mode keeps
    /// every resource, including edits; Immich keeps only the original photo, motion, or video.
    static func resources(of asset: PHAsset, mode: ServerAPI.StorageMode) throws -> [PHAssetResource] {
        let all = PHAssetResource.assetResources(for: asset)
        let roles = all.map { PhotoLibrary.role(of: $0.type) }
        // Every resource is uploaded and checked, so each needs its own role.
        guard Set(roles).count == roles.count, !roles.contains(.other) else {
            throw PhotoLibrary.Failure.unsupported("This item has files Homespun doesn't recognise yet.")
        }
        guard mode == .immich else { return all }
        // Immich keeps only the original photo, motion, or video; anything else (edits, a RAW
        // alongside a JPEG) would be lost if the item were removed.
        guard all.allSatisfy({ [.photo, .pairedVideo, .video].contains($0.type) }) else {
            throw PhotoLibrary.Failure.unsupported("Edited items and RAW+JPEG pairs aren't supported with Immich yet.")
        }
        return all
    }

    struct Exported: Sendable {
        var role: ServerAPI.ResourceRole
        var url: URL
        var descriptor: ServerAPI.ResourceDescriptor
    }

    /// Exports resources (each in its own folder, since names can repeat) and hashes them.
    static func export(_ resources: [PHAssetResource], to directory: URL,
                       progress: @escaping @Sendable (String) -> Void) async throws -> [Exported] {
        var exported: [Exported] = []
        for resource in resources {
            let role = PhotoLibrary.role(of: resource.type)
            guard !exported.contains(where: { $0.role == role }) else {
                throw PhotoLibrary.Failure.unsupported("This item has two \(role.rawValue) files.")
            }
            let folder = directory.appendingPathComponent(role.rawValue, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = try await PhotoLibrary.export(resource, to: folder, progress: progress)
            let digests = try await Task.detached { try Fingerprint.digests(of: url) }.value
            exported.append(Exported(role: role, url: url, descriptor: .init(
                role: role, filename: resource.originalFilename, size: digests.size, sha256: digests.sha256, sha1: digests.sha1)))
        }
        return exported
    }

    func compact(_ localIdentifier: String, compactNow: Bool = true,
                 progress: @escaping @Sendable (String) -> Void) async throws -> CompactOutcome {
        guard let asset = PhotoLibrary.asset(localIdentifier) else { throw PhotoLibrary.Failure.notFound }
        guard let kind = PhotoLibrary.kind(of: asset) else { throw PhotoLibrary.Failure.unsupported("Audio items are not supported.") }
        if let reason = await PhotoLibrary.skipReason(for: asset, ledger: ledger) { return .unchanged(reason) }
        let resources = try Self.resources(of: asset, mode: mode)

        let work = try PhotoLibrary.workDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        progress("Reading")
        let exported = try await Self.export(resources, to: work.appendingPathComponent("original"), progress: progress)
        let originalBytes = exported.reduce(0) { $0 + $1.descriptor.size }

        progress("Contacting server")
        // A recent item is backed up now and compacted later. (Immich mode has no backing up of
        // its own: automatic mode leaves recent items for later there.)
        let backUpOnly = !compactNow && mode == .files
        let request = ServerAPI.RegisterAssetRequest(kind: kind.api, captureDate: asset.creationDate,
                                                     resources: exported.map(\.descriptor), compact: compactNow)
        guard let assetID = request.assetID else { throw PhotoLibrary.Failure.missingResource(request.primaryRole.rawValue) }
        var status: ServerAPI.AssetStatus
        do {
            status = try await client.register(request)
        } catch let failure as ServerClient.Failure where failure.code == ServerAPI.ErrorCode.compactCopy {
            return .unchanged(failure.message)
        }

        if mode == .files {
            for item in exported where status.resources.first(where: { $0.role == item.role })?.state != .verified {
                let size = item.descriptor.size, label = item.role == .pairedVideo ? "motion" : item.role.rawValue
                try await client.upload(item.url, assetID: assetID, role: item.role, size: size) { sent in
                    progress("Uploading \(label) \(Int(Double(sent) / Double(max(size, 1)) * 100))%")
                }
            }
            status = try await client.status(assetID)
        }

        if backUpOnly {
            switch status.state {
            case .held: return .unchanged(status.message ?? "Kept as is")
            case .failed: throw ServerClient.Failure(status: 0, message: status.message ?? "The server could not keep it.")
            default:
                guard status.resources.allSatisfy({ $0.state == .verified }) else {
                    throw ServerClient.Failure(status: 0, message: "The server is still missing some files; try again.")
                }
                try await ledger.recordBackedUp(original: localIdentifier, serverAssetID: assetID, originalBytes: originalBytes)
                return .backedUp(originalBytes: originalBytes)
            }
        }

        var askedAgain = false
        while true {
            switch status.state {
            case .ready, .imported: break
            case .held: return .unchanged(status.message ?? "Kept as is")
            case .waitingForImmich:
                return .notYet((status.message ?? "Not in Immich yet.") + " Back it up with the Immich app, then pick it again.")
            case .failed: throw ServerClient.Failure(status: 0, message: status.message ?? "The server could not process it.")
            case .receiving where status.resources.allSatisfy({ $0.state == .verified }): progress("Queued on server")
            case .receiving:
                throw ServerClient.Failure(status: 0, message: "The server is still missing some files; try again.")
            case .verifying: progress(mode == .immich ? "Checking Immich" : "Verifying")
            case .queued: progress("Queued on server")
            case .compressing: progress("Compressing on server")
            case .stored:
                // Waiting as a recent item, though it's due now (a register that raced): ask again, once.
                guard !askedAgain else {
                    throw ServerClient.Failure(status: 0, message: "The server is keeping it without a compact copy; try again.")
                }
                askedAgain = true
                status = try await client.register(request)
                continue
            case .trashed:
                throw ServerClient.Failure(status: 0, message: "The server has this item in its trash; try again.")
            }
            if status.state == .ready || status.state == .imported { break }
            try await Task.sleep(for: pollInterval)
            status = try await client.status(assetID)
        }

        progress("Downloading compact copy")
        let compactDirectory = work.appendingPathComponent("compact", isDirectory: true)
        try FileManager.default.createDirectory(at: compactDirectory, withIntermediateDirectories: true)
        var plan = PhotoLibrary.ImportPlan(asset: asset)
        var deviceCopies: [ServerAPI.CopyHash] = []
        for compact in status.compact {
            let url = try await client.download(compact, assetID: assetID, to: compactDirectory)
            let type: PHAssetResourceType = switch compact.role {
            case .video: .video
            case .pairedVideo: .pairedVideo
            default: .photo
            }
            plan.resources.append((type, url))
        }
        if status.deviceCompresses.contains(.pairedVideo) {
            progress("Compressing motion")
            guard let motion = exported.first(where: { $0.role == .fullSizePairedVideo })
                    ?? exported.first(where: { $0.role == .pairedVideo }),
                  let still = plan.resources.first(where: { $0.0 == .photo })?.1 else {
                throw PhotoLibrary.Failure.missingResource("Live Photo motion")
            }
            let output = compactDirectory.appendingPathComponent(still.deletingPathExtension().lastPathComponent + ".mov")
            _ = try await LivePhotoMotionCompressor(profile: profile).compress(input: motion.url, output: output)
            progress("Checking Live Photo")
            if case .invalid(let reason) = await LivePhotoValidator.validate(photo: still, video: output) {
                throw PhotoLibrary.Failure.livePhotoInvalid(reason)
            }
            plan.resources.append((.pairedVideo, output))
            let digests = try await Task.detached { try Fingerprint.digests(of: output) }.value
            deviceCopies.append(.init(role: .pairedVideo, sha256: digests.sha256, sha1: digests.sha1))
        } else if let still = plan.resources.first(where: { $0.0 == .photo })?.1,
                  let motion = plan.resources.first(where: { $0.0 == .pairedVideo })?.1 {
            // A Mac server compressed the motion; check the pair before importing it.
            progress("Checking Live Photo")
            if case .invalid(let reason) = await LivePhotoValidator.validate(photo: still, video: motion) {
                throw PhotoLibrary.Failure.livePhotoInvalid(reason)
            }
        }
        guard !plan.resources.isEmpty else { return .unchanged("Already compact") }
        let compactBytes = try plan.resources.reduce(0) { $0 + (try PhotoLibrary.size(of: $1.1)) }

        progress("Saving")
        let identifier = try await PhotoLibrary.save(plan)
        try await ledger.record(original: localIdentifier, compact: identifier, originalBytes: originalBytes,
                                compactBytes: compactBytes, serverAssetID: assetID)
        try? await client.imported(assetID, deviceCopies: deviceCopies)
        return .saved(compactIdentifier: identifier, originalBytes: originalBytes, compactBytes: compactBytes)
    }
}
