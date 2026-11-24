// SPDX-License-Identifier: Apache-2.0
import Foundation
import HomespunCore

extension BackupStore {
    static func isCurrent(_ operation: Operation, _ connection: BackupDatabase.Connection) throws -> Bool {
        guard let row = try connection.rows("""
            SELECT current_operation, generation FROM lineages WHERE namespace = ? AND item = ?
            """, [.text(operation.namespace), .text(operation.itemID)]).first else { return false }
        return row.values["current_operation"] == .text(operation.id.uuidString)
            && row.values["generation"] == .integer(operation.lineage)
    }

    static func bindingUsable(_ operation: Operation, _ connection: BackupDatabase.Connection) throws -> Bool {
        try !connection.rows("SELECT id FROM bindings WHERE id = ? AND retired = 0",
                             [.text(operation.bindingID.uuidString)]).isEmpty
    }

    static func supersedeCurrent(namespace: String, item: String, _ connection: BackupDatabase.Connection) throws {
        guard let row = try connection.rows("SELECT current_operation FROM lineages WHERE namespace = ? AND item = ?",
                                            [.text(namespace), .text(item)]).first else { return }
        if row.values["current_operation"] == .null { return }
        guard let id = UUID(uuidString: try row.text("current_operation")),
              var operation = try operation(id, connection), operation.epoch < Int64.max else { throw Failure.unsupportedSchema }
        operation.epoch += 1
        operation.lease = nil
        operation.bindingPaused = nil
        if operation.desired == .active { operation.desired = .paused }
        operation.updatedAt = Date()
        try write(operation, connection)
    }

    @discardableResult
    static func ensureCompactPromotion(_ operation: inout Operation, _ connection: BackupDatabase.Connection) throws -> Bool {
        guard operation.desired == .active, operation.wantsCompact, operation.request?.compact == false,
              operation.promotionCommandID == nil, let receipt = operation.receipt,
              try isCurrent(operation, connection), try bindingUsable(operation, connection) else { return false }
        for row in try connection.rows("SELECT body FROM outbox WHERE operation = ? ORDER BY rowid",
                                       [.text(operation.id.uuidString)]) {
            let item = try decode(OutboxItem.self, row.blob("body"))
            guard item.kind == .serverCommand else { continue }
            let envelope = try decode(CommandEnvelope.self, item.payload)
            if envelope.command.action == .compactNow, envelope.requestID == receipt.requestID,
               envelope.command.version == receipt.version {
                operation.promotionCommandID = item.id
                operation.updatedAt = Date()
                return true
            }
        }
        let command = BackupAPI.Command(operationID: UUID(), version: receipt.version, action: .compactNow)
        let envelope = CommandEnvelope(requestID: receipt.requestID, command: command)
        try enqueue(.init(id: command.operationID, operationID: operation.id, bindingID: operation.bindingID,
                          kind: .serverCommand, payload: encode(envelope)), connection)
        operation.promotionCommandID = command.operationID
        operation.updatedAt = Date()
        return true
    }

    static func releaseReservations(_ lease: Lease, _ connection: BackupDatabase.Connection) throws {
        try connection.execute("""
            DELETE FROM reservations WHERE operation = ? AND stage = ?
            AND json_extract(CAST(body AS TEXT), '$.epoch') = ?
            """, [.text(lease.operationID.uuidString), .text(lease.stage.rawValue), .integer(lease.epoch)])
    }
}
