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
    let originals: OriginalsStore
    let compactor: Compactor
    let immichState: ImmichState
    let hub: ConnectorHub
    let logger: Logger
    let owner = UUID().uuidString
    let pollInterval: Duration
    let connectors: Bool
    let budget: ServerWorkBudget
    let legacyLane: String?

    init(catalog: Catalog, storage: Storage, originals: OriginalsStore, compactor: Compactor, immichState: ImmichState,
         hub: ConnectorHub, logger: Logger, pollInterval: Duration = .seconds(1), connectors: Bool = false,
         budget: ServerWorkBudget = ServerWorkBudget(), legacyLane: String? = nil) {
        self.catalog = catalog
        self.storage = storage
        self.originals = originals
        self.compactor = compactor
        self.immichState = immichState
        self.hub = hub
        self.logger = logger
        self.pollInterval = pollInterval
        self.connectors = connectors
        self.budget = budget
        self.legacyLane = legacyLane
    }

    public func run() async throws {
        await cancelWhenGracefulShutdown {
            var lastEmptied = ContinuousClock.now - .seconds(3600)
            while !Task.isCancelled {
                // About once an hour, the main runner deletes originals that have been in the trash 30 days.
                if !self.connectors, ContinuousClock.now - lastEmptied >= .seconds(3600) {
                    lastEmptied = .now
                    _ = try? await Trash(catalog: self.catalog, originals: self.originals, storage: self.storage)
                        .empty(logger: self.logger)
                }
                if (try? await self.runNext()) == true { continue }
                try? await Task.sleep(for: self.pollInterval)
            }
        }
    }

    /// Runs one ready job. Returns false when none is ready.
    @discardableResult
    func runNext() async throws -> Bool {
        guard let job = try await catalog.claim(owner: owner, lease: 90, connectors: connectors, lane: legacyLane) else { return false }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await self.catalog.mutations.withClaim(job.assetID) {
                    try await self.budget.run(self.connectors ? .connector : self.legacyLane == "photo" ? .photo : .video) {
                        guard try await self.catalog.legacyJobCurrent(job) else { throw CancellationError() }
                        try await self.runClaimed(job)
                    }
                }
            }
            group.addTask {
                while true {
                    try await Task.sleep(for: .seconds(20))
                    guard try await self.catalog.heartbeatLegacyJob(job) else { throw CancellationError() }
                }
            }
            _ = try await group.next()
            group.cancelAll()
        }
        return true
    }

    private func runClaimed(_ job: Job) async throws {
        if job.type.hasPrefix(ConnectorHub.jobPrefix) {
            try await copy(job)
            return
        }
        do {
            switch job.type {
            case Self.compress: try await compressStored(job)
            case Self.immich: try await processFromImmich(job)
            default: throw Compactor.Unprocessable(description: "unknown job \(job.type)")
            }
            try await catalog.finish(job)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as Compactor.Unprocessable {
            logger.warning("legacy processing: media validation failed")
            try await catalog.setState(job.assetID, .failed, message: error.description, job: job)
            try await catalog.finish(job)
        } catch {
            logger.error("legacy processing: retryable worker failure")
            _ = try await catalog.fail(job, error: "processing_retryable")
        }
    }

    /// Processes jobs until none is ready (for tests and tools).
    func drain() async throws {
        while try await runNext() {}
    }

    private func compressStored(_ job: Job) async throws {
        let assetID = job.assetID
        guard let asset = try await catalog.asset(assetID) else { return }
        let resources = try await catalog.resources(assetID)
        guard asset.permanent, asset.state != .trashed, !asset.purging,
              !resources.isEmpty, resources.allSatisfy({ $0.state == .verified && ($0.storedPath != nil || $0.externalPath != nil) }) else {
            throw Compactor.Unprocessable(description: "originals are incomplete")
        }
        let cache = storage.cache(assetID + "-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cache) }
        let sources = try await stage(resources, assetID: assetID, into: cache)
        try await compactAndStore(asset, resources: resources, sources: sources, job: job)
    }

    /// Root readers hold a lease only while taking a checked local snapshot, never throughout
    /// an encode or connector network operation. Renaming/switching roots then cannot invalidate
    /// a worker's input paths.
    private func stage(_ resources: [ResourceRecord], assetID: String, into cache: URL) async throws -> [Role: URL] {
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        return try await originals.place { root in
            var sources: [Role: URL] = [:]
            let current = try await self.catalog.resources(assetID)
            for expected in resources {
                guard let resource = current.first(where: { $0.role == expected.role }),
                      resource.generation == expected.generation, resource.sha256 == expected.sha256, resource.size == expected.size else {
                    throw Catalog.StaleResource()
                }
                let source: URL
                if let path = resource.externalPath { source = URL(fileURLWithPath: path) }
                else if let path = resource.storedPath, let resolved = OriginalsStore.resolve(path, in: root) { source = resolved }
                else { throw Compactor.Unprocessable(description: "bad stored path") }
                guard (try? Self.size(of: source)) == resource.size else {
                    throw Compactor.Unprocessable(description: "The original at \(source.path) is missing or changed.")
                }
                let file = cache.appendingPathComponent(resource.role.rawValue + "-" + Storage.sanitized(resource.filename))
                let copied = try await detached { try Fingerprint.copy(from: source, to: file) }
                guard copied.size == resource.size, copied.sha256 == resource.sha256 else {
                    throw Compactor.Unprocessable(description: "The original at \(source.path) is missing or changed.")
                }
                sources[resource.role] = file
            }
            return sources
        }
    }

    /// Copies one item to a connector. A `failed` copy is final; `retryLater` waits without
    /// counting as an attempt; anything else is retried with backoff, then recorded as failed.
    private func copy(_ job: Job) async throws {
        let connector = String(job.type.dropFirst(ConnectorHub.jobPrefix.count))
        let cache = storage.cache(job.assetID + "-" + Storage.sanitized(connector))
        defer { try? FileManager.default.removeItem(at: cache) }
        do {
            try await hub.copy(connector, assetID: job.assetID, job: job) { asset, resources in
                try await self.originals(asset, resources, cache: cache)
            }
            try await catalog.finish(job)
        } catch is CancellationError {
            throw CancellationError()
        } catch ConnectorError.failed(let message) {
            logger.warning("connector copy: rejected")
            try await hub.copyFailed(connector, assetID: job.assetID, message: message, final: true, job: job)
            try await catalog.finish(job)
        } catch ConnectorError.retryLater(let message, let delay) {
            logger.notice("connector copy: deferred")
            try await hub.copyFailed(connector, assetID: job.assetID, message: message, final: false, job: job)
            try await catalog.postpone(job, by: delay, reason: message)
        } catch {
            logger.error("connector copy: retryable worker failure")
            let retrying = job.attempts < Catalog.maximumAttempts
            try await hub.copyFailed(connector, assetID: job.assetID,
                                     message: retrying ? "Copy waiting for a retry." : "Copy failed after repeated errors.",
                                     final: !retrying, job: job)
            _ = try await catalog.fail(job, error: "connector_copy_failed")
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
            return try await stage(resources, assetID: asset.id, into: cache)
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

    private func processFromImmich(_ job: Job) async throws {
        let assetID = job.assetID
        guard let asset = try await catalog.asset(assetID) else { return }
        guard let immich = await immichState.client else {
            throw Compactor.Unprocessable(description: "Immich is not connected to this server any more.")
        }
        let resources = try await catalog.resources(assetID)
        try await catalog.setState(assetID, .verifying, job: job)

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
                try await catalog.markResource(assetID, role: resource.role, state: .notInImmich, job: job)
            }
            try await catalog.setState(assetID, .waitingForImmich,
                                       message: "Not in Immich yet: " + missing.joined(separator: ", "), job: job)
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
                try await catalog.markResource(assetID, role: resource.role, state: .mismatch, immichAssetID: immichID, job: job)
                throw Compactor.Unprocessable(description: "Immich's copy of \(resource.role.rawValue) differs from the iPhone original")
            }
            try await catalog.markResource(assetID, role: resource.role, state: .verified, immichAssetID: immichID, job: job)
            sources[resource.role] = file
        }
        try await hub.originalsVerified(assetID, job: job)
        try await compactAndStore(asset, resources: resources, sources: sources, job: job)
    }

    private func compactAndStore(_ asset: AssetRecord, resources: [ResourceRecord], sources: [Role: URL], job: Job) async throws {
        try await catalog.setState(asset.id, .compressing, job: job)
        let base = resources.first { $0.role == (asset.kind == .video ? .video : .photo) }?.filename ?? asset.id
        // A previous output can still be downloading. Never erase it to publish a new result.
        let directory = storage.compact(asset.id + "-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let outcome = try await compactor.compact(kind: asset.kind, sources: sources, baseName: base, into: directory)
        var files: [CompactRecord] = []
        for file in outcome.files {
            var record = file
            record.sha1 = try? await detached { try Fingerprint.digests(of: URL(fileURLWithPath: file.path)).sha1 }
            record.path = storage.relative(URL(fileURLWithPath: file.path))
            files.append(record)
        }
        for file in files {
            guard let url = storage.resolve(file.path) else { throw Compactor.Unprocessable(description: "Invalid derivative path.") }
            try BackupDurability.publish(url, root: storage.root)
            try FileManager.default.setAttributes([.posixPermissions: 0o440], ofItemAtPath: url.path)
        }
        try await catalog.storeCompact(asset.id, files, deviceCompresses: outcome.deviceCompresses,
                                       state: outcome.state, message: outcome.message, job: job)
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
        OriginalsStore.resolve(relative, in: root)
    }
}
