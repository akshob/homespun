// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import HomespunCore
import Logging
import ServiceLifecycle

/// Processes durable jobs one at a time: `compress` (files mode) and `immich` (find, download,
/// and verify originals in Immich, then compress). Leases make restarts safe; a job that keeps
/// failing for transient reasons is retried with backoff, then marks its asset failed.
public final class JobRunner: Service, Sendable {
    static let compress = "compress"
    static let immich = "immich"

    let catalog: Catalog
    let storage: Storage
    let compactor: Compactor
    let immichState: ImmichState
    let logger: Logger
    let owner = UUID().uuidString
    let pollInterval: Duration

    init(catalog: Catalog, storage: Storage, compactor: Compactor, immichState: ImmichState, logger: Logger,
         pollInterval: Duration = .seconds(1)) {
        self.catalog = catalog
        self.storage = storage
        self.compactor = compactor
        self.immichState = immichState
        self.logger = logger
        self.pollInterval = pollInterval
    }

    public func run() async throws {
        try await catalog.releaseLeases()
        await cancelWhenGracefulShutdown {
            while !Task.isCancelled {
                if (try? await self.runNext()) == true { continue }
                try? await Task.sleep(for: self.pollInterval)
            }
        }
    }

    /// Runs one ready job. Returns false when none is ready.
    @discardableResult
    func runNext() async throws -> Bool {
        guard let job = try await catalog.claim(owner: owner, lease: 3600) else { return false }
        do {
            switch job.type {
            case Self.compress: try await compressStored(job.assetID)
            case Self.immich: try await processFromImmich(job.assetID)
            default: throw Compactor.Unprocessable(description: "unknown job \(job.type)")
            }
            try await catalog.finish(job)
        } catch let error as Compactor.Unprocessable {
            logger.warning("asset \(job.assetID): \(error)")
            try await catalog.setState(job.assetID, .failed, message: error.description)
            try await catalog.finish(job)
        } catch {
            logger.error("job \(job.type) for \(job.assetID) failed: \(error)")
            if try await !catalog.fail(job, error: "\(error)") {
                try await catalog.setState(job.assetID, .failed, message: "Gave up after repeated errors: \(error)")
            }
        }
        return true
    }

    /// Processes jobs until none is ready (for tests and tools).
    func drain() async throws {
        while try await runNext() {}
    }

    private func compressStored(_ assetID: String) async throws {
        guard let asset = try await catalog.asset(assetID) else { return }
        let resources = try await catalog.resources(assetID)
        guard resources.allSatisfy({ $0.state == .verified && $0.storedPath != nil }) else {
            throw Compactor.Unprocessable(description: "originals are incomplete")
        }
        var sources: [Role: URL] = [:]
        for resource in resources { sources[resource.role] = storage.root.appendingPathComponent(resource.storedPath!) }
        try await compactAndStore(asset, resources: resources, sources: sources)
    }

    private func processFromImmich(_ assetID: String) async throws {
        guard let asset = try await catalog.asset(assetID) else { return }
        guard let immich = await immichState.client else {
            throw Compactor.Unprocessable(description: "Immich is not connected to this server any more.")
        }
        let resources = try await catalog.resources(assetID)
        try await catalog.setState(assetID, .verifying)

        // Find each original in Immich. Motion is reached through its still, because Immich
        // hides Live Photo motion from search.
        var located: [Role: String] = [:]
        var missing: [String] = []
        for resource in resources where [.photo, .video].contains(resource.role) {
            guard let sha1 = resource.sha1, let match = try await immich.assets(sha1Hex: sha1).first else {
                missing.append(resource.role.rawValue)
                continue
            }
            located[resource.role] = match.id
            if let motion = resources.first(where: { $0.role == .pairedVideo }) {
                if let motionID = match.livePhotoVideoId, let sha1 = motion.sha1,
                   try await immich.stillHolds(id: motionID, sha1Hex: sha1).0 {
                    located[.pairedVideo] = motionID
                } else {
                    missing.append(motion.role.rawValue)
                }
            }
        }
        for resource in resources where ![.photo, .video, .pairedVideo].contains(resource.role) {
            missing.append(resource.role.rawValue)
        }
        if !missing.isEmpty {
            for resource in resources where located[resource.role] == nil {
                try await catalog.markResource(assetID, role: resource.role, state: .notInImmich)
            }
            try await catalog.setState(assetID, .waitingForImmich,
                                       message: "Not in Immich yet: " + missing.joined(separator: ", "))
            return
        }

        // Download and verify every original byte for byte before trusting it.
        let cache = storage.cache(assetID)
        try? FileManager.default.removeItem(at: cache)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cache) }
        var sources: [Role: URL] = [:]
        for resource in resources {
            let immichID = located[resource.role]!
            let file = cache.appendingPathComponent("\(resource.role.rawValue)-\(Storage.sanitized(resource.filename))")
            try await immich.downloadOriginal(id: immichID, to: file)
            let (sha256, size) = try await detached { (try Fingerprint.sha256(of: file), try Self.size(of: file)) }
            guard sha256 == resource.sha256, size == resource.size else {
                try await catalog.markResource(assetID, role: resource.role, state: .mismatch, immichAssetID: immichID)
                throw Compactor.Unprocessable(description: "Immich's copy of \(resource.role.rawValue) differs from the iPhone original")
            }
            try await catalog.markResource(assetID, role: resource.role, state: .verified, immichAssetID: immichID)
            sources[resource.role] = file
        }
        try await compactAndStore(asset, resources: resources, sources: sources)
    }

    private func compactAndStore(_ asset: AssetRecord, resources: [ResourceRecord], sources: [Role: URL]) async throws {
        try await catalog.setState(asset.id, .compressing)
        let base = resources.first { $0.role == (asset.kind == .video ? .video : .photo) }?.filename ?? asset.id
        let directory = storage.compact(asset.id)
        try? FileManager.default.removeItem(at: directory)
        let outcome = try await compactor.compact(kind: asset.kind, sources: sources, baseName: base, into: directory)
        let files = outcome.files.map { file in
            var record = file
            record.path = storage.relative(URL(fileURLWithPath: file.path))
            return record
        }
        try await catalog.storeCompact(asset.id, files, deviceCompresses: outcome.deviceCompresses,
                                       state: outcome.state, message: outcome.message)
    }

    static func size(of url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
    }
}

extension Storage {
    /// A path relative to the data directory, as stored in the catalog.
    func relative(_ url: URL) -> String {
        let rootPath = root.standardizedFileURL.path, path = url.standardizedFileURL.path
        return path.hasPrefix(rootPath + "/") ? String(path.dropFirst(rootPath.count + 1)) : path
    }

    /// A catalog path resolved inside the data directory; nil if it would escape it.
    func resolve(_ relative: String) -> URL? {
        let url = root.appendingPathComponent(relative).standardizedFileURL
        return url.path.hasPrefix(root.standardizedFileURL.path + "/") ? url : nil
    }
}
