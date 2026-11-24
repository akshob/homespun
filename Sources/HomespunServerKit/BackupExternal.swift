// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import HomespunCore
import Hummingbird
import ServiceLifecycle

struct BackupExternalFile: Codable, Sendable {
    var role: Role
    var filename: String
    var size: Int
    var sha256: String
    var immichID: String
    var path: String
    enum CodingKeys: String, CodingKey { case role, filename, size, sha256, immichID = "immichId", path }
}

struct BackupExternalJob: Sendable {
    var id: String
    var manifest: String
    var binding: String
    var generation: Int64
    var owner: String
    var fence: Int64
    var output: UUID
}

enum BackupExternal {
    static func cleanupOrphans(catalog: Catalog, storage: Storage) async throws {
        let known = try await catalog.externalCacheDirectories()
        for directory in try FileManager.default.contentsOfDirectory(at: storage.cacheRoot, includingPropertiesForKeys: nil) {
            let name = directory.lastPathComponent
            let prefix = ["external-scrub-", "external-fetch-", "external-v2-"].first { name.hasPrefix($0) }
            guard let prefix, UUID(uuidString: String(name.dropFirst(prefix.count))) != nil,
                  !known.contains(storage.relative(directory)),
                  storage.resolve(storage.relative(directory)) != nil else { continue }
            try FileManager.default.removeItem(at: directory)
        }
    }

    static func validate(_ manifest: BackupAPI.Manifest) throws {
        let allowed: Set<Role>
        switch manifest.kind {
        case .photo: allowed = [.photo]
        case .livePhoto: allowed = [.photo, .pairedVideo]
        case .video: allowed = [.video]
        }
        guard Set(manifest.resources.map(\.role)) == allowed,
              manifest.resources.allSatisfy({ $0.sha1.map(Validation.isSHA1) == true && !raw($0.filename) }) else {
            throw APIError(.unprocessableContent, code: "unsupported",
                           message: "Immich needs SHA-1 for each original. Edited, RAW and auxiliary-resource versions are unsupported.")
        }
    }

    static func raw(_ filename: String) -> Bool {
        ["dng", "cr2", "cr3", "nef", "arw", "raf", "rw2", "orf", "pef", "srw", "raw"]
            .contains((filename as NSString).pathExtension.lowercased())
    }

    /// Search/checksum metadata only locates a candidate. Every returned byte set is freshly
    /// downloaded in full and checked against the immutable SHA-256 AND positive size.
    static func fetch(_ manifest: BackupAPI.Manifest, client: ImmichClient, directory: URL,
                      roles: Set<Role>? = nil) async throws -> [BackupExternalFile] {
        try validate(manifest)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let primary: Role = manifest.kind == .video ? .video : .photo
        let expected = manifest.resources.first { $0.role == primary }!
        guard let found = try await client.assets(sha1Hex: expected.sha1!).first,
              let current = try await client.asset(id: found.id),
              !current.isTrashed, current.checksum == ImmichClient.base64(sha1Hex: expected.sha1!),
              !(current.originalFileName.map(raw) ?? false) else {
            throw APIError(.conflict, code: BackupAPI.ErrorCode.versionChanged, message: "The external original is unavailable or unsupported.")
        }
        var located: [Role: String] = [primary: current.id]
        if manifest.kind == .livePhoto {
            guard let motion = current.livePhotoVideoId else {
                throw APIError(.conflict, code: BackupAPI.ErrorCode.versionChanged, message: "The external Live Photo motion is missing.")
            }
            located[.pairedVideo] = motion
        }
        var files: [BackupExternalFile] = []
        for resource in manifest.resources where roles == nil || roles!.contains(resource.role) {
            guard let id = located[resource.role], let metadata = try await client.asset(id: id),
                  !metadata.isTrashed, metadata.checksum == ImmichClient.base64(sha1Hex: resource.sha1!),
                  !(metadata.originalFileName.map(raw) ?? false) else {
                throw APIError(.conflict, code: BackupAPI.ErrorCode.versionChanged, message: "An external resource was removed, trashed or changed.")
            }
            let file = directory.appendingPathComponent(resource.role.rawValue + "-" + Storage.sanitized(resource.filename))
            try await client.downloadOriginal(id: id, to: file, maximumBytes: resource.size)
            let checked = try await detached { try Fingerprint.digests(of: file) }
            guard checked.size == resource.size, checked.sha256 == resource.sha256.lowercased() else {
                throw APIError(.conflict, code: BackupAPI.ErrorCode.versionChanged, message: "External original bytes no longer match the expected version.")
            }
            let present = try await client.stillHolds(id: id, sha1Hex: resource.sha1!)
            guard present.0 else {
                throw APIError(.conflict, code: BackupAPI.ErrorCode.versionChanged, message: "An external resource changed during its byte scrub.")
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o440], ofItemAtPath: file.path)
            files.append(.init(role: resource.role, filename: resource.filename, size: resource.size,
                               sha256: resource.sha256.lowercased(), immichID: id, path: file.path))
        }
        if manifest.kind == .livePhoto {
            guard let final = try await client.asset(id: current.id), !final.isTrashed,
                  final.livePhotoVideoId == current.livePhotoVideoId else {
                throw APIError(.conflict, code: BackupAPI.ErrorCode.versionChanged, message: "The external Live Photo association changed during verification.")
            }
        }
        return files
    }
}

extension Catalog {
    static let backupExternalMigration = """
        ALTER TABLE backup_requests ADD COLUMN source_binding TEXT;
        ALTER TABLE backup_jobs ADD COLUMN external_set_id TEXT;
        CREATE TABLE backup_external_jobs (
            id TEXT PRIMARY KEY, manifest_id TEXT NOT NULL REFERENCES backup_manifests(id), binding TEXT NOT NULL,
            generation INTEGER NOT NULL, lane TEXT NOT NULL, principal TEXT NOT NULL, status TEXT NOT NULL,
            owner TEXT, fence INTEGER NOT NULL DEFAULT 0, expires_at TEXT, available_at TEXT NOT NULL,
            output_id TEXT, message TEXT, UNIQUE(manifest_id, binding)
        );
        CREATE INDEX backup_external_ready ON backup_external_jobs(lane, status, available_at);
        CREATE TABLE backup_external_sets (
            id TEXT PRIMARY KEY, manifest_id TEXT NOT NULL REFERENCES backup_manifests(id), binding TEXT NOT NULL,
            directory TEXT NOT NULL, files_json TEXT NOT NULL, available INTEGER NOT NULL DEFAULT 1, verified_at TEXT NOT NULL
        );
        CREATE INDEX backup_external_manifest ON backup_external_sets(manifest_id, binding, available);
        CREATE TABLE backup_external_resources (
            manifest_id TEXT NOT NULL, binding TEXT NOT NULL, role TEXT NOT NULL,
            sha256 TEXT NOT NULL, size INTEGER NOT NULL, immich_id TEXT NOT NULL, verified_at TEXT NOT NULL,
            PRIMARY KEY(manifest_id, binding, role)
        );
        """

    func configureBackupExternal(_ binding: String?) throws {
        guard try setting("backup.external_binding") != binding else { return }
        try database.transaction {
            try setSetting("backup.external_binding", binding)
            try database.execute("UPDATE backup_requests SET source_binding = ? WHERE source = 'external'", [binding.sqlValue])
            for row in try database.query("SELECT DISTINCT manifest_id FROM backup_requests WHERE source = 'external'") {
                try queueBackupExternal(row["manifest_id"]!.string!)
                try refreshBackupRequests(row["manifest_id"]!.string!)
            }
        }
    }

    func queueBackupExternal(_ manifest: String) throws {
        guard let binding = try setting("backup.external_binding") else { return }
        guard let definition = try database.query("SELECT generation, kind FROM backup_manifests WHERE id = ?", [.text(manifest)]).first else { return }
        #if os(macOS)
        let lane = definition["kind"]?.string == "photo" ? "photo" : "video"
        #else
        let lane = definition["kind"]?.string == "video" ? "video" : "photo"
        #endif
        for row in try database.query("""
            SELECT * FROM backup_requests WHERE manifest_id = ? AND source = 'external' AND source_binding = ?
              AND paused = 0 AND cancelled = 0
            """, [.text(manifest), .text(binding)]) {
            let verified = try externalResourcesVerified(manifest, binding: binding)
            let jobState = try database.query("SELECT status FROM backup_jobs WHERE manifest_id = ? AND recipe_id = ?",
                                             [.text(manifest), .text(row["recipe_id"]!.string!)]).first?["status"]?.string
            let held = jobState == "succeeded" && row["derivative_id"]?.string == nil
            let workWanted = row["wants_compact"]?.int == 1 && row["compact_state"]?.string != "failed" && !held
            let cached = try database.query("""
                SELECT id FROM backup_external_sets WHERE manifest_id = ? AND binding = ? AND available = 1 ORDER BY verified_at DESC LIMIT 1
                """, [.text(manifest), .text(binding)]).first?["id"]?.string
            if !verified || (workWanted && cached == nil && row["derivative_id"]?.string == nil) {
                try database.execute("""
                    INSERT INTO backup_external_jobs(id, manifest_id, binding, generation, lane, principal, status, available_at)
                    VALUES (?, ?, ?, ?, ?, ?, 'queued', ?)
                    ON CONFLICT(manifest_id, binding) DO UPDATE SET status = 'queued', fence = fence + 1,
                      owner = NULL, expires_at = NULL, available_at = excluded.available_at
                    WHERE backup_external_jobs.status IN ('succeeded', 'cancelled')
                    """, [.text(UUID().uuidString.lowercased()), .text(manifest), .text(binding),
                           .integer(Int64(definition["generation"]!.int!)), .text(lane), .text(row["principal"]!.string!),
                           .text(Timestamp.string())])
            }
            guard row["wants_compact"]?.int == 1 else { continue }
            if held {
                try database.execute("UPDATE backup_requests SET compact_state = 'held' WHERE id = ?", [.text(row["id"]!.string!)])
                continue
            }
            if let ready = try database.query("""
                SELECT id FROM backup_derivatives WHERE manifest_id = ? AND recipe_id = ? ORDER BY created_at DESC LIMIT 1
                """, [.text(manifest), .text(row["recipe_id"]!.string!)]).first?["id"]?.string {
                try database.execute("UPDATE backup_requests SET compact_state = 'ready', derivative_id = ? WHERE id = ?",
                                     [.text(ready), .text(row["id"]!.string!)])
            } else if workWanted, let cached {
                try database.execute("""
                    INSERT INTO backup_jobs(id, manifest_id, recipe_id, recipe_json, generation, lane, principal, status,
                        available_at, created_at, external_set_id) VALUES (?, ?, ?, ?, ?, ?, ?, 'queued', ?, ?, ?)
                    ON CONFLICT(manifest_id, recipe_id) DO UPDATE SET status = 'queued', external_set_id = excluded.external_set_id,
                        fence = fence + 1, owner = NULL, expires_at = NULL, attempts = 0
                    WHERE backup_jobs.status IN ('failed', 'cancelled')
                       OR (backup_jobs.status IN ('queued', 'retry_wait') AND backup_jobs.external_set_id IS NOT excluded.external_set_id)
                    """, [.text(UUID().uuidString.lowercased()), .text(manifest), .text(row["recipe_id"]!.string!),
                           .text(row["recipe_json"]!.string!), .integer(Int64(definition["generation"]!.int!)), .text(lane),
                           .text(row["principal"]!.string!), .text(Timestamp.string()), .text(Timestamp.string()), .text(cached)])
                try database.execute("UPDATE backup_requests SET compact_state = 'queued' WHERE id = ? AND compact_state != 'processing'",
                                     [.text(row["id"]!.string!)])
            }
        }
    }

    func externalResourcesVerified(_ manifest: String, binding: String) throws -> Bool {
        let expected = try backupObjects(manifest)
        let rows = try database.query("SELECT role, sha256, size FROM backup_external_resources WHERE manifest_id = ? AND binding = ?",
                                      [.text(manifest), .text(binding)])
        return !expected.isEmpty && expected.allSatisfy { object in
            rows.contains { $0["role"]?.string == object.role.rawValue && $0["sha256"]?.string == object.sha256 && $0["size"]?.int == object.size }
        }
    }

    func externalProofRequest(_ version: BackupAPI.Version, principal: String, binding: String) throws {
        guard let row = try database.query("""
            SELECT r.id FROM backup_requests r JOIN backup_claims c ON c.request_id = r.id
            WHERE r.principal = ? AND r.manifest_id = ? AND r.recipe_id = ? AND r.source = 'external'
              AND r.source_binding = ? AND c.policy = 'permanent' LIMIT 1
            """, [.text(principal), .text(version.manifestID), .text(version.recipeID), .text(binding)]).first else {
            throw HTTPError(.conflict, message: "This device has no external request for that exact version and current provider.")
        }
        try requireBackupVersion(version, request: row["id"]!.string!, principal: principal)
    }

    func claimExternalBackup(lane: String, owner: String, binding: String) throws -> BackupExternalJob? {
        try database.transaction {
            try database.execute("UPDATE backup_external_jobs SET status = 'queued', owner = NULL WHERE status = 'leased' AND expires_at <= ?",
                                 [.text(Timestamp.string())])
            guard let row = try database.query("""
                SELECT * FROM backup_external_jobs j WHERE lane = ? AND binding = ? AND status IN ('queued', 'retry_wait') AND available_at <= ?
                  AND EXISTS(SELECT 1 FROM backup_requests r WHERE r.manifest_id = j.manifest_id AND r.source_binding = j.binding
                    AND r.source = 'external' AND r.paused = 0 AND r.cancelled = 0)
                ORDER BY COALESCE((SELECT last_claim FROM backup_scheduler s WHERE s.principal = j.principal AND s.lane = ?), 0), id LIMIT 1
                """, [.text(lane), .text(binding), .text(Timestamp.string()), .text("external-" + lane)]).first else { return nil }
            let id = row["id"]!.string!, fence = try StorageBytes.add(Int64(row["fence"]!.int!), 1), output = UUID()
            try database.execute("""
                UPDATE backup_external_jobs SET status = 'leased', owner = ?, fence = ?, output_id = ?, expires_at = ? WHERE id = ?
                """, [.text(owner), .integer(fence), .text(output.uuidString.lowercased()),
                       .text(Timestamp.string(Date().addingTimeInterval(90))), .text(id)])
            try database.execute("""
                INSERT INTO backup_scheduler(principal, lane, last_claim)
                VALUES (?, ?, (SELECT COALESCE(MAX(last_claim), 0) + 1 FROM backup_scheduler))
                ON CONFLICT(principal, lane) DO UPDATE SET last_claim = excluded.last_claim
                """, [.text(row["principal"]!.string!), .text("external-" + lane)])
            return .init(id: id, manifest: row["manifest_id"]!.string!, binding: binding,
                         generation: Int64(row["generation"]!.int!), owner: owner, fence: fence, output: output)
        }
    }

    func externalBackupCurrent(_ job: BackupExternalJob) throws -> Bool {
        guard try setting("backup.external_binding") == job.binding else { return false }
        return !(try database.query("""
            SELECT j.id FROM backup_external_jobs j JOIN backup_manifests m ON m.id = j.manifest_id
            WHERE j.id = ? AND j.owner = ? AND j.fence = ? AND j.generation = ? AND m.generation = j.generation
              AND j.status = 'leased' AND j.expires_at > ?
              AND EXISTS(SELECT 1 FROM backup_requests r WHERE r.manifest_id = j.manifest_id
                AND r.source = 'external' AND r.source_binding = j.binding AND r.cancelled = 0 AND r.paused = 0)
            """, [.text(job.id), .text(job.owner), .integer(job.fence), .integer(job.generation), .text(Timestamp.string())]).isEmpty)
    }

    func heartbeatExternalBackup(_ job: BackupExternalJob) throws -> Bool {
        guard try externalBackupCurrent(job) else { return false }
        try database.execute("UPDATE backup_external_jobs SET expires_at = ? WHERE id = ? AND owner = ? AND fence = ?",
                             [.text(Timestamp.string(Date().addingTimeInterval(90))), .text(job.id), .text(job.owner), .integer(job.fence)])
        return database.changes == 1
    }

    func finishExternalBackup(_ job: BackupExternalJob, files: [BackupExternalFile], directory: String) throws {
        try database.transaction {
            guard try externalBackupCurrent(job) else { throw CancellationError() }
            try database.execute("""
                INSERT INTO backup_external_sets(id, manifest_id, binding, directory, files_json, verified_at) VALUES (?, ?, ?, ?, ?, ?)
                """, [.text(job.output.uuidString.lowercased()), .text(job.manifest), .text(job.binding), .text(directory),
                       .text(try Self.backupJSON(files)), .text(Timestamp.string())])
            for file in files {
                try database.execute("""
                    INSERT INTO backup_external_resources(manifest_id, binding, role, sha256, size, immich_id, verified_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT(manifest_id, binding, role) DO UPDATE SET
                      sha256 = excluded.sha256, size = excluded.size, immich_id = excluded.immich_id, verified_at = excluded.verified_at
                    """, [.text(job.manifest), .text(job.binding), .text(file.role.rawValue), .text(file.sha256),
                           .integer(Int64(file.size)), .text(file.immichID), .text(Timestamp.string())])
            }
            try database.execute("UPDATE backup_external_jobs SET status = 'succeeded', owner = NULL, expires_at = NULL WHERE id = ? AND owner = ? AND fence = ?",
                                 [.text(job.id), .text(job.owner), .integer(job.fence)])
            try queueBackupExternal(job.manifest)
            try refreshBackupRequests(job.manifest)
        }
    }

    func failExternalBackup(_ job: BackupExternalJob) throws {
        try database.transaction {
            guard try externalBackupCurrent(job) else { throw CancellationError() }
            try database.execute("""
                UPDATE backup_external_jobs SET status = 'retry_wait', owner = NULL, expires_at = NULL, available_at = ?,
                    message = 'Waiting for an unchanged, byte-verifiable original in Immich.' WHERE id = ? AND owner = ? AND fence = ?
                """, [.text(Timestamp.string(Date().addingTimeInterval(60))), .text(job.id), .text(job.owner), .integer(job.fence)])
            try database.execute("""
                UPDATE backup_requests SET message = 'Waiting for an unchanged, byte-verifiable original in Immich.'
                WHERE manifest_id = ? AND source = 'external' AND cancelled = 0
                """, [.text(job.manifest)])
            try refreshBackupRequests(job.manifest)
        }
    }

    func backupExternalFiles(_ set: String) throws -> [BackupExternalFile] {
        guard let row = try database.query("SELECT files_json FROM backup_external_sets WHERE id = ? AND available = 1",
                                            [.text(set)]).first else { throw HTTPError(.serviceUnavailable) }
        return try Self.backupDecode([BackupExternalFile].self, row["files_json"]!.string!)
    }

    func invalidateExternalSet(_ set: String) throws {
        try database.execute("UPDATE backup_external_sets SET available = 0 WHERE id = ?", [.text(set)])
    }

    func queueAllBackupExternal() throws {
        try database.transaction {
            for row in try database.query("SELECT DISTINCT manifest_id FROM backup_requests WHERE source = 'external' AND cancelled = 0 AND paused = 0") {
                try queueBackupExternal(row["manifest_id"]!.string!)
                try refreshBackupRequests(row["manifest_id"]!.string!)
            }
        }
    }

    func releaseExternalBackupLeases() throws {
        try database.execute("UPDATE backup_external_jobs SET status = 'queued', owner = NULL, expires_at = NULL, fence = fence + 1 WHERE status = 'leased'")
    }

    func externalCacheCleanup() throws -> [String] {
        return try database.transaction {
            let rows = try database.query("""
                SELECT id, directory FROM backup_external_sets s WHERE s.available = 1
                  AND NOT EXISTS(SELECT 1 FROM backup_jobs j WHERE j.external_set_id = s.id AND j.status IN ('queued', 'leased', 'retry_wait'))
                LIMIT 20
                """)
            for row in rows { try database.execute("UPDATE backup_external_sets SET available = 0 WHERE id = ?", [.text(row["id"]!.string!)]) }
            return rows.map { $0["directory"]!.string! }
        }
    }

    func externalCacheDirectories() throws -> Set<String> {
        Set(try database.query("SELECT directory FROM backup_external_sets WHERE available = 1").map { $0["directory"]!.string! })
    }
}

struct BackupExternalWorker: Service {
    let lane: String
    let catalog: Catalog
    let storage: Storage
    let immich: ImmichState
    let budget: ServerWorkBudget
    let configuration: ServerConfiguration
    let owner = UUID().uuidString.lowercased()

    func run() async throws {
        await cancelWhenGracefulShutdown {
            while !Task.isCancelled {
                do { if try await runNext() { continue } }
                catch is CancellationError { if Task.isCancelled { return } }
                catch {}
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    @discardableResult
    func runNext() async throws -> Bool {
        guard let client = await immich.client, let binding = await immich.backupBinding else { return false }
        try await catalog.configureBackupExternal(binding)
        return try await budget.run(lane == "photo" ? .acquisitionPhoto : .acquisitionVideo) {
            guard let job = try await catalog.claimExternalBackup(lane: lane, owner: owner, binding: binding) else { return false }
            let directory = storage.cache("external-v2-" + job.output.uuidString.lowercased())
            var committed = false
            defer { if !committed { try? FileManager.default.removeItem(at: directory) } }
            do {
                try await withThrowingTaskGroup(of: [BackupExternalFile].self) { group in
                    group.addTask {
                        let manifest = try await catalog.backupManifest(job.manifest)
                        let bytes = try StorageBytes.sum(manifest.resources.map(\.size))
                        guard bytes <= configuration.maximumStagingBytes,
                              let free = OriginalsStore.space(at: storage.root.path).free,
                              free > configuration.minimumFreeBytes, bytes <= free - configuration.minimumFreeBytes else {
                            throw HTTPError(.serviceUnavailable)
                        }
                        return try await BackupExternal.fetch(manifest, client: client, directory: directory)
                    }
                    group.addTask {
                        while true {
                            try await Task.sleep(for: .seconds(20))
                            guard try await catalog.heartbeatExternalBackup(job) else { throw CancellationError() }
                        }
                    }
                    let files = try await group.next()!
                    group.cancelAll()
                    guard await immich.backupBinding == binding else { throw CancellationError() }
                    let indexed = files.map { file in
                        var record = file
                        record.path = storage.relative(URL(fileURLWithPath: file.path))
                        return record
                    }
                    try await catalog.finishExternalBackup(job, files: indexed, directory: storage.relative(directory))
                    committed = true
                }
            } catch is CancellationError { throw CancellationError() }
            catch { try await catalog.failExternalBackup(job) }
            return true
        }
    }
}
