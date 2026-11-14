// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import HomespunCore
import Logging
import ServiceLifecycle

/// Processes durable jobs one at a time: `compress` (files mode) and `immich` (find, download,
/// and verify originals in Immich, then compress). Leases make restarts safe; a job that keeps
/// failing for transient reasons is retried with backoff, then marks its asset failed.
/// A second runner (`connectors: true`) copies originals to connectors, so its backlog never
/// delays compact copies; its failures never change an item's state.
public final class JobRunner: Service, Sendable {
    static let compress = "compress"
    static let immich = "immich"

    let catalog: Catalog
    let storage: Storage
    let compactor: Compactor
    let immichState: ImmichState
    let hub: ConnectorHub
    let logger: Logger
    let owner = UUID().uuidString
    let pollInterval: Duration
    let connectors: Bool

    init(catalog: Catalog, storage: Storage, compactor: Compactor, immichState: ImmichState, hub: ConnectorHub,
         logger: Logger, pollInterval: Duration = .seconds(1), connectors: Bool = false) {
        self.catalog = catalog
        self.storage = storage
        self.compactor = compactor
        self.immichState = immichState
        self.hub = hub
        self.logger = logger
        self.pollInterval = pollInterval
        self.connectors = connectors
    }

    public func run() async throws {
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
        guard let job = try await catalog.claim(owner: owner, lease: 3600, connectors: connectors) else { return false }
        if job.type.hasPrefix(ConnectorHub.jobPrefix) {
            try await copy(job)
            return true
        }
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

    /// Copies one item to a connector. A `failed` copy is final; `retryLater` waits without
    /// counting as an attempt; anything else is retried with backoff, then recorded as failed.
    private func copy(_ job: Job) async throws {
        let connector = String(job.type.dropFirst(ConnectorHub.jobPrefix.count))
        let cache = storage.cache(job.assetID + "-" + Storage.sanitized(connector))
        defer { try? FileManager.default.removeItem(at: cache) }
        do {
            try await hub.copy(connector, assetID: job.assetID) { asset, resources in
                try await self.originals(asset, resources, cache: cache)
            }
            try await catalog.finish(job)
        } catch ConnectorError.failed(let message) {
            logger.warning("copy of \(job.assetID) to \(connector) failed: \(message)")
            try await hub.copyFailed(connector, assetID: job.assetID, message: message, final: true)
            try await catalog.finish(job)
        } catch ConnectorError.retryLater(let message, let delay) {
            logger.notice("copy of \(job.assetID) to \(connector) waits: \(message)")
            try await hub.copyFailed(connector, assetID: job.assetID, message: message, final: false)
            try await catalog.postpone(job, by: delay, reason: message)
        } catch {
            logger.error("copy of \(job.assetID) to \(connector) failed: \(error)")
            let retrying = try await catalog.fail(job, error: "\(error)")
            try await hub.copyFailed(connector, assetID: job.assetID,
                                     message: retrying ? "\(error)" : "Gave up after repeated errors: \(error)", final: !retrying)
        }
    }

    /// The item's originals: the files stored here or imported in place, or (Immich mode) fresh downloads from
    /// Immich into `cache`, checked byte for byte against the iPhone's hashes.
    private func originals(_ asset: AssetRecord, _ resources: [ResourceRecord], cache: URL) async throws -> [Role: URL] {
        guard !resources.isEmpty, resources.allSatisfy({ $0.state == .verified }) else {
            throw ConnectorError.failed("The server doesn't have every original of this item.")
        }
        var urls: [Role: URL] = [:]
        if resources.allSatisfy({ $0.storedPath != nil || $0.externalPath != nil }) {
            for resource in resources {
                if let path = resource.externalPath {
                    // Kept where it was before Homespun: make sure it's still there and whole.
                    let url = URL(fileURLWithPath: path)
                    guard (try? Self.size(of: url)) == resource.size else {
                        throw ConnectorError.retryLater("The original at \(path) is missing or changed.", after: 3600)
                    }
                    urls[resource.role] = url
                } else {
                    guard let url = storage.resolve(resource.storedPath!) else { throw ConnectorError.failed("bad stored path") }
                    urls[resource.role] = url
                }
            }
            return urls
        }
        guard let immich = await immichState.client else {
            throw ConnectorError.failed("Immich is not connected to this server any more.")
        }
        try? FileManager.default.removeItem(at: cache)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        for resource in resources {
            guard let immichID = resource.immichAssetID else { throw ConnectorError.failed("This original isn't in Immich.") }
            let file = cache.appendingPathComponent("\(resource.role.rawValue)-\(Storage.sanitized(resource.filename))")
            try await immich.downloadOriginal(id: immichID, to: file)
            let (sha256, size) = try await detached { (try Fingerprint.sha256(of: file), try Self.size(of: file)) }
            guard sha256 == resource.sha256, size == resource.size else {
                throw ConnectorError.failed("Immich's copy of \(resource.role.rawValue) no longer matches the iPhone original.")
            }
            urls[resource.role] = file
        }
        return urls
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
        try await hub.originalsVerified(assetID)
        try await compactAndStore(asset, resources: resources, sources: sources)
    }

    private func compactAndStore(_ asset: AssetRecord, resources: [ResourceRecord], sources: [Role: URL]) async throws {
        try await catalog.setState(asset.id, .compressing)
        let base = resources.first { $0.role == (asset.kind == .video ? .video : .photo) }?.filename ?? asset.id
        let directory = storage.compact(asset.id)
        try? FileManager.default.removeItem(at: directory)
        let outcome = try await compactor.compact(kind: asset.kind, sources: sources, baseName: base, into: directory)
        var files: [CompactRecord] = []
        for file in outcome.files {
            var record = file
            record.sha1 = try? await detached { try Fingerprint.digests(of: URL(fileURLWithPath: file.path)).sha1 }
            record.path = storage.relative(URL(fileURLWithPath: file.path))
            files.append(record)
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
