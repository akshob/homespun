// SPDX-License-Identifier: Apache-2.0
import Foundation
import HomespunCore

extension BackupStore {
    struct TransferSession: Codable, Equatable, Sendable {
        var id: UUID
        var bindingID: UUID
        var identifier: String
        var installationID: UUID
        var background = false
        var draining = false
        var lastEnumeratedAt: Date?
    }

    struct Transfer: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable { case upload, download, originalDownload }
        enum State: String, Codable, Sendable {
            case intent, suspended, running, unknown, captured, completed, failed, cancelling
            var terminal: Bool { self == .completed || self == .failed }
        }
        var id: UUID
        var operationID: UUID
        var epoch: Int64
        var sessionID: UUID
        var kind: Kind
        var version: BackupAPI.Version
        var expected: ServerAPI.ResourceDescriptor
        var resourceID: UUID?
        var uploadID: UUID?
        var generationID: UUID?
        var capturedResourceID: UUID?
        var taskID: Int?
        var state: State = .intent
    }

    func registerSession(_ session: TransferSession) throws {
        guard !session.background, !session.identifier.isEmpty, session.identifier.utf8.count <= 200,
              session.identifier.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw Failure.nativeTransferUnavailable
        }
        try mutateState { connection in
            guard try !connection.rows("SELECT id FROM bindings WHERE id = ? AND retired = 0",
                                       [.text(session.bindingID.uuidString)]).isEmpty else { throw Failure.retiredBinding }
            if let row = try connection.rows("SELECT body FROM sessions WHERE id = ?", [.text(session.id.uuidString)]).first {
                let old = try Self.decode(TransferSession.self, row.blob("body"))
                guard old.bindingID == session.bindingID, old.identifier == session.identifier,
                      old.installationID == session.installationID, old.background == session.background else {
                    throw Failure.invalidReceipt
                }
                return
            }
            try connection.execute("INSERT INTO sessions (id, binding, identifier, draining, body) VALUES (?, ?, ?, ?, ?)",
                                   [.text(session.id.uuidString), .text(session.bindingID.uuidString), .text(session.identifier),
                                    .integer(session.draining ? 1 : 0), .blob(try Self.encode(session))])
        }
    }

    func sessions(bindingID: UUID? = nil) throws -> [TransferSession] {
        try readState { connection in
            let rows = try connection.rows("SELECT body FROM sessions" + (bindingID == nil ? "" : " WHERE binding = ?"),
                                           bindingID.map { [.text($0.uuidString)] } ?? [])
            return try rows.map { try Self.decode(TransferSession.self, $0.blob("body")) }
        }
    }

    /// Intent exists before a native task or foreground request can have a side effect.
    func stageTransfer(_ transfer: Transfer) throws {
        guard transfer.state == .intent, transfer.taskID == nil, transfer.expected.size > 0 else {
            throw Failure.invalidReceipt
        }
        try mutateState { connection in
            guard let operation = try Self.operation(transfer.operationID, connection),
                  operation.epoch == transfer.epoch, operation.desired == .active,
                  operation.receipt?.version == transfer.version,
                  let sessionRow = try connection.rows("SELECT body FROM sessions WHERE id = ? AND draining = 0",
                                                       [.text(transfer.sessionID.uuidString)]).first else {
                throw Failure.staleOperation
            }
            let session = try Self.decode(TransferSession.self, sessionRow.blob("body"))
            guard operation.bindingID == session.bindingID else { throw Failure.retiredBinding }
            if let old = try connection.rows("SELECT body FROM transfers WHERE id = ?", [.text(transfer.id.uuidString)]).first {
                var previous = try Self.decode(Transfer.self, old.blob("body"))
                previous.taskID = nil
                previous.state = .intent
                previous.capturedResourceID = nil
                guard previous == transfer else { throw Failure.invalidReceipt }
                return
            }
            switch transfer.kind {
            case .upload:
                guard let resourceID = transfer.resourceID, transfer.uploadID != nil,
                      let row = try connection.rows("SELECT body FROM resources WHERE id = ? AND operation = ?",
                                                   [.text(resourceID.uuidString), .text(operation.id.uuidString)]).first else {
                    throw Failure.invalidReceipt
                }
                let resource = try Self.decode(Resource.self, row.blob("body"))
                guard resource.kind == .original, resource.availability == .present,
                      Self.match(resource.descriptor, transfer.expected) else {
                    throw Failure.invalidReceipt
                }
                try connection.execute("INSERT OR IGNORE INTO file_refs (resource, owner) VALUES (?, ?)",
                                       [.text(resourceID.uuidString), .text("transfer:" + transfer.id.uuidString)])
            case .download:
                guard let derivative = operation.receipt?.derivative, transfer.generationID == derivative.generationID,
                      derivative.resources.contains(where: {
                          $0.role == transfer.expected.role && $0.size == transfer.expected.size
                              && $0.sha256.lowercased() == transfer.expected.sha256.lowercased()
                      }) else { throw Failure.invalidReceipt }
            case .originalDownload:
                guard operation.manifest?.resources.contains(where: {
                    Self.match($0, transfer.expected)
                }) == true else { throw Failure.invalidReceipt }
            }
            try Self.write(transfer, connection)
        }
    }

    func attachTask(transferID: UUID, sessionID: UUID, taskID: Int) throws {
        guard taskID > 0 else { throw Failure.invalidReceipt }
        try mutateState { connection in
            guard var transfer = try Self.transfer(transferID, connection), transfer.sessionID == sessionID,
                  transfer.taskID == nil || transfer.taskID == taskID,
                  transfer.state == .intent || transfer.state == .suspended else { throw Failure.staleOperation }
            transfer.taskID = taskID
            transfer.state = .suspended
            try Self.write(transfer, connection)
        }
    }

    func startTransfer(_ id: UUID) throws {
        try mutateState { connection in
            guard var transfer = try Self.transfer(id, connection),
                  let operation = try Self.operation(transfer.operationID, connection),
                  operation.epoch == transfer.epoch, operation.desired == .active else { throw Failure.staleOperation }
            if transfer.state == .running || transfer.state.terminal { return }
            guard transfer.state == .intent || transfer.state == .suspended || transfer.state == .unknown else {
                throw Failure.staleOperation
            }
            transfer.state = .running
            try Self.write(transfer, connection)
        }
    }

    func finishTransfer(_ id: UUID, state: Transfer.State) throws {
        guard state.terminal || state == .captured || state == .unknown else { throw Failure.invalidReceipt }
        try mutateState { connection in
            guard var transfer = try Self.transfer(id, connection) else { throw Failure.staleOperation }
            if transfer.state.terminal {
                guard transfer.state == state else { throw Failure.staleOperation }
                return
            }
            transfer.state = state
            try Self.write(transfer, connection)
            if state.terminal {
                try connection.execute("DELETE FROM file_refs WHERE owner = ?", [.text("transfer:" + id.uuidString)])
            }
        }
    }

    func transfers(operationID: UUID? = nil) throws -> [Transfer] {
        try readState { connection in
            let rows = try connection.rows("SELECT body FROM transfers" + (operationID == nil ? "" : " WHERE operation = ?"),
                                           operationID.map { [.text($0.uuidString)] } ?? [])
            return try rows.map { try Self.decode(Transfer.self, $0.blob("body")) }
        }
    }

    func recordResource(_ resource: Resource) throws {
        guard resource.descriptor.size > 0 else { throw Failure.invalidImport }
        try mutateState { connection in
            guard try Self.operation(resource.operationID, connection) != nil else { throw Failure.missingOperation }
            if let old = try connection.rows("SELECT body FROM resources WHERE id = ?", [.text(resource.fileID.uuidString)]).first {
                guard try Self.decode(Resource.self, old.blob("body")) == resource else { throw Failure.invalidImport }
                return
            }
            try connection.execute("INSERT INTO resources (id, operation, kind, size, body) VALUES (?, ?, ?, ?, ?)",
                                   [.text(resource.fileID.uuidString), .text(resource.operationID.uuidString),
                                    .text(resource.kind.rawValue), .integer(Int64(resource.descriptor.size)),
                                    .blob(try Self.encode(resource))])
            try connection.execute("INSERT INTO file_refs (resource, owner) VALUES (?, ?)",
                                   [.text(resource.fileID.uuidString), .text("operation:" + resource.operationID.uuidString)])
        }
    }

    func captureDownload(_ id: UUID, resource: Resource) throws {
        guard resource.kind != .original, resource.descriptor.size > 0 else { throw Failure.invalidImport }
        try mutateState { connection in
            guard var transfer = try Self.transfer(id, connection), transfer.kind != .upload,
                  resource.operationID == transfer.operationID, Self.match(resource.descriptor, transfer.expected),
                  transfer.capturedResourceID == nil || transfer.capturedResourceID == resource.fileID else {
                throw Failure.invalidImport
            }
            guard (transfer.kind == .originalDownload) == (resource.kind == .restoredOriginal) else {
                throw Failure.invalidImport
            }
            if let row = try connection.rows("SELECT body FROM resources WHERE id = ?", [.text(resource.fileID.uuidString)]).first {
                guard try Self.decode(Resource.self, row.blob("body")) == resource else { throw Failure.invalidImport }
            } else {
                try connection.execute("INSERT INTO resources (id, operation, kind, size, body) VALUES (?, ?, ?, ?, ?)",
                                       [.text(resource.fileID.uuidString), .text(resource.operationID.uuidString),
                                        .text(resource.kind.rawValue), .integer(Int64(resource.descriptor.size)),
                                        .blob(try Self.encode(resource))])
                try connection.execute("INSERT INTO file_refs (resource, owner) VALUES (?, ?)",
                                       [.text(resource.fileID.uuidString), .text("operation:" + resource.operationID.uuidString)])
            }
            transfer.capturedResourceID = resource.fileID
            if !transfer.state.terminal { transfer.state = .captured }
            try Self.write(transfer, connection)
        }
    }

    func releaseOriginalSpools(_ id: UUID) throws {
        try mutateState { connection in
            guard let operation = try Self.operation(id, connection), operation.backup == .retained,
                  operation.receipt?.retention == .permanent || operation.receipt?.retention == .external else {
                throw Failure.invalidReceipt
            }
            let needsMotion = operation.manifest?.kind == .livePhoto
                && (operation.receipt?.derivative == nil || operation.receipt?.derivative?.deviceCompresses.contains(.pairedVideo) == true)
            for row in try connection.rows("SELECT body FROM resources WHERE operation = ? AND kind = 'original'", [.text(id.uuidString)]) {
                let resource = try Self.decode(Resource.self, row.blob("body"))
                if needsMotion, [.pairedVideo, .fullSizePairedVideo].contains(resource.descriptor.role) { continue }
                try connection.execute("DELETE FROM file_refs WHERE resource = ? AND owner = ?",
                                       [.text(resource.fileID.uuidString), .text("operation:" + id.uuidString)])
            }
        }
    }

    func claimCleanup(limit: Int = 100) throws -> [Resource] {
        guard (1...1_000).contains(limit) else { throw Failure.invalidImport }
        return try mutateState { connection in
            let rows = try connection.rows("""
                SELECT r.body FROM resources r WHERE NOT EXISTS (SELECT 1 FROM file_refs f WHERE f.resource = r.id)
                AND NOT EXISTS (SELECT 1 FROM transfers t WHERE t.resource = r.id AND t.status NOT IN ('completed', 'failed'))
                AND coalesce(json_extract(CAST(r.body AS TEXT), '$.fileState'), 'present') != 'removed'
                ORDER BY r.rowid LIMIT ?
                """, [.integer(Int64(limit))])
            return try rows.map { row in
                var resource = try Self.decode(Resource.self, row.blob("body"))
                resource.fileState = .deleting
                try connection.execute("UPDATE resources SET body = ? WHERE id = ?",
                                       [.blob(try Self.encode(resource)), .text(resource.fileID.uuidString)])
                return resource
            }
        }
    }

    func cleanedResource(_ id: UUID) throws {
        try mutateState { connection in
            guard let row = try connection.rows("SELECT body FROM resources WHERE id = ?", [.text(id.uuidString)]).first else {
                throw Failure.invalidImport
            }
            var resource = try Self.decode(Resource.self, row.blob("body"))
            guard resource.availability == .deleting || resource.availability == .removed else { throw Failure.invalidImport }
            resource.fileState = .removed
            try connection.execute("UPDATE resources SET body = ? WHERE id = ?",
                                   [.blob(try Self.encode(resource)), .text(id.uuidString)])
        }
    }

    static func transfer(_ id: UUID, _ connection: BackupDatabase.Connection) throws -> Transfer? {
        try connection.rows("SELECT body FROM transfers WHERE id = ?", [.text(id.uuidString)])
            .first.map { try Self.decode(Transfer.self, $0.blob("body")) }
    }

    static func write(_ transfer: Transfer, _ connection: BackupDatabase.Connection) throws {
        try connection.execute("""
            INSERT INTO transfers (id, operation, session, resource, task, status, body) VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET task = excluded.task, status = excluded.status, body = excluded.body
            """, [.text(transfer.id.uuidString), .text(transfer.operationID.uuidString), .text(transfer.sessionID.uuidString),
                   (transfer.resourceID ?? transfer.capturedResourceID).map { .text($0.uuidString) } ?? .null,
                   transfer.taskID.map { .integer(Int64($0)) } ?? .null,
                   .text(transfer.state.rawValue), .blob(try Self.encode(transfer))])
    }

    private static func match(_ left: ServerAPI.ResourceDescriptor, _ right: ServerAPI.ResourceDescriptor) -> Bool {
        left.role == right.role && left.size == right.size && left.sha256.lowercased() == right.sha256.lowercased()
    }
}
