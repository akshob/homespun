// SPDX-License-Identifier: Apache-2.0
import Foundation
import HomespunCore

extension BackupStore {
    struct CommandEnvelope: Codable, Equatable, Sendable {
        var requestID: UUID
        var command: BackupAPI.Command
    }

    func runnable(_ stage: Stage, limit: Int = 200) throws -> [Operation] {
        guard (1...1_000).contains(limit) else { throw Failure.missingOperation }
        let predicate: String
        switch stage {
        case .preparation: predicate = "backup = 'selected'"
        case .upload: predicate = "backup IN ('uploading', 'verifying')"
        case .finalization:
            predicate = "json_extract(CAST(body AS TEXT), '$.compact') = 'ready' AND delivery != 'imported_verified'"
        }
        return try readState { connection in
            try connection.rows("""
                SELECT body FROM operations WHERE desired = 'active' AND \(predicate)
                AND json_extract(CAST(body AS TEXT), '$.lease') IS NULL
                AND coalesce(json_extract(CAST(body AS TEXT), '$.attention'), 0) = 0
                ORDER BY rowid LIMIT ?
                """, [.integer(Int64(limit))]).map { try Self.decode(Operation.self, $0.blob("body")) }
        }
    }

    func fail(_ lease: Lease, code: String, message: String, requiresAttention: Bool = true) throws {
        guard !code.isEmpty, code.utf8.count <= 80,
              code.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0) }) else {
            throw Failure.staleOperation
        }
        try mutateState { connection in
            var operation = try Self.checked(lease, connection)
            operation.problem = .init(code: code, message: message, stage: lease.stage)
            operation.attention = requiresAttention
            operation.lease = nil
            operation.updatedAt = Date()
            if lease.stage != .finalization, operation.backup != .retained {
                operation.backup = requiresAttention ? .blocked : .failed
            }
            try Self.write(operation, connection)
        }
    }

    func retry(_ id: UUID) throws {
        try mutateState { connection in
            guard var operation = try Self.operation(id, connection),
                  operation.epoch < Int64.max,
                  let lineage = try connection.rows("SELECT current_operation FROM lineages WHERE namespace = ? AND item = ?",
                                                   [.text(operation.namespace), .text(operation.itemID)]).first,
                  try lineage.text("current_operation") == id.uuidString else { throw Failure.staleOperation }
            operation.desired = .active
            operation.epoch += 1
            operation.lease = nil
            operation.attention = false
            operation.problem = nil
            operation.backup = operation.manifest == nil ? .selected : (operation.receipt?.backup ?? .uploading)
            operation.updatedAt = Date()
            try Self.write(operation, connection)
        }
    }

    func retireBinding(_ id: UUID) throws {
        try mutateState { connection in
            guard let row = try connection.rows("SELECT body FROM bindings WHERE id = ?", [.text(id.uuidString)]).first else {
                throw Failure.retiredBinding
            }
            var binding = try Self.decode(Binding.self, row.blob("body"))
            binding.retired = true
            try connection.execute("UPDATE bindings SET retired = 1, body = ? WHERE id = ?",
                                   [.blob(try Self.encode(binding)), .text(id.uuidString)])
            for row in try connection.rows("SELECT body FROM operations WHERE binding = ? AND desired = 'active'",
                                           [.text(id.uuidString)]) {
                var operation = try Self.decode(Operation.self, row.blob("body"))
                guard operation.epoch < Int64.max else { throw Failure.unsupportedSchema }
                operation.desired = .paused
                operation.epoch += 1
                operation.lease = nil
                operation.updatedAt = Date()
                try Self.write(operation, connection)
            }
            for row in try connection.rows("SELECT body FROM sessions WHERE binding = ?", [.text(id.uuidString)]) {
                var session = try Self.decode(TransferSession.self, row.blob("body"))
                session.draining = true
                try connection.execute("UPDATE sessions SET draining = 1, body = ? WHERE id = ?",
                                       [.blob(try Self.encode(session)), .text(session.id.uuidString)])
            }
        }
    }

    func importUncertain(_ id: UUID) throws {
        try mutateState { connection in
            guard let row = try connection.rows("SELECT body FROM imports WHERE id = ?", [.text(id.uuidString)]).first else {
                throw Failure.importNeedsReconciliation
            }
            var intent = try Self.decode(ImportIntent.self, row.blob("body"))
            guard intent.phase == .mutating || intent.phase == .uncertain else { return }
            intent.phase = .uncertain
            try connection.execute("UPDATE imports SET body = ? WHERE id = ?", [.blob(try Self.encode(intent)), .text(id.uuidString)])
            if var operation = try Self.operation(intent.operationID, connection) {
                operation.delivery = .uncertain
                operation.attention = true
                try Self.write(operation, connection)
            }
        }
    }

    func enqueueCommand(_ id: UUID, action: BackupAPI.CommandAction) throws -> UUID {
        try mutateState { connection in
            guard let operation = try Self.operation(id, connection), let receipt = operation.receipt else {
                throw Failure.missingOperation
            }
            let command = BackupAPI.Command(operationID: UUID(), version: receipt.version, action: action)
            let payload = try Self.encode(CommandEnvelope(requestID: receipt.requestID, command: command))
            let item = OutboxItem(id: command.operationID, operationID: id, bindingID: operation.bindingID,
                                  kind: .serverCommand, payload: payload)
            try connection.execute("INSERT INTO outbox (id, operation, body) VALUES (?, ?, ?)",
                                   [.text(item.id.uuidString), .text(id.uuidString), .blob(try Self.encode(item))])
            return item.id
        }
    }

    func retryOutbox(_ id: UUID, after date: Date) throws {
        try mutateState { connection in
            guard let row = try connection.rows("SELECT body FROM outbox WHERE id = ?", [.text(id.uuidString)]).first else { return }
            var item = try Self.decode(OutboxItem.self, row.blob("body"))
            guard item.attempts < Int.max else { throw Failure.unsupportedSchema }
            item.attempts += 1
            item.nextAttempt = date
            try connection.execute("UPDATE outbox SET body = ? WHERE id = ?", [.blob(try Self.encode(item)), .text(id.uuidString)])
        }
    }
}
