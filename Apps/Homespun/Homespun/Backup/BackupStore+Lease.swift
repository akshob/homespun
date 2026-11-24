// SPDX-License-Identifier: Apache-2.0
import Foundation

extension BackupStore {
    func deferLease(_ lease: Lease, until date: Date? = nil) throws {
        try mutateState { connection in
            var operation = try Self.checked(lease, connection)
            operation.lease = nil
            if lease.stage == .preparation, operation.backup == .preparing { operation.backup = .selected }
            operation.notBefore = date
            operation.updatedAt = Date()
            try Self.write(operation, connection)
            try connection.execute("DELETE FROM reservations WHERE operation = ? AND stage = ?",
                                   [.text(operation.id.uuidString), .text(lease.stage.rawValue)])
        }
    }
}
