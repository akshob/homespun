// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import HomespunCore
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing
@testable import HomespunServerKit

extension Catalog {
    func makeBackupCopiesDueForTest() throws {
        try database.execute("UPDATE backup_connector_jobs SET available_at = '2000-01-01T00:00:00Z' WHERE status = 'retry_wait'")
    }

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
