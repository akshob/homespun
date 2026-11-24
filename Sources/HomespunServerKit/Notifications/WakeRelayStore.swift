// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import HomespunCore

enum WakeRelayFailure: Error, Equatable {
    case invalidInput, unauthorized, notFound, generationChanged, capacity, corruptStorage
}

struct WakeRelayPolicy: Sendable {
    var maximumRoutes: Int
    var minimumInterval: TimeInterval
    var pendingLifetime: TimeInterval
    var activeLifetime: TimeInterval
    var leaseDuration: TimeInterval

    func validate() throws {
        guard maximumRoutes > 0, maximumRoutes <= 1_000_000,
              minimumInterval.isFinite, minimumInterval >= 20 * 60,
              pendingLifetime.isFinite, pendingLifetime > 0,
              activeLifetime.isFinite, activeLifetime > 0,
              leaseDuration.isFinite, leaseDuration >= 60 else { throw WakeRelayFailure.invalidInput }
    }
}

actor WakeRelayStore {
    struct Lease: Sendable {
        var routeID: UUID
        var generationID: UUID
        var owner: UUID
        var fence: Int64
        var nonce: UUID
        var deviceToken: String
        var environment: WakeRelayAPI.Environment
    }

    enum Outcome: Sendable { case sent, invalidDevice, retry }
    private let database: SQLiteDatabase
    private let policy: WakeRelayPolicy

    init(directory: URL, policy: WakeRelayPolicy) throws {
        try policy.validate()
        let files = FileManager.default
        let directory = directory.standardizedFileURL
        guard directory.isFileURL, directory.path != "/", directory.path != files.homeDirectoryForCurrentUser.path,
              !files.fileExists(atPath: directory.appendingPathComponent(".git").path),
              !files.fileExists(atPath: directory.appendingPathComponent("Package.swift").path) else {
            throw WakeRelayFailure.invalidInput
        }
        if files.fileExists(atPath: directory.path) {
            let allowed: Set<String> = ["wake-relay.sqlite", "wake-relay.sqlite-wal", "wake-relay.sqlite-shm"]
            guard try Set(files.contentsOfDirectory(atPath: directory.path)).isSubset(of: allowed) else {
                throw WakeRelayFailure.invalidInput
            }
        }
        try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attributes = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard attributes.isDirectory == true, attributes.isSymbolicLink != true else { throw WakeRelayFailure.invalidInput }
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let url = directory.appendingPathComponent("wake-relay.sqlite")
        if files.fileExists(atPath: url.path) {
            guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw WakeRelayFailure.invalidInput
            }
        }
        let database = try SQLiteDatabase(path: url.path)
        try database.executeScript("""
            CREATE TABLE IF NOT EXISTS wake_routes (
                id TEXT PRIMARY KEY, generation TEXT NOT NULL, management BLOB NOT NULL,
                sender BLOB, token TEXT, environment TEXT, active INTEGER NOT NULL DEFAULT 0,
                pending_nonce TEXT, sent_nonce TEXT, next_send REAL NOT NULL DEFAULT 0,
                expires REAL NOT NULL, owner TEXT, fence INTEGER NOT NULL DEFAULT 0, lease_until REAL
            );
            CREATE INDEX IF NOT EXISTS wake_due ON wake_routes(active, next_send, expires);
            """)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        self.database = database
        self.policy = policy
    }

    /// Begin stores no device token. Activation requires this particular server-generated generation.
    func begin(id: UUID, managementToken: String, now: Date) throws -> WakeRelayAPI.Registration {
        try Self.validateSecret(managementToken)
        return try database.transaction {
            try database.execute("DELETE FROM wake_routes WHERE expires <= ?", [.real(now.timeIntervalSince1970)])
            if let row = try route(id) {
                try Self.authenticate(managementToken, row, column: "management")
                return .init(generationID: try Self.uuid(row, "generation"))
            }
            guard let count = try database.query("SELECT count(*) AS count FROM wake_routes").first?["count"]?.int else {
                throw WakeRelayFailure.corruptStorage
            }
            guard count < policy.maximumRoutes else { throw WakeRelayFailure.capacity }
            let generation = UUID()
            try database.execute("INSERT INTO wake_routes (id, generation, management, expires) VALUES (?, ?, ?, ?)",
                [.text(id.uuidString), .text(generation.uuidString), .blob(PairingCrypto.tokenHash(managementToken)),
                 .real(now.addingTimeInterval(policy.pendingLifetime).timeIntervalSince1970)])
            return .init(generationID: generation)
        }
    }

    func activate(id: UUID, managementToken: String, body: WakeRelayAPI.Activation, now: Date) throws {
        try Self.validateSecret(body.senderToken)
        guard !body.deviceToken.isEmpty, body.deviceToken.utf8.count <= 1_024, body.deviceToken.utf8.count.isMultiple(of: 2),
              body.deviceToken.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
            throw WakeRelayFailure.invalidInput
        }
        try database.transaction {
            guard let row = try route(id) else { throw WakeRelayFailure.notFound }
            try Self.authenticate(managementToken, row, column: "management")
            guard try Self.uuid(row, "generation") == body.generationID,
                  try Self.real(row, "expires") > now.timeIntervalSince1970 else { throw WakeRelayFailure.generationChanged }
            let token = body.deviceToken.lowercased(), sender = PairingCrypto.tokenHash(body.senderToken)
            let same = row["token"]?.string == token && row["environment"]?.string == body.environment.rawValue
                && row["sender"] == .blob(sender)
            if same {
                try database.execute("UPDATE wake_routes SET expires = ? WHERE id = ?",
                    [.real(now.addingTimeInterval(policy.activeLifetime).timeIntervalSince1970), .text(id.uuidString)])
                return
            }
            guard let fence = row["fence"]?.int, fence < Int.max else { throw WakeRelayFailure.corruptStorage }
            try database.execute("""
                UPDATE wake_routes SET sender = ?, token = ?, environment = ?, active = 1, expires = ?,
                owner = NULL, lease_until = NULL, fence = fence + 1 WHERE id = ?
                """, [.blob(sender), .text(token), .text(body.environment.rawValue),
                       .real(now.addingTimeInterval(policy.activeLifetime).timeIntervalSince1970), .text(id.uuidString)])
        }
    }

    func erase(id: UUID, managementToken: String) throws {
        try Self.validateSecret(managementToken)
        try database.transaction {
            guard let row = try route(id) else { return }
            try Self.authenticate(managementToken, row, column: "management")
            try database.execute("DELETE FROM wake_routes WHERE id = ?", [.text(id.uuidString)])
        }
    }

    func hint(id: UUID, senderToken: String, body: WakeRelayAPI.Hint, now: Date) throws {
        try database.transaction {
            guard let row = try route(id), row["active"]?.int == 1,
                  try Self.real(row, "expires") > now.timeIntervalSince1970 else { throw WakeRelayFailure.notFound }
            try Self.authenticate(senderToken, row, column: "sender")
            guard try Self.uuid(row, "generation") == body.generationID else { throw WakeRelayFailure.generationChanged }
            if row["pending_nonce"]?.string == body.nonce.uuidString || row["sent_nonce"]?.string == body.nonce.uuidString { return }
            try database.execute("UPDATE wake_routes SET pending_nonce = ? WHERE id = ?",
                                 [.text(body.nonce.uuidString), .text(id.uuidString)])
        }
    }

    func claim(owner: UUID, now: Date) throws -> Lease? {
        try database.transaction {
            try database.execute("DELETE FROM wake_routes WHERE expires <= ?", [.real(now.timeIntervalSince1970)])
            guard let row = try database.query("""
                SELECT * FROM wake_routes WHERE active = 1 AND pending_nonce IS NOT NULL AND next_send <= ?
                AND (lease_until IS NULL OR lease_until <= ?) ORDER BY next_send, rowid LIMIT 1
                """, [.real(now.timeIntervalSince1970), .real(now.timeIntervalSince1970)]).first else { return nil }
            guard let fence = row["fence"]?.int, fence < Int.max,
                  let token = row["token"]?.string, let rawEnvironment = row["environment"]?.string,
                  let environment = WakeRelayAPI.Environment(rawValue: rawEnvironment) else { throw WakeRelayFailure.corruptStorage }
            let id = try Self.uuid(row, "id")
            try database.execute("""
                UPDATE wake_routes SET owner = ?, fence = fence + 1, lease_until = ?, next_send = ? WHERE id = ?
                """, [.text(owner.uuidString), .real(now.addingTimeInterval(policy.leaseDuration).timeIntervalSince1970),
                       .real(now.addingTimeInterval(policy.minimumInterval).timeIntervalSince1970), .text(id.uuidString)])
            return .init(routeID: id, generationID: try Self.uuid(row, "generation"), owner: owner,
                fence: Int64(fence) + 1, nonce: try Self.uuid(row, "pending_nonce"), deviceToken: token, environment: environment)
        }
    }

    func finish(_ lease: Lease, outcome: Outcome) throws {
        try database.transaction {
            guard let row = try route(lease.routeID), row["owner"]?.string == lease.owner.uuidString,
                  let fence = row["fence"]?.int, Int64(fence) == lease.fence,
                  try Self.uuid(row, "generation") == lease.generationID else { return }
            switch outcome {
            case .invalidDevice:
                try database.execute("DELETE FROM wake_routes WHERE id = ?", [.text(lease.routeID.uuidString)])
            case .sent:
                try database.execute("""
                    UPDATE wake_routes SET sent_nonce = ?, pending_nonce = CASE WHEN pending_nonce = ? THEN NULL ELSE pending_nonce END,
                    owner = NULL, lease_until = NULL WHERE id = ?
                    """, [.text(lease.nonce.uuidString), .text(lease.nonce.uuidString), .text(lease.routeID.uuidString)])
            case .retry:
                try database.execute("UPDATE wake_routes SET owner = NULL, lease_until = NULL WHERE id = ?", [.text(lease.routeID.uuidString)])
            }
        }
    }

    func routeCount() throws -> Int {
        guard let value = try database.query("SELECT count(*) AS count FROM wake_routes").first?["count"]?.int else {
            throw WakeRelayFailure.corruptStorage
        }
        return value
    }

    private func route(_ id: UUID) throws -> Row? {
        try database.query("SELECT * FROM wake_routes WHERE id = ?", [.text(id.uuidString)]).first
    }

    private static func validateSecret(_ token: String) throws {
        guard PairingCrypto.decode(token, count: 32) != nil else { throw WakeRelayFailure.invalidInput }
    }

    private static func authenticate(_ token: String, _ row: Row, column: String) throws {
        try validateSecret(token)
        guard let value = row[column], case .blob(let hash) = value, PairingCrypto.equal(hash, PairingCrypto.tokenHash(token)) else {
            throw WakeRelayFailure.unauthorized
        }
    }

    private static func uuid(_ row: Row, _ column: String) throws -> UUID {
        guard let string = row[column]?.string, let uuid = UUID(uuidString: string) else { throw WakeRelayFailure.corruptStorage }
        return uuid
    }

    private static func real(_ row: Row, _ column: String) throws -> Double {
        guard let value = row[column], case .real(let number) = value, number.isFinite else { throw WakeRelayFailure.corruptStorage }
        return number
    }
}
