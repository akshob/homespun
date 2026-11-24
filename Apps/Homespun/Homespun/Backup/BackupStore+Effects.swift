// SPDX-License-Identifier: Apache-2.0
import Foundation
import HomespunCore

extension BackupStore {
    struct ImportContext: Codable, Equatable, Sendable {
        var metadata: BackupPhotoMetadata
        var observation: PhotosObservation
        var metadataApplied: Bool?
    }

    struct PhotoEffect: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable { case restore, keepOriginal, removeOriginal }
        enum Phase: String, Codable, Sendable { case planned, mutating, uncertain, created, verified, cancelled }
        var id: UUID
        var namespace: String
        var item: String
        var kind: Kind
        var phase: Phase = .planned
        var bindingID: UUID?
        var version: BackupAPI.Version?
        var epochs: [UUID: Int64] = [:]
        var mappings: [SavedMapping]
        var metadata: BackupPhotoMetadata?
        var observation: PhotosObservation?
        var expected: [ServerAPI.ResourceDescriptor] = []
        var approvals: [PhotosRemovalApproval] = []
        var createdIdentifier: String?
        var submitted: Set<String> = []
        var resources: [UUID]?
        var problem: String?

        var originals: Set<String> { Set(mappings.map(\.originalID)) }
    }

    func prepareImportContext(_ intent: ImportIntent, metadata: BackupPhotoMetadata,
                              observation: PhotosObservation) throws -> ImportContext {
        try mutateState { connection in
            guard let row = try connection.rows("SELECT body FROM imports WHERE id = ?", [.text(intent.id.uuidString)]).first else {
                throw Failure.importNeedsReconciliation
            }
            let current = try Self.decode(ImportIntent.self, row.blob("body"))
            let key = "import-context:" + intent.id.uuidString
            if let context = try Self.metadata(key, as: ImportContext.self, connection), current.phase != .planned { return context }
            guard current.phase == .planned, current.operationEpoch == intent.operationEpoch else { throw Failure.importNeedsReconciliation }
            let context = ImportContext(metadata: metadata, observation: observation)
            try Self.saveMetadata(key, value: context, connection)
            return context
        }
    }

    func importContext(_ id: UUID) throws -> ImportContext? {
        try metadata("import-context:" + id.uuidString, as: ImportContext.self)
    }

    func importMetadataApplied(_ id: UUID) throws {
        try mutateState { connection in
            guard let row = try connection.rows("SELECT body FROM imports WHERE id = ?", [.text(id.uuidString)]).first,
                  let context = try Self.metadata("import-context:" + id.uuidString, as: ImportContext.self, connection) else {
                throw Failure.importNeedsReconciliation
            }
            let intent = try Self.decode(ImportIntent.self, row.blob("body"))
            guard intent.createdIdentifier != nil, intent.phase == .created || intent.phase == .verified else {
                throw Failure.importNeedsReconciliation
            }
            var applied = context
            applied.metadataApplied = true
            try Self.saveMetadata("import-context:" + id.uuidString, value: applied, connection)
        }
    }

    func planEffect(_ effect: PhotoEffect) throws -> PhotoEffect {
        guard effect.phase == .planned, !effect.namespace.isEmpty, !effect.item.isEmpty,
              !effect.mappings.isEmpty else { throw Failure.invalidImport }
        return try mutateState { connection in
            for row in try connection.rows("""
                SELECT body FROM photo_effects WHERE namespace = ?
                AND phase IN ('planned','mutating','uncertain','created')
                """, [.text(effect.namespace)]) {
                let old = try Self.decode(PhotoEffect.self, row.blob("body"))
                if old.id == effect.id { return old }
                guard old.originals.isDisjoint(with: effect.originals) else { throw Failure.importNeedsReconciliation }
            }
            try Self.writeEffect(effect, connection)
            return effect
        }
    }

    func effects(namespace: String, unfinished: Bool = true) throws -> [PhotoEffect] {
        try readState { connection in
            let predicate = unfinished ? " AND phase IN ('planned','mutating','uncertain','created')" : ""
            return try connection.rows("SELECT body FROM photo_effects WHERE namespace = ?\(predicate) ORDER BY rowid",
                                       [.text(namespace)]).map { try Self.decode(PhotoEffect.self, $0.blob("body")) }
        }
    }

    func effect(_ id: UUID) throws -> PhotoEffect? { try readState { try Self.effect(id, $0) } }

    func effectResources(_ id: UUID, resources: [Resource]) throws {
        try mutateState { connection in
            guard var effect = try Self.effect(id, connection), effect.kind == .restore, effect.phase == .planned,
                  BackupValidation.matches(effect.expected, resources.map(\.descriptor)),
                  resources.allSatisfy({ $0.kind == .restoredOriginal && $0.availability == .present
                      && effect.epochs[$0.operationID] != nil }) else { throw Failure.invalidImport }
            let ids = resources.map(\.fileID)
            guard effect.resources == nil || effect.resources == ids else { throw Failure.invalidImport }
            effect.resources = ids
            try Self.writeEffect(effect, connection)
        }
    }

    func effectMetadata(_ id: UUID, metadata: BackupPhotoMetadata) throws {
        try mutateState { connection in
            guard var effect = try Self.effect(id, connection), effect.kind == .restore, effect.phase == .planned else {
                throw Failure.importNeedsReconciliation
            }
            effect.metadata = metadata
            try Self.writeEffect(effect, connection)
        }
    }

    func startEffect(_ id: UUID) throws {
        try mutateState { connection in
            guard var effect = try Self.effect(id, connection), effect.phase == .planned else {
                throw Failure.importNeedsReconciliation
            }
            if let bindingID = effect.bindingID {
                guard let row = try connection.rows("SELECT body FROM bindings WHERE id = ? AND retired = 0",
                                                    [.text(bindingID.uuidString)]).first,
                      try Self.decode(Binding.self, row.blob("body")).origin == effect.version?.origin else {
                    throw Failure.retiredBinding
                }
            }
            for mapping in effect.mappings {
                guard let row = try connection.rows("SELECT current_mapping FROM lineages WHERE namespace = ? AND item = ?",
                                                   [.text(effect.namespace), .text(mapping.originalID)]).first,
                      try row.text("current_mapping") == mapping.id.uuidString else { throw Failure.staleOperation }
            }
            for (operationID, epoch) in effect.epochs {
                guard try Self.operation(operationID, connection)?.epoch == epoch else { throw Failure.staleOperation }
            }
            effect.phase = .mutating
            try Self.writeEffect(effect, connection)
        }
    }

    /// Facts survive cancellation, retirement and a later failure to update the projected mapping.
    func effectCreated(_ id: UUID, identifier: String? = nil, submitted: Set<String> = [], problem: String? = nil) throws {
        try mutateState { connection in
            guard var effect = try Self.effect(id, connection),
                  effect.phase != .cancelled else { throw Failure.importNeedsReconciliation }
            if let identifier {
                guard effect.createdIdentifier == nil || effect.createdIdentifier == identifier else { throw Failure.invalidImport }
                effect.createdIdentifier = identifier
            }
            effect.submitted.formUnion(submitted)
            effect.problem = problem
            if effect.phase != .verified { effect.phase = .created }
            try Self.writeEffect(effect, connection)
        }
    }

    func effectUncertain(_ id: UUID, message: String) throws {
        try mutateState { connection in
            guard var effect = try Self.effect(id, connection) else { throw Failure.importNeedsReconciliation }
            if effect.phase == .verified || effect.phase == .cancelled { return }
            if effect.phase != .created { effect.phase = .uncertain }
            effect.problem = message
            try Self.writeEffect(effect, connection)
        }
    }

    func cancelEffect(_ id: UUID) throws {
        try mutateState { connection in
            guard var effect = try Self.effect(id, connection),
                  effect.phase == .planned || effect.phase == .mutating, effect.createdIdentifier == nil,
                  effect.submitted.isEmpty else { throw Failure.importNeedsReconciliation }
            effect.phase = .cancelled
            try Self.writeEffect(effect, connection)
        }
    }

    func completeRemoval(_ id: UUID) throws {
        try mutateState { connection in
            guard var effect = try Self.effect(id, connection), effect.kind == .removeOriginal,
                  effect.phase == .created || effect.phase == .verified else { throw Failure.importNeedsReconciliation }
            effect.phase = .verified
            try Self.writeEffect(effect, connection)
        }

    }

    func completeKeep(_ id: UUID) throws {
            try mutateState { connection in
                guard var effect = try Self.effect(id, connection), effect.kind == .keepOriginal,
                      effect.phase == .created || effect.phase == .verified else { throw Failure.importNeedsReconciliation }
                if effect.phase == .verified { return }
                for mapping in effect.mappings where effect.submitted.contains(mapping.entry.compactIdentifier) {
                    guard let row = try connection.rows("SELECT current_mapping FROM lineages WHERE namespace = ? AND item = ?",
                                                        [.text(effect.namespace), .text(mapping.originalID)]).first else { continue }
                    if case .null? = row.values["current_mapping"] { continue }
                    guard try row.text("current_mapping") == mapping.id.uuidString else { continue }
                    let entry = mapping.entry
                    let kept = CompactLedger.BackedUp(serverAssetID: entry.serverAssetID ?? "", originalBytes: entry.originalBytes,
                        backedUpAt: Date(), kept: true, origin: mapping.origin, version: mapping.proof?.version,
                        requestID: entry.requestID, bindingID: entry.bindingID, operationID: entry.operationID)
                    try connection.execute("""
                        INSERT INTO legacy_backed_up(namespace,original,body) VALUES(?,?,?)
                        ON CONFLICT(namespace,original) DO UPDATE SET body = excluded.body
                        """, [.text(effect.namespace), .text(mapping.originalID), .blob(try Self.encode(kept))])
                    try connection.execute("UPDATE lineages SET current_mapping = NULL WHERE namespace = ? AND item = ? AND current_mapping = ?",
                                           [.text(effect.namespace), .text(mapping.originalID), .text(mapping.id.uuidString)])
                    try connection.execute("""
                        INSERT INTO decisions(namespace,item,kept) VALUES(?,?,1)
                        ON CONFLICT(namespace,item) DO UPDATE SET kept = 1
                        """, [.text(effect.namespace), .text(mapping.originalID)])
                }
                effect.phase = .verified
                try Self.writeEffect(effect, connection)
            }
        }

    func completeRestore(_ id: UUID, actual: [ServerAPI.ResourceDescriptor],
                             proof: BackupAPI.OriginalProof) throws -> SavedMapping {
            try mutateState { connection in
                guard var effect = try Self.effect(id, connection), effect.kind == .restore,
                      let created = effect.createdIdentifier, let original = effect.mappings.first,
                      effect.mappings.count == 1, proof.version == effect.version,
                      proof.retention == .permanent, proof.claimID != nil,
                      proof.resources.allSatisfy({ $0.state == .verified && $0.verifiedAt != nil && $0.receivedBytes == $0.size }),
                      BackupValidation.matches(effect.expected, proof.resources.map {
                          .init(role: $0.role, filename: "", size: $0.size, sha256: $0.sha256)
                      }),
                      BackupValidation.matches(effect.expected, actual),
                      effect.phase == .created || effect.phase == .verified else { throw Failure.invalidImport }
                if let stored = try Self.metadata("restored-mapping:" + id.uuidString, as: SavedMapping.self, connection) {
                    return stored
                }
                var entry = original.entry
                entry.savedAt = Date()
                let mapping = SavedMapping(id: UUID(), namespace: effect.namespace, originalID: created, entry: entry,
                                           origin: original.origin, proof: proof, compactResources: original.compactResources)
                try Self.insertMapping(mapping, connection)
                try connection.execute("""
                    INSERT INTO lineages(namespace,item,generation,current_mapping) VALUES(?,?,0,?)
                    ON CONFLICT(namespace,item) DO NOTHING
                    """, [.text(effect.namespace), .text(created), .text(mapping.id.uuidString)])
                if created == original.originalID {
                    try connection.execute("""
                        UPDATE lineages SET current_mapping = ? WHERE namespace = ? AND item = ? AND current_mapping = ?
                        """, [.text(mapping.id.uuidString), .text(effect.namespace), .text(created), .text(original.id.uuidString)])
                } else {
                    try connection.execute("""
                        UPDATE lineages SET current_mapping = NULL WHERE namespace = ? AND item = ? AND current_mapping = ?
                        """, [.text(effect.namespace), .text(original.originalID), .text(original.id.uuidString)])
                }
                try Self.saveMetadata("restored-mapping:" + id.uuidString, value: mapping, connection)
                effect.phase = .verified
                try Self.writeEffect(effect, connection)
                if let operationID = original.entry.operationID {
                    for resource in effect.resources ?? [] {
                        try connection.execute("DELETE FROM file_refs WHERE owner = ? AND resource = ?",
                            [.text("operation:" + operationID.uuidString), .text(resource.uuidString)])
                    }
                }
                return mapping
            }
        }
    static func effect(_ id: UUID, _ connection: BackupDatabase.Connection) throws -> PhotoEffect? {
        try connection.rows("SELECT body FROM photo_effects WHERE id = ?", [.text(id.uuidString)]).first.map {
            try Self.decode(PhotoEffect.self, $0.blob("body"))
        }
    }

    static func writeEffect(_ effect: PhotoEffect, _ connection: BackupDatabase.Connection) throws {
        try connection.execute("""
            INSERT INTO photo_effects(id,namespace,item,kind,phase,body) VALUES(?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET phase = excluded.phase, body = excluded.body
            """, [.text(effect.id.uuidString), .text(effect.namespace), .text(effect.item), .text(effect.kind.rawValue),
                   .text(effect.phase.rawValue), .blob(try Self.encode(effect))])
    }
}
