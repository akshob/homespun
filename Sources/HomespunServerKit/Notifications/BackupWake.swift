// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import HomespunCore
import Hummingbird
import ServiceLifecycle

struct BackupWakeLease: Sendable {
    var principal: String
    var sender: WakeRelayAPI.Sender
    var routeRevision: Int64
    var sequence: Int64
    var owner: String
    var fence: Int64
    var nonce: UUID
}

extension Catalog {
    static let backupWakeMigration = """
        CREATE TABLE backup_wake_routes (
            principal TEXT PRIMARY KEY REFERENCES devices(id) ON DELETE CASCADE,
            route_id TEXT NOT NULL, generation_id TEXT NOT NULL, token TEXT NOT NULL,
            relay_url TEXT NOT NULL, revision INTEGER NOT NULL, next_hint_at TEXT NOT NULL
        );
        CREATE UNIQUE INDEX backup_wake_consumer_route ON backup_wake_routes(route_id, generation_id);
        CREATE TABLE backup_wake_retired (
            principal TEXT NOT NULL, route_id TEXT NOT NULL, generation_id TEXT NOT NULL,
            PRIMARY KEY(principal, route_id, generation_id)
        );
        ALTER TABLE backup_wake_outbox ADD COLUMN owner TEXT;
        ALTER TABLE backup_wake_outbox ADD COLUMN fence INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE backup_wake_outbox ADD COLUMN expires_at TEXT;
        ALTER TABLE backup_wake_outbox ADD COLUMN retry_at TEXT NOT NULL DEFAULT '2000-01-01T00:00:00Z';
        ALTER TABLE backup_wake_outbox ADD COLUMN attempts INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE backup_wake_outbox ADD COLUMN nonce TEXT;
        ALTER TABLE backup_wake_outbox ADD COLUMN nonce_sequence INTEGER;
        """

    func enrollBackupWake(_ sender: WakeRelayAPI.Sender, principal: String, relay: URL) throws {
        guard let bytes = PairingCrypto.decode(sender.token, count: 32), PairingCrypto.encode(bytes) == sender.token else {
            throw HTTPError(.badRequest, message: "The scoped sender token is not canonical 32-byte data.")
        }
        try database.transaction {
            let route = sender.routeID.uuidString.lowercased(), generation = sender.generationID.uuidString.lowercased()
            guard try database.query("""
                SELECT principal FROM backup_wake_routes WHERE route_id = ? AND generation_id = ? AND principal != ?
                """, [.text(route), .text(generation), .text(principal)]).isEmpty else {
                throw APIError(.conflict, code: BackupAPI.ErrorCode.idempotencyConflict, message: "That route generation belongs to another device.")
            }
            guard try database.query("""
                SELECT principal FROM backup_wake_retired WHERE principal = ? AND route_id = ? AND generation_id = ?
                """, [.text(principal), .text(route), .text(generation)]).isEmpty else {
                throw APIError(.conflict, code: BackupAPI.ErrorCode.versionChanged, message: "That wake generation was retired; activate a new one.")
            }
            let old = try database.query("SELECT * FROM backup_wake_routes WHERE principal = ?", [.text(principal)]).first
            if let old, old["route_id"]?.string == route, old["generation_id"]?.string == generation {
                guard old["token"]?.string == sender.token, old["relay_url"]?.string == relay.absoluteString else {
                    throw APIError(.conflict, code: BackupAPI.ErrorCode.idempotencyConflict, message: "Activate a new generation before changing its scoped credential or relay.")
                }
                return
            }
            if let old { try retireBackupWakeRow(old, principal: principal) }
            let revision = try StorageBytes.add(Int64(old?["revision"]?.int ?? 0), 1)
            try database.execute("""
                INSERT INTO backup_wake_routes(principal, route_id, generation_id, token, relay_url, revision, next_hint_at)
                VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT(principal) DO UPDATE SET route_id = excluded.route_id,
                  generation_id = excluded.generation_id, token = excluded.token, relay_url = excluded.relay_url,
                  revision = excluded.revision, next_hint_at = excluded.next_hint_at
                """, [.text(principal), .text(route), .text(generation), .text(sender.token), .text(relay.absoluteString),
                       .integer(revision), .text(Timestamp.string())])
            let sequence = try database.query("SELECT MAX(sequence) AS n FROM result_changes WHERE principal = ?", [.text(principal)]).first?["n"]?.int
            if let sequence {
                try database.execute("""
                    INSERT INTO backup_wake_outbox(principal, sequence, updated_at) VALUES (?, ?, ?)
                    ON CONFLICT(principal) DO UPDATE SET sequence = MAX(sequence, excluded.sequence), updated_at = excluded.updated_at,
                      owner = NULL, expires_at = NULL, fence = fence + 1, nonce = NULL, nonce_sequence = NULL, attempts = 0,
                      retry_at = '2000-01-01T00:00:00Z'
                    """, [.text(principal), .integer(Int64(sequence)), .text(Timestamp.string())])
            }
        }
    }

    private func retireBackupWakeRow(_ row: Row, principal: String) throws {
        try database.execute("INSERT OR IGNORE INTO backup_wake_retired(principal, route_id, generation_id) VALUES (?, ?, ?)",
                             [.text(principal), .text(row["route_id"]!.string!), .text(row["generation_id"]!.string!)])
    }

    func removeBackupWake(principal: String, expectedGeneration: UUID? = nil) throws {
        try database.transaction {
            if let old = try database.query("SELECT * FROM backup_wake_routes WHERE principal = ?", [.text(principal)]).first {
                if let expectedGeneration, old["generation_id"]?.string != expectedGeneration.uuidString.lowercased() { return }
                try retireBackupWakeRow(old, principal: principal)
            }
            try database.execute("DELETE FROM backup_wake_routes WHERE principal = ?", [.text(principal)])
            try database.execute("""
                UPDATE backup_wake_outbox SET owner = NULL, expires_at = NULL, fence = fence + 1,
                  nonce = NULL, nonce_sequence = NULL WHERE principal = ?
                """, [.text(principal)])
        }
    }

    func claimBackupWake(owner: String, relay: URL, now: Date = Date()) throws -> BackupWakeLease? {
        try database.transaction {
            guard let row = try database.query("""
                SELECT o.*, r.route_id, r.generation_id, r.token, r.revision AS route_revision
                FROM backup_wake_outbox o JOIN backup_wake_routes r ON r.principal = o.principal
                JOIN devices d ON d.id = o.principal WHERE d.revoked_at IS NULL AND r.relay_url = ?
                  AND r.next_hint_at <= ? AND o.retry_at <= ? AND (o.owner IS NULL OR o.expires_at <= ?)
                ORDER BY o.updated_at, o.principal LIMIT 1
                """, [.text(relay.absoluteString), .text(Timestamp.string(now)), .text(Timestamp.string(now)),
                       .text(Timestamp.string(now))]).first else { return nil }
            let principal = row["principal"]!.string!, fence = try StorageBytes.add(Int64(row["fence"]!.int!), 1)
            let nonce = (row["nonce"]?.string).flatMap { UUID(uuidString: $0) } ?? UUID()
            let sequence = Int64(row["nonce_sequence"]?.int ?? row["sequence"]!.int!)
            try database.execute("""
                UPDATE backup_wake_outbox SET owner = ?, fence = ?, expires_at = ?, nonce = ?, nonce_sequence = ? WHERE principal = ?
                """, [.text(owner), .integer(fence), .text(Timestamp.string(now.addingTimeInterval(90))),
                       .text(nonce.uuidString.lowercased()), .integer(sequence), .text(principal)])
            return .init(principal: principal, sender: .init(routeID: UUID(uuidString: row["route_id"]!.string!)!,
                generationID: UUID(uuidString: row["generation_id"]!.string!)!, token: row["token"]!.string!),
                routeRevision: Int64(row["route_revision"]!.int!), sequence: sequence, owner: owner, fence: fence, nonce: nonce)
        }

        func releaseBackupWakeLeases() throws {
            try database.execute("""
                UPDATE backup_wake_outbox SET owner = NULL, expires_at = NULL, fence = fence + 1 WHERE owner IS NOT NULL
                """)
        }
    }

    func completeBackupWake(_ job: BackupWakeLease, result: WakeHintResult, relay: URL, now: Date = Date()) throws {
        try database.transaction {
            guard let route = try database.query("""
                SELECT * FROM backup_wake_routes WHERE principal = ? AND route_id = ? AND generation_id = ? AND revision = ? AND relay_url = ?
                """, [.text(job.principal), .text(job.sender.routeID.uuidString.lowercased()),
                       .text(job.sender.generationID.uuidString.lowercased()), .integer(job.routeRevision), .text(relay.absoluteString)]).first,
                  let row = try database.query("""
                SELECT * FROM backup_wake_outbox WHERE principal = ? AND owner = ? AND fence = ? AND expires_at > ?
                  AND nonce = ? AND nonce_sequence = ?
                """, [.text(job.principal), .text(job.owner), .integer(job.fence), .text(Timestamp.string(now)),
                       .text(job.nonce.uuidString.lowercased()), .integer(job.sequence)]).first else { return }
            switch result {
            case .accepted:
                // Acceptance is not delivery/execution. A newer sequence needs a NEW nonce
                // after this batch, even when the relay deduplicated a lost-response retry.
                try database.execute("UPDATE backup_wake_routes SET next_hint_at = ? WHERE principal = ? AND revision = ?",
                    [.text(Timestamp.string(now.addingTimeInterval(20 * 60))), .text(job.principal), .integer(job.routeRevision)])
                if Int64(row["sequence"]!.int!) == job.sequence {
                    try database.execute("DELETE FROM backup_wake_outbox WHERE principal = ? AND owner = ? AND fence = ?",
                                         [.text(job.principal), .text(job.owner), .integer(job.fence)])
                } else {
                    try database.execute("""
                        UPDATE backup_wake_outbox SET owner = NULL, expires_at = NULL, nonce = NULL, nonce_sequence = NULL,
                          attempts = 0, retry_at = ? WHERE principal = ? AND owner = ? AND fence = ?
                        """, [.text(Timestamp.string(now.addingTimeInterval(20 * 60))), .text(job.principal), .text(job.owner), .integer(job.fence)])
                }
            case .gone:
                try retireBackupWakeRow(route, principal: job.principal)
                try database.execute("DELETE FROM backup_wake_routes WHERE principal = ? AND revision = ?",
                                     [.text(job.principal), .integer(job.routeRevision)])
                try database.execute("""
                    UPDATE backup_wake_outbox SET owner = NULL, expires_at = NULL, nonce = NULL, nonce_sequence = NULL
                    WHERE principal = ? AND owner = ? AND fence = ?
                    """, [.text(job.principal), .text(job.owner), .integer(job.fence)])
            case .retry:
                let attempt = min(16, (row["attempts"]?.int ?? 0) + 1)
                let delay = min(20 * 60, 15 * (1 << min(attempt, 7)))
                try database.execute("""
                    UPDATE backup_wake_outbox SET owner = NULL, expires_at = NULL, attempts = ?, retry_at = ?
                    WHERE principal = ? AND owner = ? AND fence = ?
                    """, [.integer(Int64(attempt)), .text(Timestamp.string(now.addingTimeInterval(TimeInterval(delay)))),
                           .text(job.principal), .text(job.owner), .integer(job.fence)])
            }
        }
    }
}

struct BackupWakeWorker: Service {
    let catalog: Catalog
    let relay: URL
    let sender: any WakeHintSending
    let ownedClient: WakeHintClient?
    let owner = UUID().uuidString.lowercased()

    func run() async throws {
        do {
            await cancelWhenGracefulShutdown {
                while !Task.isCancelled {
                    do { if try await runNext() { continue } }
                    catch is CancellationError { if Task.isCancelled { return } }
                    catch {}
                    try? await Task.sleep(for: .seconds(5))
                }
            }
        }
        try await ownedClient?.shutdown()
    }

    @discardableResult
    func runNext(now: Date = Date()) async throws -> Bool {
        guard let job = try await catalog.claimBackupWake(owner: owner, relay: relay, now: now) else { return false }
        let started = ContinuousClock.now
        let result: WakeHintResult
        do { result = try await sender.send(job.sender, nonce: job.nonce) }
        catch is CancellationError { throw CancellationError() }
        catch { result = .retry }
        let elapsed = (ContinuousClock.now - started) / .seconds(1)
        try await catalog.completeBackupWake(job, result: result, relay: relay, now: now.addingTimeInterval(elapsed))
        return true
    }
}
