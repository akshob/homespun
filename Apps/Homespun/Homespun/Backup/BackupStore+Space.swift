// SPDX-License-Identifier: Apache-2.0
import Foundation

struct BackupSpacePolicy: Equatable, Sendable {
    var maximumTransientBytes: Int64
    var minimumAvailableBytes: Int64
    var finalizationReserveBytes: Int64
    var maximumTransfers: Int
}

struct BackupSpaceObservation: Sendable {
    var availableBytes: Int64?
    var transientBytes: Int64
}

enum BackupSpaceFailure: Error, LocalizedError, Equatable {
    case invalidPolicy
    case capacityUnavailable
    case workingSpaceRequired
    case transferLimit

    var errorDescription: String? {
        switch self {
        case .invalidPolicy: "The backup workspace limits are invalid."
        case .capacityUnavailable: "Available working space could not be checked. Try again when storage is available."
        case .workingSpaceRequired: "More working space is needed. Free some space or adjust the workspace limit; other items can continue."
        case .transferLimit: "Other transfers are using the available transfer slots."
        }
    }
}

extension BackupStore {
    struct Reservation: Codable, Equatable, Sendable {
        var id: UUID
        var operationID: UUID
        var epoch: Int64
        var stage: Stage
        var futureBytes: Int64
        var systemCopyBytes: Int64
        var taskSlots: Int
        var transferID: UUID?
    }

    /// Existing files affect the spool cap, not reported free space a second time.
    func reserveSpace(_ reservation: Reservation, policy: BackupSpacePolicy,
                      observation: BackupSpaceObservation? = nil) throws {
        guard policy.maximumTransientBytes > 0, policy.minimumAvailableBytes >= 0,
              policy.finalizationReserveBytes >= 0, (1...128).contains(policy.maximumTransfers),
              reservation.futureBytes >= 0, reservation.systemCopyBytes >= 0,
              reservation.taskSlots >= 0, reservation.taskSlots <= policy.maximumTransfers else {
            throw BackupSpaceFailure.invalidPolicy
        }
        try mutateState { connection in
            guard let operation = try Self.operation(reservation.operationID, connection),
                  operation.epoch == reservation.epoch, operation.desired == .active else { throw Failure.staleOperation }
            let observation = try observation ?? files.spaceObservation()
            guard let available = observation.availableBytes, available >= 0, observation.transientBytes >= 0 else {
                throw BackupSpaceFailure.capacityUnavailable
            }
            let existing = try connection.rows("SELECT body FROM reservations WHERE id != ?", [.text(reservation.id.uuidString)])
                .map { try Self.decode(Reservation.self, $0.blob("body")) }
            let active = try connection.rows("SELECT id FROM transfers WHERE status NOT IN ('completed', 'failed')")
            let activeIDs = Set(try active.map { try $0.text("id") })
            let reservations = existing + [reservation]
            let future = try Self.spaceSum(reservations.map(\.futureBytes))
            let systemCopies = try Self.spaceSum(reservations.map(\.systemCopyBytes))
            let finalizationActive = reservation.stage == .finalization || existing.contains { $0.stage == .finalization }
            let headroom = finalizationActive ? 0 : policy.finalizationReserveBytes
            let needed = try Self.spaceSum([future, systemCopies, policy.minimumAvailableBytes, headroom])
            let transient = try Self.spaceSum([observation.transientBytes, future, systemCopies, headroom])
            guard needed <= available, transient <= policy.maximumTransientBytes else {
                throw BackupSpaceFailure.workingSpaceRequired
            }
            var slots = Int64(active.count)
            for entry in reservations where entry.transferID.map({ !activeIDs.contains($0.uuidString) }) ?? true {
                slots = try Self.spaceSum([slots, Int64(entry.taskSlots)])
            }
            guard slots <= Int64(policy.maximumTransfers) else { throw BackupSpaceFailure.transferLimit }
            if let old = try connection.rows("SELECT body FROM reservations WHERE id = ?", [.text(reservation.id.uuidString)]).first {
                let previous = try Self.decode(Reservation.self, old.blob("body"))
                guard previous.operationID == reservation.operationID, previous.epoch == reservation.epoch,
                      previous.stage == reservation.stage, previous.transferID == reservation.transferID else {
                    throw Failure.staleOperation
                }
            }
            try connection.execute("""
                INSERT INTO reservations (id, operation, stage, body) VALUES (?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET body = excluded.body
                """, [.text(reservation.id.uuidString), .text(reservation.operationID.uuidString),
                       .text(reservation.stage.rawValue), .blob(try Self.encode(reservation))])
        }
    }

    func releaseReservation(_ id: UUID) throws {
        try mutateState { connection in
            _ = try connection.execute("DELETE FROM reservations WHERE id = ?", [.text(id.uuidString)])
        }
    }

    func reservations(operationID: UUID? = nil) throws -> [Reservation] {
        try readState { connection in
            let rows = try connection.rows("SELECT body FROM reservations" + (operationID == nil ? "" : " WHERE operation = ?"),
                                           operationID.map { [.text($0.uuidString)] } ?? [])
            return try rows.map { try Self.decode(Reservation.self, $0.blob("body")) }
        }
    }

    private static func spaceSum(_ values: [Int64]) throws -> Int64 {
        var total: Int64 = 0
        for value in values {
            let (next, overflow) = total.addingReportingOverflow(value)
            guard value >= 0, !overflow else { throw BackupSpaceFailure.workingSpaceRequired }
            total = next
        }
        return total
    }
}
