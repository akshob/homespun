// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import HomespunCore
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing
@testable import HomespunServerKit

@Test(arguments: [false, true])
func durablePublicationStopsAtTheConfiguredRootRegardlessOfDirectoryHint(_ directoryHint: Bool) throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("originals").path
    let root = URL(fileURLWithPath: path, isDirectory: directoryHint)
    let file = URL(fileURLWithPath: path + "/one/two/original.bin")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("synthetic-original".utf8).write(to: file)
    let expected = [path + "/one/two", path + "/one", path]
    var visited: [String] = []
    try BackupDurability.publish(file, root: root) { candidate in
        // Fail promptly if a regression escapes the boundary instead of hanging
        // the cooperative pool (the filesystem root is its own parent).
        guard visited.count < expected.count else { throw CocoaError(.fileWriteInvalidFileName) }
        visited.append(candidate.path)
    }
    #expect(visited == expected)
}

@Test func durablePublicationRejectsASiblingWithTheSamePathPrefixBeforeSyncing() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = directory.appendingPathComponent("originals", isDirectory: true)
    let outside = directory.appendingPathComponent("originals-other/original.bin")
    try FileManager.default.createDirectory(at: outside.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("synthetic-original".utf8).write(to: outside)
    var synced = false
    #expect(throws: CocoaError.self) {
        try BackupDurability.publish(outside, root: root) { _ in synced = true }
    }
    #expect(!synced)
}

@Test func backupCatalogCodecsDoNotMutateWireDatesOrAcronymKeys() throws {
    let bytes = Data("codec-original".utf8)
    let request = BackupAPI.Request(operationID: UUID(), origin: .init(serverID: "server", historyEpoch: "epoch"),
        manifest: .init(kind: .photo, resources: [.init(role: .photo, filename: "a.jpg", size: bytes.count,
            sha256: Fingerprint.sha256(of: bytes), sha1: Fingerprint.sha1(of: bytes))]),
        profile: testProfile, captureDate: Date(timeIntervalSince1970: 1_700_000_000))
    let before = try ServerAPI.encoder.encode(request)
    _ = try Catalog.backupIntentHash(request)
    let stored = try Catalog.backupJSON(request)
    #expect(try Catalog.backupDecode(BackupAPI.Request.self, stored) == request)
    let after = try ServerAPI.encoder.encode(request)
    #expect(after == before)
    let object = try #require(JSONSerialization.jsonObject(with: after) as? [String: Any])
    #expect(object["capture_date"] is String)
    #expect(try ServerAPI.decoder.decode(BackupAPI.Request.self, from: after) == request)

    let legacy = JSONEncoder()
    legacy.keyEncodingStrategy = .convertToSnakeCase
    legacy.dateEncodingStrategy = .millisecondsSince1970
    let legacyJSON = String(decoding: try legacy.encode(request), as: UTF8.self)
    #expect(try Catalog.backupDecode(BackupAPI.Request.self, legacyJSON) == request)
    #expect(try ServerAPI.encoder.encode(request) == before)
}

extension Catalog {
    func copyRecoveryCountsForTest() throws -> [Int] {
        try ["backup_requests", "backup_claims", "backup_objects", "backup_uploads"].map { table in
            try database.query("SELECT COUNT(*) AS n FROM \(table)").first!["n"]!.int!
        }
    }

    func makeBackupCopiesDueForTest() throws {
        try database.execute("UPDATE backup_connector_jobs SET available_at = '2000-01-01T00:00:00Z' WHERE status = 'retry_wait'")
    }
}

private struct ImportedCopyRecovery: Sendable {
    var originals: BackupAPI.Manifest
    var compact: BackupAPI.Manifest
    var files: [URL]

    static func make(_ fixture: Fixture) async throws -> Self {
        let archive = fixture.directory.appendingPathComponent("archive")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        var resources: [ResourceRecord] = [], files: [URL] = []
        for role in [ServerAPI.ResourceRole.photo, .pairedVideo, .alternatePhoto] {
            let bytes = Data(("synthetic-original-" + role.rawValue).utf8)
            let file = archive.appendingPathComponent(role.rawValue)
            try bytes.write(to: file)
            files.append(file)
            resources.append(.init(role: role, filename: role.rawValue, size: bytes.count,
                sha256: Fingerprint.sha256(of: bytes), sha1: nil, state: .verified,
                receivedBytes: bytes.count, storedPath: nil, immichAssetID: nil,
                verifiedAt: Timestamp.string(), externalPath: file.path))
        }
        let original = BackupAPI.Manifest(kind: .livePhoto, resources: resources.map {
            .init(role: $0.role, filename: $0.filename, size: $0.size, sha256: $0.sha256)
        })
        let compact = BackupAPI.Manifest(kind: .livePhoto, resources: [ServerAPI.ResourceRole.photo, .pairedVideo].map { role in
            let bytes = Data(("copy-" + role.rawValue).utf8)
            return .init(role: role, filename: role.rawValue, size: bytes.count, sha256: Fingerprint.sha256(of: bytes))
        })
        _ = try await fixture.server.catalog.importExisting(assetID: original.assetID(), kind: original.kind,
            captureDate: nil, originals: resources, copies: compact.resources.map { .init(role: $0.role, sha256: $0.sha256) })
        return .init(originals: original, compact: compact, files: files)
    }
}

@Test func copyRecoveryAdoptsAllImportedOriginalsWithRealVersionedProofAndIdempotentClaims() async throws {
    let fixture = try await Fixture()
    let item = try await ImportedCopyRecovery.make(fixture)
    try await fixture.test { client, token in
        let capabilities = try await client.call("/api/v2/capabilities", token: token).decode(BackupAPI.Capabilities.self)
        let lookup = BackupAPI.CopyLookup(origin: capabilities.origin, assetID: try item.originals.assetID(), compact: item.compact)
        #expect(try await client.call("/api/v2/copies/resolve", .post, json: lookup).status == .unauthorized)
        let candidate = try await client.call("/api/v2/copies/resolve", .post, token: token, json: lookup)
            .decode(BackupAPI.CopyCandidate.self)
        #expect(try candidate.manifest.identifier() == item.originals.identifier())
        #expect(candidate.manifest.resources.count == 3)
        let request = BackupAPI.Request(operationID: UUID(), origin: capabilities.origin, manifest: candidate.manifest,
            profile: capabilities.recipe.profile, compact: false)
        let adoption = BackupAPI.CopyAdoption(request: request, compact: item.compact)
        let retained = try await client.call("/api/v2/copies/adopt", .post, token: token, json: adoption).decode(BackupAPI.Receipt.self)
        #expect(retained.backup == .retained && retained.retention == .permanent && retained.derivative == nil)
        #expect(retained.version.descriptorGeneration > 0 && retained.revision > 0 && retained.originals.count == 3)
        let proofPath = "/api/v2/assets/\(retained.version.assetID)/versions/\(retained.version.manifestID)/verify"
        let proof = try await client.call(proofPath, .post, token: token, json: retained.version).decode(BackupAPI.OriginalProof.self)
        #expect(proof.version == retained.version && proof.retention == .permanent && proof.claimID != nil)
        #expect(proof.resources.allSatisfy { $0.state == .verified && $0.receivedBytes == $0.size })
        let counts = try await fixture.server.catalog.copyRecoveryCountsForTest()
        #expect(counts == [1, 1, 3, 3])
        let repeated = try await client.call("/api/v2/copies/adopt", .post, token: token, json: adoption).decode(BackupAPI.Receipt.self)
        #expect(repeated == retained)
        #expect(try await fixture.server.catalog.copyRecoveryCountsForTest() == counts)
        #expect(try await client.call("/api/v2/backup-requests?operation_id=\(request.operationID)", token: token)
            .decode(BackupAPI.Receipt.self) == retained)
        let reopened = try Catalog(path: fixture.server.storage.catalog.path)
        let principal = try #require(try await fixture.server.catalog.devices().first?.id)
        let (replayed, created) = try await reopened.admitBackup(request, principal: principal,
            recipe: capabilities.recipe, external: false, copy: item.compact)
        #expect(!created && replayed == retained)
        #expect(try await reopened.copyRecoveryCountsForTest() == counts)
        var differentCopy = adoption
        differentCopy.compact.resources[1].sha256 = Fingerprint.sha256(of: Data("another-equivalent-copy".utf8))
        try await fixture.server.catalog.rememberCopies(lookup.assetID,
            [.init(role: differentCopy.compact.resources[1].role, sha256: differentCopy.compact.resources[1].sha256)])
        let conflict = try await client.call("/api/v2/copies/adopt", .post, token: token, json: differentCopy)
        #expect(conflict.status == .conflict)
        #expect(try conflict.decode(ServerAPI.ErrorBody.self).error.code == BackupAPI.ErrorCode.idempotencyConflict)
        #expect(try await fixture.server.catalog.copyRecoveryCountsForTest() == counts)
        for (index, file) in item.files.enumerated() {
            #expect(try Fingerprint.sha256(of: file) == item.originals.resources[index].sha256)
        }

        let other = try await fixture.pair(client)
        #expect(try await client.call("/api/v2/backup-requests/\(retained.requestID)", token: other).status == .notFound)
        #expect(try await client.call(proofPath, .post, token: other, json: retained.version).status == .conflict)
        let otherReceipt = try await client.call("/api/v2/copies/adopt", .post, token: other, json: adoption).decode(BackupAPI.Receipt.self)
        #expect(otherReceipt.requestID != retained.requestID && otherReceipt.version == retained.version)
        #expect(try await fixture.server.catalog.copyRecoveryCountsForTest() == [2, 2, 3, 3])

        // A later original mismatch is caught by the same real proof endpoint used at deletion.
        let object = try #require(try await fixture.server.catalog.backupObjects(retained.version.manifestID).first)
        let path = try #require(object.path), url = try #require(await fixture.server.originals.url(path))
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: url.path)
        try Data(repeating: 0, count: object.size).write(to: url)
        #expect(try await client.call(proofPath, .post, token: token, json: retained.version).status == .conflict)
    }
}

@Test func copyRecoveryRejectsPartialChangedAndStaleEvidenceWithoutTrustingLegacyVerification() async throws {
    let fixture = try await Fixture()
    let item = try await ImportedCopyRecovery.make(fixture)
    try await fixture.test { client, token in
        let capabilities = try await client.call("/api/v2/capabilities", token: token).decode(BackupAPI.Capabilities.self)
        let lookup = BackupAPI.CopyLookup(origin: capabilities.origin, assetID: try item.originals.assetID(), compact: item.compact)
        var partial = lookup
        partial.compact.resources.removeLast()
        let incomplete = try await client.call("/api/v2/copies/resolve", .post, token: token, json: partial)
        #expect(incomplete.status == .badRequest)
        #expect(try incomplete.decode(ServerAPI.ErrorBody.self).error.code == "invalid_request")
        var changed = lookup
        changed.compact.resources[1].sha256 = String(repeating: "f", count: 64)
        #expect(try await client.call("/api/v2/copies/resolve", .post, token: token, json: changed).status == .conflict)
        var stale = lookup
        stale.origin.historyEpoch = UUID().uuidString
        #expect(try await client.call("/api/v2/copies/resolve", .post, token: token, json: stale).status == .conflict)
        #expect(try await fixture.server.catalog.copyRecoveryCountsForTest() == [0, 0, 0, 0])

        // Source metadata still says verified; current bytes, including secondary originals,
        // must nevertheless pass the existing immutable adoption/publication path.
        try Data("changed-secondary".utf8).write(to: item.files[1])
        let candidate = try await client.call("/api/v2/copies/resolve", .post, token: token, json: lookup)
            .decode(BackupAPI.CopyCandidate.self)
        let request = BackupAPI.Request(operationID: UUID(), origin: capabilities.origin, manifest: candidate.manifest,
            profile: capabilities.recipe.profile, compact: false)
        let adoption = BackupAPI.CopyAdoption(request: request, compact: item.compact)
        #expect(try await client.call("/api/v2/copies/adopt", .post, token: token, json: adoption).status == .conflict)
        let pending = try await client.call("/api/v2/backup-requests?operation_id=\(request.operationID)", token: token)
            .decode(BackupAPI.Receipt.self)
        #expect(pending.retention == .pending && pending.backup != .retained)
        #expect(try await client.call(
            "/api/v2/assets/\(pending.version.assetID)/versions/\(pending.version.manifestID)/verify",
            .post, token: token, json: pending.version).status == .conflict)
        var wrongManifest = adoption
        wrongManifest.request.manifest.resources[0].size += 1
        #expect(try await client.call("/api/v2/copies/adopt", .post, token: token, json: wrongManifest).status == .conflict)

        var secondaryVersion = candidate.manifest
        let secondary = try #require(secondaryVersion.resources.firstIndex { $0.role == .pairedVideo })
        secondaryVersion.resources[secondary].sha256 = Fingerprint.sha256(of: Data("different-motion-version".utf8))
        let competing = BackupAPI.Request(operationID: UUID(), origin: capabilities.origin, manifest: secondaryVersion,
            profile: capabilities.recipe.profile, compact: false)
        #expect(try await client.call("/api/v2/backup-requests", .post, token: token, json: competing).status == .created)
        let counts = try await fixture.server.catalog.copyRecoveryCountsForTest()
        // The primary hash is unchanged, but it cannot select between whole original versions.
        #expect(try await client.call("/api/v2/copies/resolve", .post, token: token, json: lookup).status == .conflict)
        #expect(try await fixture.server.catalog.copyRecoveryCountsForTest() == counts)
    }
}

extension Catalog {
    func wakeRouteCountForTest() throws -> Int {
        try database.query("SELECT COUNT(*) AS n FROM backup_wake_routes").first!["n"]!.int!
    }

    func eventDetailsForTest() throws -> String {
        try database.query("SELECT detail FROM events").compactMap { $0["detail"]?.string }.joined(separator: "\n")
    }
}

@Test func delayedAcceptedCancelReplaysItsOutcomeWithoutExecutingAfterRetry() async throws {
    let fixture = try await Fixture()
    try await fixture.test { client, token in
        let (_, receipt) = try await backupTestRequest(client, token: token, data: Data("command-version".utf8))
        let cancel = BackupAPI.Command(operationID: UUID(), version: receipt.version, action: .cancel)
        let cancelled = try await client.call("/api/v2/backup-requests/\(receipt.requestID)/commands", .post, token: token, json: cancel)
            .decode(BackupAPI.Receipt.self)
        let retry = try await client.call("/api/v2/backup-requests/\(receipt.requestID)/commands", .post, token: token,
            json: BackupAPI.Command(operationID: UUID(), version: receipt.version, action: .retry)).decode(BackupAPI.Receipt.self)
        #expect(retry.revision > cancelled.revision)
        let delayed = try await client.call("/api/v2/backup-requests/\(receipt.requestID)/commands", .post, token: token, json: cancel)
            .decode(BackupAPI.Receipt.self)
        #expect(delayed == cancelled)
        #expect(try await client.call("/api/v2/backup-requests/\(receipt.requestID)", token: token)
            .decode(BackupAPI.Receipt.self) == retry)
    }
}

@Test func oneDriveImmutableNamesPreserveOlderSecondaryVersionsAndDeduplicateRetries() async throws {
    let remote = FakeMicrosoft()
    try await Application(router: remote.router(), configuration: .init(address: .hostname("localhost", port: 0))).test(.live) { live in
        let base = "http://localhost:\(live.port!)"
        remote.lock.withLock { remote.base = base; remote.valid.insert("version-access") }
        let connector = OneDriveConnector(clientID: "test-client", authority: URL(string: base + "/common")!,
                                         graph: URL(string: base + "/v1.0")!)
        await connector.tokens.store("version-access", lifetime: 3600)
        let fixture = try await Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let context = await fixture.server.connectorContext("onedrive")
        let original = Data("cloud-primary".utf8), a = Data("secondary-A".utf8), b = Data("secondary-B".utf8)
        let first = fixture.directory.appendingPathComponent("primary.jpg"), second = fixture.directory.appendingPathComponent("secondary.jpg")
        try original.write(to: first)
        func item(_ secondary: Data) throws -> ConnectorItem {
            try secondary.write(to: second)
            let manifest = BackupAPI.Manifest(kind: .photo, resources: [
                .init(role: .photo, filename: "same.jpg", size: original.count, sha256: Fingerprint.sha256(of: original)),
                .init(role: .alternatePhoto, filename: "same.jpg", size: secondary.count, sha256: Fingerprint.sha256(of: secondary))
            ])
            return .init(assetID: try manifest.assetID(), kind: .photo, captureDate: nil, files: [
                .init(role: .photo, url: first, filename: "same.jpg", size: original.count, sha256: Fingerprint.sha256(of: original)),
                .init(role: .alternatePhoto, url: second, filename: "same.jpg", size: secondary.count, sha256: Fingerprint.sha256(of: secondary))
            ], immutableManifestID: try manifest.identifier())
        }
        let versionA = try item(a)
        let manifestA = try #require(versionA.immutableManifestID)
        _ = try await connector.copy(versionA, context: context)
        _ = try await connector.copy(versionA, context: context)
        #expect(remote.lock.withLock { remote.uploads } == 2)
        let versionB = try item(b)
        _ = try await connector.copy(versionB, context: context)
        let stored = remote.lock.withLock { remote.files }
        #expect(stored.count == 4 && remote.lock.withLock { remote.uploads } == 4)
        #expect(stored.keys.contains { $0.contains(manifestA) })
        #expect(Set(stored.values.map { $0.data }) == Set([original, a, b]))
        let collision = try #require(stored.keys.first { $0.contains(manifestA) && $0.contains("/photo-") })
        let rogue = Data("keep-this-existing-object".utf8)
        remote.lock.withLock { remote.files[collision] = (rogue, nil) }
        await #expect(throws: ConnectorError.self) { _ = try await connector.copy(versionA, context: context) }
        #expect(remote.lock.withLock { remote.files[collision]?.data } == rogue)
    }
}

@Test func immutableConnectorCopiesCaptureEveryVersionAndRetryWithoutReleasingOriginals() async throws {
    let fake = FakeConnector()
    let fixture = try await Fixture(connectors: [fake])
    try await fixture.test { client, token in
        _ = try await client.call("/api/v1/connectors/fake", .put, token: token, json: ServerAPI.ConnectorUpdate(enabled: true))
        let caps = try await client.call("/api/v2/capabilities", token: token).decode(BackupAPI.Capabilities.self)
        let primary = Data("same-primary".utf8)
        var receipts: [BackupAPI.Receipt] = []
        for value in ["secondary-one", "secondary-two"] {
            let secondary = Data(value.utf8)
            let request = BackupAPI.Request(operationID: UUID(), origin: caps.origin, manifest: .init(kind: .photo, resources: [
                .init(role: .photo, filename: "same.jpg", size: primary.count, sha256: Fingerprint.sha256(of: primary)),
                .init(role: .alternatePhoto, filename: "same.jpg", size: secondary.count, sha256: Fingerprint.sha256(of: secondary))
            ]), profile: caps.recipe.profile, compact: false)
            let receipt = try await client.call("/api/v2/backup-requests", .post, token: token, json: request).decode(BackupAPI.Receipt.self)
            _ = try await backupTestUpload(client, token: token, receipt: receipt, data: primary)
            receipts.append(try await backupTestUpload(client, token: token, receipt: receipt, role: .alternatePhoto, data: secondary))
        }
        let worker = BackupConnectorWorker(catalog: fixture.server.catalog, storage: fixture.server.storage,
            originals: fixture.server.originals, budget: fixture.server.budget, hub: fixture.server.hub,
            immich: fixture.server.immichState, configuration: fixture.server.configuration)
        fake.lock.withLock { fake.behaviour = .retryLater }
        #expect(try await worker.runNext())
        fake.lock.withLock { fake.behaviour = .copy }
        try await fixture.server.catalog.makeBackupCopiesDueForTest()
        while try await worker.runNext() {}
        let captured = fake.lock.withLock { (fake.copies, fake.manifests) }
        #expect(captured.0.count == 2)
        #expect(Set(captured.1.compactMap { $0 }) == Set(receipts.map(\.version.manifestID)))
        #expect(Set(captured.0.compactMap { $0.files[.alternatePhoto] }) == Set([Data("secondary-one".utf8), Data("secondary-two".utf8)]))
        #expect(captured.0.allSatisfy { $0.files[.photo] == primary })
        let counts = try await client.call("/api/v1/connectors", token: token).decode([ServerAPI.ConnectorInfo].self)
        #expect(counts.first?.counts.copied == 2)
        for receipt in receipts {
            let status = try await client.call("/api/v2/backup-requests/\(receipt.requestID)/copies", token: token)
                .decode([String: ServerAPI.ConnectorCounts].self)
            #expect(status["fake"]?.copied == 1)
            #expect(try await client.call("/api/v2/backup-requests/\(receipt.requestID)", token: token)
                .decode(BackupAPI.Receipt.self).retention == .permanent)
        }
        let other = try await fixture.pair(client)
        #expect(try await client.call("/api/v2/backup-requests/\(receipts[0].requestID)/copies", token: other).status == .notFound)
        let (_, third) = try await backupTestRequest(client, token: token, data: Data("cancelled-copy".utf8))
        _ = try await backupTestUpload(client, token: token, receipt: third, data: Data("cancelled-copy".utf8))
        let destinations = try await fixture.server.hub.enabledDestinations()
        try await fixture.server.catalog.queueBackupCopies(connectors: destinations)
        let claimed = try #require(try await fixture.server.catalog.claimBackupCopy(owner: "stale-copy", connectors: ["fake"]))
        _ = try await client.call("/api/v1/connectors/fake", .put, token: token, json: ServerAPI.ConnectorUpdate(enabled: false))
        #expect(try await !fixture.server.catalog.heartbeatBackupCopy(claimed))
        await #expect(throws: CancellationError.self) {
            try await fixture.server.catalog.finishBackupCopy(claimed, reference: "not-current")
        }
        #expect(try await fixture.server.catalog.versionedCopyCounts(connector: "fake").copied == 2)
    }
}

@Test func externalProofAlwaysScrubsBytesAndRejectsRemovalOrChecksumPreservingMutation() async throws {
    let remote = FakeImmich(), bytes = Data("external-full-original".utf8)
    let original = remote.add(bytes)
    try await Application(router: remote.router(), configuration: .init(address: .hostname("localhost", port: 0))).test(.live) { live in
        let fake = FakeConnector()
        let fixture = try await Fixture(immich: .init(url: URL(string: "http://localhost:\(live.port!)")!, apiKey: remote.key), connectors: [fake])
        try await fixture.test { client, token in
            _ = try await client.call("/api/v1/connectors/fake", .put, token: token, json: ServerAPI.ConnectorUpdate(enabled: true))
            let caps = try await client.call("/api/v2/capabilities", token: token).decode(BackupAPI.Capabilities.self)
            #expect(caps.uploadProtocols.isEmpty && caps.externalVerification == .fullResourceScrub)
            let (_, receipt) = try await backupTestRequest(client, token: token, data: bytes)
            let acquisition = BackupExternalWorker(lane: "photo", catalog: fixture.server.catalog, storage: fixture.server.storage,
                immich: fixture.server.immichState, budget: fixture.server.budget, configuration: fixture.server.configuration)
            #expect(try await acquisition.runNext())
            let retained = try await client.call("/api/v2/backup-requests/\(receipt.requestID)", token: token).decode(BackupAPI.Receipt.self)
            #expect(retained.backup == .retained && retained.retention == .external)
            let cloud = BackupConnectorWorker(catalog: fixture.server.catalog, storage: fixture.server.storage,
                originals: fixture.server.originals, budget: fixture.server.budget, hub: fixture.server.hub,
                immich: fixture.server.immichState, configuration: fixture.server.configuration)
            #expect(try await cloud.runNext())
            #expect(fake.lock.withLock { fake.copies.first?.files[.photo] } == bytes)
            let proofURL = "/api/v2/assets/\(receipt.version.assetID)/versions/\(receipt.version.manifestID)/verify"
            for _ in 0..<2 {
                let before = remote.lock.withLock { remote.downloads[original, default: 0] }
                let proof = try await client.call(proofURL, .post, token: token, json: receipt.version).decode(BackupAPI.OriginalProof.self)
                #expect(proof.retention == .external && proof.claimID == nil && proof.resources.allSatisfy { $0.state == .verified })
                #expect(remote.lock.withLock { remote.downloads[original, default: 0] } == before + 1)
            }
            let sourceURL = "/api/v2/assets/\(receipt.version.assetID)/versions/\(receipt.version.manifestID)/resources/photo?request_id=\(receipt.requestID)"
            #expect(try await client.call(sourceURL, token: token).data == bytes)
            remote.lock.withLock { remote.downloadOverrides[original] = Data(repeating: 0, count: bytes.count) }
            #expect(try await client.call(proofURL, .post, token: token, json: receipt.version).status == .conflict)
            #expect(try await client.call(sourceURL, token: token).status == .conflict)
            remote.lock.withLock { remote.assets[original] = nil; remote.downloadOverrides[original] = nil }
            #expect(try await client.call(proofURL, .post, token: token, json: receipt.version).status == .conflict)
            #expect(try await fixture.server.catalog.backupObjects(receipt.version.manifestID).allSatisfy { $0.path == nil })
            #expect(try FileManager.default.subpathsOfDirectory(atPath: fixture.server.storage.originals.path).isEmpty)
        }
    }
}

@Test(.enabled(if: ffmpegAvailable)) func externalAcquisitionQueuesIndependentCompactionWithoutManagedOriginalDuplicates() async throws {
    let remote = FakeImmich()
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let media = try await Media.make(in: directory), bytes = try Data(contentsOf: media.photo)
    _ = remote.add(bytes)
    try await Application(router: remote.router(), configuration: .init(address: .hostname("localhost", port: 0))).test(.live) { live in
        let fixture = try await Fixture(immich: .init(url: URL(string: "http://localhost:\(live.port!)")!, apiKey: remote.key))
        try await fixture.test { client, token in
            let (_, receipt) = try await backupTestRequest(client, token: token, data: bytes, compact: true)
            let acquisition = BackupExternalWorker(lane: "photo", catalog: fixture.server.catalog, storage: fixture.server.storage,
                immich: fixture.server.immichState, budget: fixture.server.budget, configuration: fixture.server.configuration)
            #expect(try await acquisition.runNext())
            #expect(try await fixture.server.backupPhoto.runNext())
            let ready = try await client.call("/api/v2/backup-requests/\(receipt.requestID)", token: token).decode(BackupAPI.Receipt.self)
            #expect(ready.backup == .retained && ready.retention == .external && ready.compact == .ready && ready.derivative != nil)
            #expect(try await fixture.server.catalog.backupObjects(receipt.version.manifestID).allSatisfy { $0.path == nil })
            #expect(try FileManager.default.subpathsOfDirectory(atPath: fixture.server.storage.originals.path).isEmpty)
        }
    }
}

@Test func externalScrubIncludesLivePhotoMotionAndBlocksEditedOrRawDescriptors() async throws {
    let remote = FakeImmich(), still = Data("still-original".utf8), motion = Data("motion-original".utf8)
    let motionID = remote.add(motion)
    _ = remote.add(still, motion: motionID)
    try await Application(router: remote.router(), configuration: .init(address: .hostname("localhost", port: 0))).test(.live) { live in
        let fixture = try await Fixture(immich: .init(url: URL(string: "http://localhost:\(live.port!)")!, apiKey: remote.key))
        try await fixture.test { client, token in
            let caps = try await client.call("/api/v2/capabilities", token: token).decode(BackupAPI.Capabilities.self)
            var request = BackupAPI.Request(operationID: UUID(), origin: caps.origin, manifest: .init(kind: .livePhoto, resources: [
                .init(role: .photo, filename: "a.jpg", size: still.count, sha256: Fingerprint.sha256(of: still), sha1: Fingerprint.sha1(of: still)),
                .init(role: .pairedVideo, filename: "a.mov", size: motion.count, sha256: Fingerprint.sha256(of: motion), sha1: Fingerprint.sha1(of: motion))
            ]), profile: caps.recipe.profile, compact: false)
            let receipt = try await client.call("/api/v2/backup-requests", .post, token: token, json: request).decode(BackupAPI.Receipt.self)
            let url = "/api/v2/assets/\(receipt.version.assetID)/versions/\(receipt.version.manifestID)/verify"
            #expect(try await client.call(url, .post, token: token, json: receipt.version).status == .ok)
            remote.lock.withLock { remote.downloadOverrides[motionID] = Data(repeating: 1, count: motion.count) }
            #expect(try await client.call(url, .post, token: token, json: receipt.version).status == .conflict)
            request.operationID = UUID()
            request.manifest.resources[0].filename = "RAW.DNG"
            #expect(try await client.call("/api/v2/backup-requests", .post, token: token, json: request).status == .unprocessableContent)
            request.operationID = UUID()
            request.manifest.resources[0].filename = "a.jpg"
            request.manifest.resources[0].role = .fullSizePhoto
            let rejected = try await client.call("/api/v2/backup-requests", .post, token: token, json: request)
            #expect([.badRequest, .unprocessableContent].contains(rejected.status))
        }
    }
}

private actor FakeWakeSender: WakeHintSending {
    var results: [WakeHintResult]
    var calls: [(WakeRelayAPI.Sender, UUID)] = []
    init(_ results: [WakeHintResult]) { self.results = results }
    func send(_ sender: WakeRelayAPI.Sender, nonce: UUID) async throws -> WakeHintResult {
        calls.append((sender, nonce))
        return results.isEmpty ? .accepted : results.removeFirst()
    }
}

@Test func wakeEnrollmentIsOptionalPrivateAndGenerationFenced() async throws {
    let disabled = try await Fixture()
    let sender = WakeRelayAPI.Sender(routeID: UUID(), generationID: UUID(), token: PairingCrypto.encode(Data(repeating: 8, count: 32)))
    try await disabled.test { client, token in
        let response = try await client.call("/api/v2/wake/enrollment", .post, token: token, json: sender)
        let count = try await disabled.server.catalog.wakeRouteCountForTest()
        #expect(response.status == .serviceUnavailable)
        #expect(count == 0)
    }
    let relay = URL(string: "https://relay.example.invalid")!
    let fixture = try await Fixture(wakeRelay: relay)
    try await fixture.test { client, token in
        let (_, receipt) = try await backupTestRequest(client, token: token, data: Data("wake-result".utf8))
        let enrolled = try await client.call("/api/v2/wake/enrollment", .post, token: token, json: sender)
        #expect(enrolled.status == .noContent && enrolled.headers[.eTag] == "\"\(sender.generationID.uuidString.lowercased())\"")
        var invalid = sender
        invalid.token += "="
        #expect(try await client.call("/api/v2/wake/enrollment", .post, token: token, json: invalid).status == .badRequest)
        let other = try await fixture.pair(client)
        #expect(try await client.call("/api/v2/wake/enrollment", .post, token: other, json: sender).status == .conflict)
        let principal = try #require(try await fixture.server.catalog.device(tokenHash: Pairing.hash(token))).id
        let now = Date().addingTimeInterval(1)
        let claimed = try #require(try await fixture.server.catalog.claimBackupWake(owner: "old-route", relay: relay, now: now))
        let replacement = WakeRelayAPI.Sender(routeID: UUID(), generationID: UUID(),
            token: PairingCrypto.encode(Data(repeating: 9, count: 32)))
        #expect(try await client.call("/api/v2/wake/enrollment", .post, token: token, json: replacement).status == .noContent)
        try await fixture.server.catalog.completeBackupWake(claimed, result: .gone, relay: relay, now: now)
        #expect(try await fixture.server.catalog.wakeRouteCountForTest() == 1)
        #expect(try await client.call("/api/v2/wake/enrollment", .post, token: token, json: sender).status == .conflict)
        var headers = HTTPFields()
        headers[.authorization] = "Bearer \(token)"
        headers[.ifMatch] = "\"\(sender.generationID)\""
        #expect(try await client.execute(uri: "/api/v2/wake/enrollment", method: .delete, headers: headers, body: nil).status == .noContent)
        #expect(try await fixture.server.catalog.wakeRouteCountForTest() == 1)
        #expect(try await !fixture.server.catalog.eventDetailsForTest().contains(sender.token))
        #expect(!String(describing: replacement).contains(replacement.token))
        #expect(try await fixture.server.catalog.revoke(deviceID: principal))
        #expect(try await fixture.server.catalog.wakeRouteCountForTest() == 0)
        #expect(try await client.call("/api/v2/backup-requests/\(receipt.requestID)", token: token).status == .unauthorized)
    }
}

@Test func wakeRetriesCoalesceWithoutLosingAChangeBehindALostResponseNonce() async throws {
    let relay = URL(string: "https://relay.example.invalid")!
    let fixture = try await Fixture(wakeRelay: relay)
    try await fixture.test { client, token in
        let (_, receipt) = try await backupTestRequest(client, token: token, data: Data("wake-coalescing".utf8))
        let sender = WakeRelayAPI.Sender(routeID: UUID(), generationID: UUID(),
            token: PairingCrypto.encode(Data(repeating: 5, count: 32)))
        _ = try await client.call("/api/v2/wake/enrollment", .post, token: token, json: sender)
        let fake = FakeWakeSender([.retry, .accepted, .accepted])
        let worker = BackupWakeWorker(catalog: fixture.server.catalog, relay: relay, sender: fake, ownedClient: nil)
        let now = Date().addingTimeInterval(1)
        #expect(try await worker.runNext(now: now))
        _ = try await client.call("/api/v2/backup-requests/\(receipt.requestID)/commands", .post, token: token,
            json: BackupAPI.Command(operationID: UUID(), version: receipt.version, action: .pause))
        #expect(try await worker.runNext(now: now.addingTimeInterval(31)))
        #expect(try await !worker.runNext(now: now.addingTimeInterval(32)))
        #expect(try await worker.runNext(now: now.addingTimeInterval(31 + 1201)))
        let calls = await fake.calls
        #expect(calls.count == 3 && calls[0].1 == calls[1].1 && calls[2].1 != calls[1].1)
        #expect(calls.allSatisfy { $0.0 == sender })
        #expect(try await !worker.runNext(now: now.addingTimeInterval(4000)))
        let principal = try #require(try await fixture.server.catalog.device(tokenHash: Pairing.hash(token))).id
        #expect(try await fixture.server.catalog.backupReceipt(receipt.requestID.uuidString.lowercased(),
                                                               principal: principal).retention == .pending)
    }
}
