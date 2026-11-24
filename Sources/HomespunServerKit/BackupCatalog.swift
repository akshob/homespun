// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import HomespunCore
import Hummingbird

struct BackupObject: Sendable {
    var manifest: String
    var role: Role
    var filename: String
    var size: Int
    var sha256: String
    var path: String?
}

struct BackupUpload: Sendable {
    var id: String
    var request: String
    var principal: String
    var version: BackupAPI.Version
    var object: BackupObject
    var offset: Int64
    var state: String
}

struct BackupJob: Sendable {
    var id: String
    var manifest: String
    var recipe: BackupAPI.Recipe
    var recipeID: String
    var generation: Int64
    var owner: String
    var fence: Int64
    var output: UUID
    var lane: String
    var attempts: Int
}

struct BackupAdoptionCandidate: Sendable {
    var request: String
    var principal: String
    var manifest: String
    var role: Role
    var sourceAsset: String
}

struct BackupLegacySource: Sendable {
    var asset: String
    var stored: String?
    var external: String?
}

extension Catalog {
    static let backupMigration = """
        CREATE TABLE backup_manifests (
            id TEXT PRIMARY KEY, asset_id TEXT NOT NULL, generation INTEGER NOT NULL, kind TEXT NOT NULL,
            manifest_json TEXT NOT NULL, device_id TEXT NOT NULL REFERENCES devices(id),
            capture_date TEXT, created_at TEXT NOT NULL, UNIQUE(asset_id, generation)
        );
        CREATE TABLE backup_objects (
            manifest_id TEXT NOT NULL REFERENCES backup_manifests(id), role TEXT NOT NULL,
            filename TEXT NOT NULL, size INTEGER NOT NULL CHECK(size > 0), sha256 TEXT NOT NULL,
            stored_path TEXT, verified_at TEXT, PRIMARY KEY(manifest_id, role)
        );
        CREATE INDEX backup_objects_path ON backup_objects(stored_path);
        CREATE INDEX backup_objects_hash ON backup_objects(sha256);
        CREATE TABLE backup_requests (
            id TEXT PRIMARY KEY, principal TEXT NOT NULL REFERENCES devices(id), operation_id TEXT NOT NULL,
            payload_hash TEXT NOT NULL, manifest_id TEXT NOT NULL REFERENCES backup_manifests(id),
            recipe_id TEXT NOT NULL, recipe_json TEXT NOT NULL, source TEXT NOT NULL,
            wants_compact INTEGER NOT NULL, paused INTEGER NOT NULL DEFAULT 0,
            cancelled INTEGER NOT NULL DEFAULT 0, compact_state TEXT NOT NULL DEFAULT 'requested',
            derivative_id TEXT, message TEXT, receipt_json TEXT NOT NULL DEFAULT '',
            created_at TEXT NOT NULL, revision INTEGER NOT NULL DEFAULT 0, UNIQUE(principal, operation_id)
        );
        CREATE INDEX backup_requests_version ON backup_requests(manifest_id, recipe_id);
        CREATE TABLE backup_claims (
            id TEXT PRIMARY KEY, request_id TEXT NOT NULL UNIQUE REFERENCES backup_requests(id),
            principal TEXT NOT NULL REFERENCES devices(id), manifest_id TEXT NOT NULL REFERENCES backup_manifests(id),
            policy TEXT NOT NULL, created_at TEXT NOT NULL
        );
        CREATE TABLE backup_uploads (
            id TEXT PRIMARY KEY, request_id TEXT NOT NULL REFERENCES backup_requests(id),
            principal TEXT NOT NULL REFERENCES devices(id), manifest_id TEXT NOT NULL, role TEXT NOT NULL,
            version_json TEXT NOT NULL, offset INTEGER NOT NULL DEFAULT 0, state TEXT NOT NULL DEFAULT 'open',
            created_at TEXT NOT NULL, cleaned INTEGER NOT NULL DEFAULT 0,
            FOREIGN KEY(manifest_id, role) REFERENCES backup_objects(manifest_id, role)
        );
        CREATE TABLE backup_publications (
            upload_id TEXT PRIMARY KEY REFERENCES backup_uploads(id), manifest_id TEXT NOT NULL, role TEXT NOT NULL,
            relative_path TEXT NOT NULL, UNIQUE(manifest_id, role)
        );
        CREATE TABLE backup_adoption_wait (
            manifest_id TEXT NOT NULL, role TEXT NOT NULL, available_at TEXT NOT NULL, PRIMARY KEY(manifest_id, role)
        );
        CREATE TABLE backup_jobs (
            id TEXT PRIMARY KEY, manifest_id TEXT NOT NULL REFERENCES backup_manifests(id), recipe_id TEXT NOT NULL,
            recipe_json TEXT NOT NULL, generation INTEGER NOT NULL, lane TEXT NOT NULL, principal TEXT NOT NULL,
            status TEXT NOT NULL, fence INTEGER NOT NULL DEFAULT 0, owner TEXT, expires_at TEXT,
            output_id TEXT, attempts INTEGER NOT NULL DEFAULT 0, available_at TEXT NOT NULL,
            created_at TEXT NOT NULL, UNIQUE(manifest_id, recipe_id)
        );
        CREATE INDEX backup_jobs_ready ON backup_jobs(lane, status, available_at);
        CREATE TABLE backup_scheduler (
            principal TEXT NOT NULL, lane TEXT NOT NULL, last_claim INTEGER NOT NULL, PRIMARY KEY(principal, lane)
        );
        CREATE TABLE backup_derivatives (
            id TEXT PRIMARY KEY, manifest_id TEXT NOT NULL REFERENCES backup_manifests(id),
            recipe_id TEXT NOT NULL, generation INTEGER NOT NULL, files_json TEXT NOT NULL,
            device_compresses_json TEXT NOT NULL, created_at TEXT NOT NULL
        );
        CREATE TABLE backup_commands (
            principal TEXT NOT NULL, operation_id TEXT NOT NULL, request_id TEXT NOT NULL,
            payload_hash TEXT NOT NULL, PRIMARY KEY(principal, operation_id)
        );
        CREATE TABLE backup_delivery_acks (
            id TEXT PRIMARY KEY, principal TEXT NOT NULL, request_id TEXT NOT NULL REFERENCES backup_requests(id),
            generation_id TEXT NOT NULL REFERENCES backup_derivatives(id), payload_hash TEXT NOT NULL, created_at TEXT NOT NULL
        );
        CREATE TABLE result_changes (
            sequence INTEGER PRIMARY KEY AUTOINCREMENT, principal TEXT NOT NULL,
            request_id TEXT NOT NULL REFERENCES backup_requests(id), receipt_json TEXT NOT NULL, created_at TEXT NOT NULL
        );
        CREATE INDEX result_changes_principal ON result_changes(principal, sequence);
        CREATE INDEX result_changes_request ON result_changes(principal, request_id, sequence DESC);
        CREATE TABLE backup_snapshots (
            id TEXT PRIMARY KEY, principal TEXT NOT NULL, epoch TEXT NOT NULL,
            cursor INTEGER NOT NULL, expires_at TEXT NOT NULL
        );
        CREATE TABLE backup_snapshot_pages (
            token_hash TEXT PRIMARY KEY, snapshot_id TEXT NOT NULL REFERENCES backup_snapshots(id) ON DELETE CASCADE,
            principal TEXT NOT NULL, position INTEGER NOT NULL
        );
        CREATE TABLE backup_wake_outbox (
            principal TEXT PRIMARY KEY, sequence INTEGER NOT NULL, updated_at TEXT NOT NULL
        );
        ALTER TABLE jobs ADD COLUMN generation INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE jobs ADD COLUMN fence INTEGER NOT NULL DEFAULT 0;
        UPDATE jobs SET generation = COALESCE((SELECT generation FROM assets WHERE assets.id = jobs.asset_id), 0);
        """

    static func backupJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = ServerAPI.encoder
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    static func backupDecode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try ServerAPI.decoder.decode(type, from: Data(json.utf8))
    }

    static func backupIntentHash<T: Encodable>(_ value: T) throws -> String {
        let encoder = ServerAPI.encoder
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return Fingerprint.sha256(of: try encoder.encode(value))
    }

    func backupOrigin() throws -> BackupAPI.Origin {
        try database.transaction { try backupOriginInTransaction() }
    }

    func hasVersionedBackups() throws -> Bool {
        !(try database.query("SELECT id FROM backup_requests LIMIT 1").isEmpty)
    }

    private func backupOriginInTransaction() throws -> BackupAPI.Origin {
        let savedServer = try setting("backup.server_id"), savedEpoch = try setting("backup.history_epoch")
        if savedServer == nil || savedEpoch == nil {
            guard try database.query("SELECT id FROM backup_requests LIMIT 1").isEmpty else {
                throw HTTPError(.serviceUnavailable, message: "The backup history identity is incomplete; restore it rather than inventing a new identity.")
            }
        }
        let server = savedServer ?? UUID().uuidString.lowercased()
        let epoch = savedEpoch ?? UUID().uuidString.lowercased()
        try setSetting("backup.server_id", server)
        try setSetting("backup.history_epoch", epoch)
        return .init(serverID: server, historyEpoch: epoch)
    }

    func checkBackupOrigin(_ expected: BackupAPI.Origin) throws {
        let current = try backupOrigin()
        guard current == expected else {
            throw APIError(.conflict, code: BackupAPI.ErrorCode.historyChanged, message: "Refresh this server's capabilities and reconcile a snapshot.")
        }
    }

    func admitBackup(_ request: BackupAPI.Request, principal: String, recipe: BackupAPI.Recipe,
                     external: Bool) throws -> (BackupAPI.Receipt, Bool) {
        try checkBackupOrigin(request.origin)
        let manifestID = try request.manifest.identifier(), assetID = try request.manifest.assetID()
        let recipeID = try recipe.identifier(), hash = try Self.backupIntentHash(request)
        let operation = request.operationID.uuidString.lowercased()
        return try database.transaction {
            if let old = try database.query("SELECT id, payload_hash FROM backup_requests WHERE principal = ? AND operation_id = ?",
                                             [.text(principal), .text(operation)]).first {
                guard old["payload_hash"]?.string == hash else { throw Self.backupConflict() }
                return (try backupReceipt(old["id"]!.string!, principal: principal), false)
            }
            if try database.query("SELECT id FROM backup_manifests WHERE id = ?", [.text(manifestID)]).isEmpty {
                let previous = try database.query("SELECT MAX(generation) AS n FROM backup_manifests WHERE asset_id = ?",
                                                   [.text(assetID)]).first?["n"]?.int
                let generation = try previous.map { try StorageBytes.add(Int64($0), 1) } ?? 0
                try database.execute("""
                    INSERT INTO backup_manifests(id, asset_id, generation, kind, manifest_json, device_id, capture_date, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """, [.text(manifestID), .text(assetID), .integer(generation), .text(request.manifest.kind.rawValue),
                           .text(try Self.backupJSON(request.manifest)),
                           .text(principal), request.captureDate.map(Timestamp.string).sqlValue, .text(Timestamp.string())])
                for resource in request.manifest.resources {
                    try database.execute("""
                        INSERT INTO backup_objects(manifest_id, role, filename, size, sha256) VALUES (?, ?, ?, ?, ?)
                        """, [.text(manifestID), .text(resource.role.rawValue), .text(resource.filename),
                               .integer(Int64(resource.size)), .text(resource.sha256.lowercased())])
                }
            }
            let id = UUID().uuidString.lowercased()
            try database.execute("""
                INSERT INTO backup_requests(id, principal, operation_id, payload_hash, manifest_id, recipe_id,
                    recipe_json, source, wants_compact, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, [.text(id), .text(principal), .text(operation), .text(hash), .text(manifestID), .text(recipeID),
                       .text(try Self.backupJSON(recipe)), .text(external ? "external" : "files"),
                       .integer(request.compact ? 1 : 0), .text(Timestamp.string())])
            // This claim is committed before any byte or processing receipt is returned.
            try database.execute("""
                INSERT INTO backup_claims(id, request_id, principal, manifest_id, policy, created_at) VALUES (?, ?, ?, ?, ?, ?)
                """, [.text(UUID().uuidString.lowercased()), .text(id), .text(principal), .text(manifestID),
                       .text(request.retention.rawValue), .text(Timestamp.string())])
            if request.retention == .permanent, !external {
                // A versioned permanent consumer also dominates legacy temporary cleanup.
                // Admission's caller holds this legacy asset's mutation claim.
                try database.execute("UPDATE assets SET permanent = 1 WHERE id = ? AND purging = 0", [.text(assetID)])
                for resource in request.manifest.resources {
                    if let source = try legacyBackupSource(manifest: manifestID, role: resource.role) {
                        try database.execute("UPDATE assets SET permanent = 1 WHERE id = ? AND purging = 0", [.text(source.asset)])
                    }
                }
            }
            try queueBackupIfComplete(manifestID)
            try refreshBackupRequests(manifestID)
            return (try backupReceipt(id, principal: principal), true)
        }
    }

    static func backupConflict() -> APIError {
        APIError(.conflict, code: BackupAPI.ErrorCode.idempotencyConflict,
                 message: "That operation identifier already describes a different request.")
    }

    func backupObjects(_ manifest: String) throws -> [BackupObject] {
        try database.query("SELECT * FROM backup_objects WHERE manifest_id = ? ORDER BY role", [.text(manifest)]).compactMap {
            guard let role = Role(rawValue: $0["role"]?.string ?? "") else { return nil }
            return .init(manifest: manifest, role: role, filename: $0["filename"]?.string ?? "",
                         size: $0["size"]?.int ?? 0, sha256: $0["sha256"]?.string ?? "", path: $0["stored_path"]?.string)
        }

        func backupObjectFolder(_ manifest: String) throws -> String {
            guard let row = try database.query("""
                SELECT d.folder FROM backup_manifests m JOIN devices d ON d.id = m.device_id WHERE m.id = ?
                """, [.text(manifest)]).first, let folder = row["folder"]?.string else { throw HTTPError(.serviceUnavailable) }
            let safe = Storage.folderName(folder)
            guard !safe.isEmpty, safe == folder else { throw HTTPError(.serviceUnavailable) }
            return safe
        }

        func backupObjectDirectory(_ manifest: String) throws -> String {
            let folder = try backupObjectFolder(manifest)
            guard let row = try database.query("SELECT capture_date, manifest_json FROM backup_manifests WHERE id = ?", [.text(manifest)]).first else {
                throw HTTPError(.notFound)
            }
            let definition = try Self.backupDecode(BackupAPI.Manifest.self, row["manifest_json"]!.string!)
            let primary: Role = definition.kind == .video ? .video : .photo
            let name = Storage.sanitized(definition.resources.first(where: { $0.role == primary })!.filename)
            let stem = String((name as NSString).deletingPathExtension.prefix(60))
            var month = "undated"
            if let date = Timestamp.date(row["capture_date"]?.string) {
                let parts = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(secondsFromGMT: 0)!, from: date)
                month = String(format: "%04d/%02d", parts.year ?? 0, parts.month ?? 0)
            }
            return folder + "/" + month + "/" + (stem.isEmpty ? "Item" : stem) + "." + manifest
        }
    }

    func backupVersion(_ request: String, principal: String) throws -> BackupAPI.Version {
        let row = try backupRequestRow(request, principal: principal)
        let manifest = row["manifest_id"]!.string!
        guard let version = try database.query("SELECT asset_id, generation FROM backup_manifests WHERE id = ?", [.text(manifest)]).first else {
            throw HTTPError(.notFound)
        }
        return .init(origin: try backupOriginRead(), assetID: version["asset_id"]!.string!, manifestID: manifest,
                     descriptorGeneration: Int64(version["generation"]!.int!), recipeID: row["recipe_id"]!.string!)
    }

    func backupOriginRead() throws -> BackupAPI.Origin {
        guard let server = try setting("backup.server_id"), let epoch = try setting("backup.history_epoch") else {
            throw HTTPError(.serviceUnavailable, message: "The backup history identity has not been initialized.")
        }
        return .init(serverID: server, historyEpoch: epoch)
    }

    func backupRequestRow(_ request: String, principal: String) throws -> Row {
        guard let row = try database.query("SELECT * FROM backup_requests WHERE id = ? AND principal = ?",
                                            [.text(request), .text(principal)]).first else { throw HTTPError(.notFound) }
        return row
    }

    func backupReceipt(_ id: String, principal: String) throws -> BackupAPI.Receipt {
        let row = try backupRequestRow(id, principal: principal), version = try backupVersion(id, principal: principal)
        let objects = try backupObjects(version.manifestID)
        let complete = !objects.isEmpty && objects.allSatisfy { $0.path != nil }
        let external = row["source"]?.string == "external"
        let policy = try database.query("SELECT policy FROM backup_claims WHERE request_id = ?", [.text(id)]).first?["policy"]?.string
        var derivative: BackupAPI.Derivative?
        if let generation = row["derivative_id"]?.string, row["wants_compact"]?.int == 1 {
            derivative = try backupDerivative(generation, principal: principal)
        }
        let originals: [ServerAPI.ResourceStatus] = objects.map {
            .init(role: $0.role, sha256: $0.sha256, size: $0.size, state: $0.path == nil ? .missing : .verified,
                  receivedBytes: $0.path == nil ? 0 : $0.size, verifiedAt: nil)
        }
        return .init(requestID: UUID(uuidString: id)!, operationID: UUID(uuidString: row["operation_id"]!.string!)!,
                     version: version, revision: Int64(row["revision"]?.int ?? 0),
                     backup: external ? .blocked : complete ? .retained : .uploading,
                     compact: BackupAPI.CompactState(rawValue: row["compact_state"]?.string ?? "") ?? .requested,
                     retention: external ? .external : complete ? (policy == "permanent" ? .permanent : .deferred) : .pending,
                     originals: originals, derivative: derivative,
                     message: external ? "Immich is external storage. Versioned acquisition and permanent-local proof are unsupported."
                        : row["message"]?.string ?? (row["wants_compact"]?.int == 0 ? "Compact processing was not requested." : nil))
    }

    func findBackup(operation: UUID, principal: String) throws -> BackupAPI.Receipt {
        guard let id = try database.query("SELECT id FROM backup_requests WHERE principal = ? AND operation_id = ?",
                                          [.text(principal), .text(operation.uuidString.lowercased())]).first?["id"]?.string else {
            throw HTTPError(.notFound)
        }
        return try backupReceipt(id, principal: principal)
    }

    func requireBackupVersion(_ version: BackupAPI.Version, request: String, principal: String) throws {
        guard version.origin == (try backupOriginRead()) else {
            throw APIError(.conflict, code: BackupAPI.ErrorCode.historyChanged, message: "The server history changed; reconcile a snapshot.")
        }
        guard try backupVersion(request, principal: principal) == version else {
            throw APIError(.conflict, code: BackupAPI.ErrorCode.versionChanged, message: "The immutable resource version does not match this request.")
        }
    }

    func queueBackupIfComplete(_ manifest: String) throws {
        let objects = try backupObjects(manifest)
        guard !objects.isEmpty, objects.allSatisfy({ $0.path != nil }) else { return }
        let kind = try database.query("SELECT manifest_json, generation FROM backup_manifests WHERE id = ?", [.text(manifest)]).first!
        let definition = try Self.backupDecode(BackupAPI.Manifest.self, kind["manifest_json"]!.string!)
        #if os(macOS)
        let lane = definition.kind == .photo ? "photo" : "video"
        #else
        let lane = definition.kind == .video ? "video" : "photo"
        #endif
        for request in try database.query("""
            SELECT * FROM backup_requests WHERE manifest_id = ? AND source = 'files'
              AND wants_compact = 1 AND paused = 0 AND cancelled = 0
            """, [.text(manifest)]) {
            let recipe = request["recipe_id"]!.string!
            if let ready = try database.query("""
                SELECT id FROM backup_derivatives WHERE manifest_id = ? AND recipe_id = ? ORDER BY created_at DESC LIMIT 1
                """, [.text(manifest), .text(recipe)]).first?["id"]?.string {
                try database.execute("UPDATE backup_requests SET derivative_id = ?, compact_state = 'ready', message = NULL WHERE id = ?",
                                     [.text(ready), .text(request["id"]!.string!)])
                continue
            }
            try database.execute("""
                INSERT INTO backup_jobs(id, manifest_id, recipe_id, recipe_json, generation, lane, principal,
                    status, available_at, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, 'queued', ?, ?)
                ON CONFLICT(manifest_id, recipe_id) DO UPDATE SET status = 'queued', available_at = excluded.available_at,
                    owner = NULL, expires_at = NULL, fence = backup_jobs.fence + 1, attempts = 0
                WHERE backup_jobs.status IN ('failed', 'cancelled')
                """, [.text(UUID().uuidString.lowercased()), .text(manifest), .text(recipe), .text(request["recipe_json"]!.string!),
                       .integer(Int64(kind["generation"]!.int!)), .text(lane), .text(request["principal"]!.string!),
                       .text(Timestamp.string()), .text(Timestamp.string())])
            try database.execute("""
                UPDATE backup_requests SET compact_state = COALESCE(
                    (SELECT CASE status WHEN 'leased' THEN 'processing' WHEN 'succeeded' THEN 'held'
                        WHEN 'failed' THEN 'failed' ELSE 'queued' END FROM backup_jobs WHERE manifest_id = ? AND recipe_id = ?),
                    'queued') WHERE id = ?
                """, [.text(manifest), .text(recipe), .text(request["id"]!.string!)])
        }
    }

    func refreshBackupRequests(_ manifest: String, force: Set<String> = []) throws {
        for row in try database.query("SELECT id, principal FROM backup_requests WHERE manifest_id = ?", [.text(manifest)]) {
            let id = row["id"]!.string!, principal = row["principal"]!.string!
            let candidate = try Self.backupJSON(backupReceipt(id, principal: principal))
            let previous = try database.query("SELECT receipt_json FROM backup_requests WHERE id = ?", [.text(id)]).first?["receipt_json"]?.string
            guard candidate != previous || force.contains(id) else { continue }
            try database.execute("UPDATE backup_requests SET revision = revision + 1 WHERE id = ? AND revision < 9223372036854775807", [.text(id)])
            guard database.changes == 1 else { throw HTTPError(.serviceUnavailable, message: "The receipt revision cannot advance safely.") }
            let json = try Self.backupJSON(backupReceipt(id, principal: principal))
            try database.execute("UPDATE backup_requests SET receipt_json = ? WHERE id = ?", [.text(json), .text(id)])
            try database.execute("INSERT INTO result_changes(principal, request_id, receipt_json, created_at) VALUES (?, ?, ?, ?)",
                                 [.text(principal), .text(id), .text(json), .text(Timestamp.string())])
            let sequence = try backupHighWater()
            try database.execute("""
                INSERT INTO backup_wake_outbox(principal, sequence, updated_at) VALUES (?, ?, ?)
                ON CONFLICT(principal) DO UPDATE SET sequence = excluded.sequence, updated_at = excluded.updated_at
                """, [.text(principal), .integer(sequence), .text(Timestamp.string())])
        }
    }

    func createBackupUpload(_ upload: BackupAPI.UploadRequest, principal: String, staging: URL? = nil,
                            originalRoot: URL? = nil, maximumStaging: Int64 = 64 << 30,
                            minimumFree: Int64 = 1 << 30) throws -> BackupUpload {
        let id = upload.uploadID.uuidString.lowercased(), request = upload.requestID.uuidString.lowercased()
        try requireBackupVersion(upload.version, request: request, principal: principal)
        let row = try backupRequestRow(request, principal: principal)
        guard row["source"]?.string == "files", row["paused"]?.int == 0, row["cancelled"]?.int == 0 else {
            throw HTTPError(.conflict, message: "This request is external, paused or cancelled; no upload was admitted.")
        }
        guard try backupObjects(upload.version.manifestID).contains(where: { $0.role == upload.role }) else { throw HTTPError(.notFound) }
        return try database.transaction {
            if let existing = try database.query("SELECT principal, request_id, version_json, role FROM backup_uploads WHERE id = ?", [.text(id)]).first {
                guard existing["principal"]?.string == principal else { throw HTTPError(.notFound) }
                guard existing["request_id"]?.string == request, existing["role"]?.string == upload.role.rawValue,
                      existing["version_json"]?.string == (try Self.backupJSON(upload.version)) else { throw Self.backupConflict() }
            } else {
                let size = Int64(try backupObjects(upload.version.manifestID).first(where: { $0.role == upload.role })!.size)
                guard size <= maximumStaging else {
                    throw APIError(.serviceUnavailable, code: "storage_backpressure", message: "This resource exceeds the configured staging limit.")
                }
                let open = try database.query("""
                    SELECT o.size, o.manifest_id, o.role, o.stored_path, u.offset FROM backup_uploads u JOIN backup_objects o
                      ON o.manifest_id = u.manifest_id AND o.role = u.role WHERE u.state = 'open'
                    """)
                let reserved = try StorageBytes.sum(open.map { $0["size"]!.int! })
                guard open.count < 128 else { throw HTTPError(.tooManyRequests, message: "Too many active upload records; finish or cancel a transfer first.") }
                guard reserved <= maximumStaging - size else {
                    throw APIError(.serviceUnavailable, code: "storage_backpressure", message: "Upload capacity is reserved by other transfers; retry later.")
                }
                var stageFuture = size, originalFuture: Int64 = 0, pendingObjects = Set<String>()
                for existing in open {
                    let length = Int64(existing["size"]!.int!), offset = Int64(existing["offset"]!.int!)
                    guard offset >= 0, offset <= length else { throw HTTPError(.serviceUnavailable) }
                    stageFuture = try StorageBytes.add(stageFuture, length - offset)
                    let key = existing["manifest_id"]!.string! + "/" + existing["role"]!.string!
                    if existing["stored_path"]?.string == nil, pendingObjects.insert(key).inserted {
                        originalFuture = try StorageBytes.add(originalFuture, length)
                    }
                }
                let objectKey = upload.version.manifestID + "/" + upload.role.rawValue
                if try backupObjects(upload.version.manifestID).first(where: { $0.role == upload.role })?.path == nil,
                   pendingObjects.insert(objectKey).inserted {
                    originalFuture = try StorageBytes.add(originalFuture, size)
                }
                let stageDisk = staging.flatMap { OriginalsStore.device(of: $0.path) }
                let originalDisk = originalRoot.flatMap { OriginalsStore.device(of: $0.path) }
                let sameDisk = stageDisk == nil || originalDisk == nil || stageDisk == originalDisk
                let sharedFuture = try StorageBytes.add(stageFuture, originalFuture)
                for (root, future) in [(staging, sameDisk ? sharedFuture : stageFuture),
                                       (originalRoot, sameDisk ? sharedFuture : originalFuture)] {
                    guard let root else { continue }
                    guard let free = OriginalsStore.space(at: root.path).free, free >= minimumFree,
                          future <= free - minimumFree else {
                        throw APIError(.serviceUnavailable, code: "storage_backpressure", message: "Insufficient known storage capacity; originals were not removed.")
                    }
                }
                try database.execute("""
                    INSERT INTO backup_uploads(id, request_id, principal, manifest_id, role, version_json, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, [.text(id), .text(request), .text(principal), .text(upload.version.manifestID), .text(upload.role.rawValue),
                           .text(try Self.backupJSON(upload.version)), .text(Timestamp.string())])
            }
            return try backupUpload(id, principal: principal)
        }
    }

    func backupUpload(_ id: String, principal: String, recovering: Bool = false) throws -> BackupUpload {
        guard let row = try database.query("SELECT * FROM backup_uploads WHERE id = ? AND principal = ?",
                                            [.text(id), .text(principal)]).first,
              let role = Role(rawValue: row["role"]?.string ?? ""),
              let object = try backupObjects(row["manifest_id"]!.string!).first(where: { $0.role == role }) else { throw HTTPError(.notFound) }
        let version: BackupAPI.Version
        if recovering { version = try backupVersion(row["request_id"]!.string!, principal: principal) }
        else { version = try Self.backupDecode(BackupAPI.Version.self, row["version_json"]!.string!) }
        if !recovering { try requireBackupVersion(version, request: row["request_id"]!.string!, principal: principal) }
        return .init(id: id, request: row["request_id"]!.string!, principal: principal, version: version, object: object,
                     offset: Int64(row["offset"]?.int ?? 0), state: row["state"]!.string!)
    }

    func advanceBackupUpload(_ upload: BackupUpload, to offset: Int64) throws {
        guard offset >= upload.offset, offset <= Int64(upload.object.size), upload.offset >= 0 else {
            throw APIError(.conflict, code: BackupAPI.ErrorCode.versionChanged, message: "The upload offset exceeds this immutable resource.")
        }
        let request = try backupRequestRow(upload.request, principal: upload.principal)
        guard request["paused"]?.int == 0, request["cancelled"]?.int == 0 else {
            throw APIError(.conflict, code: BackupAPI.ErrorCode.versionChanged, message: "The request was paused or cancelled.")
        }
        try database.execute("UPDATE backup_uploads SET offset = ? WHERE id = ? AND offset = ? AND state = 'open'",
                             [.integer(offset), .text(upload.id), .integer(upload.offset)])
        guard database.changes == 1 else { throw Self.backupConflict() }
    }

    func completeBackupUpload(_ upload: BackupUpload, path: String) throws -> BackupAPI.Receipt {
        try database.transaction {
            try requireBackupVersion(upload.version, request: upload.request, principal: upload.principal)
            try database.execute("""
                UPDATE backup_objects SET stored_path = ?, verified_at = ?
                WHERE manifest_id = ? AND role = ? AND sha256 = ? AND size = ? AND stored_path IS NULL
                  AND EXISTS(SELECT 1 FROM backup_manifests WHERE id = ? AND generation = ?)
                """, [.text(path), .text(Timestamp.string()), .text(upload.object.manifest), .text(upload.object.role.rawValue),
                       .text(upload.object.sha256), .integer(Int64(upload.object.size)), .text(upload.object.manifest),
                       .integer(upload.version.descriptorGeneration)])
            let published = database.changes == 1
            if !published {
                guard try backupObjects(upload.object.manifest).first(where: { $0.role == upload.object.role })?.path == path else {
                    throw APIError(.conflict, code: BackupAPI.ErrorCode.versionChanged, message: "Publication no longer owns this immutable object.")
                }
            }
            try database.execute("UPDATE backup_uploads SET state = 'verified', offset = ? WHERE id = ?",
                                 [.integer(Int64(upload.object.size)), .text(upload.id)])
            try database.execute("DELETE FROM backup_publications WHERE upload_id = ?", [.text(upload.id)])
            if published {
                try database.execute("""
                    UPDATE backup_requests SET message = NULL WHERE manifest_id = ? AND source = 'files'
                      AND message LIKE 'An upload failed SHA-256%' AND paused = 0 AND cancelled = 0
                    """, [.text(upload.object.manifest)])
                try queueBackupIfComplete(upload.object.manifest)
                try refreshBackupRequests(upload.object.manifest)
            }
            return try backupReceipt(upload.request, principal: upload.principal)
        }
    }

    func commandBackup(_ id: String, principal: String, command: BackupAPI.Command) throws -> BackupAPI.Receipt {
        try requireBackupVersion(command.version, request: id, principal: principal)
        let operation = command.operationID.uuidString.lowercased()
        let hash = try Self.backupIntentHash(command)
        return try database.transaction {
            if let old = try database.query("SELECT * FROM backup_commands WHERE principal = ? AND operation_id = ?",
                                            [.text(principal), .text(operation)]).first {
                guard old["request_id"]?.string == id, old["payload_hash"]?.string == hash else { throw Self.backupConflict() }
                return try backupReceipt(id, principal: principal)
            }
            let row = try backupRequestRow(id, principal: principal)
            guard row["source"]?.string == "files" else {
                throw HTTPError(.unprocessableContent, message: "Versioned Immich processing is unsupported.")
            }
            try database.execute("INSERT INTO backup_commands(principal, operation_id, request_id, payload_hash) VALUES (?, ?, ?, ?)",
                                 [.text(principal), .text(operation), .text(id), .text(hash)])
            switch command.action {
            case .pause: try database.execute("""
                UPDATE backup_requests SET paused = 1, compact_state = CASE WHEN derivative_id IS NULL THEN 'requested' ELSE compact_state END,
                    message = 'Paused; admitted work may finish.' WHERE id = ?
                """, [.text(id)])
            case .cancel:
                try database.execute("""
                    UPDATE backup_requests SET cancelled = 1, compact_state = CASE WHEN derivative_id IS NULL THEN 'requested' ELSE compact_state END,
                        message = 'Cancelled; original retention is unchanged.' WHERE id = ?
                    """, [.text(id)])
                try database.execute("UPDATE backup_uploads SET state = 'cancelled' WHERE request_id = ? AND state = 'open'", [.text(id)])
            case .retry: try database.execute("UPDATE backup_requests SET paused = 0, cancelled = 0, message = NULL WHERE id = ?", [.text(id)])
            case .compactNow:
                try database.execute("UPDATE backup_requests SET wants_compact = 1, paused = 0, cancelled = 0, message = NULL WHERE id = ?", [.text(id)])
            }
            let manifest = row["manifest_id"]!.string!, recipe = row["recipe_id"]!.string!
            if try database.query("""
                SELECT id FROM backup_requests WHERE manifest_id = ? AND recipe_id = ?
                  AND wants_compact = 1 AND paused = 0 AND cancelled = 0 AND source = 'files' LIMIT 1
                """, [.text(manifest), .text(recipe)]).isEmpty {
                try database.execute("""
                    UPDATE backup_jobs SET status = 'cancelled', fence = fence + 1, owner = NULL, expires_at = NULL
                    WHERE manifest_id = ? AND recipe_id = ? AND status IN ('queued', 'leased', 'retry_wait')
                    """, [.text(manifest), .text(recipe)])
            }
            try queueBackupIfComplete(manifest)
            try refreshBackupRequests(manifest, force: [id])
            return try backupReceipt(id, principal: principal)
        }
    }

    func backupHighWater() throws -> Int64 {
        Int64(try database.query("SELECT COALESCE(MAX(sequence), 0) AS n FROM result_changes").first?["n"]?.int ?? 0)
    }

    func backupChanges(principal: String, after: Int64, epoch: String, limit: Int) throws -> BackupAPI.Changes {
        let limit = max(1, min(200, limit))
        return try database.transaction {
            let origin = try backupOriginRead(), high = try backupHighWater()
            guard epoch == origin.historyEpoch else {
                throw APIError(.conflict, code: BackupAPI.ErrorCode.historyChanged, message: "The history epoch changed; request a snapshot.")
            }
            guard after >= 0, after <= high else {
                throw APIError(.conflict, code: BackupAPI.ErrorCode.snapshotRequired, message: "That cursor is not in this history; request a snapshot.")
            }
            let rows = try database.query("""
                SELECT sequence, receipt_json FROM result_changes WHERE principal = ? AND sequence > ? ORDER BY sequence LIMIT ?
                """, [.text(principal), .integer(after), .integer(Int64(limit + 1))])
            let page = Array(rows.prefix(limit))
            let changes = try page.map { BackupAPI.Change(sequence: Int64($0["sequence"]!.int!),
                receipt: try Self.backupDecode(BackupAPI.Receipt.self, $0["receipt_json"]!.string!)) }
            return .init(origin: origin, cursor: rows.count > limit ? changes.last!.sequence : high,
                         hasMore: rows.count > limit, changes: changes)
        }
    }

    func backupSnapshot(principal: String, continuation: String?, limit: Int) throws -> BackupAPI.Snapshot {
        let limit = max(1, min(200, limit))
        return try database.transaction {
            try database.execute("DELETE FROM backup_snapshots WHERE expires_at < ?", [.text(Timestamp.string())])
            let origin = try backupOriginRead(), snapshot: String, offset: Int
            if let continuation {
                guard let row = try database.query("""
                    SELECT p.snapshot_id, p.position FROM backup_snapshot_pages p JOIN backup_snapshots s ON s.id = p.snapshot_id
                    WHERE p.token_hash = ? AND p.principal = ? AND s.epoch = ?
                    """, [.text(Pairing.hash(continuation)), .text(principal), .text(origin.historyEpoch)]).first else {
                    throw APIError(.conflict, code: BackupAPI.ErrorCode.snapshotRequired, message: "The snapshot expired or does not belong to this device.")
                }
                snapshot = row["snapshot_id"]!.string!
                offset = row["position"]!.int!
            } else {
                snapshot = UUID().uuidString.lowercased()
                offset = 0
                try database.execute("INSERT INTO backup_snapshots(id, principal, epoch, cursor, expires_at) VALUES (?, ?, ?, ?, ?)",
                                     [.text(snapshot), .text(principal), .text(origin.historyEpoch), .integer(try backupHighWater()),
                                      .text(Timestamp.string(Date().addingTimeInterval(3600)))])
            }
            let cursor = try database.query("SELECT cursor FROM backup_snapshots WHERE id = ?", [.text(snapshot)]).first!["cursor"]!.int!
            let rows = try database.query("""
                SELECT receipt_json FROM (
                    SELECT request_id, receipt_json, ROW_NUMBER() OVER (PARTITION BY request_id ORDER BY sequence DESC) AS version
                    FROM result_changes WHERE principal = ? AND sequence <= ?
                ) WHERE version = 1 ORDER BY request_id LIMIT ? OFFSET ?
                """, [.text(principal), .integer(Int64(cursor)), .integer(Int64(limit + 1)), .integer(Int64(offset))])
            var next: String?
            if rows.count > limit {
                let token = UUID().uuidString.lowercased() + "." + UUID().uuidString.lowercased()
                try database.execute("INSERT INTO backup_snapshot_pages(token_hash, snapshot_id, principal, position) VALUES (?, ?, ?, ?)",
                                     [.text(Pairing.hash(token)), .text(snapshot), .text(principal), .integer(Int64(offset + limit))])
                next = token
            }
            return .init(origin: origin, cursor: Int64(cursor),
                         receipts: try rows.prefix(limit).map { try Self.backupDecode(BackupAPI.Receipt.self, $0["receipt_json"]!.string!) },
                         continuation: next)
        }
    }

    func backupDerivative(_ id: String, principal: String) throws -> BackupAPI.Derivative {
        guard let row = try database.query("""
            SELECT d.*, r.id AS request_id FROM backup_derivatives d JOIN backup_requests r
              ON r.manifest_id = d.manifest_id AND r.recipe_id = d.recipe_id
            WHERE d.id = ? AND r.principal = ? LIMIT 1
            """, [.text(id), .text(principal)]).first else { throw HTTPError(.notFound) }
        return .init(generationID: UUID(uuidString: id)!, version: try backupVersion(row["request_id"]!.string!, principal: principal),
                     resources: try Self.backupDecode([ServerAPI.CompactResource].self, row["files_json"]!.string!),
                     deviceCompresses: try Self.backupDecode([Role].self, row["device_compresses_json"]!.string!))
    }

    func acknowledgeBackup(_ ack: BackupAPI.DeliveryAcknowledgement, principal: String) throws -> BackupAPI.Receipt {
        let id = ack.deliveryID.uuidString.lowercased(), request = ack.requestID.uuidString.lowercased()
        try requireBackupVersion(ack.version, request: request, principal: principal)
        let derivative = try backupDerivative(ack.generationID.uuidString.lowercased(), principal: principal)
        guard derivative.version == ack.version else {
            throw APIError(.conflict, code: BackupAPI.ErrorCode.versionChanged, message: "The delivered generation does not match this request.")
        }
        let hash = try Self.backupIntentHash(ack)
        return try database.transaction {
            if let old = try database.query("SELECT principal, payload_hash FROM backup_delivery_acks WHERE id = ?", [.text(id)]).first {
                guard old["principal"]?.string == principal else { throw HTTPError(.notFound) }
                guard old["payload_hash"]?.string == hash else { throw Self.backupConflict() }
            } else {
                try database.execute("""
                    INSERT INTO backup_delivery_acks(id, principal, request_id, generation_id, payload_hash, created_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """, [.text(id), .text(principal), .text(request), .text(ack.generationID.uuidString.lowercased()),
                           .text(hash), .text(Timestamp.string())])
                try refreshBackupRequests(ack.version.manifestID, force: [request])
            }
            // Accounting only: deliberately no UPDATE/DELETE of backup_claims or originals.
            return try backupReceipt(request, principal: principal)
        }
    }

    func backupProofClaim(asset: String, manifest: String, version: BackupAPI.Version, principal: String) throws -> UUID {
        guard version.assetID == asset, version.manifestID == manifest else {
            throw APIError(.conflict, code: BackupAPI.ErrorCode.versionChanged, message: "The verification URL and expected version differ.")
        }
        guard let row = try database.query("""
            SELECT r.id, c.id AS claim_id FROM backup_requests r JOIN backup_claims c ON c.request_id = r.id
            WHERE r.principal = ? AND r.manifest_id = ? AND r.recipe_id = ? AND r.source = 'files' AND c.policy = 'permanent'
            LIMIT 1
            """, [.text(principal), .text(manifest), .text(version.recipeID)]).first else {
            throw HTTPError(.conflict, message: "This device has no permanent local retention claim for that exact version.")
        }
        try requireBackupVersion(version, request: row["id"]!.string!, principal: principal)
        let resources = try backupObjects(manifest)
        guard !resources.isEmpty, resources.allSatisfy({ $0.path != nil && $0.size > 0 }) else {
            throw HTTPError(.conflict, message: "The original resource set is incomplete.")
        }
        return UUID(uuidString: row["claim_id"]!.string!)!
    }

    /// Opaque durable wake hints; an optional relay must acknowledge the exact sequence.
    func pendingBackupWakes(limit: Int = 100) throws -> [(principal: String, sequence: Int64)] {
        try database.query("SELECT principal, sequence FROM backup_wake_outbox ORDER BY sequence LIMIT ?", [.integer(Int64(limit))])
            .map { ($0["principal"]!.string!, Int64($0["sequence"]!.int!)) }
    }

    func acknowledgeBackupWake(principal: String, sequence: Int64) throws {
        try database.execute("DELETE FROM backup_wake_outbox WHERE principal = ? AND sequence = ?", [.text(principal), .integer(sequence)])
    }

    /// Explicit catalog-restore boundary. A silent replacement within one epoch cannot be
    /// detected reliably; stop serving and rotate the epoch after restoring a catalog.
    func rotateBackupHistory() throws -> BackupAPI.Origin {
        _ = try backupOrigin()
        return try database.transaction {
            try setSetting("backup.history_epoch", UUID().uuidString.lowercased())
            try database.execute("DELETE FROM backup_snapshots")
            try database.execute("DELETE FROM result_changes")
            try database.execute("DELETE FROM backup_wake_outbox")
            for row in try database.query("SELECT DISTINCT manifest_id FROM backup_requests") {
                try refreshBackupRequests(row["manifest_id"]!.string!)
            }
            return try backupOriginRead()
        }
    }

    func prepareBackupPublication(_ upload: BackupUpload, path: String) throws {
        try database.execute("""
            INSERT INTO backup_publications(upload_id, manifest_id, role, relative_path) VALUES (?, ?, ?, ?)
            ON CONFLICT(upload_id) DO NOTHING
            """, [.text(upload.id), .text(upload.object.manifest), .text(upload.object.role.rawValue), .text(path)])
        guard try backupPublicationPath(upload.id) == path else { throw Self.backupConflict() }
    }

    func backupPublicationPath(_ upload: String) throws -> String? {
        try database.query("SELECT relative_path FROM backup_publications WHERE upload_id = ?", [.text(upload)]).first?["relative_path"]?.string
    }

    func pendingBackupPublications() throws -> [BackupUpload] {
        try database.query("""
            SELECT u.id, u.principal FROM backup_publications p JOIN backup_uploads u ON u.id = p.upload_id
            """).map { try backupUpload($0["id"]!.string!, principal: $0["principal"]!.string!, recovering: true) }
    }

    func rejectBackupUpload(_ upload: BackupUpload) throws {
        try database.transaction {
            try database.execute("UPDATE backup_uploads SET state = 'mismatch' WHERE id = ? AND state = 'open'", [.text(upload.id)])
            try database.execute("""
                UPDATE backup_requests SET message = 'An upload failed SHA-256 verification; retry with a new upload identifier.'
                WHERE id = ? AND cancelled = 0
                """, [.text(upload.request)])
            try refreshBackupRequests(upload.object.manifest)
        }
    }

    func backupStagingCleanup() throws -> [String] {
        try database.query("""
            SELECT u.id FROM backup_uploads u WHERE u.state IN ('verified', 'cancelled', 'mismatch') AND u.cleaned = 0
              AND NOT EXISTS(SELECT 1 FROM backup_publications p WHERE p.upload_id = u.id)
            ORDER BY u.created_at LIMIT 50
            """).map { $0["id"]!.string! }
    }

    func backupStagingCleaned(_ id: String) throws {
        try database.execute("UPDATE backup_uploads SET cleaned = 1 WHERE id = ? AND state != 'open'", [.text(id)])
    }

    func hasBackupPublications() throws -> Bool {
        !(try database.query("SELECT upload_id FROM backup_publications LIMIT 1").isEmpty)
    }

    func legacyBackupSource(manifest: String, role: Role) throws -> BackupLegacySource? {
        guard let object = try backupObjects(manifest).first(where: { $0.role == role }) else { return nil }
        let rows = try database.query("""
            SELECT asset_id, stored_path, external_path FROM (
                SELECT r.asset_id, r.stored_path, r.external_path, CASE WHEN a.permanent = 1 THEN 0 ELSE 2 END AS priority
                FROM resources r JOIN assets a ON a.id = r.asset_id
                WHERE r.sha256 = ? AND r.size = ? AND r.role = ? AND r.state = 'verified'
                  AND (r.stored_path IS NOT NULL OR r.external_path IS NOT NULL)
                UNION ALL
                SELECT asset_id, stored_path, external_path, 1 AS priority FROM resource_history
                WHERE sha256 = ? AND size = ? AND role = ? AND (stored_path IS NOT NULL OR external_path IS NOT NULL)
            ) ORDER BY priority, asset_id LIMIT 1
            """, [.text(object.sha256), .integer(Int64(object.size)), .text(role.rawValue),
                   .text(object.sha256), .integer(Int64(object.size)), .text(role.rawValue)])
        guard let row = rows.first else { return nil }
        return .init(asset: row["asset_id"]!.string!, stored: row["stored_path"]?.string, external: row["external_path"]?.string)
    }

    func nextBackupAdoption(lane: String? = nil) throws -> BackupAdoptionCandidate? {
        #if os(macOS)
        let photoCondition = "m.kind = 'photo'"
        #else
        let photoCondition = "m.kind != 'video'"
        #endif
        for row in try database.query("""
            SELECT r.id, r.principal, o.manifest_id, o.role FROM backup_objects o
            JOIN backup_requests r ON r.manifest_id = o.manifest_id
            JOIN backup_manifests m ON m.id = o.manifest_id
            LEFT JOIN backup_adoption_wait w ON w.manifest_id = o.manifest_id AND w.role = o.role
            WHERE o.stored_path IS NULL AND r.source = 'files' AND r.paused = 0 AND r.cancelled = 0
              AND (? IS NULL OR (CASE WHEN \(photoCondition) THEN 'photo' ELSE 'video' END) = ?)
              AND (w.available_at IS NULL OR w.available_at <= ?)
              AND (EXISTS(SELECT 1 FROM resources v WHERE v.sha256 = o.sha256 AND v.size = o.size AND v.role = o.role
                    AND v.state = 'verified' AND (v.stored_path IS NOT NULL OR v.external_path IS NOT NULL))
                OR EXISTS(SELECT 1 FROM resource_history h WHERE h.sha256 = o.sha256 AND h.size = o.size AND h.role = o.role
                    AND (h.stored_path IS NOT NULL OR h.external_path IS NOT NULL)))
              AND NOT EXISTS(SELECT 1 FROM backup_publications p WHERE p.manifest_id = o.manifest_id AND p.role = o.role)
            ORDER BY r.created_at, r.id LIMIT 200
            """, [lane.sqlValue, lane.sqlValue, .text(Timestamp.string())]) {
            let manifest = row["manifest_id"]!.string!, role = Role(rawValue: row["role"]!.string!)!
            if let source = try legacyBackupSource(manifest: manifest, role: role) {
                return .init(request: row["id"]!.string!, principal: row["principal"]!.string!,
                             manifest: manifest, role: role, sourceAsset: source.asset)
            }
        }
        return nil
    }

    func postponeBackupAdoption(_ candidate: BackupAdoptionCandidate) throws {
        try database.execute("""
            INSERT INTO backup_adoption_wait(manifest_id, role, available_at) VALUES (?, ?, ?)
            ON CONFLICT(manifest_id, role) DO UPDATE SET available_at = excluded.available_at
            """, [.text(candidate.manifest), .text(candidate.role.rawValue),
                   .text(Timestamp.string(Date().addingTimeInterval(60)))])
    }

    func abandonInternalUpload(_ id: String) throws {
        try database.execute("UPDATE backup_uploads SET state = 'cancelled' WHERE id = ? AND state = 'open'", [.text(id)])
    }

    func retainBackupAdoptionSource(_ candidate: BackupAdoptionCandidate) throws {
        guard !(try database.query("""
            SELECT c.id FROM backup_claims c JOIN backup_requests r ON r.id = c.request_id
            WHERE c.manifest_id = ? AND c.policy = 'permanent' AND r.source = 'files' LIMIT 1
            """, [.text(candidate.manifest)]).isEmpty) else { return }
        try database.execute("UPDATE assets SET permanent = 1 WHERE id = ? AND purging = 0", [.text(candidate.sourceAsset)])
    }
}
