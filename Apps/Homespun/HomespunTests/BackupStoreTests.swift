// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import HomespunCore
import SQLite3
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

private struct LegacyUpgradeFixture: Sendable {
    let root: URL
    let directory: URL
    let legacyURL: URL
    let sources: [URL: Data]
    let store: BackupStore
    let binding: BackupStore.Binding
    static let checkedAt = Date(timeIntervalSince1970: 1_800_000_000)

    static func make() async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("upgrade-\(UUID().uuidString)")
        let real = root.appendingPathComponent("real", isDirectory: true)
        let link = root.appendingPathComponent("container", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let support = link.appendingPathComponent("Library/Application Support/Homespun", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        func entry(_ copy: String, _ hash: String?, bytes: Int = 100) -> String {
            """
            {"compactIdentifier":"\(copy)","originalBytes":\(bytes),"compactBytes":10,
            "savedAt":"2025-01-02T03:04:05Z"\(hash.map { ",\"serverAssetID\":\"" + String(repeating: $0, count: 64) + "\"" } ?? "")}
            """
        }
        let files = [
            "ledger.json": """
            {"pair":\(entry("pair-copy", "a")),"elsewhere:home-copy":\(entry("home-copy", "b")),
            "live":\(entry("live-copy", "c", bytes: 300)),"on-phone":\(entry("local-copy", nil)),
            "removed":\(entry("removed-copy", "0"))}
            """,
            "ledger.journal": """
            {"set":{"journal":\(entry("journal-copy", "d", bytes: 200))}}
            {"remove":["removed"]}
            {"set":
            """,
            "backed-up.json": """
            {"backed":{"serverAssetID":"\(String(repeating: "e", count: 64))","originalBytes":100,"backedUpAt":"2025-01-02T03:04:05Z"},
            "kept":{"serverAssetID":"\(String(repeating: "f", count: 64))","originalBytes":100,"backedUpAt":"2025-01-02T03:04:05Z","kept":true}}
            """,
            // 1.0 had settled, not keptAsIs. It must not be reinterpreted as a new decision.
            "automatic.json": #"{"settled":["old-settled"],"lastChecked":"2025-01-02T03:04:05Z"}"#,
        ]
        var sources: [URL: Data] = [:]
        for (name, text) in files {
            let url = support.appendingPathComponent(name), data = Data(text.utf8)
            try data.write(to: url)
            sources[url] = data
        }
        let directory = support.appendingPathComponent("Backup"), legacyURL = support.appendingPathComponent("ledger.json")
        let store = BackupStore(directory: directory, legacyURL: legacyURL)
        let binding = BackupStore.Binding(id: UUID(),
            origin: .init(serverID: UUID().uuidString, historyEpoch: UUID().uuidString),
            trustEpoch: UUID(), baseURL: URL(string: "https://server.invalid")!, keychainReference: "legacy-test")
        try await store.bind(binding)
        return Self(root: root, directory: directory, legacyURL: legacyURL, sources: sources, store: store, binding: binding)
    }

    static func candidates(_ projection: BackupStore.LedgerProjection) -> [LegacyCheck.Candidate] {
        LegacyCheck.candidates(projection) { $0 == "journal-copy" ? .video : .photo }
    }

    static func match(_ candidate: LegacyCheck.Candidate) -> ServerAPI.CopyLookupResponse.Match {
        .init(sha256: candidate.asset, assetID: candidate.asset, role: candidate.role,
              isOriginal: true, originalsVerified: true, originalBytes: candidate.bytes)
    }
}

@MainActor private final class LegacyCheckCurrent {
    var value = true
}

private actor LegacyLookupBatches {
    let candidates: [String: LegacyCheck.Candidate]
    let failSecond: Bool
    private(set) var sizes: [Int] = []

    init(_ candidates: [LegacyCheck.Candidate], failSecond: Bool) {
        self.candidates = Dictionary(uniqueKeysWithValues: candidates.map { ($0.asset, $0) })
        self.failSecond = failSecond
    }

    func lookup(_ hashes: [String]) throws -> [ServerAPI.CopyLookupResponse.Match] {
        sizes.append(hashes.count)
        if failSecond && sizes.count == 2 { throw PhotoHandoffTestFailure.interrupted }
        return hashes.compactMap { candidates[$0].map(LegacyUpgradeFixture.match) }
    }
}

@Test @MainActor func onePointZeroUpgradeThroughASymlinkChecksCatalogWithoutChangingLegacyRecordsOrActionProofs() async throws {
    let fixture = try await LegacyUpgradeFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let ledger = CompactLedger(store: fixture.store)
    let projection = try await ledger.projection()
    #expect(Set(projection.entries.keys) == ["pair", "elsewhere:home-copy", "live", "on-phone", "journal"])
    #expect(projection.entries.values.allSatisfy { $0.origin == nil && $0.version == nil && !$0.verifiedCompact })
    #expect(Set(projection.backedUp.keys) == ["backed", "kept"])
    #expect(projection.backedUp.values.allSatisfy { $0.origin == nil && $0.version == nil })
    #expect(projection.backedUp["kept"]?.kept == true && projection.kept.isEmpty)
    let marker = try await fixture.store.readState {
        try $0.rows("SELECT value FROM meta WHERE key = 'legacy_sources'").first?.blob("value")
    }
    #expect(marker != nil)
    let candidates = LegacyUpgradeFixture.candidates(projection)
    #expect(candidates.count == 6 && !candidates.contains { $0.item == "on-phone" || $0.item == "removed" })
    let matches = candidates.map(LegacyUpgradeFixture.match)
    try await LegacyCheck.run(candidates, ledger: ledger, binding: fixture.binding,
        lookup: { hashes in
            #expect(hashes.count == 6)
            return matches.filter { hashes.contains($0.sha256) }
        }, current: { true }, serverOrigin: { fixture.binding.origin }, now: { LegacyUpgradeFixture.checkedAt })
    // The facade's previously cached projection must observe the check transaction.
    let checked = try await ledger.projection()
    let confirmed = checked.legacyConfirmed(binding: fixture.binding, now: LegacyUpgradeFixture.checkedAt)
    #expect(confirmed.count == 6)
    #expect(checked.entries == projection.entries && checked.backedUp == projection.backedUp)
    #expect(try await ledger.serverBacked().isEmpty)
    let state = LibraryState(library: ["pair", "pair-copy", "home-copy", "live-copy", "journal-copy",
        "on-phone", "local-copy", "backed", "kept", "new"], ledger: checked.entries, album: ["local-copy"], job: [:],
        origin: fixture.binding.origin, legacyConfirmed: confirmed, legacyServerName: "polonium")
    #expect(state.cell("pair") == nil && state.cell("pair-copy")?.badge == .legacyBackedUp(originalOnPhone: true))
    #expect(state.cell("home-copy")?.badge == .legacyBackedUp(originalOnPhone: false))
    #expect(state.cell("live-copy")?.badge == .legacyBackedUp(originalOnPhone: false))
    #expect(state.cell("journal-copy")?.badge == .legacyBackedUp(originalOnPhone: false))
    #expect(state.cell("backed")?.badge == .copyLater && state.cell("backed")?.compactAfter == nil)
    #expect(state.cell("local-copy")?.badge == .compactCopy && state.cell("on-phone")?.badge == .none)
    #expect(state.count(.atHome) == 3 && state.count(.needsAttention) == 0 && state.count(.notBackedUp) == 2)
    #expect(state.cells.filter(\.legacy).count == 6 && state.cells.allSatisfy { !$0.canFree && !$0.canRestore })
    #expect(state.cells.filter(\.legacy).allSatisfy { !$0.canCompact && ItemAction.for($0) == .none })
    #expect(LibraryView.backupSubtitle(state: state, server: "polonium") == "2 not backed up · polonium")
    var incremental = state
    #expect(incremental.apply(job: ["backed": .failed("old job"), "kept": .notYet("old job")]).isEmpty)
    #expect(incremental == state)
    let unconfirmed = LibraryState(library: ["pair", "pair-copy", "home-copy"], ledger: checked.entries,
        album: [], job: [:], origin: fixture.binding.origin)
    #expect(unconfirmed.cell("pair-copy")?.badge == .recovery && unconfirmed.count(.needsAttention) == 2)
    #expect(LibraryView.backupSubtitle(state: unconfirmed, server: "polonium") == "2 need attention · polonium")
    let mappings = try await fixture.store.mappings(namespace: "photos")
    try await fixture.store.close()
    let reopened = BackupStore(directory: fixture.directory, legacyURL: fixture.legacyURL)
    let reloaded = try await reopened.ledgerProjection(namespace: "photos")
    #expect(try await reopened.mappings(namespace: "photos") == mappings)
    #expect(reloaded.legacyConfirmed(binding: fixture.binding, now: LegacyUpgradeFixture.checkedAt) == confirmed)
    let reopenedMarker = try await reopened.readState {
        try $0.rows("SELECT value FROM meta WHERE key = 'legacy_sources'").first?.blob("value")
    }
    #expect(reopenedMarker == marker)
    for (url, data) in fixture.sources { #expect(try Data(contentsOf: url) == data) }
    try await reopened.close()
}

@Test @MainActor func legacyLookupRequiresTheWholeCatalogMatchAndExpiresEvenACachedProjection() async throws {
    let fixture = try await LegacyUpgradeFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let ledger = CompactLedger(store: fixture.store)
    let candidates = LegacyUpgradeFixture.candidates(try await ledger.projection())
    let matches = candidates.compactMap { candidate -> ServerAPI.CopyLookupResponse.Match? in
        var match = LegacyUpgradeFixture.match(candidate)
        switch candidate.item {
        case "pair": match.originalBytes += 1
        case "live": match.originalsVerified = false
        case "journal": match.role = .photo
        case "backed": match.assetID = String(repeating: "0", count: 64)
        case "kept": return nil
        default: break
        }
        return match
    }
    try await LegacyCheck.run(candidates, ledger: ledger, binding: fixture.binding,
        lookup: { _ in matches }, current: { true }, serverOrigin: { fixture.binding.origin },
        now: { LegacyUpgradeFixture.checkedAt })
    let projection = try await ledger.projection(), now = LegacyUpgradeFixture.checkedAt
    #expect(Set(projection.legacyConfirmed(binding: fixture.binding, now: now).keys) == ["elsewhere:home-copy"])
    #expect(projection.legacyChecks.count == 6)
    #expect(LegacyCheck.pending(candidates, projection: projection, binding: fixture.binding, now: now).isEmpty)
    #expect(projection.legacyConfirmed(binding: fixture.binding, now: now.addingTimeInterval(LegacyCheck.maximumAge)).count == 1)
    #expect(projection.legacyConfirmed(binding: fixture.binding, now: now.addingTimeInterval(LegacyCheck.maximumAge + 1)).isEmpty)
    #expect(projection.legacyConfirmed(binding: fixture.binding, now: now.addingTimeInterval(-1)).isEmpty)
    #expect(LegacyCheck.pending(candidates, projection: projection, binding: fixture.binding,
        now: now.addingTimeInterval(LegacyCheck.maximumAge + 1)).count == 6)
    var other = fixture.binding
    other.id = UUID()
    try await fixture.store.bind(other)
    #expect(projection.legacyConfirmed(binding: other, now: now).isEmpty)
    other = fixture.binding
    other.origin.historyEpoch = UUID().uuidString
    #expect(projection.legacyConfirmed(binding: other, now: now).isEmpty)
    other = fixture.binding
    other.origin.serverID = UUID().uuidString
    #expect(projection.legacyConfirmed(binding: other, now: now).isEmpty)
    try await fixture.store.retireBinding(fixture.binding.id)
    #expect(try await ledger.projection().legacyChecks.isEmpty)
    await #expect(throws: BackupStore.Failure.retiredBinding) {
        try await fixture.store.recordLegacyChecks(Array(projection.legacyChecks.values),
                                                   binding: fixture.binding, namespace: "photos")
    }
    try await fixture.store.close()
}

@Test @MainActor func legacyLookupDoesNotTurnCompactHintsUnrelatedHashesOrErrorsIntoConfirmation() async throws {
    let fixture = try await LegacyUpgradeFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let ledger = CompactLedger(store: fixture.store)
    let candidates = LegacyUpgradeFixture.candidates(try await ledger.projection())
    let wrong = candidates.map { candidate in
        var match = LegacyUpgradeFixture.match(candidate)
        if candidate.item == "pair" { match.isOriginal = false }
        else { match.sha256 = String(repeating: "0", count: 64) }
        return match
    }
    try await LegacyCheck.run(candidates, ledger: ledger, binding: fixture.binding,
        lookup: { _ in wrong }, current: { true }, serverOrigin: { fixture.binding.origin },
        now: { LegacyUpgradeFixture.checkedAt })
    #expect(try await ledger.projection().legacyConfirmed(binding: fixture.binding, now: LegacyUpgradeFixture.checkedAt).isEmpty)
    try await fixture.store.discardLegacyChecks(bindingID: fixture.binding.id)
    await #expect(throws: PhotoHandoffTestFailure.interrupted) {
        try await LegacyCheck.run(candidates, ledger: ledger, binding: fixture.binding,
            lookup: { _ in throw PhotoHandoffTestFailure.interrupted }, current: { true },
            serverOrigin: { fixture.binding.origin })
    }
    #expect(try await ledger.projection().legacyChecks.isEmpty, "A failed request is not a negative catalog result")
    let current = LegacyCheckCurrent()
    let lookup: CopyFinder.Lookup = { _ in
        await MainActor.run { current.value = false }
        return candidates.map(LegacyUpgradeFixture.match)
    }
    await #expect(throws: CancellationError.self) {
        try await LegacyCheck.run(candidates, ledger: ledger, binding: fixture.binding, lookup: lookup,
            current: { current.value }, serverOrigin: { fixture.binding.origin })
    }
    #expect(try await ledger.projection().legacyChecks.isEmpty, "An answer after a binding/trust change must be discarded")
    let anotherOrigin = BackupAPI.Origin(serverID: fixture.binding.origin.serverID, historyEpoch: UUID().uuidString)
    await #expect(throws: LegacyCheck.Failure.serverChanged) {
        try await LegacyCheck.run(candidates, ledger: ledger, binding: fixture.binding,
            lookup: { _ in Issue.record("A changed server epoch must stop before any fingerprint is sent"); return [] },
            current: { true }, serverOrigin: { anotherOrigin })
    }
    #expect(try await ledger.projection().legacyChecks.isEmpty)
    try await fixture.store.close()
}

@Test @MainActor func legacyLookupBatchesAtFiveHundredAndResumesOnlyUnansweredItemsAfterAnError() async throws {
    let fixture = try await LegacyUpgradeFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let ledger = CompactLedger(store: fixture.store, namespace: "batch-test")
    let entries = Dictionary(uniqueKeysWithValues: (0..<1_001).map { index in
        ("item-\(index)", CompactLedger.Entry(compactIdentifier: "copy-\(index)", originalBytes: 100, compactBytes: 10,
            savedAt: LegacyUpgradeFixture.checkedAt, serverAssetID: Fingerprint.sha256(of: Data("original-\(index)".utf8))))
    })
    try await ledger.record(entries)
    let candidates = LegacyUpgradeFixture.candidates(try await ledger.projection())
    let interrupted = LegacyLookupBatches(candidates, failSecond: true)
    await #expect(throws: PhotoHandoffTestFailure.interrupted) {
        try await LegacyCheck.run(candidates, ledger: ledger, binding: fixture.binding,
            lookup: { try await interrupted.lookup($0) }, current: { true }, serverOrigin: { fixture.binding.origin },
            now: { LegacyUpgradeFixture.checkedAt })
    }
    #expect(await interrupted.sizes == [500, 500])
    let partial = try await ledger.projection()
    #expect(partial.legacyConfirmed(binding: fixture.binding, now: LegacyUpgradeFixture.checkedAt).count == 500)
    let pending = LegacyCheck.pending(candidates, projection: partial, binding: fixture.binding, now: LegacyUpgradeFixture.checkedAt)
    #expect(pending.count == 501)
    let resumed = LegacyLookupBatches(pending, failSecond: false)
    try await LegacyCheck.run(pending, ledger: ledger, binding: fixture.binding,
        lookup: { try await resumed.lookup($0) }, current: { true }, serverOrigin: { fixture.binding.origin },
        now: { LegacyUpgradeFixture.checkedAt })
    #expect(await resumed.sizes == [500, 1])
    let complete = try await ledger.projection()
    #expect(complete.legacyConfirmed(binding: fixture.binding, now: LegacyUpgradeFixture.checkedAt).count == 1_001)
    #expect(LegacyCheck.pending(candidates, projection: complete, binding: fixture.binding,
                              now: LegacyUpgradeFixture.checkedAt).isEmpty)
    try await ledger.record(["new": .init(compactIdentifier: "new-copy", originalBytes: 100, compactBytes: 10,
        savedAt: Date(), serverAssetID: String(repeating: "a", count: 64))])
    let extended = try await ledger.projection()
    #expect(LegacyCheck.pending(LegacyUpgradeFixture.candidates(extended), projection: extended,
                               binding: fixture.binding, now: LegacyUpgradeFixture.checkedAt).map(\.item) == ["new"])
    var changed = try #require(entries["item-0"])
    changed.originalBytes += 1
    try await ledger.record(["item-0": changed])
    #expect(try await ledger.projection().legacyChecks["item-0"] == nil)
    let old = try #require(candidates.first { $0.item == "item-0" })
    try await LegacyCheck.run([old], ledger: ledger, binding: fixture.binding,
        lookup: { _ in [LegacyUpgradeFixture.match(old)] }, current: { true }, serverOrigin: { fixture.binding.origin },
        now: { LegacyUpgradeFixture.checkedAt })
    #expect(try await ledger.projection().legacyChecks["item-0"] == nil, "A late response cannot confirm a changed mapping")
    try await fixture.store.close()
}

@Test func failedUploadIntentAdmissionReleasesItsReservation() async throws {
    let fixture = try await BackupStoreFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let original = try #require(try await fixture.store.resources(fixture.operationID).first)
    let transfer = BackupStore.Transfer(id: UUID(), operationID: fixture.operationID, epoch: 1,
        sessionID: UUID(), kind: .upload, version: fixture.receipt.version,
        expected: original.descriptor, resourceID: original.fileID, uploadID: UUID())
    let workspace = BackupWorkspace(store: fixture.store, policy: .init(
        maximumTransientBytes: 8 << 20, minimumAvailableBytes: 0, finalizationReserveBytes: 0, maximumTransfers: 3))
    // Capacity is available, but this transfer has no registered foreground session.
    await #expect(throws: BackupStore.Failure.staleOperation) {
        _ = try await workspace.reserveTransfer(transfer, futureBytes: 0)
    }
    #expect(try await fixture.store.reservations().isEmpty)
    #expect(try await fixture.store.transfers().isEmpty)
    let digest = try Fingerprint.digests(of: fixture.store.files.stagedFile(
        operationID: fixture.operationID, fileID: original.fileID))
    #expect(digest.sha256 == original.descriptor.sha256 && digest.size == original.descriptor.size)
    try await fixture.store.close()
}

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
    let legacyCandidate = LegacyCheck.Candidate(item: historical, asset: fixture.receipt.version.assetID,
        bytes: fixture.original.size, role: .photo, compact: "found-copy")
    try await fixture.store.recordLegacyChecks([.init(candidate: legacyCandidate, bindingID: fixture.binding.id,
        origin: fixture.binding.origin, verified: true, checkedAt: Date())], binding: fixture.binding, namespace: "photos")
    let legacyProjection = try await ledger.projection()
    #expect(legacyProjection.legacyConfirmed(binding: fixture.binding).count == 1)
    let legacyState = LibraryState(library: ["found-copy"], ledger: legacyProjection.entries, album: [], job: [:],
        origin: fixture.binding.origin, legacyConfirmed: legacyProjection.legacyConfirmed(binding: fixture.binding))
    #expect(legacyState.cell("found-copy")?.badge == .legacyBackedUp(originalOnPhone: false))
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
    let adoptedProjection = try await restoredLedger.projection()
    #expect(adoptedProjection.legacyChecks.isEmpty)
    let adoptedState = LibraryState(library: ["found-copy"], ledger: adoptedProjection.entries, album: [], job: [:],
        origin: fixture.binding.origin)
    #expect(adoptedState.cell("found-copy")?.badge == .backedUp && adoptedState.cell("found-copy")?.canRestore == true)
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

@Test func libraryProjectionPublishesAnImportedCopyOnlyAfterItsMappingIsVerified() async throws {
    let fixture = try await BackupStoreFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let ledger = CompactLedger(store: fixture.store)
    let lease = try #require(try await fixture.store.claim(fixture.operationID, stage: .finalization))
    let intent = try await fixture.store.planImport(lease, expected: [fixture.compact])
    try await fixture.store.startImport(intent.id, lease: lease)
    try await fixture.store.importCreated(intent.id, identifier: "new-compact")
    let pending = try await ledger.projection()
    #expect(pending.pendingImports == ["new-compact"] && pending.entries.isEmpty)
    _ = try await fixture.store.finishImport(intent.id, actual: [fixture.compact], proof: fixture.proof)
    let verified = try await ledger.projection()
    #expect(verified.pendingImports.isEmpty)
    #expect(verified.entries.values.map(\.compactIdentifier) == ["new-compact"])
}

@Test func libraryProjectionDoesNotConcealAnInterruptedImportNeedingRecovery() async throws {
    let fixture = try await BackupStoreFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let lease = try #require(try await fixture.store.claim(fixture.operationID, stage: .finalization))
    let intent = try await fixture.store.planImport(lease, expected: [fixture.compact])
    try await fixture.store.startImport(intent.id, lease: lease)
    try await fixture.store.importCreated(intent.id, identifier: "interrupted-compact")
    let restarted = BackupStore(directory: fixture.directory, legacyURL: nil, processID: UUID())
    let projection = try await restarted.ledgerProjection(namespace: "photos")
    #expect(projection.pendingImports.isEmpty)
    #expect(try await restarted.importIntent(fixture.operationID)?.createdIdentifier == "interrupted-compact")
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

@MainActor @Test func canonicalPresentationKeepsStagesStableBetweenLeasesAndDoesNotFinishRemoteWork() {
    let now = Date()
    var operation = BackupStore.Operation(id: UUID(), namespace: "photos", itemID: "original", lineage: 1,
        bindingID: UUID(), origin: .init(serverID: UUID().uuidString, historyEpoch: UUID().uuidString),
        profile: .standard, wantsCompact: true, createdAt: now, updatedAt: now)
    #expect(CompactJob.project(operation, kept: false).phase == .waiting)
    operation.lease = .init(id: UUID(), operationID: operation.id, epoch: 1, processID: UUID(), stage: .preparation)
    #expect(CompactJob.project(operation, kept: false).phase == .working)
    operation.lease = nil
    for stage in [BackupAPI.BackupState.preparing, .uploading, .verifying] {
        operation.backup = stage
        let state = CompactJob.project(operation, kept: false)
        #expect(state.phase == .working && !state.isFinished)
    }
    operation.backup = .retained
    operation.compact = .processing
    let remote = CompactJob.project(operation, kept: false)
    #expect(remote.phase == .processing && !remote.isOpen && !remote.isFinished)
    operation.compact = .ready
    for stage in [BackupAPI.DeliveryState.pending, .downloading, .validating, .importPlanned] {
        operation.delivery = stage
        let state = CompactJob.project(operation, kept: false)
        #expect(state.phase == .working && !state.isFinished)
    }
    operation.manifest = .init(kind: .photo, resources: [
        .init(role: .photo, filename: "original.jpg", size: 100, sha256: String(repeating: "a", count: 64)),
    ])
    operation.delivery = .importedVerified
    #expect(CompactJob.project(operation, kept: false).isFinished)
}

@MainActor @Test func compactInProgressRequiresTheCurrentRetainedActiveBindingButNotALocalLease() {
    let now = Date()
    var operation = BackupStore.Operation(id: UUID(), namespace: "photos", itemID: "original", lineage: 1,
        bindingID: UUID(), origin: .init(serverID: UUID().uuidString, historyEpoch: UUID().uuidString),
        backup: .retained, profile: .standard, wantsCompact: true, createdAt: now, updatedAt: now)
    let origin = operation.origin, bindingID = operation.bindingID
    func presents(_ candidate: BackupStore.Operation) -> Bool {
        CompactJob.presentsCompactInProgress(candidate, origin: origin, bindingID: bindingID)
    }
    #expect(presents(operation))
    operation.lease = .init(id: UUID(), operationID: operation.id, epoch: 1, processID: UUID(), stage: .finalization)
    #expect(presents(operation))
    operation.lease = nil
    operation.epoch += 1
    #expect(presents(operation))
    for compact in [BackupAPI.CompactState.requested, .queued, .processing, .ready] {
        operation.compact = compact
        for delivery in [BackupAPI.DeliveryState.pending, .downloading, .validating, .importPlanned] {
            operation.delivery = delivery
            #expect(presents(operation))
        }
    }
    #expect(!CompactJob.presentsCompactInProgress(operation, origin: nil, bindingID: bindingID))
    #expect(!CompactJob.presentsCompactInProgress(operation, origin: origin, bindingID: nil))
    #expect(!CompactJob.presentsCompactInProgress(operation, origin: origin, bindingID: UUID()))
    #expect(!CompactJob.presentsCompactInProgress(operation,
        origin: .init(serverID: UUID().uuidString, historyEpoch: origin.historyEpoch), bindingID: bindingID))
    #expect(!CompactJob.presentsCompactInProgress(operation,
        origin: .init(serverID: origin.serverID, historyEpoch: UUID().uuidString), bindingID: bindingID))
    var excluded = operation
    excluded.attention = true
    #expect(!presents(excluded))
    excluded = operation
    excluded.wantsCompact = false
    #expect(!presents(excluded))
    excluded = operation
    excluded.delivery = .importedVerified
    #expect(!presents(excluded))
    for desired in [BackupStore.Desired.paused, .cancelled] {
        excluded = operation
        excluded.desired = desired
        #expect(!presents(excluded))
    }
    for compact in [BackupAPI.CompactState.held, .failed] {
        excluded = operation
        excluded.compact = compact
        #expect(!presents(excluded))
    }
    for backup in [BackupAPI.BackupState.selected, .preparing, .uploading, .verifying, .blocked, .failed] {
        excluded = operation
        excluded.backup = backup
        #expect(!presents(excluded))
    }
}

@MainActor @Test func pendingPresentationUsesCurrentBindingAndCanonicalCompletionNotLeases() {
    let now = Date()
    var operation = BackupStore.Operation(id: UUID(), namespace: "photos", itemID: "original", lineage: 1,
        bindingID: UUID(), origin: .init(serverID: UUID().uuidString, historyEpoch: UUID().uuidString),
        profile: .standard, wantsCompact: true, createdAt: now, updatedAt: now)
    let origin = operation.origin, bindingID = operation.bindingID
    func pending(_ candidate: BackupStore.Operation, kept: Bool = false) -> Bool {
        CompactJob.presentsPendingWork(candidate, state: CompactJob.project(candidate, kept: kept),
                                      origin: origin, bindingID: bindingID)
    }
    #expect(pending(operation))
    operation.lease = .init(id: UUID(), operationID: operation.id, epoch: 1, processID: UUID(), stage: .preparation)
    #expect(pending(operation))
    operation.lease = nil
    operation.backup = .retained
    operation.compact = .processing
    #expect(pending(operation))
    operation.compact = .ready
    #expect(pending(operation))
    let state = CompactJob.project(operation, kept: false)
    #expect(!CompactJob.presentsPendingWork(operation, state: state, origin: nil, bindingID: bindingID))
    #expect(!CompactJob.presentsPendingWork(operation, state: state, origin: origin, bindingID: nil))
    #expect(!CompactJob.presentsPendingWork(operation, state: state, origin: origin, bindingID: UUID()))
    #expect(!CompactJob.presentsPendingWork(operation, state: state,
        origin: .init(serverID: origin.serverID, historyEpoch: UUID().uuidString), bindingID: bindingID))
    #expect(!CompactJob.presentsPendingWork(operation, state: state,
        origin: .init(serverID: UUID().uuidString, historyEpoch: origin.historyEpoch), bindingID: bindingID))
    #expect(!pending(operation, kept: true))
    var terminal = operation
    terminal.attention = true
    #expect(!pending(terminal))
    terminal = operation
    terminal.wantsCompact = false
    #expect(!pending(terminal))
    for desired in [BackupStore.Desired.paused, .cancelled] {
        terminal = operation
        terminal.desired = desired
        #expect(!pending(terminal))
    }
    for compact in [BackupAPI.CompactState.held, .failed] {
        terminal = operation
        terminal.compact = compact
        #expect(!pending(terminal))
    }
    terminal = operation
    terminal.delivery = .importedVerified
    terminal.manifest = .init(kind: .photo, resources: [
        .init(role: .photo, filename: "original.jpg", size: 100, sha256: String(repeating: "a", count: 64)),
    ])
    #expect(!pending(terminal))
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

@Test func backupStoreThroughSymlinkedAncestorPersistsAndProtectsDatabaseFiles() async throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? manager.removeItem(at: root) }
    let real = root.appendingPathComponent("real", isDirectory: true)
    let linked = root.appendingPathComponent("linked", isDirectory: true)
    try manager.createDirectory(at: real, withIntermediateDirectories: true)
    try manager.createSymbolicLink(at: linked, withDestinationURL: real)
    let directory = linked.appendingPathComponent("Library/Application Support/Homespun/Backup", isDirectory: true)
    let store = BackupStore(directory: directory, legacyURL: nil)
    try await store.open()
    try await store.keepAsIs(["persisted-item"], namespace: "photos", kept: true)
    let openedPath = try #require(try await store.readState { connection in
        try connection.rows("PRAGMA database_list").first?.text("file")
    })
    for suffix in ["", "-wal", "-shm"] {
        let actualPath = openedPath + suffix
        let linkedPath = store.files.database.path + suffix
        #expect(manager.fileExists(atPath: actualPath))
        #expect(manager.fileExists(atPath: linkedPath))
        #expect(try PhotoResourceHandoff.file(URL(fileURLWithPath: actualPath)).identity
            == PhotoResourceHandoff.file(URL(fileURLWithPath: linkedPath)).identity)
        try manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: actualPath)
    }
    try store.files.protectDatabase()
    for suffix in ["", "-wal", "-shm"] {
        let attributes = try manager.attributesOfItem(atPath: openedPath + suffix)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
    }
    try await store.close()
    let reopened = BackupStore(directory: directory, legacyURL: nil)
    try await reopened.open()
    #expect(try await reopened.decision("persisted-item", namespace: "photos"))
    try await reopened.close()
}

@Test func backupDatabaseRejectsSymlinkedFileThroughSymlinkedAncestor() throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? manager.removeItem(at: root) }
    let real = root.appendingPathComponent("real", isDirectory: true)
    let linked = root.appendingPathComponent("linked", isDirectory: true)
    try manager.createDirectory(at: real, withIntermediateDirectories: true)
    try manager.createSymbolicLink(at: linked, withDestinationURL: real)
    let files = BackupFiles(root: linked.appendingPathComponent("Backup", isDirectory: true))
    try files.prepare()
    let target = real.appendingPathComponent("untouched.sqlite")
    try Data().write(to: target)
    try manager.createSymbolicLink(at: files.database, withDestinationURL: target)
    do {
        _ = try BackupDatabase(url: files.database)
        Issue.record("A database file that is itself a symlink must not be opened.")
    } catch let failure as BackupDatabase.Failure {
        guard case .sqlite(let code) = failure else { throw failure }
        #expect(code & 0xFF == SQLITE_CANTOPEN)
    }
    #expect(try Data(contentsOf: target).isEmpty)
    #expect(try files.database.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
}

@Test func backupDatabaseReportsUnresolvableParentDirectory() throws {
    let missing = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .appendingPathComponent("backup.sqlite")
    do {
        _ = try BackupDatabase(url: missing)
        Issue.record("An unresolved database parent must not be opened.")
    } catch let failure as BackupDatabase.Failure {
        guard case .directoryResolution(let code) = failure else { throw failure }
        #expect(code == ENOENT)
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

@Test func onePointZeroJournalMigrationThroughSymlinkPreservesSourcesAndRejectsUnreadableSnapshot() async throws {
    // Frozen stored Codable shapes from b35fc19: CompactLedger, AutomaticMode.State and CompactSchedule.
    struct Entry: Codable {
        var compactIdentifier: String
        var originalBytes: Int
        var compactBytes: Int
        var savedAt: Date
        var serverAssetID: String?
    }
    struct BackedUp: Codable {
        var serverAssetID: String
        var originalBytes: Int
        var backedUpAt: Date
        var kept: Bool? = nil
    }
    struct Change: Codable {
        var set: [String: Entry]?
        var remove: [String]?
    }
    struct Schedule: Codable {
        var days = 30
        var keepFavorites = true
    }
    struct AutomaticState: Codable {
        var enabled = false
        var since = Date.distantPast
        var token: Data?
        var attempts: [String: Int] = [:]
        var settled: Set<String> = []
        var lastRun: Date?
        var lastSummary: String?
        var pending: Set<String> = []
        var notifies = true
        var schedule = Schedule()
        var firstSeen: [String: Date] = [:]
        var removalToken: Data?
        var removed: [String: Date] = [:]
    }
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent("one-point-zero-\(UUID().uuidString)", isDirectory: true)
    defer { try? manager.removeItem(at: root) }
    let real = root.appendingPathComponent("real", isDirectory: true)
    let linked = root.appendingPathComponent("container", isDirectory: true)
    try manager.createDirectory(at: real, withIntermediateDirectories: true)
    try manager.createSymbolicLink(at: linked, withDestinationURL: real)
    let support = linked.appendingPathComponent("Library/Application Support/Homespun", isDirectory: true)
    try manager.createDirectory(at: support, withIntermediateDirectories: true)
    let date = Date(timeIntervalSince1970: 1_735_787_045)
    let original = Entry(compactIdentifier: "original-copy", originalBytes: 100, compactBytes: 10,
                         savedAt: date, serverAssetID: String(repeating: "a", count: 64))
    let added = Entry(compactIdentifier: "added-copy", originalBytes: 200, compactBytes: 20,
                      savedAt: date, serverAssetID: String(repeating: "b", count: 64))
    let after = Entry(compactIdentifier: "after-copy", originalBytes: 300, compactBytes: 30,
                      savedAt: date, serverAssetID: String(repeating: "c", count: 64))
    let snapshotEncoder = JSONEncoder()
    snapshotEncoder.dateEncodingStrategy = .iso8601
    snapshotEncoder.outputFormatting = [.sortedKeys]
    let journalEncoder = JSONEncoder()
    journalEncoder.dateEncodingStrategy = .iso8601
    func line(_ change: Change) throws -> Data {
        var data = try journalEncoder.encode(change)
        data.append(UInt8(ascii: "\n"))
        return data
    }
    var journal = try line(Change(set: ["added": added]))
    let torn = try journalEncoder.encode(Change(set: ["partial": after], remove: ["original"]))
    journal.append(contentsOf: torn.prefix(torn.count / 2))
    // 1.0 append() starts a new line after reopening an interrupted write.
    journal.append(UInt8(ascii: "\n"))
    journal.append(try line(Change(set: ["after": after], remove: ["removed"])))
    let backedUp = [
        "deferred": BackedUp(serverAssetID: String(repeating: "d", count: 64), originalBytes: 400, backedUpAt: date),
        "kept": BackedUp(serverAssetID: String(repeating: "e", count: 64), originalBytes: 500, backedUpAt: date, kept: true),
    ]
    var automatic = AutomaticState()
    automatic.settled = ["old-settled"]
    automatic.lastRun = date
    let sources = [
        "ledger.json": try snapshotEncoder.encode(["original": original, "removed": added]),
        "ledger.journal": journal,
        "backed-up.json": try snapshotEncoder.encode(backedUp),
        // The 1.0 automatic state uses default numeric dates, unlike ledger files.
        "automatic.json": try JSONEncoder().encode(automatic),
    ]
    for (name, data) in sources { try data.write(to: support.appendingPathComponent(name)) }
    let legacyURL = support.appendingPathComponent("ledger.json")
    let directory = support.appendingPathComponent("Backup", isDirectory: true)
    let store = BackupStore(directory: directory, legacyURL: legacyURL)
    try await store.open()
    let projection = try await store.ledgerProjection(namespace: "photos")
    #expect(Set(projection.entries.keys) == ["original", "added", "after"])
    #expect(projection.entries["original"]?.compactIdentifier == original.compactIdentifier)
    #expect(projection.entries["added"]?.compactIdentifier == added.compactIdentifier)
    #expect(projection.entries["after"]?.compactIdentifier == after.compactIdentifier)
    #expect(projection.entries.values.allSatisfy {
        $0.savedAt == date && $0.origin == nil && $0.version == nil && $0.requestID == nil && !$0.verifiedCompact
    })
    #expect(Set(projection.backedUp.keys) == ["deferred", "kept"])
    #expect(projection.backedUp["deferred"]?.kept == nil && projection.backedUp["kept"]?.kept == true)
    #expect(projection.backedUp.values.allSatisfy { $0.backedUpAt == date && $0.origin == nil && $0.version == nil })
    #expect(projection.kept.isEmpty, "1.0 settled must not be guessed to mean a new keep decision")
    #expect(try await store.metadata("legacy_journal_fragments", as: Int.self) == 1)
    let mappings = try await store.mappings(namespace: "photos")
    #expect(mappings.values.allSatisfy { $0.origin == nil && $0.proof == nil })
    try await store.close()
    let reopened = BackupStore(directory: directory, legacyURL: legacyURL)
    #expect(try await reopened.mappings(namespace: "photos") == mappings)
    #expect(try await reopened.metadata("legacy_journal_fragments", as: Int.self) == 1)
    for (name, data) in sources { #expect(try Data(contentsOf: support.appendingPathComponent(name)) == data) }
    try await reopened.close()

    let unreadable = support.appendingPathComponent("Unreadable", isDirectory: true)
    try manager.createDirectory(at: unreadable, withIntermediateDirectories: true)
    var damagedSources = sources
    damagedSources["ledger.json"] = Data("{".utf8)
    for (name, data) in damagedSources { try data.write(to: unreadable.appendingPathComponent(name)) }
    let blocked = BackupStore(directory: unreadable.appendingPathComponent("Backup", isDirectory: true),
                              legacyURL: unreadable.appendingPathComponent("ledger.json"))
    await #expect(throws: BackupStore.Failure.legacyUnreadable) { try await blocked.open() }
    for (name, data) in damagedSources { #expect(try Data(contentsOf: unreadable.appendingPathComponent(name)) == data) }
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
