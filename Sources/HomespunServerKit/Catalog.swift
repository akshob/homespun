// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import HomespunCore

typealias Role = ServerAPI.ResourceRole

enum Timestamp {
    static func string(_ date: Date = Date()) -> String { date.formatted(.iso8601) }
    static func date(_ string: String?) -> Date? { string.flatMap { try? Date($0, strategy: .iso8601) } }
}

public struct DeviceRecord: Equatable, Sendable {
    public var id: String
    public var name: String
    /// The folder its originals go in, under the originals folder: its name when it paired.
    public var folder: String? = nil
    public var createdAt: String
    public var lastSeenAt: String?
    public var revokedAt: String?
}

struct ResourceRecord: Equatable, Sendable {
    var role: Role
    var filename: String
    var size: Int
    var sha256: String
    var sha1: String?
    var state: ServerAPI.ResourceState
    var receivedBytes: Int
    var storedPath: String?
    var immichAssetID: String?
    var verifiedAt: String?
    /// An original kept outside the data folder (`homespun-server import`): read, never changed.
    var externalPath: String? = nil
    /// Where an original copied in by `homespun-server import --copy` came from.
    var importedFrom: String? = nil
}

struct CompactRecord: Equatable, Sendable {
    var role: Role
    var filename: String
    var size: Int
    var sha256: String
    var path: String
    /// Immich finds files by SHA-1, so it is kept to spot compact copies uploaded there.
    var sha1: String? = nil
}

struct AssetRecord: Equatable, Sendable {
    var id: String
    var kind: ServerAPI.AssetKind
    var captureDate: String?
    var state: ServerAPI.AssetState
    var message: String?
    var deviceCompresses: [Role]
    /// The phone asked to back it up without a compact copy for now.
    var holdCompact = false
    var trashedAt: String?
}

struct Job: Equatable, Sendable {
    var id: Int
    var type: String
    var assetID: String
    var attempts: Int
}

/// The server's SQLite catalog (WAL, foreign keys, numbered migrations). The actor is the
/// single writer; file and network work happens outside it.
public actor Catalog {
    let database: SQLiteDatabase
    static let maximumAttempts = 3
    static let pairingFailureLimit = 10

    public init(path: String) throws {
        // Owner-only: the catalog holds token hashes and the Immich API key. SQLite gives its
        // -wal and -shm files the database's permissions.
        let files = FileManager.default
        if !files.fileExists(atPath: path) {
            files.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        for file in [path, path + "-wal", path + "-shm"] where files.fileExists(atPath: file) {
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file)
        }
        database = try SQLiteDatabase(path: path)
        try Self.migrate(database)
    }

    static let migrations: [String] = [
        """
        CREATE TABLE devices (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            token_hash TEXT NOT NULL UNIQUE,
            created_at TEXT NOT NULL,
            last_seen_at TEXT,
            revoked_at TEXT
        );
        CREATE TABLE pairing_codes (
            code_hash TEXT PRIMARY KEY,
            created_at TEXT NOT NULL,
            expires_at TEXT NOT NULL,
            used_at TEXT,
            device_id TEXT REFERENCES devices(id)
        );
        CREATE TABLE pairing_failures (id INTEGER PRIMARY KEY, created_at TEXT NOT NULL);
        CREATE TABLE assets (
            id TEXT PRIMARY KEY CHECK (length(id) = 64),
            kind TEXT NOT NULL,
            capture_date TEXT,
            state TEXT NOT NULL,
            message TEXT,
            device_compresses TEXT NOT NULL DEFAULT '',
            device_id TEXT REFERENCES devices(id),
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            imported_at TEXT
        );
        CREATE TABLE resources (
            asset_id TEXT NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
            role TEXT NOT NULL,
            filename TEXT NOT NULL,
            size INTEGER NOT NULL CHECK (size > 0),
            sha256 TEXT NOT NULL,
            sha1 TEXT,
            state TEXT NOT NULL,
            received_bytes INTEGER NOT NULL DEFAULT 0,
            stored_path TEXT,
            immich_asset_id TEXT,
            verified_at TEXT,
            PRIMARY KEY (asset_id, role)
        );
        CREATE TABLE compact (
            asset_id TEXT NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
            role TEXT NOT NULL,
            filename TEXT NOT NULL,
            size INTEGER NOT NULL,
            sha256 TEXT NOT NULL,
            path TEXT NOT NULL,
            PRIMARY KEY (asset_id, role)
        );
        CREATE TABLE jobs (
            id INTEGER PRIMARY KEY,
            type TEXT NOT NULL,
            asset_id TEXT NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
            status TEXT NOT NULL,
            attempts INTEGER NOT NULL DEFAULT 0,
            available_at TEXT NOT NULL,
            lease_owner TEXT,
            lease_expires_at TEXT,
            last_error TEXT,
            created_at TEXT NOT NULL,
            UNIQUE (type, asset_id)
        );
        CREATE TABLE events (
            id INTEGER PRIMARY KEY,
            asset_id TEXT,
            device_id TEXT,
            type TEXT NOT NULL,
            detail TEXT,
            created_at TEXT NOT NULL
        );
        CREATE INDEX jobs_ready ON jobs (status, available_at);
        """,
        """
        CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        """,
        // Every compact copy ever made, kept after re-compression, so a copy is never taken for
        // an original (it may sit outside the Homespun album on the phone, or be backed up to Immich).
        """
        CREATE TABLE made_copies (
            sha256 TEXT PRIMARY KEY,
            asset_id TEXT NOT NULL,
            role TEXT NOT NULL,
            created_at TEXT NOT NULL
        );
        INSERT OR IGNORE INTO made_copies (sha256, asset_id, role, created_at)
            SELECT sha256, asset_id, role, strftime('%Y-%m-%dT%H:%M:%SZ', 'now') FROM compact;
        """,
        // Copies of each item's originals made by connectors (OneDrive and so on).
        """
        CREATE TABLE connector_copies (
            asset_id TEXT NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
            connector TEXT NOT NULL,
            state TEXT NOT NULL,
            reference TEXT,
            message TEXT,
            updated_at TEXT NOT NULL,
            PRIMARY KEY (asset_id, connector)
        );
        CREATE INDEX connector_copies_state ON connector_copies (connector, state);
        """,
        // SHA-1 of each compact copy (filled in later for older ones whose file is still here).
        """
        ALTER TABLE made_copies ADD COLUMN sha1 TEXT;
        """,
        // Originals that stay where they already were on this computer, and lookups by hash.
        """
        ALTER TABLE resources ADD COLUMN external_path TEXT;
        CREATE INDEX resources_sha256 ON resources (sha256);
        CREATE INDEX resources_external_path ON resources (external_path);
        CREATE INDEX made_copies_asset ON made_copies (asset_id);
        """,
        // Originals copied in from elsewhere remember where from, so an import can resume.
        """
        ALTER TABLE resources ADD COLUMN imported_from TEXT;
        CREATE INDEX resources_imported_from ON resources (imported_from);
        """,
        // The originals folder became a setting of its own: stored paths are relative to it, not
        // to the data folder, and each phone gets a folder in it.
        """
        UPDATE resources SET stored_path = substr(stored_path, 11) WHERE stored_path LIKE 'originals/%';
        INSERT INTO settings (key, value) SELECT 'originals.legacy', '1'
            WHERE EXISTS (SELECT 1 FROM resources WHERE stored_path IS NOT NULL);
        ALTER TABLE devices ADD COLUMN folder TEXT;
        """,
        // Recent items are backed up first and compacted later (`hold_compact`); those removed on the
        // phone meanwhile wait in the server's trash (`trashed_at`).
        """
        ALTER TABLE assets ADD COLUMN hold_compact INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE assets ADD COLUMN trashed_at TEXT;
        """,
    ]

    static func migrate(_ database: SQLiteDatabase) throws {
        let current = try database.query("PRAGMA user_version").first?["user_version"]?.int ?? 0
        guard current <= migrations.count else {
            throw SQLiteError(code: 0, message: "catalog schema \(current) is newer than this server")
        }
        for (index, script) in migrations.enumerated().dropFirst(current) {
            try database.transaction {
                try database.executeScript(script)
                try database.execute("PRAGMA user_version = \(index + 1)")
            }
        }
    }

    // MARK: Settings

    func setting(_ key: String) throws -> String? {
        try database.query("SELECT value FROM settings WHERE key = ?", [.text(key)]).first?["value"]?.string
    }

    func setSetting(_ key: String, _ value: String?) throws {
        if let value {
            try database.execute("INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value",
                                 [.text(key), .text(value)])
        } else {
            try database.execute("DELETE FROM settings WHERE key = ?", [.text(key)])
        }
    }

    // MARK: Events

    func log(_ type: String, asset: String? = nil, device: String? = nil, detail: String? = nil) {
        try? database.execute("INSERT INTO events (asset_id, device_id, type, detail, created_at) VALUES (?, ?, ?, ?, ?)",
                              [asset.sqlValue, device.sqlValue, .text(type), detail.sqlValue, .text(Timestamp.string())])
    }

    func events(asset: String) throws -> [String] {
        try database.query("SELECT type FROM events WHERE asset_id = ? ORDER BY id", [.text(asset)]).compactMap { $0["type"]?.string }
    }

    // MARK: Pairing and devices

    public func addPairingCode(hash: String, expiresAt: Date) throws {
        try database.transaction {
            try database.execute("DELETE FROM pairing_failures")
            try database.execute("INSERT INTO pairing_codes (code_hash, created_at, expires_at) VALUES (?, ?, ?)",
                                 [.text(hash), .text(Timestamp.string()), .text(Timestamp.string(expiresAt))])
        }
        log("pairing_code_created")
    }

    /// Spends an unexpired, unused code and registers the device. Too many wrong codes
    /// invalidate every outstanding code.
    func redeemPairingCode(hash: String, device: DeviceRecord, tokenHash: String) throws -> Bool {
        let now = Timestamp.string()
        let redeemed: Bool = try database.transaction {
            let rows = try database.query(
                "SELECT code_hash FROM pairing_codes WHERE code_hash = ? AND used_at IS NULL AND expires_at > ?",
                [.text(hash), .text(now)])
            guard !rows.isEmpty else {
                try database.execute("INSERT INTO pairing_failures (created_at) VALUES (?)", [.text(now)])
                let failures = try database.query("SELECT count(*) AS n FROM pairing_failures").first?["n"]?.int ?? 0
                if failures >= Self.pairingFailureLimit {
                    try database.execute("UPDATE pairing_codes SET expires_at = ? WHERE used_at IS NULL", [.text(now)])
                }
                return false
            }
            try insertDevice(device, tokenHash: tokenHash, at: now)
            try database.execute("UPDATE pairing_codes SET used_at = ?, device_id = ? WHERE code_hash = ?",
                                 [.text(now), .text(device.id), .text(hash)])
            return true
        }
        log(redeemed ? "device_paired" : "pairing_failed", device: redeemed ? device.id : nil,
            detail: redeemed ? device.name : nil)
        return redeemed
    }

    /// Registers a device someone at the server allowed.
    func addApprovedDevice(_ device: DeviceRecord, tokenHash: String) throws {
        try database.transaction { try insertDevice(device, tokenHash: tokenHash, at: Timestamp.string()) }
        log("device_paired", device: device.id, detail: "\(device.name) (allowed on the server)")
    }

    private func insertDevice(_ device: DeviceRecord, tokenHash: String, at now: String) throws {
        try database.execute("INSERT INTO devices (id, name, token_hash, created_at, folder) VALUES (?, ?, ?, ?, ?)",
                             [.text(device.id), .text(device.name), .text(tokenHash), .text(now),
                              .text(try uniqueFolder(for: device.name))])
    }

    /// A folder name for a new phone: its name, made safe, and not one another phone has.
    private func uniqueFolder(for name: String) throws -> String {
        let taken = Set(try database.query("SELECT folder FROM devices WHERE folder IS NOT NULL")
            .compactMap { $0["folder"]?.string?.lowercased() })
        let named = Storage.folderName(name)
        let base = named.isEmpty ? "iPhone" : named
        var candidate = base, number = 2
        while taken.contains(candidate.lowercased()) {
            candidate = "\(base) \(number)"
            number += 1
        }
        return candidate
    }

    /// The folder for an item's originals: the phone that sent it, or nil.
    func folder(forAsset assetID: String) throws -> String? {
        try database.query("""
            SELECT d.folder AS folder FROM assets a JOIN devices d ON d.id = a.device_id WHERE a.id = ?
            """, [.text(assetID)]).first?["folder"]?.string
    }

    func folder(forDevice deviceID: String) throws -> String? {
        try database.query("SELECT folder FROM devices WHERE id = ?", [.text(deviceID)]).first?["folder"]?.string
    }

    /// Phones paired before they had folders get one now.
    func assignMissingFolders() throws {
        try database.transaction {
            for row in try database.query("SELECT id, name FROM devices WHERE folder IS NULL ORDER BY created_at") {
                guard let id = row["id"]?.string else { continue }
                try database.execute("UPDATE devices SET folder = ? WHERE id = ?",
                                     [.text(try uniqueFolder(for: row["name"]?.string ?? "iPhone")), .text(id)])
            }
        }
    }

    /// Makes `root` the originals folder and ends the move, in one transaction, once every stored
    /// original is among `copied`; otherwise switches nothing and returns those that aren't.
    func switchOriginals(to root: String, copied: Set<String>) throws -> [String] {
        try database.transaction {
            let missing = try database.query("SELECT stored_path FROM resources WHERE stored_path IS NOT NULL")
                .compactMap { $0["stored_path"]?.string }.filter { !copied.contains($0) }
            guard missing.isEmpty else { return missing }
            try setSetting(OriginalsStore.setting, root)
            try setSetting(OriginalsMover.setting, nil)
            return []
        }
    }

    func storedOriginalCount() throws -> Int {
        try database.query("SELECT count(*) AS n FROM resources WHERE stored_path IS NOT NULL").first?["n"]?.int ?? 0
    }

    /// Every original stored in the originals folder (path relative to it), for moving them.
    func storedOriginals() throws -> [(assetID: String, role: Role, path: String, size: Int, sha256: String)] {
        try database.query("SELECT asset_id, role, stored_path, size, sha256 FROM resources WHERE stored_path IS NOT NULL ORDER BY rowid")
            .compactMap { row in
                guard let asset = row["asset_id"]?.string, let path = row["stored_path"]?.string,
                      let sha256 = row["sha256"]?.string else { return nil }
                return (asset, Role(rawValue: row["role"]?.string ?? "") ?? .other, path, row["size"]?.int ?? 0, sha256)
            }
    }

    func device(tokenHash: String) throws -> DeviceRecord? {
        guard let row = try database.query(
            "SELECT * FROM devices WHERE token_hash = ? AND revoked_at IS NULL", [.text(tokenHash)]).first else { return nil }
        let device = Self.device(row)
        let now = Date()
        if Timestamp.date(device.lastSeenAt).map({ now.timeIntervalSince($0) > 60 }) ?? true {
            try database.execute("UPDATE devices SET last_seen_at = ? WHERE id = ?", [.text(Timestamp.string(now)), .text(device.id)])
        }
        return device
    }

    public func devices() throws -> [DeviceRecord] {
        try database.query("SELECT * FROM devices ORDER BY created_at").map(Self.device)
    }

    /// A phone's new name and folder, and every path of its originals (stored, or in the trash) moved
    /// from `from` to `to`, in one transaction that also ends the rename's journal: the folders on
    /// disk have moved already (`DeviceRename`).
    func renameDevice(_ id: String, name: String, folder: String, from: String?, journal: String) throws {
        try database.transaction {
            try database.execute("UPDATE devices SET name = ?, folder = ? WHERE id = ?", [.text(name), .text(folder), .text(id)])
            if let from, from != folder {
                let rows = try database.query("""
                    SELECT r.asset_id, r.role, r.stored_path FROM resources r JOIN assets a ON a.id = r.asset_id
                    WHERE a.device_id = ? AND r.stored_path IS NOT NULL
                    """, [.text(id)])
                for row in rows {
                    guard let asset = row["asset_id"]?.string, let role = row["role"]?.string,
                          let path = row["stored_path"]?.string,
                          let moved = DeviceRename.moved(path, from: from, to: folder) else { continue }
                    try database.execute("UPDATE resources SET stored_path = ? WHERE asset_id = ? AND role = ?",
                                         [.text(moved), .text(asset), .text(role)])
                }
            }
            try setSetting(journal, nil)
        }
        log("device_renamed", device: id, detail: from.map { "\($0) → \(folder)" } ?? folder)
    }

    /// The trash folders (`.trash/<item>`) holding originals of a phone's items.
    func trashFolders(device id: String) throws -> [String] {
        let rows = try database.query("""
            SELECT DISTINCT r.stored_path FROM resources r JOIN assets a ON a.id = r.asset_id
            WHERE a.device_id = ? AND r.stored_path LIKE '.trash/%'
            """, [.text(id)])
        return Array(Set(rows.compactMap { row -> String? in
            guard let path = row["stored_path"]?.string, let original = Trash.restored(path) else { return nil }
            return String(path.dropLast(original.count + 1))
        })).sorted()
    }

    public func revoke(deviceID: String) throws -> Bool {
        try database.execute("UPDATE devices SET revoked_at = ? WHERE id = ? AND revoked_at IS NULL",
                             [.text(Timestamp.string()), .text(deviceID)])
        let changed = database.changes > 0
        if changed { log("device_revoked", device: deviceID) }
        return changed
    }

    private static func device(_ row: Row) -> DeviceRecord {
        DeviceRecord(id: row["id"]?.string ?? "", name: row["name"]?.string ?? "", folder: row["folder"]?.string,
                     createdAt: row["created_at"]?.string ?? "", lastSeenAt: row["last_seen_at"]?.string,
                     revokedAt: row["revoked_at"]?.string)
    }

    // MARK: Assets

    enum RegisterOutcome: Equatable { case created, unchanged, changed }

    /// Inserts the asset or reconciles its resources with a new description. Resources whose
    /// size or SHA-256 changed (for example, after an edit) must be supplied again, and any
    /// compact copy made from the old ones is dropped.
    func register(_ request: ServerAPI.RegisterAssetRequest, assetID: String, device: String,
                  initialState: ServerAPI.AssetState) throws -> RegisterOutcome {
        let now = Timestamp.string()
        let outcome: RegisterOutcome = try database.transaction {
            let existing = try database.query("SELECT id FROM assets WHERE id = ?", [.text(assetID)])
            if existing.isEmpty {
                try database.execute(
                    """
                    INSERT INTO assets (id, kind, capture_date, state, device_id, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    [.text(assetID), .text(request.kind.rawValue), request.captureDate.map(Timestamp.string).sqlValue,
                     .text(initialState.rawValue), .text(device), .text(now), .text(now)])
            }
            var changed = false
            let current = Dictionary(uniqueKeysWithValues: try resources(assetID).map { ($0.role, $0) })
            for resource in request.resources {
                let sha256 = resource.sha256.lowercased(), sha1 = resource.sha1?.lowercased()
                if let old = current[resource.role], old.sha256 == sha256, old.size == resource.size {
                    if old.sha1 == nil, let sha1 {
                        try database.execute("UPDATE resources SET sha1 = ? WHERE asset_id = ? AND role = ?",
                                             [.text(sha1), .text(assetID), .text(resource.role.rawValue)])
                    }
                    continue
                }
                changed = changed || !existing.isEmpty
                try database.execute(
                    """
                    INSERT OR REPLACE INTO resources (asset_id, role, filename, size, sha256, sha1, state, received_bytes)
                    VALUES (?, ?, ?, ?, ?, ?, 'missing', 0)
                    """,
                    [.text(assetID), .text(resource.role.rawValue), .text(resource.filename), .integer(Int64(resource.size)),
                     .text(sha256), sha1.sqlValue])
            }
            let kept = Set(request.resources.map(\.role))
            for role in current.keys where !kept.contains(role) {
                changed = true
                try database.execute("DELETE FROM resources WHERE asset_id = ? AND role = ?",
                                     [.text(assetID), .text(role.rawValue)])
            }
            if changed {
                try database.execute("DELETE FROM compact WHERE asset_id = ?", [.text(assetID)])
                try database.execute(
                    "UPDATE assets SET state = ?, message = NULL, imported_at = NULL, updated_at = ? WHERE id = ?",
                    [.text(initialState.rawValue), .text(now), .text(assetID)])
            }
            return existing.isEmpty ? .created : changed ? .changed : .unchanged
        }
        if outcome != .unchanged {
            log(outcome == .created ? "asset_registered" : "asset_resources_changed", asset: assetID, device: device)
        }
        return outcome
    }

    /// The newest compact copies made, with their SHA-1 if known, or else where the file is.
    func recentMadeCopies(limit: Int) throws -> [(sha256: String, sha1: String?, path: String?)] {
        try database.query("""
            SELECT m.sha256 AS sha256, m.sha1 AS sha1, (SELECT c.path FROM compact c WHERE c.sha256 = m.sha256 LIMIT 1) AS path
            FROM made_copies m ORDER BY m.created_at DESC, m.rowid DESC LIMIT ?
            """, [.integer(Int64(limit))]).compactMap { row in
            row["sha256"]?.string.map { ($0, row["sha1"]?.string, row["path"]?.string) }
        }
    }

    func setMadeCopySHA1(_ sha256: String, _ sha1: String) throws {
        try database.execute("UPDATE made_copies SET sha1 = ? WHERE sha256 = ?", [.text(sha1), .text(sha256)])
    }

    /// The original's file name when `sha256` is a compact copy this server made (and not
    /// also an original's bytes, as when a photo couldn't be made smaller).
    func madeCopy(sha256: String) throws -> (assetID: String, originalName: String?)? {
        guard let row = try database.query("""
            SELECT m.asset_id AS asset_id,
                   (SELECT r.filename FROM resources r WHERE r.asset_id = m.asset_id
                    ORDER BY CASE r.role WHEN 'photo' THEN 0 WHEN 'video' THEN 1 ELSE 2 END LIMIT 1) AS name
            FROM made_copies m
            WHERE m.sha256 = ? AND NOT EXISTS (SELECT 1 FROM resources r WHERE r.sha256 = m.sha256)
            """, [.text(sha256)]).first, let assetID = row["asset_id"]?.string else { return nil }
        return (assetID, row["name"]?.string)
    }

    /// Which of these hashes are compact copies or originals of items here.
    func lookup(_ hashes: [String]) throws -> [ServerAPI.CopyLookupResponse.Match] {
        guard !hashes.isEmpty else { return [] }
        let marks = Array(repeating: "?", count: hashes.count).joined(separator: ", ")
        let values = hashes.map { SQLValue.text($0) }
        var found: [String: (assetID: String, role: Role, isOriginal: Bool)] = [:]
        for row in try database.query("SELECT sha256, asset_id, role FROM made_copies WHERE sha256 IN (\(marks))", values) {
            guard let sha256 = row["sha256"]?.string, let asset = row["asset_id"]?.string else { continue }
            found[sha256] = (asset, Role(rawValue: row["role"]?.string ?? "") ?? .other, false)
        }
        for row in try database.query(
            "SELECT sha256, asset_id, role FROM resources WHERE sha256 IN (\(marks)) AND state = 'verified'", values) {
            guard let sha256 = row["sha256"]?.string, let asset = row["asset_id"]?.string else { continue }
            found[sha256] = (asset, Role(rawValue: row["role"]?.string ?? "") ?? .other, true)
        }
        var originals: [String: (verified: Bool, bytes: Int)] = [:]
        return try found.sorted { $0.key < $1.key }.map { sha256, match in
            if originals[match.assetID] == nil {
                let resources = try resources(match.assetID)
                originals[match.assetID] = (!resources.isEmpty && resources.allSatisfy { $0.state == .verified },
                                            resources.reduce(0) { $0 + $1.size })
            }
            let summary = originals[match.assetID]!
            return .init(sha256: sha256, assetID: match.assetID, role: match.role, isOriginal: match.isOriginal,
                         originalsVerified: summary.verified, originalBytes: summary.bytes)
        }
    }

    /// The item an original at `path` belongs to, if it was imported (in place or copied) before
    /// and is the same size.
    func importedAsset(path: String, size: Int) throws -> String? {
        try database.query("SELECT asset_id FROM resources WHERE (external_path = ? OR imported_from = ?) AND size = ?",
                           [.text(path), .text(path), .integer(Int64(size))]).first?["asset_id"]?.string
    }

    enum ImportOutcome: Equatable { case imported, linked }

    /// Records an item whose originals stay at their paths and whose compact copies were made
    /// elsewhere (and are already on the phone). An item already here keeps its originals and
    /// only learns the copies.
    /// `placedIn`: the originals folder the copied originals were put in; refused (nothing
    /// recorded) if a move is under way or the folder changed since, because those paths are
    /// relative to it.
    func importExisting(assetID: String, kind: ServerAPI.AssetKind, captureDate: Date?,
                        originals: [ResourceRecord], copies: [ServerAPI.CopyHash], placedIn: String? = nil) throws -> ImportOutcome {
        let now = Timestamp.string()
        let outcome: ImportOutcome = try database.transaction {
            if let placedIn {
                guard try setting(OriginalsMover.setting) == nil, try setting(OriginalsStore.setting) == placedIn else {
                    throw OriginalsMover.Failure(description: "the originals folder is being moved or has changed; "
                                                 + "run the import again when that's done")
                }
            }
            let exists = !(try database.query("SELECT id FROM assets WHERE id = ?", [.text(assetID)]).isEmpty)
            if !exists {
                try database.execute(
                    """
                    INSERT INTO assets (id, kind, capture_date, state, created_at, updated_at, imported_at)
                    VALUES (?, ?, ?, 'imported', ?, ?, ?)
                    """,
                    [.text(assetID), .text(kind.rawValue), captureDate.map(Timestamp.string).sqlValue,
                     .text(now), .text(now), .text(now)])
                for original in originals {
                    try database.execute(
                        """
                        INSERT INTO resources (asset_id, role, filename, size, sha256, sha1, state, received_bytes,
                                               verified_at, external_path, stored_path, imported_from)
                        VALUES (?, ?, ?, ?, ?, ?, 'verified', ?, ?, ?, ?, ?)
                        """,
                        [.text(assetID), .text(original.role.rawValue), .text(original.filename),
                         .integer(Int64(original.size)), .text(original.sha256), original.sha1.sqlValue,
                         .integer(Int64(original.size)), .text(now), original.externalPath.sqlValue,
                         original.storedPath.sqlValue, original.importedFrom.sqlValue])
                }
            }
            try insertCopies(assetID, copies, at: now)
            return exists ? .linked : .imported
        }
        log(outcome == .imported ? "asset_imported_existing" : "copies_linked", asset: assetID,
            detail: "\(copies.count) compact copies")
        return outcome
    }

    /// Remembers compact files made from the item (a copy already mapped to another item keeps it).
    private func insertCopies(_ assetID: String, _ copies: [ServerAPI.CopyHash], at now: String) throws {
        for copy in copies {
            try database.execute(
                """
                INSERT INTO made_copies (sha256, asset_id, role, created_at, sha1) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT (sha256) DO UPDATE SET sha1 = COALESCE(made_copies.sha1, excluded.sha1)
                """, [.text(copy.sha256.lowercased()), .text(assetID), .text(copy.role.rawValue), .text(now),
                      copy.sha1.map { $0.lowercased() }.sqlValue])
        }
    }

    func rememberCopies(_ assetID: String, _ copies: [ServerAPI.CopyHash]) throws {
        guard !copies.isEmpty else { return }
        try database.transaction { try insertCopies(assetID, copies, at: Timestamp.string()) }
        log("device_copies", asset: assetID, detail: copies.map(\.role.rawValue).joined(separator: ","))
    }

    func asset(_ id: String) throws -> AssetRecord? {
        guard let row = try database.query("SELECT * FROM assets WHERE id = ?", [.text(id)]).first else { return nil }
        return AssetRecord(
            id: id, kind: ServerAPI.AssetKind(rawValue: row["kind"]?.string ?? "") ?? .photo,
            captureDate: row["capture_date"]?.string,
            state: ServerAPI.AssetState(rawValue: row["state"]?.string ?? "") ?? .failed,
            message: row["message"]?.string,
            deviceCompresses: (row["device_compresses"]?.string ?? "").split(separator: ",")
                .compactMap { Role(rawValue: String($0)) },
            holdCompact: (row["hold_compact"]?.int ?? 0) != 0, trashedAt: row["trashed_at"]?.string)
    }

    /// Whether the phone wants a compact copy now (`false`: back it up, compact it later).
    func setHoldCompact(_ assetID: String, _ hold: Bool) throws {
        try database.execute("UPDATE assets SET hold_compact = ? WHERE id = ?", [.integer(hold ? 1 : 0), .text(assetID)])
    }

    /// Moves an asset to or out of the trash: its stored paths change, and so does its state.
    func setTrashed(_ assetID: String, paths: [Role: String], at date: String?, state: ServerAPI.AssetState) throws {
        try database.transaction {
            for (role, path) in paths {
                try database.execute("UPDATE resources SET stored_path = ? WHERE asset_id = ? AND role = ?",
                                     [.text(path), .text(assetID), .text(role.rawValue)])
            }
            try database.execute("UPDATE assets SET state = ?, message = NULL, trashed_at = ?, updated_at = ? WHERE id = ?",
                                 [.text(state.rawValue), date.sqlValue, .text(Timestamp.string()), .text(assetID)])
        }
        log(date == nil ? "asset_restored" : "asset_trashed", asset: assetID)
    }

    /// A trashed file that's gone: the phone uploads it again.
    func forgetStored(_ assetID: String, role: Role) throws {
        try database.execute(
            "UPDATE resources SET stored_path = NULL, state = 'missing', received_bytes = 0, verified_at = NULL WHERE asset_id = ? AND role = ?",
            [.text(assetID), .text(role.rawValue)])
        log("resource_missing", asset: assetID, detail: role.rawValue + " (not in the trash any more)")
    }

    /// Trashed assets whose time is up.
    func trashed(before date: String) throws -> [String] {
        try database.query("SELECT id FROM assets WHERE state = 'trashed' AND trashed_at < ?", [.text(date)])
            .compactMap { $0["id"]?.string }
    }

    /// Everything waiting in the trash: count and bytes.
    func trashTotals() throws -> (count: Int, bytes: Int64) {
        let row = try database.query("""
            SELECT COUNT(DISTINCT a.id) AS count, COALESCE(SUM(r.size), 0) AS bytes FROM assets a
            LEFT JOIN resources r ON r.asset_id = a.id WHERE a.state = 'trashed'
            """).first
        return (row?["count"]?.int ?? 0, Int64(row?["bytes"]?.int ?? 0))
    }

    /// Forgets an asset whose trash time is up (its files are already deleted).
    func deleteAsset(_ assetID: String) throws {
        try database.transaction {
            try database.execute("DELETE FROM jobs WHERE asset_id = ?", [.text(assetID)])
            try database.execute("DELETE FROM connector_copies WHERE asset_id = ?", [.text(assetID)])
            try database.execute("DELETE FROM compact WHERE asset_id = ?", [.text(assetID)])
            try database.execute("DELETE FROM assets WHERE id = ?", [.text(assetID)])
        }
        log("asset_deleted", asset: assetID, detail: "removed on the phone; trash emptied")
    }

    func resources(_ assetID: String) throws -> [ResourceRecord] {
        try database.query("SELECT * FROM resources WHERE asset_id = ? ORDER BY role", [.text(assetID)]).map { row in
            ResourceRecord(
                role: Role(rawValue: row["role"]?.string ?? "") ?? .other, filename: row["filename"]?.string ?? "",
                size: row["size"]?.int ?? 0, sha256: row["sha256"]?.string ?? "", sha1: row["sha1"]?.string,
                state: ServerAPI.ResourceState(rawValue: row["state"]?.string ?? "") ?? .missing,
                receivedBytes: row["received_bytes"]?.int ?? 0, storedPath: row["stored_path"]?.string,
                immichAssetID: row["immich_asset_id"]?.string, verifiedAt: row["verified_at"]?.string,
                externalPath: row["external_path"]?.string, importedFrom: row["imported_from"]?.string)
        }
    }

    func compact(_ assetID: String) throws -> [CompactRecord] {
        try database.query("SELECT * FROM compact WHERE asset_id = ? ORDER BY role", [.text(assetID)]).map { row in
            CompactRecord(role: Role(rawValue: row["role"]?.string ?? "") ?? .other, filename: row["filename"]?.string ?? "",
                          size: row["size"]?.int ?? 0, sha256: row["sha256"]?.string ?? "", path: row["path"]?.string ?? "")
        }
    }

    func status(_ assetID: String) throws -> ServerAPI.AssetStatus? {
        guard let asset = try asset(assetID) else { return nil }
        let ready = asset.state == .ready || asset.state == .imported
        let trashedUntil = asset.state == .trashed
            ? Timestamp.date(asset.trashedAt).map { $0.addingTimeInterval(Trash.keep) } : nil
        return ServerAPI.AssetStatus(
            assetID: assetID, kind: asset.kind, state: asset.state, message: asset.message,
            resources: try resources(assetID).map {
                ServerAPI.ResourceStatus(role: $0.role, sha256: $0.sha256, size: $0.size, state: $0.state,
                                         receivedBytes: $0.receivedBytes, verifiedAt: Timestamp.date($0.verifiedAt))
            },
            compact: ready ? try compact(assetID).map {
                ServerAPI.CompactResource(role: $0.role, filename: $0.filename, size: $0.size, sha256: $0.sha256)
            } : [],
            deviceCompresses: ready ? asset.deviceCompresses : [], trashedUntil: trashedUntil)
    }

    func setReceived(_ assetID: String, role: Role, bytes: Int) throws {
        try database.execute("UPDATE resources SET received_bytes = ?, state = ? WHERE asset_id = ? AND role = ? AND state != 'verified'",
                             [.integer(Int64(bytes)), .text(bytes > 0 ? "partial" : "missing"), .text(assetID), .text(role.rawValue)])
    }

    func markResource(_ assetID: String, role: Role, state: ServerAPI.ResourceState, storedPath: String? = nil,
                      immichAssetID: String? = nil) throws {
        let verified = state == .verified ? Timestamp.string() : nil
        try database.execute(
            """
            UPDATE resources SET state = ?, verified_at = ?,
                stored_path = coalesce(?, stored_path), immich_asset_id = coalesce(?, immich_asset_id),
                received_bytes = CASE WHEN ? = 'verified' THEN size WHEN ? = 'partial' THEN received_bytes ELSE 0 END
            WHERE asset_id = ? AND role = ?
            """,
            [.text(state.rawValue), verified.sqlValue, storedPath.sqlValue, immichAssetID.sqlValue,
             .text(state.rawValue), .text(state.rawValue), .text(assetID), .text(role.rawValue)])
        log("resource_\(state.rawValue)", asset: assetID, detail: role.rawValue)
    }

    func setState(_ assetID: String, _ state: ServerAPI.AssetState, message: String? = nil) throws {
        try database.execute("UPDATE assets SET state = ?, message = ?, updated_at = ? WHERE id = ?",
                             [.text(state.rawValue), message.sqlValue, .text(Timestamp.string()), .text(assetID)])
        log("asset_\(state.rawValue)", asset: assetID, detail: message)
    }

    func storeCompact(_ assetID: String, _ files: [CompactRecord], deviceCompresses: [Role],
                      state: ServerAPI.AssetState, message: String?) throws {
        try database.transaction {
            try database.execute("DELETE FROM compact WHERE asset_id = ?", [.text(assetID)])
            for file in files {
                try database.execute("INSERT INTO compact (asset_id, role, filename, size, sha256, path) VALUES (?, ?, ?, ?, ?, ?)",
                                     [.text(assetID), .text(file.role.rawValue), .text(file.filename),
                                      .integer(Int64(file.size)), .text(file.sha256), .text(file.path)])
                try database.execute(
                    """
                    INSERT INTO made_copies (sha256, asset_id, role, created_at, sha1) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT (sha256) DO UPDATE SET sha1 = COALESCE(made_copies.sha1, excluded.sha1)
                    """, [.text(file.sha256), .text(assetID), .text(file.role.rawValue), .text(Timestamp.string()),
                          file.sha1.sqlValue])
            }
            try database.execute(
                "UPDATE assets SET state = ?, message = ?, device_compresses = ?, updated_at = ? WHERE id = ?",
                [.text(state.rawValue), message.sqlValue, .text(deviceCompresses.map(\.rawValue).joined(separator: ",")),
                 .text(Timestamp.string()), .text(assetID)])
        }
        log("asset_\(state.rawValue)", asset: assetID, detail: message)
    }

    func markImported(_ assetID: String, device: String) throws -> Bool {
        try database.execute(
            "UPDATE assets SET state = 'imported', imported_at = ?, updated_at = ? WHERE id = ? AND state IN ('ready', 'imported')",
            [.text(Timestamp.string()), .text(Timestamp.string()), .text(assetID)])
        let changed = database.changes > 0
        if changed { log("asset_imported", asset: assetID, device: device) }
        return changed
    }

    // MARK: Jobs

    /// Queues `type` for the asset unless it is already queued or running.
    // MARK: Connector copies

    func setCopyState(_ assetID: String, connector: String, state: String, reference: String? = nil,
                      message: String? = nil) throws {
        try database.execute(
            """
            INSERT INTO connector_copies (asset_id, connector, state, reference, message, updated_at) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT (asset_id, connector) DO UPDATE SET state = excluded.state,
                reference = COALESCE(excluded.reference, connector_copies.reference), message = excluded.message,
                updated_at = excluded.updated_at
            """,
            [.text(assetID), .text(connector), .text(state), reference.sqlValue, message.sqlValue, .text(Timestamp.string())])
        if state == "copied" || state == "failed" {
            log("copy_\(state)", asset: assetID, detail: [connector, reference ?? message].compactMap { $0 }.joined(separator: ": "))
        }
    }

    func copyState(_ assetID: String, connector: String) throws -> (state: String, reference: String?, message: String?)? {
        guard let row = try database.query("SELECT state, reference, message FROM connector_copies WHERE asset_id = ? AND connector = ?",
                                           [.text(assetID), .text(connector)]).first else { return nil }
        return (row["state"]?.string ?? "", row["reference"]?.string, row["message"]?.string)
    }

    func copyCounts(connector: String) throws -> ServerAPI.ConnectorCounts {
        var counts = ServerAPI.ConnectorCounts()
        for row in try database.query("SELECT state, count(*) AS n FROM connector_copies WHERE connector = ? GROUP BY state",
                                      [.text(connector)]) {
            let n = row["n"]?.int ?? 0
            switch row["state"]?.string {
            case "copied": counts.copied += n
            case "failed": counts.failed += n
            default: counts.pending += n
            }
        }
        return counts
    }

    /// Items whose every original is stored here or was checked in Immich.
    func assetsWithVerifiedOriginals() throws -> [String] {
        try database.query("""
            SELECT a.id AS id FROM assets a
            WHERE EXISTS (SELECT 1 FROM resources r WHERE r.asset_id = a.id)
              AND NOT EXISTS (SELECT 1 FROM resources r WHERE r.asset_id = a.id AND r.state != 'verified')
              -- Recent items waiting for their compact copy (or cleaned up) reach the cloud later, if at all.
              AND a.state NOT IN ('stored', 'trashed')
            ORDER BY a.capture_date, a.created_at
            """).compactMap { $0["id"]?.string }
    }

    /// Drops queued jobs of a type (a connector being removed), and their pending copies.
    func cancelJobs(prefix type: String) throws {
        try database.execute("DELETE FROM jobs WHERE type = ? AND status IN ('queued', 'retry_wait')", [.text(type)])
        let connector = String(type.dropFirst(ConnectorHub.jobPrefix.count))
        try database.execute("DELETE FROM connector_copies WHERE connector = ? AND state IN ('queued', 'copying')",
                             [.text(connector)])
    }

    // MARK: Jobs

    func enqueue(_ type: String, assetID: String) throws {
        let now = Timestamp.string()
        try database.execute(
            """
            INSERT INTO jobs (type, asset_id, status, available_at, created_at) VALUES (?, ?, 'queued', ?, ?)
            ON CONFLICT (type, asset_id) DO UPDATE SET status = 'queued', attempts = 0, available_at = excluded.available_at,
                last_error = NULL, lease_owner = NULL, lease_expires_at = NULL
            WHERE jobs.status NOT IN ('queued', 'leased', 'retry_wait')
            """,
            [.text(type), .text(assetID), .text(now), .text(now)])
    }

    /// Claims the oldest ready job of one lane: connector copies (`connectors`) or everything else,
    /// so a long backlog of copies never delays compact copies.
    func claim(owner: String, lease: TimeInterval, connectors: Bool = false) throws -> Job? {
        let now = Date()
        return try database.transaction {
            try database.execute(
                "UPDATE jobs SET status = 'queued', lease_owner = NULL WHERE status = 'leased' AND lease_expires_at <= ?",
                [.text(Timestamp.string(now))])
            guard let row = try database.query(
                """
                SELECT id, type, asset_id, attempts FROM jobs
                WHERE status IN ('queued', 'retry_wait') AND available_at <= ?
                  AND (substr(type, 1, length(?)) = ?) = ?
                ORDER BY id LIMIT 1
                """, [.text(Timestamp.string(now)), .text(ConnectorHub.jobPrefix), .text(ConnectorHub.jobPrefix),
                      .integer(connectors ? 1 : 0)]).first, let id = row["id"]?.int else { return nil }
            try database.execute(
                "UPDATE jobs SET status = 'leased', lease_owner = ?, lease_expires_at = ?, attempts = attempts + 1 WHERE id = ?",
                [.text(owner), .text(Timestamp.string(now.addingTimeInterval(lease))), .integer(Int64(id))])
            return Job(id: id, type: row["type"]?.string ?? "", assetID: row["asset_id"]?.string ?? "",
                       attempts: (row["attempts"]?.int ?? 0) + 1)
        }
    }

    func finish(_ job: Job) throws {
        try database.execute("UPDATE jobs SET status = 'succeeded', lease_owner = NULL, lease_expires_at = NULL WHERE id = ?",
                             [.integer(Int64(job.id))])
    }

    /// Schedules a retry with backoff, or gives up after `maximumAttempts`. Returns true if retrying.
    func fail(_ job: Job, error: String) throws -> Bool {
        let retry = job.attempts < Self.maximumAttempts
        let backoff = Double(30 << min(job.attempts, 6))
        try database.execute(
            "UPDATE jobs SET status = ?, last_error = ?, available_at = ?, lease_owner = NULL, lease_expires_at = NULL WHERE id = ?",
            [.text(retry ? "retry_wait" : "failed"), .text(error), .text(Timestamp.string(Date().addingTimeInterval(backoff))),
             .integer(Int64(job.id))])
        log(retry ? "job_retry" : "job_failed", asset: job.assetID, detail: "\(job.type): \(error)")
        return retry
    }

    /// Waits before trying a job again without counting the attempt (the destination is full or offline).
    func postpone(_ job: Job, by delay: TimeInterval, reason: String) throws {
        try database.execute(
            """
            UPDATE jobs SET status = 'retry_wait', attempts = max(attempts - 1, 0), last_error = ?, available_at = ?,
                lease_owner = NULL, lease_expires_at = NULL WHERE id = ?
            """, [.text(reason), .text(Timestamp.string(Date().addingTimeInterval(delay))), .integer(Int64(job.id))])
    }

    /// At startup nothing can hold a lease, so leased jobs from a previous run are queued again.
    func releaseLeases() throws {
        try database.execute("UPDATE jobs SET status = 'queued', lease_owner = NULL, lease_expires_at = NULL WHERE status = 'leased'")
    }

    func jobStatus(_ type: String, assetID: String) throws -> String? {
        try database.query("SELECT status FROM jobs WHERE type = ? AND asset_id = ?", [.text(type), .text(assetID)])
            .first?["status"]?.string
    }
}
