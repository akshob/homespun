// SPDX-License-Identifier: Apache-2.0
import Foundation
import HomespunCore

extension BackupStore {
    struct LedgerProjection: Sendable {
        var entries: [String: CompactLedger.Entry]
        var backedUp: [String: CompactLedger.BackedUp]
        var kept: Set<String>
        var pendingImports: Set<String>
        var legacyChecks: [String: LegacyCheck.Record] = [:]

        /// Filter at use time, not cache-build time: a cached projection must still expire.
        func legacyConfirmed(scope: String, origin: BackupAPI.Origin?, now: Date = Date()) -> [String: LegacyCheck.Record] {
            legacyChecks.filter {
                $0.value.verified && $0.value.isCurrent(scope: scope, origin: origin, now: now) && $0.value.candidate.matches(self)
            }
        }
    }

    struct ProjectionRevision: Equatable, Sendable {
        var local: Int64
        var external: Int64
    }

    func projectionRevision() throws -> ProjectionRevision {
        try readState { connection in
            .init(local: try connection.rows("SELECT total_changes() AS changes").first!.integer("changes"),
                  external: try connection.rows("PRAGMA data_version").first!.integer("data_version"))
        }
    }

    func keptDecisions(namespace: String) throws -> Set<String> {
        try readState { connection in
            try Set(connection.rows("SELECT item FROM decisions WHERE namespace = ? AND kept = 1", [.text(namespace)])
                .map { try $0.text("item") })
        }
    }

    func automaticExclusions(namespace: String) throws -> Set<String> {
        try readState { connection in
            let rows = try connection.rows("""
                SELECT o.body FROM operations o JOIN lineages l ON l.current_operation = o.id
                WHERE l.namespace = ?
                """, [.text(namespace)])
            return try Set(rows.compactMap { row -> String? in
                let operation = try Self.decode(Operation.self, row.blob("body"))
                return operation.wantsCompact || operation.backup != .retained || operation.desired != .active || operation.attention
                    ? operation.itemID : nil
            })
        }
    }

    func needsResultDiscovery(bindingID: UUID, namespace: String) throws -> Bool {
        try readState { connection in
            try !connection.rows("""
                SELECT 1 FROM operations o JOIN lineages l ON l.current_operation = o.id
                JOIN bindings b ON b.id = o.binding
                WHERE l.namespace = ? AND o.binding = ? AND b.retired = 0 AND o.desired = 'active'
                AND coalesce(json_extract(CAST(o.body AS TEXT),'$.attention'),0) = 0
                AND (o.backup NOT IN ('retained','blocked','failed')
                     OR (coalesce(json_extract(CAST(o.body AS TEXT),'$.wantsCompact'),0) = 1
                         AND json_extract(CAST(o.body AS TEXT),'$.compact') NOT IN ('held','failed')
                         AND o.delivery != 'imported_verified'))
                UNION ALL
                SELECT 1 FROM outbox x JOIN operations o ON o.id = x.operation
                JOIN bindings b ON b.id = o.binding
                WHERE o.namespace = ? AND json_extract(CAST(x.body AS TEXT),'$.bindingID') = ? AND b.retired = 0
                LIMIT 1
                """, [.text(namespace), .text(bindingID.uuidString), .text(namespace), .text(bindingID.uuidString)]).isEmpty
        }
    }

    struct BindingInformation: Codable, Equatable, Sendable {
        var capabilities: BackupAPI.Capabilities
        var name: String
        var namespace: String
    }

    struct AdmissionInformation: Codable, Equatable, Sendable {
        var manual: Bool
        var trigger: RunHistory.Trigger
    }

    struct OperationPage: Sendable {
        var operations: [Operation]
        var cursor: Int64
        var hasMore: Bool
    }

    func releasePreviewTransfer(_ id: UUID) throws {
        try mutateState { connection in
            let key = "preview-transfer:" + id.uuidString
            guard try Self.metadata(key, as: Bool.self, connection) == true,
                  let row = try connection.rows("SELECT body FROM transfers WHERE id = ?", [.text(id.uuidString)]).first else { return }
            let transfer = try Self.decode(Transfer.self, row.blob("body"))
            guard transfer.kind == .originalDownload, let resourceID = transfer.capturedResourceID else { return }
            try connection.execute("DELETE FROM file_refs WHERE resource = ? AND owner = ?",
                                   [.text(resourceID.uuidString), .text("operation:" + transfer.operationID.uuidString)])
            try Self.saveMetadata(key, value: false, connection)
        }
    }

    func deviceRunnable(_ stage: Stage, binding: Binding, namespace: String, limit: Int = 200) throws -> [Operation] {
        guard (1...1_000).contains(limit) else { throw Failure.missingOperation }
        let predicate: String
        switch stage {
        case .preparation: predicate = "o.backup = 'selected'"
        case .finalization:
            predicate = "json_extract(CAST(o.body AS TEXT),'$.compact') = 'ready' AND o.delivery != 'imported_verified'"
        case .upload:
            let unfinished = binding.mode == .immich ? "0" : """
                EXISTS (
                    SELECT 1 FROM json_each(json_extract(CAST(o.body AS TEXT),'$.manifest.resources')) expected
                    WHERE NOT EXISTS (
                        SELECT 1 FROM json_each(json_extract(CAST(o.body AS TEXT),'$.receipt.originals')) actual
                        WHERE json_extract(actual.value,'$.role') = json_extract(expected.value,'$.role')
                        AND json_extract(actual.value,'$.state') = 'verified'
                        AND json_extract(actual.value,'$.size') = json_extract(expected.value,'$.size')
                        AND lower(json_extract(actual.value,'$.sha256')) = lower(json_extract(expected.value,'$.sha256'))
                    )
                )
                """
            predicate = """
                o.backup IN ('uploading','verifying') AND
                (json_extract(CAST(o.body AS TEXT),'$.receipt') IS NULL OR (\(unfinished)))
                """
        }
        return try readState { connection in
            try connection.rows("""
                SELECT o.body FROM operations o
                JOIN lineages l ON l.current_operation = o.id
                JOIN bindings b ON b.id = o.binding
                WHERE l.namespace = ? AND o.binding = ? AND b.retired = 0 AND o.desired = 'active'
                AND \(predicate) AND json_extract(CAST(o.body AS TEXT),'$.lease') IS NULL
                AND coalesce(json_extract(CAST(o.body AS TEXT),'$.attention'),0) = 0
                AND (json_extract(CAST(o.body AS TEXT),'$.notBefore') IS NULL
                     OR json_extract(CAST(o.body AS TEXT),'$.notBefore') <= ?)
                ORDER BY o.rowid LIMIT ?
                """, [.text(namespace), .text(binding.id.uuidString), .real(Date().timeIntervalSinceReferenceDate),
                       .integer(Int64(limit))]).map { try Self.decode(Operation.self, $0.blob("body")) }
        }
    }

    func operationPage(namespace: String, after cursor: Int64 = 0, limit: Int = 200) throws -> OperationPage {
        guard cursor >= 0, (1...1_000).contains(limit) else { throw Failure.missingOperation }
        return try readState { connection in
            let rows = try connection.rows("""
                SELECT o.rowid AS position,o.body FROM operations o
                JOIN lineages l ON l.current_operation = o.id
                WHERE l.namespace = ? AND o.rowid > ? ORDER BY o.rowid LIMIT ?
                """, [.text(namespace), .integer(cursor), .integer(Int64(limit + 1))])
            let page = Array(rows.prefix(limit))
            return .init(operations: try page.map { try Self.decode(Operation.self, $0.blob("body")) },
                         cursor: try page.last?.integer("position") ?? cursor, hasMore: rows.count > page.count)
        }
    }

    func currentOperations(_ ids: [String], namespace: String) throws -> [Operation] {
        try readState { connection in
            var result: [Operation] = []
            for start in stride(from: 0, to: ids.count, by: 200) {
                let chunk = Array(ids[start..<min(start + 200, ids.count)])
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                result += try connection.rows("""
                    SELECT o.body FROM operations o JOIN lineages l ON l.current_operation = o.id
                    WHERE l.namespace = ? AND l.item IN (\(placeholders))
                    """, [.text(namespace)] + chunk.map { .text($0) }).map { try Self.decode(Operation.self, $0.blob("body")) }
            }
            return result
        }
    }

    func setKeptDecision(_ ids: [String], namespace: String, kept: Bool) throws {
        try mutateState { connection in
            for id in ids {
                try connection.execute("""
                    INSERT INTO decisions(namespace,item,kept) VALUES(?,?,?)
                    ON CONFLICT(namespace,item) DO UPDATE SET kept = excluded.kept
                    """, [.text(namespace), .text(id), .integer(kept ? 1 : 0)])
                if kept {
                    for row in try connection.rows("SELECT body FROM operations WHERE namespace = ? AND item = ?",
                                                   [.text(namespace), .text(id)]) {
                        var operation = try Self.decode(Operation.self, row.blob("body"))
                        guard operation.epoch < Int64.max else { throw Failure.staleOperation }
                        operation.epoch += 1
                        operation.desired = .paused
                        operation.lease = nil
                        operation.attention = false
                        operation.problem = nil
                        operation.bindingPaused = nil
                        try Self.write(operation, connection)
                    }
                }
            }
        }
    }

    func bindings() throws -> [Binding] {
        try readState { connection in
            try connection.rows("SELECT body FROM bindings ORDER BY rowid").map {
                try Self.decode(Binding.self, $0.blob("body"))
            }
        }
    }

    func rememberBinding(_ bindingID: UUID, information: BindingInformation) throws {
        guard try binding(bindingID)?.origin == information.capabilities.origin else { throw Failure.retiredBinding }
        try saveMetadata("binding:" + bindingID.uuidString, value: information, immutable: true)
    }

    func bindingInformation(_ bindingID: UUID) throws -> BindingInformation? {
        try metadata("binding:" + bindingID.uuidString, as: BindingInformation.self)
    }

    func rememberAdmission(_ batch: Batch, trigger: RunHistory.Trigger) throws {
        try mutateState { connection in
            for id in batch.operationIDs {
                let key = "admission:" + id.uuidString
                var information = AdmissionInformation(manual: trigger != .automatic, trigger: trigger)
                if let previous = try Self.metadata(key, as: AdmissionInformation.self, connection), previous.manual {
                    information = previous
                }
                try Self.saveMetadata(key, value: information, connection)
            }
        }
    }

    func admissionInformation(_ id: UUID) throws -> AdmissionInformation? {
        try metadata("admission:" + id.uuidString, as: AdmissionInformation.self)
    }

    func ledgerProjection(namespace: String) throws -> LedgerProjection {
        try readState { connection in
            var entries: [String: CompactLedger.Entry] = [:]
            var information: [UUID: BindingInformation] = [:]
            for row in try connection.rows("""
                SELECT m.body,o.id AS operation_id,o.binding AS binding_id,
                json_extract(CAST(o.body AS TEXT),'$.receipt.requestId') AS request_id
                FROM mappings m JOIN lineages l ON l.current_mapping = m.id
                LEFT JOIN imports i ON i.id = m.intent
                LEFT JOIN operations o ON o.id = coalesce(i.operation, json_extract(CAST(m.body AS TEXT),'$.entry.operationID'))
                WHERE l.namespace = ?
                """, [.text(namespace)]) {
                let mapping = try Self.decode(SavedMapping.self, row.blob("body"))
                var entry = mapping.entry
                entry.origin = mapping.origin
                entry.version = mapping.proof?.version
                entry.retention = mapping.proof?.retention
                entry.compactResources = mapping.compactResources
                if case .text(let operation)? = row.values["operation_id"],
                   case .text(let binding)? = row.values["binding_id"],
                   let bindingID = UUID(uuidString: binding) {
                    entry.operationID = UUID(uuidString: operation)
                    entry.bindingID = bindingID
                    if case .text(let request)? = row.values["request_id"] { entry.requestID = UUID(uuidString: request) }
                    if information[bindingID] == nil {
                        information[bindingID] = try Self.metadata("binding:" + binding, as: BindingInformation.self, connection)
                    }
                    entry.serverName = information[bindingID]?.name
                    entry.externalVerification = information[bindingID]?.capabilities.externalVerification
                }
                entries[mapping.originalID] = entry
            }
            var backed: [String: CompactLedger.BackedUp] = [:]
            for row in try connection.rows("SELECT original, body FROM legacy_backed_up WHERE namespace = ?", [.text(namespace)]) {
                backed[try row.text("original")] = try Self.decode(CompactLedger.BackedUp.self, row.blob("body"))
            }
            for row in try connection.rows("""
                SELECT o.body FROM operations o JOIN lineages l ON l.current_operation = o.id
                WHERE l.namespace = ? AND o.backup = 'retained' AND l.current_mapping IS NULL
                """, [.text(namespace)]) {
                let operation = try Self.decode(Operation.self, row.blob("body"))
                guard let receipt = operation.receipt, let manifest = operation.manifest else { continue }
                backed[operation.itemID] = .init(serverAssetID: receipt.version.assetID,
                    originalBytes: manifest.resources.reduce(0) { $0 + $1.size }, backedUpAt: operation.updatedAt,
                    kept: try !connection.rows("SELECT 1 FROM decisions WHERE namespace = ? AND item = ? AND kept = 1",
                                               [.text(namespace), .text(operation.itemID)]).isEmpty,
                    origin: operation.origin, version: receipt.version, requestID: receipt.requestID,
                    bindingID: operation.bindingID, operationID: operation.id)
            }
            for key in entries.keys { backed[key] = nil }
            let kept = try Set(connection.rows("SELECT item FROM decisions WHERE namespace = ? AND kept = 1",
                                                [.text(namespace)]).map { try $0.text("item") })
            var pendingImports = Set<String>()
            for row in try connection.rows("""
                SELECT i.body AS intent, o.body AS operation FROM imports i
                JOIN operations o ON o.id = i.operation
                JOIN lineages l ON l.current_operation = o.id
                JOIN bindings b ON b.id = o.binding
                WHERE l.namespace = ? AND o.desired = 'active' AND b.retired = 0
                AND json_extract(CAST(i.body AS TEXT),'$.phase') = 'created'
                AND json_extract(CAST(o.body AS TEXT),'$.lease.stage') = 'finalization'
                """, [.text(namespace)]) {
                let intent = try Self.decode(ImportIntent.self, row.blob("intent"))
                let operation = try Self.decode(Operation.self, row.blob("operation"))
                guard !operation.attention, operation.lease?.epoch == operation.epoch,
                      intent.operationEpoch == operation.epoch, let identifier = intent.createdIdentifier else { continue }
                pendingImports.insert(identifier)
            }
            return LedgerProjection(entries: entries, backedUp: backed, kept: kept, pendingImports: pendingImports,
                                    legacyChecks: try Self.legacyChecks(namespace: namespace, connection))
        }
    }

    /// Old clients/finders can preserve records but cannot manufacture origin or complete-import proof.
    func recordLegacy(_ records: [String: CompactLedger.Entry], removing: [String], namespace: String) throws {
        try mutateState { connection in
            for id in Set(removing).union(records.keys) {
                try connection.execute("DELETE FROM legacy_checks WHERE namespace = ? AND item = ?",
                                       [.text(namespace), .text(id)])
                if let row = try connection.rows("""
                    SELECT m.body FROM mappings m JOIN lineages l ON l.current_mapping = m.id
                    WHERE l.namespace = ? AND l.item = ?
                    """, [.text(namespace), .text(id)]).first {
                    guard try Self.decode(SavedMapping.self, row.blob("body")).origin == nil else { throw Failure.staleOperation }
                }
            }
            for id in removing {
                try connection.execute("UPDATE lineages SET current_mapping = NULL WHERE namespace = ? AND item = ?",
                                       [.text(namespace), .text(id)])
            }
            for (original, supplied) in records {
                var entry = supplied
                entry.origin = nil; entry.version = nil; entry.requestID = nil; entry.bindingID = nil
                entry.operationID = nil; entry.compactResources = nil; entry.retention = nil
                let mapping = SavedMapping(id: UUID(), namespace: namespace, originalID: original, entry: entry)
                try Self.insertMapping(mapping, connection)
                try connection.execute("""
                    INSERT INTO lineages(namespace,item,generation,current_mapping) VALUES(?,?,0,?)
                    ON CONFLICT(namespace,item) DO UPDATE SET current_mapping = excluded.current_mapping
                    """, [.text(namespace), .text(original), .text(mapping.id.uuidString)])
                try connection.execute("DELETE FROM legacy_backed_up WHERE namespace = ? AND original = ?",
                                       [.text(namespace), .text(original)])
            }
        }
    }

    func recordLegacyBackedUp(_ records: [String: CompactLedger.BackedUp], namespace: String,
                             removingMappings: [String] = []) throws {
        try mutateState { connection in
            for id in Set(removingMappings).union(records.keys) {
                try connection.execute("DELETE FROM legacy_checks WHERE namespace = ? AND item = ?",
                                       [.text(namespace), .text(id)])
            }
            for original in removingMappings {
                if let row = try connection.rows("""
                    SELECT m.body FROM mappings m JOIN lineages l ON l.current_mapping = m.id
                    WHERE l.namespace = ? AND l.item = ?
                    """, [.text(namespace), .text(original)]).first {
                    guard try Self.decode(SavedMapping.self, row.blob("body")).origin == nil else { throw Failure.staleOperation }
                }
                try connection.execute("UPDATE lineages SET current_mapping = NULL WHERE namespace = ? AND item = ?",
                                       [.text(namespace), .text(original)])
            }
            for (original, entry) in records {
                guard entry.origin == nil else { throw Failure.invalidReceipt }
                try connection.execute("""
                    INSERT INTO legacy_backed_up(namespace,original,body) VALUES(?,?,?)
                    ON CONFLICT(namespace,original) DO UPDATE SET body = excluded.body
                    """, [.text(namespace), .text(original), .blob(try Self.encode(entry))])
            }
        }
    }

    func forgetLegacyBackedUp(_ ids: [String], namespace: String) throws {
        try mutateState { connection in
            for id in ids {
                try connection.execute("DELETE FROM legacy_checks WHERE namespace = ? AND item = ?",
                                       [.text(namespace), .text(id)])
                try connection.execute("DELETE FROM legacy_backed_up WHERE namespace = ? AND original = ?",
                                       [.text(namespace), .text(id)])
            }
        }
    }

    static func insertMapping(_ mapping: SavedMapping, _ connection: BackupDatabase.Connection) throws {
        try connection.execute("INSERT INTO mappings(id,namespace,original,intent,body) VALUES(?,?,?,?,?)",
                               [.text(mapping.id.uuidString), .text(mapping.namespace), .text(mapping.originalID),
                                mapping.intentID.map { .text($0.uuidString) } ?? .null, .blob(try encode(mapping))])
    }

    func metadata<Value: Decodable & Sendable>(_ key: String, as type: Value.Type) throws -> Value? {
        try readState { try Self.metadata(key, as: type, $0) }
    }

    func saveMetadata<Value: Codable & Sendable>(_ key: String, value: Value, immutable: Bool = false) throws {
        try mutateState { connection in
            if immutable, let row = try connection.rows("SELECT value FROM meta WHERE key = ?", [.text(key)]).first {
                guard try row.blob("value") == Self.encode(value) else { throw Failure.staleOperation }
                return
            }
            try Self.saveMetadata(key, value: value, connection)
        }
    }

    static func metadata<Value: Decodable>(_ key: String, as type: Value.Type,
                                          _ connection: BackupDatabase.Connection) throws -> Value? {
        try connection.rows("SELECT value FROM meta WHERE key = ?", [.text(key)]).first.map {
            try decode(type, $0.blob("value"))
        }
    }

    static func saveMetadata<Value: Encodable>(_ key: String, value: Value,
                                              _ connection: BackupDatabase.Connection) throws {
        try connection.execute("""
            INSERT INTO meta(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """, [.text(key), .blob(try encode(value))])
    }
}
