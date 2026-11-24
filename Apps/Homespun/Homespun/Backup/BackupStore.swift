// SPDX-License-Identifier: Apache-2.0
import Foundation
import HomespunCore

actor BackupStore {
    enum Failure: Error, LocalizedError, Equatable {
        case unsupportedSchema
        case legacyUnreadable
        case legacyChanged
        case missingOperation
        case staleOperation
        case retiredBinding
        case invalidReceipt
        case conflictingReceipt
        case importNeedsReconciliation
        case invalidImport
        case incompatibleQueuedSettings
        case nativeTransferUnavailable
        case storageClosed
        case activeWork

        var errorDescription: String? {
            switch self {
            case .unsupportedSchema: "This backup database needs a different version of Homespun. It has not been changed."
            case .legacyUnreadable: "Previous backup records could not be read. They have been preserved; no new work was admitted."
            case .legacyChanged: "An older Homespun changed the previous backup records. Reconciliation is required before continuing."
            case .missingOperation: "This backup operation is no longer available."
            case .staleOperation: "This completion belongs to an earlier backup attempt."
            case .retiredBinding: "Work for the previous server is paused. Reconnect that server before continuing."
            case .invalidReceipt: "The server's backup proof does not match this item and version."
            case .conflictingReceipt: "The server returned conflicting progress for the same backup revision."
            case .importNeedsReconciliation: "An earlier Photos import needs to be checked before another copy can be made."
            case .invalidImport: "The compact copy has not passed complete-resource verification."
            case .incompatibleQueuedSettings: "This item is already queued with different quality settings. Finish or cancel that work first."
            case .nativeTransferUnavailable: "Native background transfers are not enabled for this connection."
            case .storageClosed: "This backup workspace has been retired."
            case .activeWork: "Backup work has not finished retiring yet."
            }
        }
    }

    struct Binding: Codable, Equatable, Sendable {
        var id: UUID
        var origin: BackupAPI.Origin
        var trustEpoch: UUID
        var baseURL: URL
        var keychainReference: String
        var mode: ServerAPI.StorageMode = .files
        var consumerID: String?
        var externalVerification: BackupAPI.ExternalVerification?
        var retired = false
    }

    enum Desired: String, Codable, Sendable { case active, paused, cancelled }
    enum Stage: String, Codable, Sendable { case preparation, upload, finalization }

    struct Lease: Codable, Equatable, Sendable {
        var id: UUID
        var operationID: UUID
        var epoch: Int64
        var processID: UUID
        var stage: Stage
    }

    struct Operation: Codable, Equatable, Sendable {
        var id: UUID
        var namespace: String
        var itemID: String
        var lineage: Int64
        var bindingID: UUID
        var origin: BackupAPI.Origin
        var epoch: Int64 = 1
        var desired: Desired = .active
        var backup: BackupAPI.BackupState = .selected
        var compact: BackupAPI.CompactState = .requested
        var delivery: BackupAPI.DeliveryState = .pending
        var profile: CompressionProfile
        var wantsCompact: Bool
        var manifest: BackupAPI.Manifest?
        var request: BackupAPI.Request?
        var metadata: Data?
        var receipt: BackupAPI.Receipt?
        var lease: Lease?
        var attention = false
        var problem: Problem?
        var bindingPaused: Bool?
        var notBefore: Date?
        var createdAt: Date
        var updatedAt: Date
    }

    struct Problem: Codable, Equatable, Sendable {
        var code: String
        var message: String
        var stage: Stage
    }

    struct Batch: Equatable, Sendable {
        var id: UUID
        var operationIDs: [UUID]
        var selectedCount: Int
    }

    struct Resource: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable { case original, compact, motion, restoredOriginal }
        enum FileState: String, Codable, Sendable { case present, deleting, removed }
        var fileID: UUID
        var operationID: UUID
        var kind: Kind
        var descriptor: ServerAPI.ResourceDescriptor
        var fileState: FileState?
        var availability: FileState { fileState ?? .present }
    }

    struct SavedMapping: Codable, Equatable, Sendable {
        var id: UUID
        var namespace: String
        var originalID: String
        var entry: CompactLedger.Entry
        var origin: BackupAPI.Origin?
        var proof: BackupAPI.OriginalProof?
        var compactResources: [ServerAPI.ResourceDescriptor]?
        var intentID: UUID?
    }

    struct ImportIntent: Codable, Equatable, Sendable {
        enum Phase: String, Codable, Sendable { case planned, mutating, uncertain, created, verified }
        var id: UUID
        var operationID: UUID
        var operationEpoch: Int64
        var version: BackupAPI.Version
        var generationID: UUID
        var expected: [ServerAPI.ResourceDescriptor]
        var phase: Phase
        var createdIdentifier: String?
    }

    struct OutboxItem: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable { case deliveryAcknowledgement, readyNotification, serverCommand }
        var id: UUID
        var operationID: UUID
        var bindingID: UUID
        var kind: Kind
        var payload: Data
        var attempts: Int = 0
        var nextAttempt: Date?
    }

    enum ReceiptApplication: Equatable, Sendable { case applied, stale }
    private struct LegacyChange: Decodable {
        var set: [String: CompactLedger.Entry]?
        var remove: [String]?
    }
    private struct LegacyDecisions: Decodable { var keptAsIs: Set<String>? }
    private struct LegacyFile: Codable, Equatable { var name: String; var sha256: String? }

    nonisolated let files: BackupFiles
    private let legacyURL: URL?
    private let legacyNamespace: String
    private let processID: UUID
    private var database: BackupDatabase?
    private var closed = false
    private static let currentProcessID = UUID()
    private static let applicationID: Int64 = 0x4853504E

    init(directory: URL = BackupFiles.defaultRoot, legacyURL: URL? = CompactLedger.defaultURL,
         namespace: String = "photos", processID: UUID? = nil) {
        self.files = BackupFiles(root: directory)
        self.legacyURL = legacyURL
        self.legacyNamespace = namespace
        self.processID = processID ?? Self.currentProcessID
    }

    func open() throws { _ = try db() }

    func bind(_ binding: Binding) throws {
        guard binding.baseURL.scheme == "https", binding.baseURL.host != nil,
              binding.baseURL.user == nil, binding.baseURL.password == nil, binding.baseURL.query == nil,
              binding.baseURL.fragment == nil, UUID(uuidString: binding.origin.serverID) != nil,
              UUID(uuidString: binding.origin.historyEpoch) != nil else { throw Failure.retiredBinding }
        try db().transaction { connection in
            let origin = Self.originKey(binding.origin)
            try connection.execute("INSERT OR IGNORE INTO origins (id, body) VALUES (?, ?)",
                                   [.text(origin), .blob(try Self.encode(binding.origin))])
            if let existing = try connection.rows("SELECT body FROM bindings WHERE id = ?", [.text(binding.id.uuidString)]).first {
                guard try Self.decode(Binding.self, existing.blob("body")) == binding else { throw Failure.retiredBinding }
                return
            }
            try connection.execute("INSERT INTO bindings (id, origin, retired, body) VALUES (?, ?, ?, ?)",
                                   [.text(binding.id.uuidString), .text(origin), .integer(binding.retired ? 1 : 0),
                                    .blob(try Self.encode(binding))])
        }
    }

    func binding(_ id: UUID) throws -> Binding? {
        try db().read { connection in
            try connection.rows("SELECT body FROM bindings WHERE id = ?", [.text(id.uuidString)]).first.map {
                try Self.decode(Binding.self, $0.blob("body"))
            }
        }
    }

    func admit(_ identifiers: [String], namespace: String, bindingID: UUID, profile: CompressionProfile,
               compact: Bool) throws -> Batch {
        guard !namespace.isEmpty, !identifiers.isEmpty, identifiers.allSatisfy({ !$0.isEmpty }) else {
            throw Failure.missingOperation
        }
        var seen = Set<String>()
        let selected = identifiers.filter { seen.insert($0).inserted }
        return try db().transaction { connection in
            guard let row = try connection.rows("SELECT body FROM bindings WHERE id = ? AND retired = 0",
                                                [.text(bindingID.uuidString)]).first else { throw Failure.retiredBinding }
            let binding = try Self.decode(Binding.self, row.blob("body"))
            let batchID = UUID(), now = Date()
            try connection.execute("INSERT INTO batches (id, selected_count, complete) VALUES (?, ?, 0)",
                                   [.text(batchID.uuidString), .integer(Int64(selected.count))])
            var admitted: [UUID] = []
            for identifier in selected {
                let existing = try connection.rows("""
                    SELECT body FROM operations WHERE namespace = ? AND item = ? AND binding = ?
                    AND desired = 'active' AND delivery != 'imported_verified' AND backup != 'failed'
                    ORDER BY rowid DESC LIMIT 1
                    """, [.text(namespace), .text(identifier), .text(bindingID.uuidString)]).first
                let operation: Operation
                if let existing {
                    var queued = try Self.decode(Operation.self, existing.blob("body"))
                    guard queued.profile == profile else { throw Failure.incompatibleQueuedSettings }
                    if compact, !queued.wantsCompact {
                        queued.wantsCompact = true
                        queued.updatedAt = now
                        try Self.write(queued, connection)
                    }
                    operation = queued
                } else {
                    let previous = try connection.rows("SELECT generation FROM lineages WHERE namespace = ? AND item = ?",
                                                        [.text(namespace), .text(identifier)]).first
                    let oldGeneration = try previous?.integer("generation") ?? 0
                    guard oldGeneration < Int64.max else { throw Failure.unsupportedSchema }
                    let generation = oldGeneration + 1
                    let id = UUID()
                    operation = Operation(id: id, namespace: namespace, itemID: identifier, lineage: generation,
                                          bindingID: bindingID, origin: binding.origin, profile: profile,
                                          wantsCompact: compact, createdAt: now, updatedAt: now)
                    try Self.write(operation, connection)
                    try connection.execute("""
                        INSERT INTO lineages (namespace, item, generation, current_operation)
                        VALUES (?, ?, ?, ?) ON CONFLICT(namespace, item)
                        DO UPDATE SET generation = excluded.generation, current_operation = excluded.current_operation
                        """, [.text(namespace), .text(identifier), .integer(generation), .text(id.uuidString)])
                }
                try connection.execute("INSERT INTO subscriptions (batch, operation) VALUES (?, ?)",
                                       [.text(batchID.uuidString), .text(operation.id.uuidString)])
                admitted.append(operation.id)
            }
            try connection.execute("UPDATE batches SET complete = 1 WHERE id = ?", [.text(batchID.uuidString)])
            return Batch(id: batchID, operationIDs: admitted, selectedCount: selected.count)
        }
    }

    func operation(_ id: UUID) throws -> Operation? {
        try db().read { connection in try Self.operation(id, connection) }
    }

    func operations(limit: Int = 200) throws -> [Operation] {
        guard (1...1_000).contains(limit) else { throw Failure.missingOperation }
        return try db().read { connection in
            try connection.rows("SELECT body FROM operations ORDER BY rowid LIMIT ?", [.integer(Int64(limit))]).map {
                try Self.decode(Operation.self, $0.blob("body"))
            }
        }
    }

    func claim(_ id: UUID, stage: Stage) throws -> Lease? {
        try db().transaction { connection in
            guard var operation = try Self.operation(id, connection) else { throw Failure.missingOperation }
            guard operation.desired == .active, operation.lease == nil else { return nil }
            guard try !connection.rows("SELECT id FROM bindings WHERE id = ? AND retired = 0",
                                       [.text(operation.bindingID.uuidString)]).isEmpty else { throw Failure.retiredBinding }
            switch stage {
            case .preparation: guard operation.backup == .selected else { return nil }
            case .upload:
                guard operation.manifest != nil, operation.backup == .uploading || operation.backup == .verifying else { return nil }
            case .finalization:
                guard operation.receipt?.compact == .ready, operation.delivery != .importedVerified else { return nil }
            }
            let lease = Lease(id: UUID(), operationID: id, epoch: operation.epoch, processID: processID, stage: stage)
            operation.lease = lease
            operation.updatedAt = Date()
            if stage == .preparation { operation.backup = .preparing }
            try Self.write(operation, connection)
            return lease
        }
    }

    func release(_ lease: Lease) throws {
        try db().transaction { connection in
            guard var operation = try Self.operation(lease.operationID, connection) else { throw Failure.missingOperation }
            guard operation.lease == lease else { return }
            operation.lease = nil
            operation.updatedAt = Date()
            try Self.write(operation, connection)
            try connection.execute("DELETE FROM reservations WHERE operation = ? AND stage = 'preparation'",
                                   [.text(operation.id.uuidString)])
        }
    }

    func setDesired(_ desired: Desired, operationID: UUID) throws {
        try db().transaction { connection in
            guard var operation = try Self.operation(operationID, connection) else { throw Failure.missingOperation }
            guard operation.epoch < Int64.max else { throw Failure.unsupportedSchema }
            operation.desired = desired
            operation.bindingPaused = nil
            operation.notBefore = nil
            operation.epoch += 1
            operation.lease = nil
            operation.updatedAt = Date()
            try Self.write(operation, connection)
        }
    }

    func prepared(_ lease: Lease, manifest: BackupAPI.Manifest, resources: [Resource],
                  captureDate: Date? = nil, metadata: Data? = nil) throws {
        _ = try manifest.validated()
        guard lease.stage == .preparation, resources.count == manifest.resources.count,
              resources.allSatisfy({ $0.operationID == lease.operationID && $0.kind == .original }),
              Self.sameResources(resources.map(\.descriptor), manifest.resources) else { throw Failure.invalidReceipt }
        try db().transaction { connection in
            var operation = try Self.checked(lease, connection)
            for resource in resources {
                try connection.execute("INSERT INTO resources (id, operation, kind, size, body) VALUES (?, ?, ?, ?, ?)",
                                       [.text(resource.fileID.uuidString), .text(operation.id.uuidString),
                                        .text(resource.kind.rawValue), .integer(Int64(resource.descriptor.size)),
                                        .blob(try Self.encode(resource))])
                try connection.execute("INSERT INTO file_refs (resource, owner) VALUES (?, ?)",
                                       [.text(resource.fileID.uuidString), .text("operation:" + operation.id.uuidString)])
            }
            operation.manifest = manifest
            operation.request = .init(operationID: operation.id, origin: operation.origin, manifest: manifest,
                                      profile: operation.profile, compact: operation.wantsCompact, captureDate: captureDate)
            operation.metadata = metadata
            operation.backup = .uploading
            operation.lease = nil
            operation.updatedAt = Date()
            try Self.write(operation, connection)
            try connection.execute("DELETE FROM reservations WHERE operation = ? AND stage = 'preparation'",
                                   [.text(operation.id.uuidString)])
        }
    }

    func resources(_ operationID: UUID) throws -> [Resource] {
        try db().read { connection in
            try connection.rows("SELECT body FROM resources WHERE operation = ? ORDER BY rowid",
                                [.text(operationID.uuidString)]).map { try Self.decode(Resource.self, $0.blob("body")) }
        }
    }

    func apply(_ receipt: BackupAPI.Receipt, operationID: UUID, epoch: Int64) throws -> ReceiptApplication {
        try db().transaction { connection in try Self.apply(receipt, operationID: operationID, epoch: epoch, connection) }
    }

    /// Applying a page and advancing its cursor is one transaction.
    func apply(_ page: BackupAPI.Changes, bindingID: UUID) throws {
        _ = try applyChanges(page, bindingID: bindingID)
    }

    func cursor(bindingID: UUID) throws -> Int64 {
        try db().read { connection in
            try connection.rows("SELECT cursor FROM cursors WHERE binding = ?", [.text(bindingID.uuidString)])
                .first?.integer("cursor") ?? 0
        }
    }

    func planImport(_ lease: Lease, expected: [ServerAPI.ResourceDescriptor]) throws -> ImportIntent {
        guard lease.stage == .finalization, !expected.isEmpty,
              expected.allSatisfy({ $0.size > 0 }), Set(expected.map(\.role)).count == expected.count else {
            throw Failure.invalidImport
        }
        return try db().transaction { connection in
            var operation = try Self.checked(lease, connection)
            guard let receipt = operation.receipt, receipt.compact == .ready, let derivative = receipt.derivative,
                  let manifest = operation.manifest else {
                throw Failure.invalidReceipt
            }
            _ = try BackupAPI.Manifest(kind: manifest.kind, resources: expected).validated()
            let serverResources = derivative.resources.map {
                ServerAPI.ResourceDescriptor(role: $0.role, filename: $0.filename, size: $0.size, sha256: $0.sha256)
            }
            let expectedServer = expected.filter { !derivative.deviceCompresses.contains($0.role) }
            guard Self.sameResources(serverResources, expectedServer),
                  Set(expected.map(\.role)) == Set(serverResources.map(\.role) + derivative.deviceCompresses) else {
                throw Failure.invalidImport
            }
            if let old = try connection.rows("SELECT body FROM imports WHERE operation = ?", [.text(operation.id.uuidString)]).first {
                var intent = try Self.decode(ImportIntent.self, old.blob("body"))
                guard intent.phase == .planned, intent.version == receipt.version,
                      intent.generationID == derivative.generationID, Self.sameResources(intent.expected, expected) else {
                    throw Failure.importNeedsReconciliation
                }
                intent.operationEpoch = lease.epoch
                try Self.write(intent, connection)
                return intent
            }
            let intent = ImportIntent(id: UUID(), operationID: operation.id, operationEpoch: lease.epoch,
                                      version: receipt.version, generationID: derivative.generationID,
                                      expected: expected, phase: .planned)
            try Self.write(intent, connection)
            operation.delivery = .importPlanned
            try Self.write(operation, connection)
            return intent
        }
    }

    func startImport(_ id: UUID, lease: Lease) throws {
        try db().transaction { connection in
            _ = try Self.checked(lease, connection)
            guard lease.stage == .finalization, var intent = try Self.intent(id, connection),
                  intent.operationID == lease.operationID, intent.operationEpoch == lease.epoch, intent.phase == .planned else {
                throw Failure.importNeedsReconciliation
            }
            intent.phase = .mutating
            try Self.write(intent, connection)
        }
    }

    /// A successful Photos effect is retained even after cancellation or server switching.
    func importCreated(_ id: UUID, identifier: String) throws {
        guard !identifier.isEmpty else { throw Failure.invalidImport }
        try db().transaction { connection in
            guard var intent = try Self.intent(id, connection) else { throw Failure.importNeedsReconciliation }
            guard intent.createdIdentifier == nil || intent.createdIdentifier == identifier else { throw Failure.invalidImport }
            if intent.phase == .verified { return }
            intent.createdIdentifier = identifier
            intent.phase = .created
            try Self.write(intent, connection)
        }
    }

    func importIntent(_ operationID: UUID) throws -> ImportIntent? {
        try db().read { connection in
            try connection.rows("SELECT body FROM imports WHERE operation = ?", [.text(operationID.uuidString)])
                .first.map { try Self.decode(ImportIntent.self, $0.blob("body")) }
        }
    }

    func finishImport(_ id: UUID, actual: [ServerAPI.ResourceDescriptor], proof: BackupAPI.OriginalProof) throws -> SavedMapping {
        try db().transaction { connection in
            guard var intent = try Self.intent(id, connection), let compactID = intent.createdIdentifier,
                  let operation = try Self.operation(intent.operationID, connection),
                  let manifest = operation.manifest, let receipt = operation.receipt,
                  intent.version == proof.version, receipt.version == proof.version,
                  [.permanent, .deferred, .external].contains(proof.retention),
                  proof.retention != .permanent || proof.claimID != nil,
                  Self.sameResources(intent.expected, actual),
                  Self.proves(manifest, proof.resources) else { throw Failure.invalidImport }
            if intent.phase == .verified {
                guard let row = try connection.rows("SELECT body FROM mappings WHERE intent = ?", [.text(id.uuidString)]).first else {
                    throw Failure.invalidImport
                }
                return try Self.decode(SavedMapping.self, row.blob("body"))
            }
            guard intent.phase == .created || intent.phase == .uncertain else { throw Failure.invalidImport }
            let originalBytes = manifest.resources.reduce(0) { $0 + $1.size }
            let compactBytes = actual.reduce(0) { $0 + $1.size }
            let entry = CompactLedger.Entry(compactIdentifier: compactID, originalBytes: originalBytes,
                                             compactBytes: compactBytes, savedAt: Date(), serverAssetID: proof.version.assetID)
            let mapping = SavedMapping(id: UUID(), namespace: operation.namespace, originalID: operation.itemID,
                                       entry: entry, origin: operation.origin, proof: proof, compactResources: actual, intentID: id)
            try connection.execute("INSERT INTO mappings (id, namespace, original, intent, body) VALUES (?, ?, ?, ?, ?)",
                                   [.text(mapping.id.uuidString), .text(mapping.namespace), .text(mapping.originalID),
                                    .text(id.uuidString), .blob(try Self.encode(mapping))])
            let current = try connection.execute("""
                UPDATE lineages SET current_mapping = ? WHERE namespace = ? AND item = ?
                AND current_operation = ? AND generation = ?
                """, [.text(mapping.id.uuidString), .text(operation.namespace), .text(operation.itemID),
                       .text(operation.id.uuidString), .integer(operation.lineage)]) == 1
            intent.phase = .verified
            try Self.write(intent, connection)
            var completed = operation
            completed.delivery = .importedVerified
            completed.lease = nil
            completed.updatedAt = Date()
            try Self.write(completed, connection)
            try connection.execute("DELETE FROM file_refs WHERE owner = ?", [.text("operation:" + operation.id.uuidString)])
            let acknowledgement = BackupAPI.DeliveryAcknowledgement(deliveryID: id, requestID: receipt.requestID,
                generationID: intent.generationID, version: intent.version)
            try Self.enqueue(.init(id: id, operationID: operation.id, bindingID: operation.bindingID,
                                   kind: .deliveryAcknowledgement, payload: ServerAPI.encoder.encode(acknowledgement)), connection)
            if current {
                try connection.execute("DELETE FROM legacy_backed_up WHERE namespace = ? AND original = ?",
                                       [.text(operation.namespace), .text(operation.itemID)])
            }
            let bindingRow = try connection.rows("SELECT body FROM bindings WHERE id = ?", [.text(operation.bindingID.uuidString)]).first
            guard let bindingRow else { throw Failure.retiredBinding }
            let binding = try Self.decode(Binding.self, bindingRow.blob("body"))
            guard proof.retention != .external || binding.mode == .immich,
                  receipt.retention != .permanent || proof.retention == .permanent else { throw Failure.invalidReceipt }
            let retained = proof.retention == .permanent
                || (proof.retention == .external && binding.mode == .immich && binding.externalVerification == .fullResourceScrub)
            if current, operation.desired == .active, !binding.retired, retained, originalBytes > compactBytes {
                try Self.enqueue(.init(id: UUID(), operationID: operation.id, bindingID: operation.bindingID,
                                       kind: .readyNotification, payload: Data()), connection)
            }
            return mapping
        }
    }

    func outbox(limit: Int = 100, bindingID: UUID? = nil, now: Date = Date()) throws -> [OutboxItem] {
        guard (1...1_000).contains(limit) else { throw Failure.missingOperation }
        return try db().read { connection in
            var values: [BackupDatabase.Value] = [.real(now.timeIntervalSinceReferenceDate)]
            if let bindingID { values.append(.text(bindingID.uuidString)) }
            values.append(.integer(Int64(limit)))
            return try connection.rows("""
                SELECT o.body FROM outbox o
                WHERE (json_extract(CAST(o.body AS TEXT), '$.nextAttempt') IS NULL
                       OR json_extract(CAST(o.body AS TEXT), '$.nextAttempt') <= ?)
                \(bindingID == nil ? "" : "AND json_extract(CAST(o.body AS TEXT), '$.bindingID') = ?")
                AND (json_extract(CAST(o.body AS TEXT), '$.kind') != 'serverCommand' OR NOT EXISTS (
                    SELECT 1 FROM outbox prior WHERE prior.operation = o.operation AND prior.rowid < o.rowid
                    AND json_extract(CAST(prior.body AS TEXT), '$.kind') = 'serverCommand'))
                ORDER BY o.rowid LIMIT ?
                """, values).map {
                try Self.decode(OutboxItem.self, $0.blob("body"))
            }
        }
    }

    func acknowledgeOutbox(_ id: UUID) throws {
        try db().transaction { connection in
            try connection.execute("DELETE FROM outbox WHERE id = ?", [.text(id.uuidString)])
        }
    }

    func decision(_ itemID: String, namespace: String) throws -> Bool {
        try db().read { connection in
            try !connection.rows("SELECT 1 FROM decisions WHERE namespace = ? AND item = ? AND kept = 1",
                                 [.text(namespace), .text(itemID)]).isEmpty
        }
    }

    func mappings(namespace: String) throws -> [String: SavedMapping] {
        try db().read { connection in
            var mappings: [String: SavedMapping] = [:]
            for row in try connection.rows("""
                SELECT m.body FROM mappings m JOIN lineages l ON l.current_mapping = m.id WHERE l.namespace = ?
                """, [.text(namespace)]) {
                let mapping = try Self.decode(SavedMapping.self, row.blob("body"))
                mappings[mapping.originalID] = mapping
            }
            return mappings
        }
    }

    func keepAsIs(_ identifiers: [String], namespace: String, kept: Bool) throws {
        try db().transaction { connection in
            for identifier in identifiers {
                try connection.execute("""
                    INSERT INTO decisions (namespace, item, kept) VALUES (?, ?, ?)
                    ON CONFLICT(namespace, item) DO UPDATE SET kept = excluded.kept
                    """, [.text(namespace), .text(identifier), .integer(kept ? 1 : 0)])
            }
        }
    }

    func readState<Result: Sendable>(_ body: (BackupDatabase.Connection) throws -> Result) throws -> Result {
        try db().read(body)
    }

    func mutateState<Result: Sendable>(_ body: (BackupDatabase.Connection) throws -> Result) throws -> Result {
        try db().transaction(body)
    }

    func close() throws {
        if let database {
            try database.read { connection in
                guard try connection.rows("""
                    SELECT 1 FROM operations WHERE json_extract(CAST(body AS TEXT), '$.lease') IS NOT NULL LIMIT 1
                    """).isEmpty,
                      try connection.rows("SELECT 1 FROM imports WHERE json_extract(CAST(body AS TEXT), '$.phase') = 'mutating' LIMIT 1").isEmpty,
                      try connection.rows("SELECT 1 FROM photo_effects WHERE phase = 'mutating' LIMIT 1").isEmpty else {
                    throw Failure.activeWork
                }
            }
        }
        closed = true
        database = nil
    }

    private func db() throws -> BackupDatabase {
        guard !closed else { throw Failure.storageClosed }
        if let database { return database }
        try files.prepare()
        try files.protectDatabase()
        let opened = try BackupDatabase(url: files.database)
        try Self.schema(opened)
        try Self.migrate(opened, legacyURL: legacyURL, namespace: legacyNamespace)
        try Self.recover(opened, processID: processID)
        try files.protectDatabase()
        database = opened
        return opened
    }

    private static func schema(_ database: BackupDatabase) throws {
        try database.transaction { connection in
            guard let version = try connection.rows("PRAGMA user_version").first?.integer("user_version"),
                  let application = try connection.rows("PRAGMA application_id").first?.integer("application_id"),
                  (0...1).contains(version), application == 0 || application == applicationID else { throw Failure.unsupportedSchema }
            if application == 0 {
                guard version == 0, try connection.rows("SELECT name FROM sqlite_master WHERE type = 'table'").isEmpty else {
                    throw Failure.unsupportedSchema
                }
            }
            for sql in [
                "CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value BLOB NOT NULL)",
                "CREATE TABLE IF NOT EXISTS origins (id TEXT PRIMARY KEY, body BLOB NOT NULL)",
                "CREATE TABLE IF NOT EXISTS bindings (id TEXT PRIMARY KEY, origin TEXT NOT NULL REFERENCES origins(id), retired INTEGER NOT NULL, body BLOB NOT NULL)",
                "CREATE TABLE IF NOT EXISTS batches (id TEXT PRIMARY KEY, selected_count INTEGER NOT NULL, complete INTEGER NOT NULL)",
                "CREATE TABLE IF NOT EXISTS lineages (namespace TEXT NOT NULL, item TEXT NOT NULL, generation INTEGER NOT NULL, current_operation TEXT, current_mapping TEXT, PRIMARY KEY(namespace, item))",
                "CREATE TABLE IF NOT EXISTS operations (id TEXT PRIMARY KEY, namespace TEXT NOT NULL, item TEXT NOT NULL, binding TEXT NOT NULL REFERENCES bindings(id), desired TEXT NOT NULL, backup TEXT NOT NULL, delivery TEXT NOT NULL, body BLOB NOT NULL)",
                "CREATE INDEX IF NOT EXISTS operations_source ON operations(namespace, item, binding)",
                "CREATE TABLE IF NOT EXISTS subscriptions (batch TEXT NOT NULL REFERENCES batches(id), operation TEXT NOT NULL REFERENCES operations(id), PRIMARY KEY(batch, operation))",
                "CREATE TABLE IF NOT EXISTS resources (id TEXT PRIMARY KEY, operation TEXT NOT NULL REFERENCES operations(id), kind TEXT NOT NULL, size INTEGER NOT NULL CHECK(size > 0), body BLOB NOT NULL)",
                "CREATE TABLE IF NOT EXISTS cursors (binding TEXT PRIMARY KEY REFERENCES bindings(id), cursor INTEGER NOT NULL CHECK(cursor >= 0))",
                "CREATE TABLE IF NOT EXISTS imports (id TEXT PRIMARY KEY, operation TEXT NOT NULL UNIQUE REFERENCES operations(id), body BLOB NOT NULL)",
                "CREATE TABLE IF NOT EXISTS mappings (id TEXT PRIMARY KEY, namespace TEXT NOT NULL, original TEXT NOT NULL, intent TEXT UNIQUE, body BLOB NOT NULL)",
                "CREATE TABLE IF NOT EXISTS legacy_backed_up (namespace TEXT NOT NULL, original TEXT NOT NULL, body BLOB NOT NULL, PRIMARY KEY(namespace, original))",
                "CREATE TABLE IF NOT EXISTS decisions (namespace TEXT NOT NULL, item TEXT NOT NULL, kept INTEGER NOT NULL, PRIMARY KEY(namespace, item))",
                "CREATE TABLE IF NOT EXISTS outbox (id TEXT PRIMARY KEY, operation TEXT NOT NULL REFERENCES operations(id), body BLOB NOT NULL)",
                "CREATE TABLE IF NOT EXISTS sessions (id TEXT PRIMARY KEY, binding TEXT NOT NULL REFERENCES bindings(id), identifier TEXT NOT NULL UNIQUE, draining INTEGER NOT NULL, body BLOB NOT NULL)",
                "CREATE TABLE IF NOT EXISTS transfers (id TEXT PRIMARY KEY, operation TEXT NOT NULL REFERENCES operations(id), session TEXT NOT NULL REFERENCES sessions(id), resource TEXT REFERENCES resources(id), task INTEGER, status TEXT NOT NULL, body BLOB NOT NULL, UNIQUE(session, task))",
                "CREATE TABLE IF NOT EXISTS file_refs (resource TEXT NOT NULL REFERENCES resources(id), owner TEXT NOT NULL, PRIMARY KEY(resource, owner))",
                "CREATE TABLE IF NOT EXISTS reservations (id TEXT PRIMARY KEY, operation TEXT NOT NULL REFERENCES operations(id), stage TEXT NOT NULL, body BLOB NOT NULL)",
                "CREATE TABLE IF NOT EXISTS photo_effects (id TEXT PRIMARY KEY, namespace TEXT NOT NULL, item TEXT NOT NULL, kind TEXT NOT NULL, phase TEXT NOT NULL, body BLOB NOT NULL)",
                "CREATE UNIQUE INDEX IF NOT EXISTS photo_effects_active ON photo_effects(namespace, item, kind) WHERE phase IN ('planned', 'mutating', 'uncertain', 'created')",
                "CREATE TABLE IF NOT EXISTS snapshot_runs (id TEXT PRIMARY KEY, binding TEXT NOT NULL REFERENCES bindings(id), body BLOB NOT NULL)",
                "CREATE TABLE IF NOT EXISTS snapshot_receipts (snapshot TEXT NOT NULL REFERENCES snapshot_runs(id), request TEXT NOT NULL, body BLOB NOT NULL, PRIMARY KEY(snapshot, request))",
                "CREATE TABLE IF NOT EXISTS orphan_receipts (binding TEXT NOT NULL REFERENCES bindings(id), request TEXT NOT NULL, body BLOB NOT NULL, PRIMARY KEY(binding, request))",
            ] { try connection.execute(sql) }
            try connection.execute("PRAGMA application_id = \(applicationID)")
            try connection.execute("PRAGMA user_version = 1")
        }
    }

    private static func migrate(_ database: BackupDatabase, legacyURL: URL?, namespace: String) throws {
        let sourceFiles: [LegacyFile]
        var entries: [String: CompactLedger.Entry] = [:]
        var backedUp: [String: CompactLedger.BackedUp] = [:]
        var kept: Set<String> = []
        if let legacyURL {
            let journal = legacyURL.deletingPathExtension().appendingPathExtension("journal")
            let backedUpURL = legacyURL.deletingLastPathComponent().appendingPathComponent("backed-up.json")
            sourceFiles = try [legacyURL, journal, backedUpURL].map { url in
                LegacyFile(name: url.lastPathComponent, sha256: try legacyData(url).map { Fingerprint.sha256(of: $0) })
            }
            if let marker = try database.read({ try $0.rows("SELECT value FROM meta WHERE key = 'legacy_sources'").first }) {
                guard try decode([LegacyFile].self, marker.blob("value")) == sourceFiles else { throw Failure.legacyChanged }
                return
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            do {
                if let data = try legacyData(legacyURL) { entries = try decoder.decode([String: CompactLedger.Entry].self, from: data) }
                if let data = try legacyData(backedUpURL) { backedUp = try decoder.decode([String: CompactLedger.BackedUp].self, from: data) }
                if let data = try legacyData(journal) {
                    let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
                    for (index, line) in lines.enumerated() where !line.isEmpty {
                        let change: LegacyChange
                        do { change = try decoder.decode(LegacyChange.self, from: Data(line)) }
                        catch {
                            guard index == lines.count - 1, data.last != UInt8(ascii: "\n") else { throw error }
                            break
                        }
                        for key in change.remove ?? [] { entries[key] = nil }
                        entries.merge(change.set ?? [:]) { _, latest in latest }
                    }
                }
                let automatic = legacyURL.deletingLastPathComponent().appendingPathComponent("automatic.json")
                if let data = try legacyData(automatic) { kept = try JSONDecoder().decode(LegacyDecisions.self, from: data).keptAsIs ?? [] }
            } catch { throw Failure.legacyUnreadable }
        } else { sourceFiles = [] }
        try database.transaction { connection in
            if let marker = try connection.rows("SELECT value FROM meta WHERE key = 'legacy_sources'").first {
                guard try decode([LegacyFile].self, marker.blob("value")) == sourceFiles else { throw Failure.legacyChanged }
                return
            }
            for (original, entry) in entries {
                let mapping = SavedMapping(id: UUID(), namespace: namespace, originalID: original, entry: entry)
                try connection.execute("INSERT INTO mappings (id, namespace, original, body) VALUES (?, ?, ?, ?)",
                                       [.text(mapping.id.uuidString), .text(namespace), .text(original), .blob(try encode(mapping))])
                try connection.execute("INSERT INTO lineages (namespace, item, generation, current_mapping) VALUES (?, ?, 0, ?)",
                                       [.text(namespace), .text(original), .text(mapping.id.uuidString)])
            }
            for (original, entry) in backedUp where entries[original] == nil {
                try connection.execute("INSERT INTO legacy_backed_up (namespace, original, body) VALUES (?, ?, ?)",
                                       [.text(namespace), .text(original), .blob(try encode(entry))])
            }
            for item in kept {
                try connection.execute("INSERT INTO decisions (namespace, item, kept) VALUES (?, ?, 1)",
                                       [.text(namespace), .text(item)])
            }
            try connection.execute("INSERT INTO meta (key, value) VALUES ('legacy_sources', ?)", [.blob(try encode(sourceFiles))])
        }
    }

    private static func recover(_ database: BackupDatabase, processID: UUID) throws {
        try database.transaction { connection in
            let marker = try connection.rows("SELECT value FROM meta WHERE key = 'process'").first
            if let marker, try decode(UUID.self, marker.blob("value")) == processID { return }
            for row in try connection.rows("SELECT body FROM operations") {
                var operation = try decode(Operation.self, row.blob("body"))
                if operation.lease != nil {
                    operation.lease = nil
                    if operation.backup == .preparing { operation.backup = .selected }
                    try write(operation, connection)
                }
            }
            for row in try connection.rows("SELECT body FROM imports") {
                var intent = try decode(ImportIntent.self, row.blob("body"))
                if intent.phase == .mutating {
                    intent.phase = .uncertain
                    try write(intent, connection)
                    if var operation = try operation(intent.operationID, connection) {
                        operation.delivery = .uncertain
                        try write(operation, connection)
                    }
                }
                for row in try connection.rows("SELECT t.body FROM transfers t JOIN sessions s ON s.id = t.session") {
                    var transfer = try decode(Transfer.self, row.blob("body"))
                    guard !transfer.state.terminal, transfer.state != .intent else { continue }
                    transfer.state = .unknown
                    try write(transfer, connection)
                }
                try connection.execute("DELETE FROM reservations WHERE stage IN ('preparation', 'finalization')")
                try connection.execute("""
                    UPDATE photo_effects SET phase = 'uncertain',
                    body = CAST(json_set(CAST(body AS TEXT), '$.phase', 'uncertain') AS BLOB)
                    WHERE phase = 'mutating'
                    """)
            }
            try connection.execute("""
                INSERT INTO meta (key, value) VALUES ('process', ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """, [.blob(try encode(processID))])
        }
    }

    private static func legacyData(_ url: URL) throws -> Data? {
        do { return try Data(contentsOf: url) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
    }

    private static func originKey(_ origin: BackupAPI.Origin) -> String {
        Fingerprint.sha256(of: Data(("homespun.origin.v1\n" + origin.serverID + "\n" + origin.historyEpoch).utf8))
    }

    static func operation(_ id: UUID, _ connection: BackupDatabase.Connection) throws -> Operation? {
        try connection.rows("SELECT body FROM operations WHERE id = ?", [.text(id.uuidString)])
            .first.map { try decode(Operation.self, $0.blob("body")) }
    }

    static func checked(_ lease: Lease, _ connection: BackupDatabase.Connection) throws -> Operation {
        guard let operation = try operation(lease.operationID, connection), operation.lease == lease,
              operation.epoch == lease.epoch, operation.desired == .active else { throw Failure.staleOperation }
        return operation
    }

    static func write(_ operation: Operation, _ connection: BackupDatabase.Connection) throws {
        try connection.execute("""
            INSERT INTO operations (id, namespace, item, binding, desired, backup, delivery, body)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET
            binding = excluded.binding, desired = excluded.desired, backup = excluded.backup,
            delivery = excluded.delivery, body = excluded.body
            """, [.text(operation.id.uuidString), .text(operation.namespace), .text(operation.itemID),
                   .text(operation.bindingID.uuidString), .text(operation.desired.rawValue), .text(operation.backup.rawValue),
                   .text(operation.delivery.rawValue), .blob(try encode(operation))])
    }

    static func apply(_ receipt: BackupAPI.Receipt, operationID: UUID, epoch: Int64,
                              _ connection: BackupDatabase.Connection) throws -> ReceiptApplication {
        guard var operation = try operation(operationID, connection), operation.epoch == epoch,
              operation.origin == receipt.version.origin, receipt.operationID == operation.id,
              let manifest = operation.manifest, try manifest.identifier() == receipt.version.manifestID,
              try manifest.assetID() == receipt.version.assetID, receipt.version.descriptorGeneration > 0,
              receipt.revision > 0 else { throw Failure.invalidReceipt }
        if let previous = operation.receipt {
            guard previous.requestID == receipt.requestID, previous.version == receipt.version else { throw Failure.invalidReceipt }
            if receipt.revision < previous.revision { return .stale }
            if receipt.revision == previous.revision {
                guard receipt == previous else { throw Failure.conflictingReceipt }
                return .stale
            }
            guard let bindingRow = try connection.rows("SELECT body FROM bindings WHERE id = ?",
                                                       [.text(operation.bindingID.uuidString)]).first else {
                throw Failure.retiredBinding
            }
            let binding = try decode(Binding.self, bindingRow.blob("body"))
            guard receipt.retention != .external || binding.mode == .immich else { throw Failure.invalidReceipt }
        }
        if receipt.backup == .retained {
            guard [.permanent, .deferred, .external].contains(receipt.retention),
                  proves(manifest, receipt.originals) else { throw Failure.invalidReceipt }
        }
        guard receipt.compact != .ready || receipt.derivative != nil else { throw Failure.invalidReceipt }
        if let derivative = receipt.derivative {
            guard derivative.version == receipt.version, !derivative.resources.isEmpty else { throw Failure.invalidReceipt }
        }
        operation.receipt = receipt
        operation.backup = receipt.backup
        operation.compact = receipt.compact
        operation.updatedAt = Date()
        try write(operation, connection)
        return .applied
    }

    private static func intent(_ id: UUID, _ connection: BackupDatabase.Connection) throws -> ImportIntent? {
        try connection.rows("SELECT body FROM imports WHERE id = ?", [.text(id.uuidString)])
            .first.map { try decode(ImportIntent.self, $0.blob("body")) }
    }

    private static func write(_ intent: ImportIntent, _ connection: BackupDatabase.Connection) throws {
        try connection.execute("""
            INSERT INTO imports (id, operation, body) VALUES (?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET body = excluded.body
            """, [.text(intent.id.uuidString), .text(intent.operationID.uuidString), .blob(try encode(intent))])
    }

    private static func enqueue(_ item: OutboxItem, _ connection: BackupDatabase.Connection) throws {
        try connection.execute("INSERT OR IGNORE INTO outbox (id, operation, body) VALUES (?, ?, ?)",
                               [.text(item.id.uuidString), .text(item.operationID.uuidString), .blob(try encode(item))])
    }

    private static func sameResources(_ left: [ServerAPI.ResourceDescriptor], _ right: [ServerAPI.ResourceDescriptor]) -> Bool {
        guard !left.isEmpty, left.count == right.count, Set(left.map(\.role)).count == left.count,
              Set(right.map(\.role)).count == right.count else { return false }
        return left.allSatisfy { resource in
            right.contains { $0.role == resource.role && $0.size == resource.size && $0.sha256.lowercased() == resource.sha256.lowercased() }
        }
    }

    private static func proves(_ manifest: BackupAPI.Manifest, _ resources: [ServerAPI.ResourceStatus]) -> Bool {
        guard resources.count == manifest.resources.count, resources.allSatisfy({
            $0.state == .verified && $0.verifiedAt != nil && $0.receivedBytes == $0.size && $0.size > 0
        }) else { return false }
        return sameResources(manifest.resources, resources.map {
            .init(role: $0.role, filename: "", size: $0.size, sha256: $0.sha256)
        })
    }

    static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    static func decode<Value: Decodable>(_ type: Value.Type, _ data: Data) throws -> Value {
        try JSONDecoder().decode(type, from: data)
    }
}

extension BackupStore.Operation {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        namespace = try values.decode(String.self, forKey: .namespace)
        itemID = try values.decode(String.self, forKey: .itemID)
        lineage = try values.decode(Int64.self, forKey: .lineage)
        bindingID = try values.decode(UUID.self, forKey: .bindingID)
        origin = try values.decode(BackupAPI.Origin.self, forKey: .origin)
        epoch = try values.decode(Int64.self, forKey: .epoch)
        desired = try values.decode(BackupStore.Desired.self, forKey: .desired)
        backup = try values.decode(BackupAPI.BackupState.self, forKey: .backup)
        compact = try values.decode(BackupAPI.CompactState.self, forKey: .compact)
        delivery = try values.decode(BackupAPI.DeliveryState.self, forKey: .delivery)
        profile = try values.decode(CompressionProfile.self, forKey: .profile)
        wantsCompact = try values.decode(Bool.self, forKey: .wantsCompact)
        manifest = try values.decodeIfPresent(BackupAPI.Manifest.self, forKey: .manifest)
        request = try values.decodeIfPresent(BackupAPI.Request.self, forKey: .request)
        metadata = try values.decodeIfPresent(Data.self, forKey: .metadata)
        receipt = try values.decodeIfPresent(BackupAPI.Receipt.self, forKey: .receipt)
        lease = try values.decodeIfPresent(BackupStore.Lease.self, forKey: .lease)
        attention = try values.decodeIfPresent(Bool.self, forKey: .attention) ?? false
        problem = try values.decodeIfPresent(BackupStore.Problem.self, forKey: .problem)
        bindingPaused = try values.decodeIfPresent(Bool.self, forKey: .bindingPaused)
        notBefore = try values.decodeIfPresent(Date.self, forKey: .notBefore)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
    }
}
