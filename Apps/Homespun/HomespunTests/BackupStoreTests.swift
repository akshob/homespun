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

    static func make(processID: UUID? = nil, consumerID: String? = nil,
                     mode: ServerAPI.StorageMode = .files, compactNow: Bool = true,
                     applyReceipt: Bool = true) async throws -> Self {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = BackupStore(directory: directory, legacyURL: nil, processID: processID)
        let binding = BackupStore.Binding(id: UUID(),
            origin: .init(serverID: UUID().uuidString, historyEpoch: UUID().uuidString),
            trustEpoch: UUID(), baseURL: URL(string: "https://server.invalid")!, keychainReference: "test-reference",
            mode: mode, consumerID: consumerID)
        try await store.bind(binding)
        let batch = try await store.admit(["item"], namespace: "photos", bindingID: binding.id,
                                         profile: .standard, compact: compactNow)
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
        if applyReceipt { _ = try await store.apply(receipt, operationID: operationID, epoch: lease.epoch) }
        return Self(directory: directory, store: store, binding: binding, operationID: operationID,
                    original: original, compact: compact, receipt: receipt)
    }

    var proof: BackupAPI.OriginalProof {
        .init(version: receipt.version, retention: .permanent, claimID: UUID(),
              verifiedAt: Date(timeIntervalSince1970: 1_001), resources: receipt.originals)
    }
}

private enum PhotoHandoffTestFailure: Error, Equatable { case interrupted }

@Test func existingCopyAdoptionPersistsCanonicalProofWithoutInventingAnImportAndReusesItsIntentAfterRestart() async throws {
    let fixture = try await BackupStoreFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let manifest = BackupAPI.Manifest(kind: .photo, resources: [fixture.original])
    let compact = BackupAPI.Manifest(kind: .photo, resources: [fixture.compact])
    let candidate = BackupAPI.CopyCandidate(origin: fixture.binding.origin, manifest: manifest)
    // Unknown historical provenance is preserved, rather than overwritten with the current URL.
    let ledger = CompactLedger(store: fixture.store)
    let key = CompactLedger.elsewhere("found-copy")
    let historical = "old-installation-original"
    try await ledger.record(original: historical, compact: "found-copy", originalBytes: fixture.original.size,
                            compactBytes: fixture.compact.size, serverAssetID: fixture.receipt.version.assetID)
    let operation = try await fixture.store.planCopyAdoption(compactID: "found-copy", originalID: nil,
        candidate: candidate, compact: compact, bindingID: fixture.binding.id, namespace: "photos", profile: .standard)
    #expect(try await fixture.store.deviceRunnable(.upload, binding: fixture.binding, namespace: "photos").isEmpty)
    #expect(try await ledger.entry(for: historical)?.verifiedCompact == false)
    try await fixture.store.close()
    let reopened = BackupStore(directory: fixture.directory, legacyURL: nil)
    let resumed = try await reopened.planCopyAdoption(compactID: "found-copy", originalID: nil,
        candidate: candidate, compact: compact, bindingID: fixture.binding.id, namespace: "photos", profile: .standard)
    #expect(resumed.id == operation.id)
    var receipt = fixture.receipt
    receipt.operationID = operation.id
    receipt.compact = .requested
    receipt.derivative = nil
    var proof = fixture.proof
    proof.verifiedAt = Date()
    var changed = fixture.compact
    changed.size += 1
    await #expect(throws: BackupStore.Failure.invalidImport) {
        try await reopened.finishCopyAdoption(operation.id, epoch: operation.epoch,
            receipt: receipt, proof: proof, actual: [changed])
    }
    var changedOriginal = proof
    changedOriginal.resources[0].sha256 = String(repeating: "f", count: 64)
    await #expect(throws: BackupStore.Failure.invalidImport) {
        try await reopened.finishCopyAdoption(operation.id, epoch: operation.epoch,
            receipt: receipt, proof: changedOriginal, actual: [fixture.compact])
    }
    try await reopened.finishCopyAdoption(operation.id, epoch: operation.epoch,
        receipt: receipt, proof: proof, actual: [fixture.compact])
    let restoredLedger = CompactLedger(store: reopened)
    let entry = try #require(try await restoredLedger.entry(for: key))
    #expect(entry.verifiedCompact && entry.origin == fixture.binding.origin && entry.requestID == receipt.requestID)
    #expect(entry.operationID == operation.id && entry.bindingID == fixture.binding.id && entry.revalidatedCopy == true)
    #expect(entry.compactResources == [fixture.compact])
    let anotherPrincipal = await CopyFinder.known([key: entry], origin: fixture.binding.origin, bindingID: UUID())
    #expect(anotherPrincipal.isEmpty)
    #expect(try await restoredLedger.entry(for: historical) == nil)
    #expect(try await reopened.importIntent(operation.id) == nil)
    #expect(try await reopened.outbox().isEmpty)
    let mapping = try #require(try await reopened.mappings(namespace: "photos")[key])
    try await reopened.finishCopyAdoption(operation.id, epoch: operation.epoch,
        receipt: receipt, proof: proof, actual: [fixture.compact])
    #expect(try await reopened.mappings(namespace: "photos")[key]?.id == mapping.id)
    #expect(try await reopened.operations().count == 2)
    let history = try await reopened.readState { connection in
        try connection.rows("SELECT body FROM mappings WHERE json_extract(CAST(body AS TEXT),'$.entry.compactIdentifier') = ?",
                            [.text("found-copy")])
            .map { try BackupStore.decode(BackupStore.SavedMapping.self, $0.blob("body")) }
    }
    #expect(history.count == 2 && history.contains { $0.origin == nil && $0.proof == nil })
    try await reopened.close()
}

@Test func existingCopyAdoptionCannotFinishAcrossRetirementOrABindingRoundTrip() async throws {
    let fixture = try await BackupStoreFixture.make(consumerID: "same-device")
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let operation = try await fixture.store.planCopyAdoption(compactID: "found-copy", originalID: nil,
        candidate: .init(origin: fixture.binding.origin, manifest: .init(kind: .photo, resources: [fixture.original])),
        compact: .init(kind: .photo, resources: [fixture.compact]), bindingID: fixture.binding.id,
        namespace: "photos", profile: .standard)
    var receipt = fixture.receipt
    receipt.operationID = operation.id
    var proof = fixture.proof
    proof.verifiedAt = Date()
    try await fixture.store.retireBinding(fixture.binding.id)
    var away = fixture.binding
    away.id = UUID()
    away.origin = .init(serverID: UUID().uuidString, historyEpoch: UUID().uuidString)
    away.trustEpoch = UUID()
    try await fixture.store.bind(away)
    await #expect(throws: BackupStore.Failure.invalidImport) {
        try await fixture.store.finishCopyAdoption(operation.id, epoch: operation.epoch,
            receipt: receipt, proof: proof, actual: [fixture.compact])
    }
    try await fixture.store.retireBinding(away.id)
    var new = fixture.binding
    new.id = UUID()
    new.trustEpoch = UUID()
    try await fixture.store.bind(new)
    try await fixture.store.reattach(from: fixture.binding.id, to: new.id)
    await #expect(throws: BackupStore.Failure.invalidImport) {
        try await fixture.store.finishCopyAdoption(operation.id, epoch: operation.epoch,
            receipt: receipt, proof: proof, actual: [fixture.compact])
    }
    #expect(try await fixture.store.mappings(namespace: "photos").isEmpty)
}

private func photoHandoffWorkspace(_ store: BackupStore) -> BackupWorkspace {
    .init(store: store, policy: .init(maximumTransientBytes: 1_000_000, minimumAvailableBytes: 0,
                                    finalizationReserveBytes: 100_000, maximumTransfers: 2))
}

private func abandonedPhotoHandoff(_ files: BackupFiles, operationID: UUID,
                                   resource: PreparedPhotoResource) throws -> (directory: URL, alias: URL) {
    let root = files.staging.appendingPathComponent(PhotoResourceHandoff.folderName, isDirectory: true)
    try BackupFiles.prepareTransientDirectory(root)
    let directory = root.appendingPathComponent(operationID.uuidString + "." + UUID().uuidString, isDirectory: true)
    try BackupFiles.prepareTransientDirectory(directory)
    let alias = directory.appendingPathComponent(resource.fileID.uuidString).appendingPathExtension("heic")
    try FileManager.default.linkItem(at: resource.url, to: alias)
    return (directory, alias)
}

@Test func photosHandoffPinsTypedLinksThroughTheTransactionWithoutDoubleCountingPayload() async throws {
    let fixture = try await BackupStoreFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let stored = try await fixture.store.resources(fixture.operationID)
    let original = try #require(stored.first)
    let files = fixture.store.files
    let resource = PreparedPhotoResource(fileID: original.fileID,
        url: files.stagedFile(operationID: fixture.operationID, fileID: original.fileID), descriptor: original.descriptor)
    let before = try files.spaceObservation()
    let workspace = photoHandoffWorkspace(fixture.store)
    let created = try await PhotoResourceHandoff.use([resource]) { resources in
        let handed = try #require(resources.first)
        #expect(handed.fileID == resource.fileID && handed.descriptor == resource.descriptor && handed.url != resource.url)
        #expect(handed.url.pathExtension == "heic")
        #expect(try PhotoResourceHandoff.file(handed.url).identity == PhotoResourceHandoff.file(resource.url).identity)
        let during = try files.spaceObservation()
        #expect(during.transientBytes == before.transientBytes)
        #expect(try handed.url.deletingLastPathComponent().resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        let recovery = try await workspace.reconcileInbox()
        #expect(recovery.problems.isEmpty)
        await Task.yield()
        #expect(FileManager.default.fileExists(atPath: handed.url.path))
        return "created-synthetic-item"
    }
    #expect(created == "created-synthetic-item")
    #expect(try PhotoResourceHandoff.orphans(in: files.staging).isEmpty)
    await #expect(throws: PhotoHandoffTestFailure.interrupted) {
        try await PhotoResourceHandoff.use([resource]) { _ in throw PhotoHandoffTestFailure.interrupted }
    }
    #expect(try PhotoResourceHandoff.orphans(in: files.staging).isEmpty)
    let retained = try Fingerprint.digests(of: resource.url)
    #expect(retained.sha256 == resource.descriptor.sha256 && retained.size == resource.descriptor.size)
}

@Test func photosHandoffLinkFailureKeepsTheCanonicalInputAndDoesNotInvokePhotos() async throws {
    let fixture = try await BackupStoreFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let stored = try await fixture.store.resources(fixture.operationID)
    let original = try #require(stored.first)
    let files = fixture.store.files
    let resource = PreparedPhotoResource(fileID: original.fileID,
        url: files.stagedFile(operationID: fixture.operationID, fileID: original.fileID), descriptor: original.descriptor)
    let missingID = UUID()
    let missing = PreparedPhotoResource(fileID: missingID,
        url: files.stagedFile(operationID: fixture.operationID, fileID: missingID), descriptor: original.descriptor)
    await #expect(throws: (any Error).self) {
        try await PhotoResourceHandoff.use([resource, missing]) { _ in
            Issue.record("Photos must not be invoked after a resource linkage failure.")
            return "unexpected-item"
        }
    }
    #expect(try PhotoResourceHandoff.orphans(in: files.staging).isEmpty)
    let retained = try Fingerprint.digests(of: resource.url)
    #expect(retained.sha256 == resource.descriptor.sha256 && retained.size == resource.descriptor.size)
}

@Test func photosHandoffCleanupFailureRetainsTheKnownCreationIdentifierAndOriginal() async throws {
    let fixture = try await BackupStoreFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let stored = try await fixture.store.resources(fixture.operationID)
    let original = try #require(stored.first)
    let files = fixture.store.files
    let resource = PreparedPhotoResource(fileID: original.fileID,
        url: files.stagedFile(operationID: fixture.operationID, fileID: original.fileID), descriptor: original.descriptor)
    do {
        _ = try await PhotoResourceHandoff.use([resource]) { resources in
            let handed = try #require(resources.first)
            try FileManager.default.removeItem(at: handed.url)
            try Data("unexpected replacement".utf8).write(to: handed.url)
            return "known-Photos-creation"
        }
        Issue.record("An unproven alias must not be removed or reported as a clean completion.")
    } catch let failure as PhotosCreationFailure {
        #expect(failure.identifier == "known-Photos-creation")
    }
    let retained = try Fingerprint.digests(of: resource.url)
    #expect(retained.sha256 == resource.descriptor.sha256 && retained.size == resource.descriptor.size)
    let recovery = try await photoHandoffWorkspace(fixture.store).reconcileInbox()
    #expect(!recovery.problems.isEmpty)
    #expect(try PhotoResourceHandoff.orphans(in: files.staging).count == 1)
}

@Test func photosHandoffRecoveryPreservesUncertainImportThenCleansBeforeReleasingCanonicalFiles() async throws {
    let fixture = try await BackupStoreFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let stored = try await fixture.store.resources(fixture.operationID)
    let original = try #require(stored.first)
    let files = fixture.store.files
    let resource = PreparedPhotoResource(fileID: original.fileID,
        url: files.stagedFile(operationID: fixture.operationID, fileID: original.fileID), descriptor: original.descriptor)
    let lease = try #require(try await fixture.store.claim(fixture.operationID, stage: .finalization))
    let intent = try await fixture.store.planImport(lease, expected: [fixture.compact])
    try await fixture.store.startImport(intent.id, lease: lease)
    let abandoned = try abandonedPhotoHandoff(files, operationID: fixture.operationID, resource: resource)
    try await fixture.store.importUncertain(intent.id)
    let reopened = BackupStore(directory: fixture.directory, legacyURL: nil)
    let workspace = photoHandoffWorkspace(reopened)
    let recovery = try await workspace.reconcileInbox()
    #expect(recovery.problems.isEmpty)
    #expect(FileManager.default.fileExists(atPath: abandoned.alias.path))
    #expect(FileManager.default.fileExists(atPath: resource.url.path))
    #expect(try await reopened.importIntent(fixture.operationID)?.phase == .uncertain)
    try await reopened.importCreated(intent.id, identifier: "reconciled-synthetic-import")
    _ = try await reopened.finishImport(intent.id, actual: [fixture.compact], proof: fixture.proof)
    try await workspace.collectReleasedFiles()
    #expect(!FileManager.default.fileExists(atPath: abandoned.directory.path))
    #expect(!FileManager.default.fileExists(atPath: resource.url.path))
    let remaining = try await reopened.resources(fixture.operationID)
    #expect(remaining.first?.availability == .removed)
}

@Test func photosHandoffRecoveryWaitsForTheRestoreJournalToBeVerified() async throws {
    let fixture = try await BackupStoreFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let stored = try await fixture.store.resources(fixture.operationID)
    let original = try #require(stored.first)
    let files = fixture.store.files
    let resource = PreparedPhotoResource(fileID: original.fileID,
        url: files.stagedFile(operationID: fixture.operationID, fileID: original.fileID), descriptor: original.descriptor)
    let lease = try #require(try await fixture.store.claim(fixture.operationID, stage: .finalization))
    let intent = try await fixture.store.planImport(lease, expected: [fixture.compact])
    try await fixture.store.startImport(intent.id, lease: lease)
    try await fixture.store.importCreated(intent.id, identifier: "synthetic-compact")
    let mapping = try await fixture.store.finishImport(intent.id, actual: [fixture.compact], proof: fixture.proof)
    let operation = try #require(try await fixture.store.operation(fixture.operationID))
    let effect = BackupStore.PhotoEffect(id: UUID(), namespace: "photos", item: "synthetic-compact", kind: .restore,
        bindingID: fixture.binding.id, version: fixture.receipt.version, epochs: [fixture.operationID: operation.epoch],
        mappings: [mapping], expected: [fixture.original])
    _ = try await fixture.store.planEffect(effect)
    try await fixture.store.startEffect(effect.id)
    let abandoned = try abandonedPhotoHandoff(files, operationID: fixture.operationID, resource: resource)
    try await fixture.store.effectUncertain(effect.id, message: "simulated process interruption")
    let workspace = photoHandoffWorkspace(fixture.store)
    let recovery = try await workspace.reconcileInbox()
    #expect(recovery.problems.isEmpty && FileManager.default.fileExists(atPath: abandoned.alias.path))
    try await workspace.collectReleasedFiles()
    #expect(FileManager.default.fileExists(atPath: resource.url.path))
    try await fixture.store.effectCreated(effect.id, identifier: "synthetic-restored")
    let createdRecovery = try await workspace.reconcileInbox()
    #expect(createdRecovery.problems.isEmpty && FileManager.default.fileExists(atPath: abandoned.alias.path))
    _ = try await fixture.store.completeRestore(effect.id, actual: [fixture.original], proof: fixture.proof)
    try await workspace.collectReleasedFiles()
    #expect(!FileManager.default.fileExists(atPath: abandoned.directory.path))
}

@Test func photosHandoffRecoveryPreservesUnknownOwnersAndUnprovenLastLinks() async throws {
    let fixture = try await BackupStoreFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let stored = try await fixture.store.resources(fixture.operationID)
    let original = try #require(stored.first)
    let files = fixture.store.files
    let resource = PreparedPhotoResource(fileID: original.fileID,
        url: files.stagedFile(operationID: fixture.operationID, fileID: original.fileID), descriptor: original.descriptor)
    let unknown = try abandonedPhotoHandoff(files, operationID: UUID(), resource: resource)
    let known = try abandonedPhotoHandoff(files, operationID: fixture.operationID, resource: resource)
    try FileManager.default.removeItem(at: resource.url)
    let workspace = photoHandoffWorkspace(fixture.store)
    let recovery = try await workspace.reconcileInbox()
    #expect(recovery.problems.count == 2)
    #expect(FileManager.default.fileExists(atPath: unknown.alias.path))
    #expect(FileManager.default.fileExists(atPath: known.alias.path))
    let retained = try Fingerprint.digests(of: known.alias)
    #expect(retained.sha256 == resource.descriptor.sha256 && retained.size == resource.descriptor.size)
    await #expect(throws: PhotoResourceHandoff.Failure.unprovenAlias) { try await workspace.collectReleasedFiles() }
    #expect(FileManager.default.fileExists(atPath: known.alias.path))
}

@Test func resultDiscoveryTracksCurrentWorkAndStopsAfterTerminalOutboxesAreDrained() async throws {
    let fixture = try await BackupStoreFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let store = fixture.store
    #expect(try await store.needsResultDiscovery(bindingID: fixture.binding.id, namespace: "photos"))
    #expect(try await !store.needsResultDiscovery(bindingID: fixture.binding.id, namespace: "other"))
    try await store.setDesired(.paused, operationID: fixture.operationID)
    #expect(try await !store.needsResultDiscovery(bindingID: fixture.binding.id, namespace: "photos"))
    try await store.setDesired(.active, operationID: fixture.operationID)
    let lease = try #require(try await store.claim(fixture.operationID, stage: .finalization))
    let intent = try await store.planImport(lease, expected: [fixture.compact])
    try await store.startImport(intent.id, lease: lease)
    try await store.importCreated(intent.id, identifier: "synthetic-import")
    _ = try await store.finishImport(intent.id, actual: [fixture.compact], proof: fixture.proof)
    #expect(try await store.needsResultDiscovery(bindingID: fixture.binding.id, namespace: "photos"))
    let pending = try await store.outbox(bindingID: fixture.binding.id)
    let acknowledgement = try #require(pending.first { $0.kind == .deliveryAcknowledgement })
    for item in pending where item.id != acknowledgement.id { try await store.acknowledgeOutbox(item.id) }
    let retry = Date().addingTimeInterval(120)
    try await store.retryOutbox(acknowledgement.id, after: retry)
    #expect(try await store.outbox(bindingID: fixture.binding.id, now: retry.addingTimeInterval(-1)).isEmpty)
    #expect(try await store.needsResultDiscovery(bindingID: fixture.binding.id, namespace: "photos"))
    let due = try await store.outbox(bindingID: fixture.binding.id, now: retry.addingTimeInterval(1))
    #expect(due.map(\.id) == [acknowledgement.id])
    try await store.acknowledgeOutbox(acknowledgement.id)
    #expect(try await !store.needsResultDiscovery(bindingID: fixture.binding.id, namespace: "photos"))
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

@Test func stagedTransferReferencesFenceCleanupAndCompletedReplayDoesNotLeakAReference() async throws {
    let fixture = try await BackupStoreFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let resource = try #require(try await fixture.store.resources(fixture.operationID).first)
    let session = BackupStore.TransferSession(id: UUID(), bindingID: fixture.binding.id,
        identifier: "foreground.test.\(UUID().uuidString)", installationID: UUID())
    try await fixture.store.registerSession(session)
    let transfer = BackupStore.Transfer(id: UUID(), operationID: fixture.operationID, epoch: 1,
        sessionID: session.id, kind: .upload, version: fixture.receipt.version, expected: fixture.original,
        resourceID: resource.fileID, uploadID: UUID())
    try await fixture.store.stageTransfer(transfer)
    try await fixture.store.releaseOriginalSpools(fixture.operationID)
    #expect(try await fixture.store.claimCleanup().isEmpty)
    try await fixture.store.attachTask(transferID: transfer.id, sessionID: session.id, taskID: 7)
    try await fixture.store.startTransfer(transfer.id)
    try await fixture.store.finishTransfer(transfer.id, state: .completed)
    try await fixture.store.stageTransfer(transfer)
    let cleanup = try await fixture.store.claimCleanup()
    #expect(cleanup.map(\.fileID) == [resource.fileID])
    let replacement = BackupStore.Transfer(id: UUID(), operationID: fixture.operationID, epoch: 1,
        sessionID: session.id, kind: .upload, version: fixture.receipt.version, expected: fixture.original,
        resourceID: resource.fileID, uploadID: UUID())
    await #expect(throws: BackupStore.Failure.invalidReceipt) { try await fixture.store.stageTransfer(replacement) }
    try await fixture.store.cleanedResource(resource.fileID)
    #expect(try await fixture.store.claimCleanup().isEmpty)
}

@Test func unprovenNativeBackgroundSessionsCannotBeRegistered() async throws {
    let fixture = try await BackupStoreFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let session = BackupStore.TransferSession(id: UUID(), bindingID: fixture.binding.id,
        identifier: "background.test", installationID: UUID(), background: true)
    await #expect(throws: BackupStore.Failure.nativeTransferUnavailable) {
        try await fixture.store.registerSession(session)
    }
    #expect(try await fixture.store.sessions().isEmpty)
}

@Test func workspaceBudgetCountsExistingFilesOnceAndPreservesFinalizationHeadroom() async throws {
    let fixture = try await BackupStoreFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let policy = BackupSpacePolicy(maximumTransientBytes: 1_000, minimumAvailableBytes: 100,
                                  finalizationReserveBytes: 200, maximumTransfers: 2)
    let observation = BackupSpaceObservation(availableBytes: 500, transientBytes: 500)
    let reservation = BackupStore.Reservation(id: UUID(), operationID: fixture.operationID, epoch: 1,
        stage: .upload, futureBytes: 100, systemCopyBytes: 0, taskSlots: 0)
    try await fixture.store.reserveSpace(reservation, policy: policy, observation: observation)
    let tooMuch = BackupStore.Reservation(id: UUID(), operationID: fixture.operationID, epoch: 1,
        stage: .upload, futureBytes: 200, systemCopyBytes: 0, taskSlots: 0)
    await #expect(throws: BackupSpaceFailure.workingSpaceRequired) {
        try await fixture.store.reserveSpace(tooMuch, policy: policy, observation: observation)
    }
    let finalization = BackupStore.Reservation(id: UUID(), operationID: fixture.operationID, epoch: 1,
        stage: .finalization, futureBytes: 200, systemCopyBytes: 0, taskSlots: 0)
    try await fixture.store.reserveSpace(finalization, policy: policy, observation: observation)
    #expect(try await fixture.store.reservations().count == 2)
}

@Test func workspaceBudgetFailsClosedForUnknownCapacityAndOverflow() async throws {
    let fixture = try await BackupStoreFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let reservation = BackupStore.Reservation(id: UUID(), operationID: fixture.operationID, epoch: 1,
        stage: .upload, futureBytes: 1, systemCopyBytes: 0, taskSlots: 0)
    let policy = BackupSpacePolicy(maximumTransientBytes: .max, minimumAvailableBytes: .max,
                                  finalizationReserveBytes: 0, maximumTransfers: 2)
    await #expect(throws: BackupSpaceFailure.capacityUnavailable) {
        try await fixture.store.reserveSpace(reservation, policy: policy,
                                              observation: .init(availableBytes: nil, transientBytes: 0))
    }
    await #expect(throws: BackupSpaceFailure.workingSpaceRequired) {
        try await fixture.store.reserveSpace(reservation, policy: policy,
                                              observation: .init(availableBytes: .max, transientBytes: 0))
    }
    #expect(try await fixture.store.reservations().isEmpty)
}

@Test func unknownServerResultsAreDurableWithoutGuessingAPhotosIdentity() async throws {
    let fixture = try await BackupStoreFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    var unknown = fixture.receipt
    unknown.operationID = UUID()
    unknown.requestID = UUID()
    var known = fixture.receipt
    known.revision = 2
    known.compact = .processing
    known.derivative = nil
    let page = BackupAPI.Changes(origin: fixture.binding.origin, cursor: 5, hasMore: false, changes: [
        .init(sequence: 4, receipt: unknown), .init(sequence: 5, receipt: known),
    ])
    #expect(try await fixture.store.applyChanges(page, bindingID: fixture.binding.id) == .applied)
    #expect(try await fixture.store.orphanReceipts(bindingID: fixture.binding.id) == [unknown])
    #expect(try await fixture.store.operation(fixture.operationID)?.receipt == known)
    #expect(try await fixture.store.cursor(bindingID: fixture.binding.id) == 5)
    #expect(try await fixture.store.applyChanges(page, bindingID: fixture.binding.id) == .stale)
    #expect(try await fixture.store.mappings(namespace: "photos").isEmpty)
}

@Test func pagedSnapshotDoesNotPublishPartialStateOrAdvanceItsCursor() async throws {
    let fixture = try await BackupStoreFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    var receipt = fixture.receipt
    receipt.revision = 2
    receipt.compact = .failed
    receipt.derivative = nil
    let id = try await fixture.store.beginSnapshot(bindingID: fixture.binding.id)
    let first = BackupAPI.Snapshot(origin: fixture.binding.origin, cursor: 10, receipts: [receipt], continuation: "next")
    let progress = try await fixture.store.applySnapshot(first, runID: id, requestedContinuation: nil)
    #expect(!progress.complete && progress.continuation == "next")
    #expect(try await fixture.store.cursor(bindingID: fixture.binding.id) == 0)
    #expect(try await fixture.store.operation(fixture.operationID)?.receipt == fixture.receipt)
    #expect(try await fixture.store.applySnapshot(first, runID: id, requestedContinuation: nil) == progress)
    await #expect(throws: BackupStore.Failure.invalidReceipt) {
        try await fixture.store.applySnapshot(.init(origin: fixture.binding.origin, cursor: 11, receipts: []),
                                               runID: id, requestedContinuation: "next")
    }
    let finished = try await fixture.store.applySnapshot(.init(origin: fixture.binding.origin, cursor: 10, receipts: []),
                                                          runID: id, requestedContinuation: "next")
    #expect(finished.complete)
    #expect(try await fixture.store.cursor(bindingID: fixture.binding.id) == 10)
    #expect(try await fixture.store.operation(fixture.operationID)?.receipt == receipt)
}

@Test func addressReattachmentRequiresTheSameAuthenticatedOriginAndConsumer() async throws {
    let fixture = try await BackupStoreFixture.make(consumerID: "authenticated-consumer")
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let oldLease = try #require(try await fixture.store.claim(fixture.operationID, stage: .finalization))
    try await fixture.store.retireBinding(fixture.binding.id)
    let next = BackupStore.Binding(id: UUID(), origin: fixture.binding.origin, trustEpoch: UUID(),
        baseURL: URL(string: "https://changed.invalid")!, keychainReference: "new-reference",
        consumerID: "authenticated-consumer")
    try await fixture.store.bind(next)
    try await fixture.store.reattach(from: fixture.binding.id, to: next.id)
    let rebound = try #require(try await fixture.store.operation(fixture.operationID))
    #expect(rebound.bindingID == next.id && rebound.desired == .active && rebound.epoch > oldLease.epoch)
    await #expect(throws: BackupStore.Failure.staleOperation) {
        try await fixture.store.planImport(oldLease, expected: [fixture.compact])
    }
    let different = BackupStore.Binding(id: UUID(), origin: fixture.binding.origin, trustEpoch: UUID(),
        baseURL: URL(string: "https://changed.invalid")!, keychainReference: "other-reference", consumerID: "different-consumer")
    try await fixture.store.bind(different)
    await #expect(throws: BackupStore.Failure.invalidReceipt) {
        try await fixture.store.reattach(from: next.id, to: different.id)
    }
    #expect(try await fixture.store.operation(fixture.operationID)?.bindingID == next.id)
}

@Test func deferredCommandsCannotOvertakeAnUnacknowledgedEarlierCommand() async throws {
    let fixture = try await BackupStoreFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let first = try await fixture.store.enqueueCommand(fixture.operationID, action: .pause)
    let second = try await fixture.store.enqueueCommand(fixture.operationID, action: .retry)
    #expect(try await fixture.store.outbox().map(\.id) == [first])
    try await fixture.store.retryOutbox(first, after: .distantFuture)
    #expect(try await fixture.store.outbox().isEmpty)
    try await fixture.store.acknowledgeOutbox(first)
    #expect(try await fixture.store.outbox(now: Date(timeIntervalSince1970: 1)).map(\.id) == [second])
}

@Test func boundedDeferralRemainsRunnableLaterAndClosedStoresCannotReopenOnLateCallbacks() async throws {
    let fixture = try await BackupStoreFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let batch = try await fixture.store.admit(["waiting-for-space"], namespace: "photos",
        bindingID: fixture.binding.id, profile: .standard, compact: true)
    let id = try #require(batch.operationIDs.first)
    let lease = try #require(try await fixture.store.claim(id, stage: .preparation))
    let now = Date()
    try await fixture.store.deferLease(lease, until: now.addingTimeInterval(60))
    #expect(try await fixture.store.runnable(.preparation, now: now).isEmpty)
    #expect(try await fixture.store.runnable(.preparation, now: now.addingTimeInterval(61)).map(\.id) == [id])
    try await fixture.store.close()
    await #expect(throws: BackupStore.Failure.storageClosed) { try await fixture.store.operation(id) }
}

@Test func externalModeAloneCannotProduceAReadySpaceNotification() async throws {
    let fixture = try await BackupStoreFixture.make(mode: .immich)
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    var external = fixture.receipt
    external.revision += 1
    external.retention = .external
    _ = try await fixture.store.apply(external, operationID: fixture.operationID, epoch: 1)
    let lease = try #require(try await fixture.store.claim(fixture.operationID, stage: .finalization))
    let intent = try await fixture.store.planImport(lease, expected: [fixture.compact])
    try await fixture.store.startImport(intent.id, lease: lease)
    try await fixture.store.importCreated(intent.id, identifier: "external-compact")
    let proof = BackupAPI.OriginalProof(version: external.version, retention: .external, claimID: nil,
                                       verifiedAt: Date(), resources: external.originals)
    _ = try await fixture.store.finishImport(intent.id, actual: [fixture.compact], proof: proof)
    #expect(try await fixture.store.outbox().map(\.kind) == [.deliveryAcknowledgement])
}

@Test func returningToAnOlderOriginCreatesANewLineageAndCannotReviveItsOldImport() async throws {
    let fixture = try await BackupStoreFixture.make(consumerID: "consumer-a")
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let oldLease = try #require(try await fixture.store.claim(fixture.operationID, stage: .finalization))
    let oldIntent = try await fixture.store.planImport(oldLease, expected: [fixture.compact])
    let other = BackupStore.Binding(id: UUID(),
        origin: .init(serverID: UUID().uuidString, historyEpoch: UUID().uuidString), trustEpoch: UUID(),
        baseURL: URL(string: "https://other.invalid")!, keychainReference: "other", consumerID: "consumer-b")
    try await fixture.store.bind(other)
    _ = try await fixture.store.admit(["item"], namespace: "photos", bindingID: other.id, profile: .standard, compact: true)
    #expect(try await fixture.store.claim(fixture.operationID, stage: .finalization) == nil)
    await #expect(throws: BackupStore.Failure.staleOperation) {
        try await fixture.store.startImport(oldIntent.id, lease: oldLease)
    }
    let next = BackupStore.Binding(id: UUID(), origin: fixture.binding.origin, trustEpoch: UUID(),
        baseURL: URL(string: "https://changed.invalid")!, keychainReference: "next", consumerID: "consumer-a")
    try await fixture.store.bind(next)
    try await fixture.store.reattach(from: fixture.binding.id, to: next.id)
    #expect(try await fixture.store.operation(fixture.operationID)?.desired == .paused)
    let returning = try await fixture.store.admit(["item"], namespace: "photos", bindingID: next.id, profile: .standard, compact: true)
    #expect(returning.operationIDs.first != fixture.operationID)
    try await fixture.store.deferLease(oldLease)
    #expect(try await fixture.store.operation(fixture.operationID)?.lease == nil)
}

@Test func compactPromotionBeforeOrAfterReceiptGetsOneDurableCommandWithoutChangingFrozenIntent() async throws {
    for receiptFirst in [false, true] {
        let fixture = try await BackupStoreFixture.make(compactNow: false, applyReceipt: receiptFirst)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        _ = try await fixture.store.admit(["item"], namespace: "photos", bindingID: fixture.binding.id,
                                          profile: .standard, compact: true)
        if !receiptFirst {
            #expect(try await fixture.store.outbox().isEmpty)
            _ = try await fixture.store.apply(fixture.receipt, operationID: fixture.operationID, epoch: 1)
        }
        let operation = try #require(try await fixture.store.operation(fixture.operationID))
        let id = try #require(operation.promotionCommandID)
        let items = try await fixture.store.outbox()
        #expect(items.map(\.id) == [id])
        let item = try #require(items.first)
        let envelope = try BackupStore.decode(BackupStore.CommandEnvelope.self, item.payload)
        #expect(envelope.command.operationID == id && envelope.command.action == .compactNow)
        #expect(operation.request?.compact == false && operation.wantsCompact)
        try await fixture.store.acknowledgeOutbox(id)
        var later = fixture.receipt
        later.revision += 1
        _ = try await fixture.store.apply(later, operationID: fixture.operationID, epoch: 1)
        let reopened = BackupStore(directory: fixture.directory, legacyURL: nil)
        _ = try await reopened.apply(later, operationID: fixture.operationID, epoch: 1)
        #expect(try await reopened.operation(fixture.operationID)?.promotionCommandID == id)
        #expect(try await reopened.outbox().isEmpty)
    }
}

@Test func staleLeaseCleanupDoesNotStrandAReservationOrReopenSupersededWork() async throws {
    let fixture = try await BackupStoreFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let lease = try #require(try await fixture.store.claim(fixture.operationID, stage: .finalization))
    let reservation = BackupStore.Reservation(id: UUID(), operationID: fixture.operationID, epoch: lease.epoch,
        stage: .finalization, futureBytes: 100, systemCopyBytes: 0, taskSlots: 0)
    try await fixture.store.reserveSpace(reservation,
        policy: .init(maximumTransientBytes: 1_000, minimumAvailableBytes: 0, finalizationReserveBytes: 0, maximumTransfers: 2),
        observation: .init(availableBytes: 1_000, transientBytes: 0))
    try await fixture.store.setDesired(.cancelled, operationID: fixture.operationID)
    _ = try await fixture.store.admit(["item"], namespace: "photos", bindingID: fixture.binding.id,
                                      profile: .standard, compact: true)
    try await fixture.store.deferLease(lease)
    #expect(try await fixture.store.reservations().isEmpty)
    #expect(try await fixture.store.operation(fixture.operationID)?.desired == .cancelled)
    try await fixture.store.close()
}

@Test func processRecoveryReconcilesTransfersWithoutRequiringAnyPhotosIntent() async throws {
    let fixture = try await BackupStoreFixture.make(processID: UUID())
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let resource = try #require(try await fixture.store.resources(fixture.operationID).first)
    let session = BackupStore.TransferSession(id: UUID(), bindingID: fixture.binding.id,
        identifier: UUID().uuidString, installationID: UUID())
    try await fixture.store.registerSession(session)
    let transfer = BackupStore.Transfer(id: UUID(), operationID: fixture.operationID, epoch: 1,
        sessionID: session.id, kind: .upload, version: fixture.receipt.version, expected: fixture.original,
        resourceID: resource.fileID, uploadID: UUID())
    try await fixture.store.stageTransfer(transfer)
    try await fixture.store.startTransfer(transfer.id)
    let reopened = BackupStore(directory: fixture.directory, legacyURL: nil, processID: UUID())
    #expect(try await reopened.transfers().first?.state == .unknown)
}
