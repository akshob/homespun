// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import HomespunCore
import Hummingbird
import Logging
import ServiceLifecycle

/// Shared by v1/v2 encoders, connector work and hashing. Waiting for one lane never owns
/// another lane or a root lease. Defaults intentionally leave CPU capacity for HTTP and Photos.
actor ServerWorkBudget {
    enum Lane: Hashable, Sendable { case photo, video, connector, verification, transfer }
    private var active: [Lane: Int] = [:]
    private var waiting: [Lane: [UUID]] = [:]
    let photos: Int
    let videos: Int
    let verifications: Int

    init(photos: Int = 1, videos: Int = 1, verifications: Int = 2) {
        self.photos = max(1, min(photos, 2))
        self.videos = max(1, min(videos, 2))
        self.verifications = max(1, min(verifications, 4))
    }
    func run<T: Sendable>(_ lane: Lane, _ body: @Sendable () async throws -> T) async throws -> T {
        let limit: Int
        switch lane {
        case .photo: limit = photos
        case .video: limit = videos
        case .connector: limit = 1
        case .verification: limit = verifications
        case .transfer: limit = 2
        }
        let ticket = UUID()
        waiting[lane, default: []].append(ticket)
        do {
            while active[lane, default: 0] >= limit || waiting[lane]?.first != ticket {
                try await Task.sleep(for: .milliseconds(20))
            }
        } catch {
            waiting[lane]?.removeAll { $0 == ticket }
            throw error
        }
        waiting[lane]?.removeFirst()
        try Task.checkCancellation()
        active[lane, default: 0] += 1
        defer { active[lane, default: 0] -= 1 }
        return try await body()
    }
}

extension Catalog {
    func claimBackupJob(lane: String, owner: String, lease: TimeInterval = 90, now: Date = Date()) throws -> BackupJob? {
        try database.transaction {
            try database.execute("""
                UPDATE backup_jobs SET status = 'queued', owner = NULL, expires_at = NULL
                WHERE status = 'leased' AND expires_at <= ?
                """, [.text(Timestamp.string(now))])
            // Round robin across principals, oldest first within each principal. Retrying
            // preserves age without letting one device's batch monopolize this lane.
            guard let row = try database.query("""
                SELECT j.* FROM backup_jobs j WHERE j.lane = ? AND j.status IN ('queued', 'retry_wait')
                  AND j.available_at <= ?
                  AND EXISTS(SELECT 1 FROM backup_requests r WHERE r.manifest_id = j.manifest_id
                    AND r.recipe_id = j.recipe_id AND r.source = 'files'
                    AND r.wants_compact = 1 AND r.paused = 0 AND r.cancelled = 0)
                ORDER BY COALESCE((SELECT s.last_claim FROM backup_scheduler s WHERE s.principal = j.principal AND s.lane = j.lane), 0),
                  j.created_at, j.id LIMIT 1
                """, [.text(lane), .text(Timestamp.string(now))]).first else { return nil }
            let id = row["id"]!.string!, fence = Int64(row["fence"]!.int! + 1), output = UUID()
            try database.execute("""
                INSERT INTO backup_scheduler(principal, lane, last_claim)
                VALUES (?, ?, (SELECT COALESCE(MAX(last_claim), 0) + 1 FROM backup_scheduler))
                ON CONFLICT(principal, lane) DO UPDATE SET last_claim = excluded.last_claim
                """, [.text(row["principal"]!.string!), .text(lane)])
            try database.execute("""
                UPDATE backup_jobs SET status = 'leased', owner = ?, fence = ?, output_id = ?, attempts = attempts + 1, expires_at = ?
                WHERE id = ?
                """, [.text(owner), .integer(fence), .text(output.uuidString.lowercased()),
                       .text(Timestamp.string(now.addingTimeInterval(lease))), .text(id)])
            try database.execute("""
                UPDATE backup_requests SET compact_state = 'processing', message = NULL WHERE manifest_id = ?
                  AND recipe_id = ? AND wants_compact = 1 AND paused = 0 AND cancelled = 0
                """, [.text(row["manifest_id"]!.string!), .text(row["recipe_id"]!.string!)])
            try refreshBackupRequests(row["manifest_id"]!.string!)
            return .init(id: id, manifest: row["manifest_id"]!.string!,
                         recipe: try Self.backupDecode(BackupAPI.Recipe.self, row["recipe_json"]!.string!),
                         recipeID: row["recipe_id"]!.string!, generation: Int64(row["generation"]!.int!),
                         owner: owner, fence: fence, output: output, lane: lane, attempts: (row["attempts"]?.int ?? 0) + 1)
        }
    }

    func backupJobCurrent(_ job: BackupJob, now: Date = Date()) throws -> Bool {
        !(try database.query("""
            SELECT j.id FROM backup_jobs j JOIN backup_manifests m ON m.id = j.manifest_id
            WHERE j.id = ? AND j.owner = ? AND j.fence = ? AND j.generation = ? AND m.generation = j.generation
              AND j.status = 'leased' AND j.expires_at > ?
            """, [.text(job.id), .text(job.owner), .integer(job.fence), .integer(job.generation), .text(Timestamp.string(now))]).isEmpty)
    }

    func heartbeatBackupJob(_ job: BackupJob, lease: TimeInterval = 90, now: Date = Date()) throws -> Bool {
        guard try backupJobCurrent(job, now: now) else { return false }
        try database.execute("UPDATE backup_jobs SET expires_at = ? WHERE id = ? AND owner = ? AND fence = ? AND generation = ?",
                             [.text(Timestamp.string(now.addingTimeInterval(lease))), .text(job.id), .text(job.owner),
                              .integer(job.fence), .integer(job.generation)])
        return database.changes == 1
    }

    func backupManifest(_ id: String) throws -> BackupAPI.Manifest {
        guard let json = try database.query("SELECT manifest_json FROM backup_manifests WHERE id = ?", [.text(id)]).first?["manifest_json"]?.string else {
            throw HTTPError(.notFound)
        }
        return try Self.backupDecode(BackupAPI.Manifest.self, json)
    }

    func publishBackupJob(_ job: BackupJob, outcome: Compactor.Outcome, storage: Storage) throws {
        try database.transaction {
            guard try backupJobCurrent(job) else { throw CancellationError() }
            guard [.ready, .held].contains(outcome.state),
                  outcome.state != .ready || !outcome.files.isEmpty,
                  Set(outcome.files.map(\.role)).count == outcome.files.count,
                  outcome.files.allSatisfy({ $0.size > 0 && Validation.isSHA256($0.sha256)
                    && $0.filename == Storage.sanitized($0.filename)
                    && URL(fileURLWithPath: $0.path).standardizedFileURL
                        == storage.compact("v2-" + job.output.uuidString.lowercased()).appendingPathComponent($0.filename).standardizedFileURL
                  }) else { throw Compactor.Unprocessable(description: "The derivative manifest failed publication checks.") }
            let files: [ServerAPI.CompactResource] = outcome.files.map {
                .init(role: $0.role, filename: $0.filename, size: $0.size, sha256: $0.sha256)
            }
            if outcome.state == .ready {
                try database.execute("""
                    INSERT INTO backup_derivatives(id, manifest_id, recipe_id, generation, files_json, device_compresses_json, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, [.text(job.output.uuidString.lowercased()), .text(job.manifest), .text(job.recipeID), .integer(job.generation),
                           .text(try Self.backupJSON(files)), .text(try Self.backupJSON(outcome.deviceCompresses)), .text(Timestamp.string())])
                let asset = try database.query("SELECT asset_id FROM backup_manifests WHERE id = ?", [.text(job.manifest)]).first!["asset_id"]!.string!
                for file in outcome.files {
                    try database.execute("""
                        INSERT INTO made_copies(sha256, asset_id, role, created_at, sha1) VALUES (?, ?, ?, ?, ?)
                        ON CONFLICT(sha256) DO UPDATE SET sha1 = COALESCE(made_copies.sha1, excluded.sha1)
                        """, [.text(file.sha256), .text(asset), .text(file.role.rawValue), .text(Timestamp.string()), file.sha1.sqlValue])
                }
            }
            try database.execute("""
                UPDATE backup_requests SET compact_state = ?, derivative_id = ?, message = ?
                WHERE manifest_id = ? AND recipe_id = ? AND source = 'files' AND wants_compact = 1 AND paused = 0 AND cancelled = 0
                """, [.text(outcome.state == .ready ? "ready" : "held"),
                       outcome.state == .ready ? .text(job.output.uuidString.lowercased()) : .null,
                       outcome.message.sqlValue, .text(job.manifest), .text(job.recipeID)])
            try database.execute("""
                UPDATE backup_jobs SET status = 'succeeded', owner = NULL, expires_at = NULL
                WHERE id = ? AND owner = ? AND fence = ? AND generation = ?
                """, [.text(job.id), .text(job.owner), .integer(job.fence), .integer(job.generation)])
            try refreshBackupRequests(job.manifest)
        }
    }

    func failBackupJob(_ job: BackupJob, message: String, permanent: Bool, now: Date = Date()) throws {
        try database.transaction {
            guard try backupJobCurrent(job, now: now) else { return }
            let final = permanent || job.attempts >= 3
            try database.execute("""
                UPDATE backup_jobs SET status = ?, owner = NULL, expires_at = NULL, available_at = ?
                WHERE id = ? AND owner = ? AND fence = ? AND generation = ?
                """, [.text(final ? "failed" : "retry_wait"), .text(Timestamp.string(now.addingTimeInterval(30 * Double(job.attempts)))),
                       .text(job.id), .text(job.owner), .integer(job.fence), .integer(job.generation)])
            try database.execute("""
                UPDATE backup_requests SET compact_state = ?, message = ? WHERE manifest_id = ? AND recipe_id = ?
                  AND source = 'files' AND wants_compact = 1 AND paused = 0 AND cancelled = 0
                """, [.text(final ? "failed" : "queued"), .text(message), .text(job.manifest), .text(job.recipeID)])
            try refreshBackupRequests(job.manifest)
        }
    }

    func releaseBackupLeases() throws {
        try database.transaction {
            let pending = try database.query("SELECT DISTINCT manifest_id FROM backup_jobs WHERE status = 'leased'")
            try database.execute("""
                UPDATE backup_jobs SET status = 'queued', owner = NULL, expires_at = NULL, fence = fence + 1 WHERE status = 'leased'
                """)
            for row in pending {
                let manifest = row["manifest_id"]!.string!
                try database.execute("""
                    UPDATE backup_requests SET compact_state = 'queued' WHERE manifest_id = ? AND wants_compact = 1
                      AND source = 'files' AND cancelled = 0 AND paused = 0 AND compact_state = 'processing'
                    """, [.text(manifest)])
                try refreshBackupRequests(manifest)
            }
        }
    }
}

struct BackupWorker: Service {
    let lane: String
    let catalog: Catalog
    let storage: Storage
    let originals: OriginalsStore
    let budget: ServerWorkBudget
    let logger: Logger
    let minimumFreeBytes: Int64
    let owner = UUID().uuidString.lowercased()
    struct Backpressure: Error {}

    func run() async throws {
        await cancelWhenGracefulShutdown {
            while !Task.isCancelled {
                do {
                    if try await runNext() { continue }
                } catch is CancellationError {
                    if Task.isCancelled { return }
                    continue
                }
                catch { logger.error("versioned worker: storage unavailable") }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    @discardableResult
    func runNext() async throws -> Bool {
        // Acquire capacity before claiming a lease, not while waiting behind a long legacy job.
        try await budget.run(lane == "photo" ? .photo : .video) {
            guard let job = try await catalog.claimBackupJob(lane: lane, owner: owner) else { return false }
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { try await process(job) }
                    group.addTask {
                        while true {
                            try await Task.sleep(for: .seconds(20))
                            guard try await catalog.heartbeatBackupJob(job) else { throw CancellationError() }
                        }
                    }
                    _ = try await group.next()
                    group.cancelAll()
                }
            } catch is CancellationError { throw CancellationError() }
            catch is Backpressure {
                try await catalog.postponeBackupJob(job)
            }
            catch let failure as Compactor.Unprocessable {
                try await catalog.failBackupJob(job, message: failure.description, permanent: true)
            } catch {
                try await catalog.failBackupJob(job, message: "Processing is waiting for storage or an encoder. Originals remain retained.", permanent: false)
            }
            return true
        }
    }

    private func process(_ job: BackupJob) async throws {
        let manifest = try await catalog.backupManifest(job.manifest)
        let objects = try await catalog.backupObjects(job.manifest)
        let bytes = try StorageBytes.sum(objects.map(\.size))
        guard let free = OriginalsStore.space(at: storage.root.path).free, free > minimumFreeBytes,
              bytes <= (free - minimumFreeBytes) / 3 else { throw Backpressure() }
        let cache = storage.cache("v2-" + job.output.uuidString.lowercased())
        defer { try? FileManager.default.removeItem(at: cache) }
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: false)
        let sources = try await originals.place { root in
            var sources: [Role: URL] = [:]
            for object in try await catalog.backupObjects(job.manifest) {
                guard let path = object.path, let source = OriginalsStore.resolve(path, in: root) else {
                    throw Compactor.Unprocessable(description: "The exact original version is incomplete.")
                }
                let target = cache.appendingPathComponent(object.role.rawValue + "-" + Storage.sanitized(object.filename))
                let copied = try await detached { try Fingerprint.copy(from: source, to: target) }
                guard copied.sha256 == object.sha256, copied.size == object.size else {
                    throw Compactor.Unprocessable(description: "An original is missing or changed; no derivative was published.")
                }
                sources[object.role] = target
            }
            return sources
        }
        let directory = storage.compact("v2-" + job.output.uuidString.lowercased())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        var outcome = try await Compactor(profile: job.recipe.profile).compact(kind: manifest.kind, sources: sources,
            baseName: manifest.resources.first(where: { $0.role == (manifest.kind == .video ? .video : .photo) })!.filename,
            into: directory)
        for index in outcome.files.indices {
            let file = outcome.files[index]
            let url = URL(fileURLWithPath: file.path)
            let checked = try await detached { try Fingerprint.digests(of: url) }
            guard checked.size == file.size, checked.sha256 == file.sha256 else {
                throw Compactor.Unprocessable(description: "Derivative bytes changed before publication.")
            }
            outcome.files[index].sha1 = checked.sha1
            try BackupDurability.publish(url, root: storage.root)
            try FileManager.default.setAttributes([.posixPermissions: 0o440], ofItemAtPath: url.path)
        }
        try await catalog.publishBackupJob(job, outcome: outcome, storage: storage)
    }
}

extension Catalog {
    func postponeBackupJob(_ job: BackupJob) throws {
        try database.transaction {
            guard try backupJobCurrent(job) else { throw CancellationError() }
            try database.execute("""
                UPDATE backup_jobs SET status = 'retry_wait', attempts = MAX(0, attempts - 1), owner = NULL,
                    expires_at = NULL, available_at = ? WHERE id = ? AND owner = ? AND fence = ? AND generation = ?
                """, [.text(Timestamp.string(Date().addingTimeInterval(60))), .text(job.id), .text(job.owner),
                       .integer(job.fence), .integer(job.generation)])
            try database.execute("""
                UPDATE backup_requests SET compact_state = 'queued', message = 'Waiting for processing storage capacity; originals remain retained.'
                WHERE manifest_id = ? AND recipe_id = ? AND source = 'files' AND wants_compact = 1 AND paused = 0 AND cancelled = 0
                """, [.text(job.manifest), .text(job.recipeID)])
            try refreshBackupRequests(job.manifest)
        }
    }
}
