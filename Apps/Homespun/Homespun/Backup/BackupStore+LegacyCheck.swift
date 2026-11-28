// SPDX-License-Identifier: Apache-2.0
import Foundation
import HomespunCore

extension BackupStore {
    func discardLegacyChecks(origin: BackupAPI.Origin) throws {
        try mutateState { connection in
            _ = try connection.execute("DELETE FROM legacy_checks WHERE origin = ?", [.blob(try Self.encode(origin))])
        }
    }

    func discardLegacyChecks(exceptScope: String? = nil) throws {
        try mutateState { connection in
            if let exceptScope {
                _ = try connection.execute("DELETE FROM legacy_checks WHERE scope != ?", [.text(exceptScope)])
            } else {
                _ = try connection.execute("DELETE FROM legacy_checks")
            }
        }
    }

    func recordLegacyChecks(_ records: [LegacyCheck.Record], scope: String, namespace: String,
                            current: @MainActor @Sendable () -> Bool = { true },
                            authorized: @Sendable () -> Bool = { true }) async throws {
        guard await current() else { throw CancellationError() }
        try Task.checkCancellation()
        guard authorized() else { throw CancellationError() }
        try mutateState { connection in
            try Task.checkCancellation()
            guard authorized() else { throw CancellationError() }
            for record in records {
                let candidate = record.candidate
                guard record.scope == scope else { throw Failure.invalidReceipt }
                // A mapping may have been replaced or adopted while the lookup was in flight.
                if let compact = candidate.compact {
                    guard let row = try connection.rows("""
                        SELECT m.body FROM mappings m JOIN lineages l ON l.current_mapping = m.id
                        WHERE l.namespace = ? AND l.item = ?
                        """, [.text(namespace), .text(candidate.item)]).first else { continue }
                    let mapping = try Self.decode(SavedMapping.self, row.blob("body"))
                    guard mapping.origin == nil, mapping.entry.serverAssetID?.lowercased() == candidate.asset,
                          mapping.entry.originalBytes == candidate.bytes, mapping.entry.compactIdentifier == compact else { continue }
                } else {
                    guard let row = try connection.rows("SELECT body FROM legacy_backed_up WHERE namespace = ? AND original = ?",
                                                       [.text(namespace), .text(candidate.item)]).first else { continue }
                    let entry = try Self.decode(CompactLedger.BackedUp.self, row.blob("body"))
                    guard entry.origin == nil, entry.serverAssetID.lowercased() == candidate.asset,
                          entry.originalBytes == candidate.bytes else { continue }
                }
                try connection.execute("""
                    INSERT INTO legacy_checks(namespace,item,scope,origin,asset,verified,bytes,role,compact,checked_at)
                    VALUES(?,?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(namespace,item) DO UPDATE SET scope=excluded.scope,origin=excluded.origin,
                    asset=excluded.asset,verified=excluded.verified,bytes=excluded.bytes,role=excluded.role,
                    compact=excluded.compact,checked_at=excluded.checked_at
                    """, [.text(namespace), .text(candidate.item), .text(scope),
                           try record.origin.map { .blob(try Self.encode($0)) } ?? .null,
                           .text(candidate.asset), .integer(record.verified ? 1 : 0),
                           .integer(Int64(candidate.bytes)), .text(candidate.role.rawValue),
                           candidate.compact.map { .text($0) } ?? .null, .real(record.checkedAt.timeIntervalSinceReferenceDate)])
            }
        }
    }

    static func legacyChecks(namespace: String, _ connection: BackupDatabase.Connection) throws -> [String: LegacyCheck.Record] {
        var records: [String: LegacyCheck.Record] = [:]
        for row in try connection.rows("""
            SELECT * FROM legacy_checks WHERE namespace = ?
            """, [.text(namespace)]) {
            guard let role = ServerAPI.ResourceRole(rawValue: try row.text("role")),
                  case .real(let checkedAt)? = row.values["checked_at"] else { continue }
            let item = try row.text("item")
            let compact: String? = if case .text(let value)? = row.values["compact"] { value } else { nil }
            let origin: BackupAPI.Origin? = if case .blob(let data)? = row.values["origin"] {
                try Self.decode(BackupAPI.Origin.self, data)
            } else { nil }
            records[item] = .init(candidate: .init(item: item, asset: try row.text("asset"),
                bytes: Int(try row.integer("bytes")), role: role, compact: compact), scope: try row.text("scope"),
                origin: origin,
                verified: try row.integer("verified") == 1,
                checkedAt: Date(timeIntervalSinceReferenceDate: checkedAt))
        }
        return records
    }
}
