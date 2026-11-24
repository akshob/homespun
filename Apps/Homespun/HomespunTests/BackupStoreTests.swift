// SPDX-License-Identifier: Apache-2.0
import Foundation
import HomespunCore
import Testing
@testable import Homespun

private struct BackupStoreFixture {
    let directory: URL
    let store: BackupStore
    let binding: BackupStore.Binding
    let operationID: UUID
    let original: ServerAPI.ResourceDescriptor
    let compact: ServerAPI.ResourceDescriptor
    let receipt: BackupAPI.Receipt

    static func make(processID: UUID? = nil) async throws -> Self {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = BackupStore(directory: directory, legacyURL: nil, processID: processID)
        let binding = BackupStore.Binding(id: UUID(),
            origin: .init(serverID: UUID().uuidString, historyEpoch: UUID().uuidString),
            trustEpoch: UUID(), baseURL: URL(string: "https://server.invalid")!, keychainReference: "test-reference")
        try await store.bind(binding)
        let batch = try await store.admit(["item"], namespace: "photos", bindingID: binding.id, profile: .standard, compact: true)
        let operationID = try #require(batch.operationIDs.first)
        let lease = try #require(try await store.claim(operationID, stage: .preparation))
        let originalData = Data("original".utf8), compactData = Data("c".utf8)
        let original = ServerAPI.ResourceDescriptor(role: .photo, filename: "original.heic",
            size: originalData.count, sha256: Fingerprint.sha256(of: originalData))
        let compact = ServerAPI.ResourceDescriptor(role: .photo, filename: "compact.heic",
            size: compactData.count, sha256: Fingerprint.sha256(of: compactData))
        let resource = BackupStore.Resource(fileID: UUID(), operationID: operationID, kind: .original, descriptor: original)
        _ = try store.files.prepareStaging(operationID: operationID)
        try originalData.write(to: store.files.stagedFile(operationID: operationID, fileID: resource.fileID))
        let manifest = BackupAPI.Manifest(kind: .photo, resources: [original])
        try await store.prepared(lease, manifest: manifest, resources: [resource])
        let recipe = BackupAPI.Recipe(profile: .standard, backend: "test", pipelineVersion: 1)
        let version = BackupAPI.Version(origin: binding.origin, assetID: try manifest.assetID(),
            manifestID: try manifest.identifier(), descriptorGeneration: 1, recipeID: try recipe.identifier())
        let receipt = BackupAPI.Receipt(requestID: UUID(), operationID: operationID, version: version, revision: 1,
            backup: .retained, compact: .ready, retention: .permanent, originals: [
                .init(role: .photo, sha256: original.sha256, size: original.size, state: .verified,
                      receivedBytes: original.size, verifiedAt: Date(timeIntervalSince1970: 1_000)),
            ], derivative: .init(generationID: UUID(), version: version, resources: [
                .init(role: .photo, filename: compact.filename, size: compact.size, sha256: compact.sha256),
            ]))
        _ = try await store.apply(receipt, operationID: operationID, epoch: lease.epoch)
        return Self(directory: directory, store: store, binding: binding, operationID: operationID,
                    original: original, compact: compact, receipt: receipt)
    }

    var proof: BackupAPI.OriginalProof {
        .init(version: receipt.version, retention: .permanent, claimID: UUID(),
              verifiedAt: Date(timeIntervalSince1970: 1_001), resources: receipt.originals)
    }
}

@Test func durableAdmissionDeduplicatesAndSurvivesReopening() async throws {
    let fixture = try await BackupStoreFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let batch = try await fixture.store.admit(["item", "item", "second"], namespace: "photos",
        bindingID: fixture.binding.id, profile: .standard, compact: true)
    #expect(batch.selectedCount == 2)
    #expect(batch.operationIDs.first == fixture.operationID)
    let reopened = BackupStore(directory: fixture.directory, legacyURL: nil)
    let operations = try await reopened.operations()
    #expect(Set(operations.map(\.itemID)) == ["item", "second"])
    var differentQuality = CompressionProfile.standard
    differentQuality.photoQuality = 90
    await #expect(throws: BackupStore.Failure.incompatibleQueuedSettings) {
        try await reopened.admit(["third", "item"], namespace: "photos", bindingID: fixture.binding.id,
                                 profile: differentQuality, compact: true)
    }
    let afterFailure = try await reopened.operations()
    #expect(Set(afterFailure.map(\.itemID)) == ["item", "second"])
}

@Test func cancelledPreparationCannotPublishFromItsOldEpoch() async throws {
    let fixture = try await BackupStoreFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let batch = try await fixture.store.admit(["second"], namespace: "photos", bindingID: fixture.binding.id,
                                              profile: .standard, compact: true)
    let id = try #require(batch.operationIDs.first)
    let lease = try #require(try await fixture.store.claim(id, stage: .preparation))
    try await fixture.store.setDesired(.cancelled, operationID: id)
    let resource = BackupStore.Resource(fileID: UUID(), operationID: id, kind: .original, descriptor: fixture.original)
    await #expect(throws: BackupStore.Failure.staleOperation) {
        try await fixture.store.prepared(lease, manifest: .init(kind: .photo, resources: [fixture.original]), resources: [resource])
    }
    #expect(try await fixture.store.resources(id).isEmpty)
    #expect(try await fixture.store.operation(id)?.desired == .cancelled)
}

@Test func resultPagesAndCursorsCommitTogetherAndIgnoreOldReceiptRevisions() async throws {
    let fixture = try await BackupStoreFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    var newer = fixture.receipt
    newer.revision = 2
    newer.compact = .failed
    newer.derivative = nil
    let page = BackupAPI.Changes(origin: fixture.binding.origin, cursor: 5, hasMore: false,
        changes: [.init(sequence: 5, receipt: newer)])
    try await fixture.store.apply(page, bindingID: fixture.binding.id)
    #expect(try await fixture.store.apply(fixture.receipt, operationID: fixture.operationID, epoch: 1) == .stale)
    #expect(try await fixture.store.operation(fixture.operationID)?.receipt == newer)

    var next = newer
    next.revision = 3
    next.compact = .queued
    var wrongEpoch = next
    wrongEpoch.revision = 4
    wrongEpoch.version.origin.historyEpoch = UUID().uuidString
    let invalid = BackupAPI.Changes(origin: fixture.binding.origin, cursor: 7, hasMore: false, changes: [
        .init(sequence: 6, receipt: next), .init(sequence: 7, receipt: wrongEpoch),
    ])
    await #expect(throws: BackupStore.Failure.invalidReceipt) {
        try await fixture.store.apply(invalid, bindingID: fixture.binding.id)
    }
    #expect(try await fixture.store.cursor(bindingID: fixture.binding.id) == 5)
    #expect(try await fixture.store.operation(fixture.operationID)?.receipt == newer)
}

@Test func interruptedPhotosMutationBecomesUncertainAndCannotReimportBlindly() async throws {
    let fixture = try await BackupStoreFixture.make(processID: UUID())
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let lease = try #require(try await fixture.store.claim(fixture.operationID, stage: .finalization))
    let intent = try await fixture.store.planImport(lease, expected: [fixture.compact])
    try await fixture.store.startImport(intent.id, lease: lease)
    let reopened = BackupStore(directory: fixture.directory, legacyURL: nil, processID: UUID())
    try await reopened.open()
    #expect(try await reopened.importIntent(fixture.operationID)?.phase == .uncertain)
    let resumed = try #require(try await reopened.claim(fixture.operationID, stage: .finalization))
    await #expect(throws: BackupStore.Failure.importNeedsReconciliation) {
        try await reopened.planImport(resumed, expected: [fixture.compact])
    }
}

@Test func successfulPhotosFactSurvivesCancellationWithoutReplacingNewerLineage() async throws {
    let fixture = try await BackupStoreFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let lease = try #require(try await fixture.store.claim(fixture.operationID, stage: .finalization))
    let intent = try await fixture.store.planImport(lease, expected: [fixture.compact])
    try await fixture.store.startImport(intent.id, lease: lease)
    try await fixture.store.setDesired(.cancelled, operationID: fixture.operationID)
    _ = try await fixture.store.admit(["item"], namespace: "photos", bindingID: fixture.binding.id,
                                      profile: .standard, compact: true)
    try await fixture.store.importCreated(intent.id, identifier: "created-before-cancellation")
    let mapping = try await fixture.store.finishImport(intent.id, actual: [fixture.compact], proof: fixture.proof)
    #expect(mapping.entry.compactIdentifier == "created-before-cancellation")
    #expect(try await fixture.store.mappings(namespace: "photos").isEmpty)
    let outbox = try await fixture.store.outbox()
    #expect(outbox.map(\.kind) == [.deliveryAcknowledgement])
    let repeated = try await fixture.store.finishImport(intent.id, actual: [fixture.compact], proof: fixture.proof)
    #expect(repeated == mapping)
}

@Test func legacyMigrationPreservesUnknownOriginAndExplicitDecisionsWithoutRewritingFiles() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let legacy = root.appendingPathComponent("ledger.json")
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let entry = CompactLedger.Entry(compactIdentifier: "legacy-compact", originalBytes: 100, compactBytes: 20,
                                    savedAt: Date(timeIntervalSince1970: 1_000), serverAssetID: "legacy-asset")
    let data = try encoder.encode(["legacy-item": entry])
    try data.write(to: legacy)
    let automatic = root.appendingPathComponent("automatic.json")
    try JSONSerialization.data(withJSONObject: ["keptAsIs": ["explicit-keep"]]).write(to: automatic)
    let directory = root.appendingPathComponent("Backup")
    let store = BackupStore(directory: directory, legacyURL: legacy)
    try await store.open()
    let mapping = try #require(try await store.mappings(namespace: "photos")["legacy-item"])
    #expect(mapping.entry == entry)
    #expect(mapping.origin == nil && mapping.proof == nil)
    #expect(try await store.decision("explicit-keep", namespace: "photos"))
    #expect(try Data(contentsOf: legacy) == data)
    let reopened = BackupStore(directory: directory, legacyURL: legacy)
    #expect(try await reopened.mappings(namespace: "photos")["legacy-item"]?.id == mapping.id)
    try encoder.encode(["changed-by-older-app": entry]).write(to: legacy)
    let afterDowngrade = BackupStore(directory: directory, legacyURL: legacy)
    await #expect(throws: BackupStore.Failure.legacyChanged) { try await afterDowngrade.open() }
}
