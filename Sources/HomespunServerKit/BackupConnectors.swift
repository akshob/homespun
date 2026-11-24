// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import HomespunCore
import Hummingbird
import ServiceLifecycle

struct BackupCopyJob: Sendable {
    var id: String
    var manifest: String
    var connector: String
    var generation: Int64
    var owner: String
    var fence: Int64
    var attempt: Int
    var workID: UUID
    var destination: String
}

extension Catalog {
    static let backupConnectorMigration = """
        ALTER TABLE backup_commands ADD COLUMN response_json TEXT;
        CREATE TABLE backup_connector_jobs (
            id TEXT PRIMARY KEY, manifest_id TEXT NOT NULL REFERENCES backup_manifests(id), connector TEXT NOT NULL,
            generation INTEGER NOT NULL, owner TEXT, fence INTEGER NOT NULL DEFAULT 0, expires_at TEXT,
            status TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0, available_at TEXT NOT NULL,
            created_at TEXT NOT NULL, principal TEXT NOT NULL, work_id TEXT,
            reference TEXT, message TEXT, destination_epoch TEXT NOT NULL DEFAULT 'legacy', UNIQUE(manifest_id, connector)
        );
        CREATE INDEX backup_connector_ready ON backup_connector_jobs(status, available_at);
        """

    func queueBackupCopies(connectors: [String: String]) throws {
        try database.transaction {
            for (connector, destination) in connectors {
            for row in try database.query("""
                SELECT m.id, m.generation, MIN(r.principal) AS principal FROM backup_manifests m
                JOIN backup_requests r ON r.manifest_id = m.id JOIN backup_claims c ON c.request_id = r.id
                WHERE c.policy = 'permanent' AND NOT EXISTS(
                    SELECT 1 FROM backup_connector_jobs j WHERE j.manifest_id = m.id AND j.connector = ?
                      AND j.destination_epoch = ? AND j.status != 'cancelled'
                ) AND (
                  (r.source = 'files' AND NOT EXISTS(SELECT 1 FROM backup_objects o WHERE o.manifest_id = m.id AND o.stored_path IS NULL))
                  OR (r.source = 'external' AND r.source_binding IS NOT NULL AND NOT EXISTS(
                    SELECT 1 FROM backup_objects o WHERE o.manifest_id = m.id AND NOT EXISTS(
                      SELECT 1 FROM backup_external_resources e WHERE e.manifest_id = o.manifest_id AND e.binding = r.source_binding
                        AND e.role = o.role AND e.sha256 = o.sha256 AND e.size = o.size))))
                GROUP BY m.id, m.generation LIMIT 200
                """, [.text(connector), .text(destination)]) {
                    try database.execute("""
                        INSERT INTO backup_connector_jobs(id, manifest_id, connector, generation, status, available_at, created_at, principal, destination_epoch)
                        VALUES (?, ?, ?, ?, 'queued', ?, ?, ?, ?)
                        ON CONFLICT(manifest_id, connector) DO UPDATE SET status = 'queued', fence = fence + 1,
                          available_at = excluded.available_at, attempts = 0, message = NULL, owner = NULL, expires_at = NULL,
                          reference = NULL, destination_epoch = excluded.destination_epoch
                        WHERE backup_connector_jobs.status = 'cancelled' OR backup_connector_jobs.destination_epoch != excluded.destination_epoch
                        """, [.text(UUID().uuidString.lowercased()), .text(row["id"]!.string!), .text(connector),
                               .integer(Int64(row["generation"]!.int!)), .text(Timestamp.string()), .text(Timestamp.string()),
                               .text(row["principal"]!.string!), .text(destination)])
                    if database.changes == 1 {
                        try refreshBackupRequests(row["id"]!.string!, force: try backupRequestIDs(row["id"]!.string!))
                    }
                }
            }
        }
    }

    func claimBackupCopy(owner: String, connectors: [String], now: Date = Date()) throws -> BackupCopyJob? {
        guard !connectors.isEmpty else { return nil }
        return try database.transaction {
            try database.execute("""
                UPDATE backup_connector_jobs SET status = 'queued', owner = NULL, expires_at = NULL
                WHERE status = 'leased' AND expires_at <= ?
                """, [.text(Timestamp.string(now))])
            let marks = connectors.map { _ in "?" }.joined(separator: ",")
            guard let row = try database.query("""
                SELECT j.* FROM backup_connector_jobs j JOIN backup_manifests m ON m.id = j.manifest_id
                WHERE j.connector IN (\(marks)) AND j.status IN ('queued', 'retry_wait') AND j.available_at <= ?
                  AND j.generation = m.generation
                ORDER BY COALESCE((SELECT last_claim FROM backup_scheduler s WHERE s.principal = j.principal
                    AND s.lane = 'versioned-connector'), 0), j.created_at, j.id LIMIT 1
                """, connectors.map(SQLValue.text) + [.text(Timestamp.string(now))]).first else { return nil }
            let id = row["id"]!.string!, fence = try StorageBytes.add(Int64(row["fence"]!.int!), 1), work = UUID()
            try database.execute("""
                UPDATE backup_connector_jobs SET status = 'leased', owner = ?, fence = ?, work_id = ?,
                    attempts = attempts + 1, expires_at = ? WHERE id = ?
                """, [.text(owner), .integer(fence), .text(work.uuidString.lowercased()),
                       .text(Timestamp.string(now.addingTimeInterval(90))), .text(id)])
            try database.execute("""
                INSERT INTO backup_scheduler(principal, lane, last_claim)
                VALUES (?, 'versioned-connector', (SELECT COALESCE(MAX(last_claim), 0) + 1 FROM backup_scheduler))
                ON CONFLICT(principal, lane) DO UPDATE SET last_claim = excluded.last_claim
                """, [.text(row["principal"]!.string!)])
            return .init(id: id, manifest: row["manifest_id"]!.string!, connector: row["connector"]!.string!,
                         generation: Int64(row["generation"]!.int!), owner: owner, fence: fence,
                         attempt: (row["attempts"]?.int ?? 0) + 1, workID: work, destination: row["destination_epoch"]!.string!)
        }
    }

    func backupCopyCurrent(_ job: BackupCopyJob) throws -> Bool {
        let settings = try setting("connector." + job.connector).flatMap { try? JSONDecoder().decode([String: String].self, from: Data($0.utf8)) } ?? [:]
        guard settings["_enabled"] == "true", settings["_sign_in_pending"] != "true",
              (settings["_destination_epoch"] ?? "legacy") == job.destination else { return false }
        return !(try database.query("""
            SELECT j.id FROM backup_connector_jobs j JOIN backup_manifests m ON m.id = j.manifest_id
            WHERE j.id = ? AND j.owner = ? AND j.fence = ? AND j.generation = ? AND m.generation = j.generation
              AND j.status = 'leased' AND j.expires_at > ?
            """, [.text(job.id), .text(job.owner), .integer(job.fence), .integer(job.generation), .text(Timestamp.string())]).isEmpty)
    }

    func heartbeatBackupCopy(_ job: BackupCopyJob) throws -> Bool {
        guard try backupCopyCurrent(job) else { return false }
        try database.execute("""
            UPDATE backup_connector_jobs SET expires_at = ? WHERE id = ? AND owner = ? AND fence = ? AND generation = ?
            """, [.text(Timestamp.string(Date().addingTimeInterval(90))), .text(job.id), .text(job.owner),
                   .integer(job.fence), .integer(job.generation)])
        return database.changes == 1
    }

    func finishBackupCopy(_ job: BackupCopyJob, reference: String?) throws {
        try database.transaction {
            guard try backupCopyCurrent(job) else { throw CancellationError() }
            try database.execute("""
                UPDATE backup_connector_jobs SET status = 'copied', reference = ?, message = NULL, owner = NULL, expires_at = NULL
                WHERE id = ? AND owner = ? AND fence = ? AND generation = ?
                """, [reference.sqlValue, .text(job.id), .text(job.owner), .integer(job.fence), .integer(job.generation)])
            try refreshBackupRequests(job.manifest, force: try backupRequestIDs(job.manifest))
        }
    }

    func failBackupCopy(_ job: BackupCopyJob, final: Bool, delay: TimeInterval = 60, message: String, countAttempt: Bool = true) throws {
        try database.transaction {
            guard try backupCopyCurrent(job) else { throw CancellationError() }
            try database.execute("""
                UPDATE backup_connector_jobs SET status = ?, available_at = ?, message = ?, owner = NULL, expires_at = NULL,
                    attempts = CASE WHEN ? = 1 THEN attempts ELSE MAX(0, attempts - 1) END
                WHERE id = ? AND owner = ? AND fence = ? AND generation = ?
                """, [.text(final ? "failed" : "retry_wait"), .text(Timestamp.string(Date().addingTimeInterval(delay))),
                       .text(message), .integer(countAttempt ? 1 : 0), .text(job.id), .text(job.owner), .integer(job.fence), .integer(job.generation)])
            try refreshBackupRequests(job.manifest, force: try backupRequestIDs(job.manifest))
        }
    }

    func backupRequestIDs(_ manifest: String) throws -> Set<String> {
        Set(try database.query("SELECT id FROM backup_requests WHERE manifest_id = ?", [.text(manifest)]).map { $0["id"]!.string! })
    }

    func versionedCopyCounts(connector: String, manifest: String? = nil) throws -> ServerAPI.ConnectorCounts {
        let destination = try setting("connector." + connector).flatMap {
            try JSONDecoder().decode([String: String].self, from: Data($0.utf8))
        }?["_destination_epoch"] ?? "legacy"
        let rows = try database.query("""
            SELECT status, COUNT(*) AS n FROM backup_connector_jobs
            WHERE connector = ? AND destination_epoch = ? AND (? IS NULL OR manifest_id = ?) GROUP BY status
            """, [.text(connector), .text(destination), manifest.sqlValue, manifest.sqlValue])
        var counts = ServerAPI.ConnectorCounts()
        for row in rows {
            switch row["status"]?.string {
            case "copied": counts.copied += row["n"]!.int!
            case "failed": counts.failed += row["n"]!.int!
            case "queued", "leased", "retry_wait": counts.pending += row["n"]!.int!
            default: break
            }
        }
        return counts
    }

    func cancelBackupCopies(connector: String) throws {
        try database.execute("""
            UPDATE backup_connector_jobs SET status = 'cancelled', fence = fence + 1, owner = NULL, expires_at = NULL
            WHERE connector = ? AND status IN ('queued', 'retry_wait', 'leased')
            """, [.text(connector)])
    }

    func backupCopyConnectorIDs(_ manifest: String) throws -> [String] {
        try database.query("SELECT connector FROM backup_connector_jobs WHERE manifest_id = ? ORDER BY connector",
                           [.text(manifest)]).map { $0["connector"]!.string! }
    }

    func releaseBackupCopyLeases() throws {
        try database.execute("""
            UPDATE backup_connector_jobs SET status = 'queued', fence = fence + 1, owner = NULL, expires_at = NULL WHERE status = 'leased'
            """)
    }

    func updateConnectorSettings(_ id: String, values: [String: String?]) throws {
        try database.transaction {
            var current = try setting("connector." + id).flatMap {
                try JSONDecoder().decode([String: String].self, from: Data($0.utf8))
            } ?? [:]
            for (key, value) in values { current[key] = value }
            try setSetting("connector." + id, current.isEmpty ? nil : String(decoding: try JSONEncoder().encode(current), as: UTF8.self))
        }
    }
}

struct BackupConnectorWorker: Service {
    let catalog: Catalog
    let storage: Storage
    let originals: OriginalsStore
    let budget: ServerWorkBudget
    let hub: ConnectorHub
    let immich: ImmichState
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
        let destinations = try await hub.enabledDestinations()
        try await catalog.queueBackupCopies(connectors: destinations)
        return try await budget.run(.connector) {
            guard let job = try await catalog.claimBackupCopy(owner: owner, connectors: destinations.keys.sorted()) else { return false }
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { try await copy(job) }
                    group.addTask {
                        while true {
                            try await Task.sleep(for: .seconds(20))
                            guard try await catalog.heartbeatBackupCopy(job) else { throw CancellationError() }
                        }
                    }
                    _ = try await group.next()
                    group.cancelAll()
                }
            } catch is CancellationError { throw CancellationError() }
            catch ConnectorError.retryLater(_, let delay) {
                try await catalog.failBackupCopy(job, final: false, delay: delay, message: "Cloud copy is waiting for its destination.", countAttempt: false)
            } catch ConnectorError.failed(_) {
                try await catalog.failBackupCopy(job, final: true, message: "Cloud copy needs attention; local retention is unchanged.")
            } catch {
                try await catalog.failBackupCopy(job, final: job.attempt >= 3, message: "Cloud transfer failed; originals remain unchanged.")
            }
            return true
        }
    }

    private func copy(_ job: BackupCopyJob) async throws {
        let directory = storage.cache("cloud-v2-" + job.workID.uuidString.lowercased())
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = try await catalog.backupManifest(job.manifest)
        let bytes = try StorageBytes.sum(manifest.resources.map(\.size))
        guard bytes <= configuration.maximumStagingBytes, let free = OriginalsStore.space(at: storage.root.path).free,
              free >= configuration.minimumFreeBytes, bytes <= free - configuration.minimumFreeBytes else {
            throw ConnectorError.retryLater("Waiting for cloud-copy staging capacity.", after: 60)
        }
        let objects = try await catalog.backupObjects(job.manifest)
        let files: [ConnectorItem.File]
        if objects.allSatisfy({ $0.path != nil }) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        files = try await originals.place { root in
            var files: [ConnectorItem.File] = []
            for object in try await catalog.backupObjects(job.manifest) {
                guard let path = object.path, let source = OriginalsStore.resolve(path, in: root) else { throw ConnectorError.retryLater("Originals unavailable.", after: 60) }
                let target = directory.appendingPathComponent(object.role.rawValue + "-" + Storage.sanitized(object.filename))
                let verified = try await detached { try Fingerprint.copy(from: source, to: target) }
                guard verified.sha256 == object.sha256, verified.size == object.size else { throw ConnectorError.failed("Original bytes changed.") }
                try FileManager.default.setAttributes([.posixPermissions: 0o440], ofItemAtPath: target.path)
                files.append(.init(role: object.role, url: target, filename: object.filename, size: object.size, sha256: object.sha256))
            }
            return files
        }
        } else {
            guard let client = await immich.client, let binding = await immich.backupBinding else {
                throw ConnectorError.retryLater("External originals unavailable.", after: 60)
            }
            let verified = try await BackupExternal.fetch(manifest, client: client, directory: directory)
            guard await immich.backupBinding == binding else { throw CancellationError() }
            files = verified.map { .init(role: $0.role, url: URL(fileURLWithPath: $0.path),
                                        filename: $0.filename, size: $0.size, sha256: $0.sha256) }
        }
        guard try await catalog.backupCopyCurrent(job) else { throw CancellationError() }
        let reference = try await hub.copyImmutable(job.connector, item: .init(assetID: try manifest.assetID(),
            kind: manifest.kind, captureDate: try await catalog.backupCaptureDate(job.manifest), files: files,
            immutableManifestID: job.manifest), destination: job.destination)
        try await catalog.finishBackupCopy(job, reference: reference)
    }
}
