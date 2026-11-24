// SPDX-License-Identifier: Apache-2.0
import Foundation
import HomespunCore

extension BackupStore {
    struct SnapshotRun: Codable, Equatable, Sendable {
        var id: UUID
        var bindingID: UUID
        var origin: BackupAPI.Origin
        var cursor: Int64?
        var continuation: String?
        var lastRequest: String?
        var lastPageHash: String?
    }

    struct SnapshotProgress: Equatable, Sendable {
        var continuation: String?
        var complete: Bool
    }

    func applyChanges(_ page: BackupAPI.Changes, bindingID: UUID) throws -> ReceiptApplication {
        guard page.changes.count <= 1_000 else { throw Failure.invalidReceipt }
        return try mutateState { connection in
            let binding = try Self.syncBinding(bindingID, connection)
            guard binding.origin == page.origin, page.cursor >= 0 else { throw Failure.invalidReceipt }
            let old = try connection.rows("SELECT cursor FROM cursors WHERE binding = ?", [.text(bindingID.uuidString)])
                .first?.integer("cursor") ?? 0
            if page.cursor < old { return .stale }
            if page.cursor == old {
                guard !page.hasMore else { throw Failure.invalidReceipt }
                return .stale
            }
            var previous = old
            for change in page.changes {
                guard change.sequence > previous, change.sequence <= page.cursor,
                      change.receipt.version.origin == page.origin else { throw Failure.invalidReceipt }
                previous = change.sequence
                try Self.syncReceipt(change.receipt, binding: binding, connection)
            }
            try Self.writeCursor(page.cursor, bindingID: bindingID, connection)
            return .applied
        }
    }

    func beginSnapshot(bindingID: UUID) throws -> UUID {
        try mutateState { connection in
            let binding = try Self.syncBinding(bindingID, connection)
            for row in try connection.rows("SELECT id FROM snapshot_runs WHERE binding = ?", [.text(bindingID.uuidString)]) {
                let id = try row.text("id")
                try connection.execute("DELETE FROM snapshot_receipts WHERE snapshot = ?", [.text(id)])
                try connection.execute("DELETE FROM snapshot_runs WHERE id = ?", [.text(id)])
            }
            let run = SnapshotRun(id: UUID(), bindingID: bindingID, origin: binding.origin)
            try Self.write(run, connection)
            return run.id
        }
    }

    func snapshotRun(bindingID: UUID) throws -> SnapshotRun? {
        try readState { connection in
            try connection.rows("SELECT body FROM snapshot_runs WHERE binding = ?", [.text(bindingID.uuidString)])
                .first.map { try Self.decode(SnapshotRun.self, $0.blob("body")) }
        }
    }

    /// A snapshot never exposes a partially replaced catalog or advances its cursor between pages.
    func applySnapshot(_ page: BackupAPI.Snapshot, runID: UUID, requestedContinuation: String?) throws -> SnapshotProgress {
        guard page.cursor >= 0, page.receipts.count <= 1_000 else { throw Failure.invalidReceipt }
        if let continuation = page.continuation {
            guard !continuation.isEmpty, continuation != requestedContinuation, continuation.utf8.count <= 4_096 else {
                throw Failure.invalidReceipt
            }
        }
        return try mutateState { connection in
            guard let row = try connection.rows("SELECT body FROM snapshot_runs WHERE id = ?", [.text(runID.uuidString)]).first else {
                throw Failure.invalidReceipt
            }
            var run = try Self.decode(SnapshotRun.self, row.blob("body"))
            let binding = try Self.syncBinding(run.bindingID, connection)
            guard run.origin == page.origin, binding.origin == page.origin else { throw Failure.invalidReceipt }
            let hash = Fingerprint.sha256(of: try Self.encode(page))
            if run.lastPageHash == hash, run.lastRequest == requestedContinuation {
                return .init(continuation: run.continuation, complete: false)
            }
            guard run.continuation == requestedContinuation, run.cursor == nil || run.cursor == page.cursor else {
                throw Failure.invalidReceipt
            }
            if run.cursor == nil {
                let old = try connection.rows("SELECT cursor FROM cursors WHERE binding = ?", [.text(binding.id.uuidString)])
                    .first?.integer("cursor") ?? 0
                guard page.cursor >= old else { throw Failure.invalidReceipt }
                run.cursor = page.cursor
            }
            for receipt in page.receipts {
                guard receipt.version.origin == page.origin, receipt.revision > 0 else { throw Failure.invalidReceipt }
                if let existing = try connection.rows("SELECT body FROM snapshot_receipts WHERE snapshot = ? AND request = ?",
                    [.text(runID.uuidString), .text(receipt.requestID.uuidString)]).first {
                    guard try Self.decode(BackupAPI.Receipt.self, existing.blob("body")) == receipt else {
                        throw Failure.conflictingReceipt
                    }
                } else {
                    try connection.execute("INSERT INTO snapshot_receipts (snapshot, request, body) VALUES (?, ?, ?)",
                                           [.text(runID.uuidString), .text(receipt.requestID.uuidString), .blob(try Self.encode(receipt))])
                }
            }
            run.lastRequest = requestedContinuation
            run.lastPageHash = hash
            run.continuation = page.continuation
            if page.continuation != nil {
                try Self.write(run, connection)
                return .init(continuation: page.continuation, complete: false)
            }
            for row in try connection.rows("SELECT body FROM snapshot_receipts WHERE snapshot = ? ORDER BY rowid",
                                           [.text(runID.uuidString)]) {
                try Self.syncReceipt(Self.decode(BackupAPI.Receipt.self, row.blob("body")), binding: binding, connection)
            }
            let current = try connection.rows("SELECT cursor FROM cursors WHERE binding = ?", [.text(binding.id.uuidString)])
                .first?.integer("cursor") ?? 0
            try Self.writeCursor(max(current, page.cursor), bindingID: binding.id, connection)
            try connection.execute("DELETE FROM snapshot_receipts WHERE snapshot = ?", [.text(runID.uuidString)])
            try connection.execute("DELETE FROM snapshot_runs WHERE id = ?", [.text(runID.uuidString)])
            return .init(continuation: nil, complete: true)
        }
    }

    func orphanReceipts(bindingID: UUID) throws -> [BackupAPI.Receipt] {
        try readState { connection in
            try connection.rows("SELECT body FROM orphan_receipts WHERE binding = ?", [.text(bindingID.uuidString)]).map {
                try Self.decode(BackupAPI.Receipt.self, $0.blob("body"))
            }
        }
    }

    private static func syncBinding(_ id: UUID, _ connection: BackupDatabase.Connection) throws -> Binding {
        guard let row = try connection.rows("SELECT body FROM bindings WHERE id = ?", [.text(id.uuidString)]).first else {
            throw Failure.retiredBinding
        }
        return try decode(Binding.self, row.blob("body"))
    }

    private static func syncReceipt(_ receipt: BackupAPI.Receipt, binding: Binding,
                                    _ connection: BackupDatabase.Connection) throws {
        guard receipt.version.origin == binding.origin, receipt.revision > 0 else { throw Failure.invalidReceipt }
        if let operation = try operation(receipt.operationID, connection) {
            let oldBinding = try syncBinding(operation.bindingID, connection)
            let sameConsumer = oldBinding.consumerID?.isEmpty == false && oldBinding.consumerID == binding.consumerID
            if operation.bindingID == binding.id || (operation.origin == binding.origin && sameConsumer) {
                _ = try apply(receipt, operationID: operation.id, epoch: operation.epoch, connection)
                return
            }
        }
        if let row = try connection.rows("SELECT body FROM orphan_receipts WHERE binding = ? AND request = ?",
                                         [.text(binding.id.uuidString), .text(receipt.requestID.uuidString)]).first {
            let old = try decode(BackupAPI.Receipt.self, row.blob("body"))
            guard old.version == receipt.version, old.operationID == receipt.operationID else { throw Failure.conflictingReceipt }
            if receipt.revision < old.revision { return }
            if receipt.revision == old.revision {
                guard receipt == old else { throw Failure.conflictingReceipt }
                return
            }
        }
        try connection.execute("""
            INSERT INTO orphan_receipts (binding, request, body) VALUES (?, ?, ?)
            ON CONFLICT(binding, request) DO UPDATE SET body = excluded.body
            """, [.text(binding.id.uuidString), .text(receipt.requestID.uuidString), .blob(try encode(receipt))])
    }

    private static func writeCursor(_ cursor: Int64, bindingID: UUID, _ connection: BackupDatabase.Connection) throws {
        try connection.execute("""
            INSERT INTO cursors (binding, cursor) VALUES (?, ?)
            ON CONFLICT(binding) DO UPDATE SET cursor = excluded.cursor
            """, [.text(bindingID.uuidString), .integer(cursor)])
    }

    private static func write(_ run: SnapshotRun, _ connection: BackupDatabase.Connection) throws {
        try connection.execute("""
            INSERT INTO snapshot_runs (id, binding, body) VALUES (?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET body = excluded.body
            """, [.text(run.id.uuidString), .text(run.bindingID.uuidString), .blob(try encode(run))])
    }
}
