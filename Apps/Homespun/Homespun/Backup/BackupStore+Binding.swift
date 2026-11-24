// SPDX-License-Identifier: Apache-2.0
import Foundation

extension BackupStore {
    /// Call only after authenticating the new address/key and looking up its authenticated consumer.
    func reattach(from oldID: UUID, to newID: UUID) throws {
        guard oldID != newID else { return }
        try mutateState { connection in
            guard let oldRow = try connection.rows("SELECT body FROM bindings WHERE id = ?", [.text(oldID.uuidString)]).first,
                  let newRow = try connection.rows("SELECT body FROM bindings WHERE id = ? AND retired = 0",
                                                   [.text(newID.uuidString)]).first else { throw Failure.retiredBinding }
            let old = try Self.decode(Binding.self, oldRow.blob("body"))
            let new = try Self.decode(Binding.self, newRow.blob("body"))
            guard old.origin == new.origin, old.mode == new.mode,
                  let consumer = old.consumerID, !consumer.isEmpty, consumer == new.consumerID else {
                throw Failure.invalidReceipt
            }
            for row in try connection.rows("SELECT body FROM operations WHERE binding = ?", [.text(oldID.uuidString)]) {
                var operation = try Self.decode(Operation.self, row.blob("body"))
                guard operation.epoch < Int64.max else { throw Failure.unsupportedSchema }
                operation.bindingID = newID
                operation.epoch += 1
                operation.lease = nil
                if operation.bindingPaused == true, operation.desired == .paused { operation.desired = .active }
                operation.bindingPaused = nil
                try Self.write(operation, connection)
            }
            for row in try connection.rows("SELECT body FROM outbox") {
                var item = try Self.decode(OutboxItem.self, row.blob("body"))
                guard item.bindingID == oldID else { continue }
                item.bindingID = newID
                try connection.execute("UPDATE outbox SET body = ? WHERE id = ?",
                                       [.blob(try Self.encode(item)), .text(item.id.uuidString)])
            }
        }
    }
}
