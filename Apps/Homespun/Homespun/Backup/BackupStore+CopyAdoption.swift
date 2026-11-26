// SPDX-License-Identifier: Apache-2.0
import Foundation
import HomespunCore

extension BackupStore {
    struct CopyIntent: Codable, Equatable, Sendable {
        var operationID: UUID
        var compactID: String
        var compact: BackupAPI.Manifest
    }

    /// Persist the operation key before contacting the server. An unfinished adoption is not
    /// upload work, and cannot be promoted by the ordinary device pipeline.
    func planCopyAdoption(compactID: String, originalID: String?, candidate: BackupAPI.CopyCandidate,
                          compact: BackupAPI.Manifest, bindingID: UUID, namespace: String,
                          profile: CompressionProfile) throws -> Operation {
        _ = try candidate.manifest.validated()
        _ = try compact.validated()
        guard !compactID.isEmpty, !namespace.isEmpty, originalID?.isEmpty != true,
              compact.kind == candidate.manifest.kind else { throw Failure.invalidImport }
        let item = originalID ?? CompactLedger.elsewhere(compactID)
        return try mutateState { connection in
            guard let row = try connection.rows("SELECT body FROM bindings WHERE id = ? AND retired = 0",
                                               [.text(bindingID.uuidString)]).first else { throw Failure.retiredBinding }
            let binding = try Self.decode(Binding.self, row.blob("body"))
            guard binding.origin == candidate.origin, binding.mode == .files else { throw Failure.invalidReceipt }
            if let row = try connection.rows("""
                SELECT o.body FROM operations o JOIN lineages l ON l.current_operation = o.id
                WHERE l.namespace = ? AND l.item = ?
                """, [.text(namespace), .text(item)]).first {
                let old = try Self.decode(Operation.self, row.blob("body"))
                if old.bindingID == bindingID, old.desired == .active,
                   let intent = try Self.metadata("copy-adoption:" + old.id.uuidString, as: CopyIntent.self, connection),
                   intent.compactID == compactID, BackupValidation.matches(intent.compact.resources, compact.resources),
                   try old.manifest?.identifier() == candidate.manifest.identifier() {
                    return old
                }
                // Never replace an admitted selection or an unresolved Photos handoff.
                guard old.desired != .active || old.delivery == .importedVerified else { throw Failure.activeWork }
            }
            let previous = try connection.rows("SELECT generation FROM lineages WHERE namespace = ? AND item = ?",
                                               [.text(namespace), .text(item)]).first?.integer("generation") ?? 0
            guard previous < Int64.max else { throw Failure.unsupportedSchema }
            try Self.supersedeCurrent(namespace: namespace, item: item, connection)
            let now = Date(), id = UUID()
            var operation = Operation(id: id, namespace: namespace, itemID: item, lineage: previous + 1,
                bindingID: bindingID, origin: candidate.origin, profile: profile, wantsCompact: false,
                createdAt: now, updatedAt: now)
            operation.manifest = candidate.manifest
            operation.request = .init(operationID: id, origin: candidate.origin, manifest: candidate.manifest,
                profile: profile, retention: .permanent, compact: false, captureDate: candidate.captureDate)
            operation.backup = .verifying
            operation.attention = true
            try Self.write(operation, connection)
            try connection.execute("""
                INSERT INTO lineages(namespace,item,generation,current_operation) VALUES(?,?,?,?)
                ON CONFLICT(namespace,item) DO UPDATE SET generation = excluded.generation,
                current_operation = excluded.current_operation
                """, [.text(namespace), .text(item), .integer(operation.lineage), .text(id.uuidString)])
            try Self.saveMetadata("copy-adoption:" + id.uuidString,
                value: CopyIntent(operationID: id, compactID: compactID, compact: compact), connection)
            return operation
        }
    }

    /// No Photos import/derivative receipt is invented: these bytes already exist on the device.
    /// Old mappings remain immutable history, including their unknown historical origin.
    func finishCopyAdoption(_ id: UUID, epoch: Int64, receipt: BackupAPI.Receipt,
                            proof: BackupAPI.OriginalProof, actual: [ServerAPI.ResourceDescriptor]) throws {
        try mutateState { connection in
            guard var operation = try Self.operation(id, connection), operation.epoch == epoch,
                  operation.desired == .active, try Self.isCurrent(operation, connection),
                  try Self.bindingUsable(operation, connection), let manifest = operation.manifest,
                  let intent = try Self.metadata("copy-adoption:" + id.uuidString, as: CopyIntent.self, connection),
                  proof.version == receipt.version, receipt.backup == .retained, receipt.retention == .permanent,
                  proof.retention == .permanent, proof.claimID != nil,
                  proof.version.origin == operation.origin,
                  abs(Date().timeIntervalSince(proof.verifiedAt)) <= 60,
                  BackupValidation.matches(intent.compact.resources, actual),
                  BackupValidation.matches(manifest.resources, proof.resources.map {
                      .init(role: $0.role, filename: "", size: $0.size, sha256: $0.sha256)
                  }), proof.resources.allSatisfy({
                      $0.state == .verified && $0.size > 0 && $0.receivedBytes == $0.size && $0.verifiedAt != nil
                  }) else { throw Failure.invalidImport }
            _ = try Self.apply(receipt, operationID: id, epoch: epoch, connection)
            operation = try Self.operation(id, connection)!
            if operation.delivery == .importedVerified { return }
            operation.delivery = .importedVerified
            operation.attention = false
            operation.updatedAt = Date()
            try Self.write(operation, connection)
            let entry = CompactLedger.Entry(compactIdentifier: intent.compactID,
                originalBytes: manifest.resources.reduce(0) { $0 + $1.size },
                compactBytes: actual.reduce(0) { $0 + $1.size }, savedAt: Date(),
                serverAssetID: receipt.version.assetID, requestID: receipt.requestID,
                bindingID: operation.bindingID, operationID: id, revalidatedCopy: true)
            let mapping = SavedMapping(id: UUID(), namespace: operation.namespace, originalID: operation.itemID,
                entry: entry, origin: operation.origin, proof: proof, compactResources: actual)
            try Self.insertMapping(mapping, connection)
            try connection.execute("""
                UPDATE lineages SET current_mapping = ? WHERE namespace = ? AND item = ? AND current_operation = ?
                """, [.text(mapping.id.uuidString), .text(operation.namespace), .text(operation.itemID), .text(id.uuidString)])
            for row in try connection.rows("""
                   SELECT m.body FROM mappings m JOIN lineages l ON l.current_mapping = m.id
                   WHERE l.namespace = ? AND l.item != ?
                   AND json_extract(CAST(m.body AS TEXT),'$.entry.compactIdentifier') = ?
                   """, [.text(operation.namespace), .text(operation.itemID), .text(intent.compactID)]) {
                let old = try Self.decode(SavedMapping.self, row.blob("body"))
                try Self.supersedeCurrent(namespace: operation.namespace, item: old.originalID, connection)
                try connection.execute("UPDATE lineages SET current_mapping = NULL, current_operation = NULL WHERE namespace = ? AND item = ?",
                                       [.text(operation.namespace), .text(old.originalID)])
            }
        }
    }
}
