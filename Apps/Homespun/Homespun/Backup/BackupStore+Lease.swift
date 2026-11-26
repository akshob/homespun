// SPDX-License-Identifier: Apache-2.0
import Foundation

extension BackupStore {
    func deferLease(_ lease: Lease, until date: Date? = nil) throws {
        try mutateState { connection in
            guard var existing = try Self.operation(lease.operationID, connection) else { throw Failure.missingOperation }
            let current = try Self.isCurrent(existing, connection)
            let usable = try Self.bindingUsable(existing, connection)
            if existing.lease != lease || existing.epoch != lease.epoch || existing.desired != .active || !current || !usable {
                try Self.releaseReservations(lease, connection)
                if existing.lease == lease {
                    existing.lease = nil
                    if existing.desired == .active { existing.desired = .paused }
                    try Self.write(existing, connection)
                }
                return
            }
            var operation = try Self.checked(lease, connection)
            operation.lease = nil
            if lease.stage == .preparation, operation.backup == .preparing { operation.backup = .selected }
            operation.notBefore = date
            operation.updatedAt = Date()
            try Self.write(operation, connection)
            try Self.releaseReservations(lease, connection)
        }
    }
}
