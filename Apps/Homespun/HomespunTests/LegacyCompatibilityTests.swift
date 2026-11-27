// SPDX-License-Identifier: Apache-2.0
import Foundation
import HomespunCore
import HomespunTestSupport
import Photos
import Synchronization
import Testing
@testable import Homespun

private final class LegacyProtocol: URLProtocol, @unchecked Sendable {
    final class Context: Sendable {
        let server: Mutex<DemoServer>
        let transform = Mutex<(@Sendable (String, DemoServer.Response) async throws -> DemoServer.Response)?>(nil)
        let requests = Mutex<[String]>([])
        init(_ server: DemoServer) { self.server = Mutex(server) }
    }
    static let contexts = Mutex<[String: Context]>([:])
    private var loading: Task<Void, Never>?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = request
        let key = request.value(forHTTPHeaderField: "X-Legacy-Test") ?? ""
        guard let context = Self.contexts.withLock({ $0[key] }), let url = request.url else { return }
        let loader = Unchecked(value: (self as URLProtocol, client))
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
        }
        let payload = body
        loading = Task {
            do {
                let path = url.path
                context.requests.withLock { $0.append(path) }
                let token = request.value(forHTTPHeaderField: "Authorization").map { String($0.dropFirst(7)) }
                let server = context.server.withLock { $0 }
                var answer = await server.handle(method: request.httpMethod ?? "GET", url: url, token: token,
                    body: payload, headers: request.allHTTPHeaderFields ?? [:])
                if let transform = context.transform.withLock({ $0 }) { answer = try await transform(path, answer) }
                guard !Task.isCancelled else { return }
                var headers = answer.headers
                headers["Content-Length"] = String(answer.body.count)
                let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: nil, headerFields: headers)!
                loader.value.1?.urlProtocol(loader.value.0, didReceive: response, cacheStoragePolicy: .notAllowed)
                loader.value.1?.urlProtocol(loader.value.0, didLoad: answer.body)
                loader.value.1?.urlProtocolDidFinishLoading(loader.value.0)
            } catch { loader.value.1?.urlProtocol(loader.value.0, didFailWithError: error) }
        }
    }

    override func stopLoading() { loading?.cancel() }
}

@MainActor @Suite(.serialized) struct LegacyCompatibilityTests {
    private final class Fixture {
        let id = UUID().uuidString
        let folder: URL
        let defaults: UserDefaults
        let library: DemoLibrary
        let server: DemoServer
        let context: LegacyProtocol.Context
        let session: URLSession
        let settings: AppSettings
        let ledger: CompactLedger
        let asked = Mutex(0)
        var client: ServerClient { settings.client! }
        var scope: String { settings.currentLegacyScope! }

        init() throws {
            folder = URL.applicationSupportDirectory.appendingPathComponent("legacy-test-" + id)
            defaults = UserDefaults(suiteName: "legacy-test-" + id)!
            let media = folder.appendingPathComponent("media")
            try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
            var samples: [DemoSample] = []
            for index in 0..<3 {
                let name = "photo-\(index)"
                try Synthetic.photo(at: media.appendingPathComponent(name + ".jpg"),
                    .init(width: 1200, height: 900, quality: 1))
                samples.append(.init(name: name, kind: "photo", date: "2024-05-0\(index + 1)T12:00:00Z",
                    width: 1200, height: 900, files: ["photo": name + ".jpg"]))
            }
            try JSONEncoder().encode(samples).write(to: media.appendingPathComponent("samples.json"))
            let asked = asked
            library = DemoLibrary(folder: folder.appendingPathComponent("library"), media: media) { _ in
                asked.withLock { $0 += 1 }
                return true
            }
            server = DemoServer(folder: folder.appendingPathComponent("server"), pace: 0, backupAPI: false, bundledCompact: { _ in nil })
            context = LegacyProtocol.Context(server)
            let key = id, registered = context
            LegacyProtocol.contexts.withLock { $0[key] = registered }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [LegacyProtocol.self]
            configuration.httpAdditionalHeaders = ["X-Legacy-Test": id]
            session = URLSession(configuration: configuration)
            settings = AppSettings(defaults: defaults, photos: library, tokens: DemoTokens(defaults: defaults),
                session: session, installationStore: DefaultsInstallation(defaults: defaults))
            ledger = CompactLedger(url: folder.appendingPathComponent("ledger.json"))
        }

        func pair() async throws {
            let challenge = await server.handle(method: "POST", url: DemoServer.baseURL.appendingPathComponent("api/v1/pair/challenge"),
                token: nil, body: try ServerAPI.encoder.encode(ServerAPI.CodeChallengeRequest(nonce: PairingCrypto.encode(PairingCrypto.nonce()))))
            let ticket = try ServerAPI.decoder.decode(ServerAPI.CodeChallenge.self, from: challenge.body)
            let response = await server.handle(method: "POST", url: DemoServer.baseURL.appendingPathComponent("api/v1/pair"),
                token: nil, body: try ServerAPI.encoder.encode(ServerAPI.PairRequest(code: "DEMO-2468", deviceName: "Test",
                    challenge: ticket.id)))
            let pairing = try ServerAPI.decoder.decode(ServerAPI.PairResponse.self, from: response.body)
            try settings.finishPairing(serverURL: DemoServer.baseURL, response: pairing,
                pins: .init(pins: [DemoServer.fingerprint], source: "test"))
            await settings.refreshServerInfo(forceBackupCheck: true)
            _ = try await settings.legacyScope()
        }

        func seed(_ ids: [String] = ["demo:photo-0"]) async throws {
            let compactor = DemoCompactor(client: client, library: library, ledger: ledger, pollInterval: .milliseconds(1))
            for id in ids { _ = try await compactor.compact(id, compactNow: true) { _ in } }
            let projection = try await ledger.projection()
            let candidates = LegacyCheck.candidates(projection) { _ in .photo }
            let client = client
            try await LegacyCheck.run(candidates, ledger: ledger, scope: scope, origin: nil,
                lookup: { try await client.lookupCopies($0) }, current: { true })
        }

        func remover(mode: ServerAPI.StorageMode = .files) -> LegacyOriginalRemover {
            let settings = settings, captured = scope
            return .init(client: client, ledger: ledger, photos: library, scope: captured, mode: mode,
                current: { settings.currentLegacyScope == captured && settings.server?.mode == .files })
        }

        func upgrade() async {
            await context.server.withLock { $0 }.stopAndWait()
            let updated = DemoServer(folder: folder.appendingPathComponent("server"), pace: 0, bundledCompact: { _ in nil })
            context.server.withLock { $0 = updated }
            await settings.refreshServerInfo(forceBackupCheck: true)
        }

        func close() async throws {
            await context.server.withLock { $0 }.stopAndWait()
            session.invalidateAndCancel()
            LegacyProtocol.contexts.withLock { $0[id] = nil }
            try await ledger.store.close()
            try FileManager.default.removeItem(at: folder)
            UserDefaults.standard.removePersistentDomain(forName: "legacy-test-" + id)
        }
    }

    @Test func missingV2IsReachableAndAdmitsNothing() async throws {
        let fixture = try Fixture()
        try await fixture.pair()
        #expect(fixture.settings.needsBackupUpdate && fixture.settings.serverStatus == .reachable)
        #expect(fixture.settings.connectionProblem == nil)
        let job = CompactJob(settings: fixture.settings, ledger: fixture.ledger)
        let before = fixture.context.requests.withLock { $0 }
        await job.refreshQueue()
        #expect(await job.enqueue(["demo:photo-0"]).isEmpty)
        #expect(job.queueProblem == nil && fixture.settings.showingBackUpUpdate)
        #expect(try await fixture.ledger.store.bindings().isEmpty)
        #expect(try await fixture.ledger.store.sessions().isEmpty)
        #expect(try await fixture.ledger.store.operations().isEmpty)
        #expect(fixture.context.requests.withLock { $0 } == before)
        await job.stopAndWait()
        try await fixture.close()
    }

    @Test func v1ScopeSurvivesAnUpgradeButNotAnotherKeyTokenURLOrDevice() async throws {
        let fixture = try Fixture()
        try await fixture.pair()
        try await fixture.seed()
        let projection = try await fixture.ledger.projection()
        let origin = BackupAPI.Origin(serverID: UUID().uuidString, historyEpoch: UUID().uuidString)
        #expect(projection.legacyConfirmed(scope: fixture.scope, origin: origin).count == 1)
        let token = fixture.client.token!
        let changes = [
            LegacyCheck.scope(url: URL(string: "https://other.local")!, pins: [DemoServer.fingerprint], token: token, consumer: fixture.defaults.string(forKey: "serverDeviceID")!),
            LegacyCheck.scope(url: DemoServer.baseURL, pins: [], token: token, consumer: fixture.defaults.string(forKey: "serverDeviceID")!),
            LegacyCheck.scope(url: DemoServer.baseURL, pins: [DemoServer.fingerprint], token: "another", consumer: fixture.defaults.string(forKey: "serverDeviceID")!),
            LegacyCheck.scope(url: DemoServer.baseURL, pins: [DemoServer.fingerprint], token: token, consumer: "another"),
        ]
        for scope in changes { #expect(projection.legacyConfirmed(scope: scope, origin: nil).isEmpty) }
        let grid = LibraryState(library: fixture.library.allIdentifiers(), ledger: projection.entries,
            album: fixture.library.albumMembers(), job: [:], legacyConfirmed: projection.legacyConfirmed(scope: fixture.scope, origin: nil),
            legacyServerName: "polonium", legacyActions: true)
        #expect(grid.count(.readyToFree) == 1 && grid.count(.needsAttention) == 0)
        #expect(grid.cells.first(where: \.legacy)?.badge == .originalOnPhone)
        #expect(ItemAction.for(grid.cells.first(where: \.legacy)!) == .freeUp(original: "demo:photo-0"))
        let capturedScope = fixture.scope
        let authorization = fixture.settings.legacyCheckAuthorization(scope: capturedScope)
        fixture.settings.retire()
        #expect(!authorization())
        await #expect(throws: CancellationError.self) {
            try await fixture.ledger.store.recordLegacyChecks(Array(projection.legacyChecks.values), scope: capturedScope,
                namespace: fixture.ledger.namespace, authorized: authorization)
        }

        @Test func transientCapabilitiesFailuresKeepTheKnownOldServerReachable() async throws {
            let fixture = try Fixture()
            try await fixture.pair()
            for status in [401, 500] {
                fixture.context.transform.withLock { $0 = { path, answer in
                    path == "/api/v2/capabilities" ? DemoServer.error(status, "Interrupted") : answer
                } }
                await fixture.settings.refreshServerInfo(forceBackupCheck: true)
                #expect(fixture.settings.needsBackupUpdate && fixture.settings.serverStatus == .reachable)
                #expect(fixture.settings.connectionProblem == nil)
            }
            try await fixture.close()
        }

        @Test func widgetsAndWatchDescribeAnUpdateWithoutLosingReachability() {
            let now = Date()
            let inputs = StatusPublisher.Inputs(unlocked: true, ready: (0, 0), lastBackup: nil, historyLoaded: true,
                serverName: "polonium", status: .reachable, checkedAt: now, automatic: true, lastRun: nil,
                needsBackupUpdate: true)
            let snapshot = StatusPublisher.snapshot(inputs, previous: nil, now: now)
            #expect(snapshot.server?.reachable == true)
            #expect(StatusWords.server(snapshot.server) == "Update polonium")
            #expect(StatusWords.headline(snapshot, now: now, watch: true) == "Update polonium")
        }
        try await fixture.close()
    }

    enum Block: CaseIterable, Sendable {
        case deviceHash, serverHash, trashBefore, trashAfter, compactHash, compactRole, compactAsset
        case compactGeneration, changedScope, zeroBytes, immich, modern, kept
    }

    @Test(arguments: Block.allCases) func legacyFreeUpFailsClosed(_ block: Block) async throws {
        let fixture = try Fixture()
        try await fixture.pair()
        try await fixture.seed()
        let entry = try #require(try await fixture.ledger.entry(for: "demo:photo-0"))
        let original = try #require(fixture.library.demoItem("demo:photo-0"))
        let compact = try #require(fixture.library.demoItem(entry.compactIdentifier))
        let checked = Mutex(false), authorized = Mutex(true)
        switch block {
        case .deviceHash:
            var data = try Data(contentsOf: original.main); data.append(1); try data.write(to: original.main)
        case .zeroBytes: try Data().write(to: original.main)
        case .kept:
            try await fixture.ledger.store.setKeptDecision(["demo:photo-0"], namespace: fixture.ledger.namespace, kept: true)
        case .modern:
            var mapping = try #require(try await fixture.ledger.store.mappings(namespace: fixture.ledger.namespace)["demo:photo-0"])
            let origin = BackupAPI.Origin(serverID: UUID().uuidString, historyEpoch: UUID().uuidString)
            mapping.origin = origin; mapping.entry.origin = origin
            let saved = mapping
            try await fixture.ledger.store.mutateState { connection in
                try connection.execute("UPDATE mappings SET body = ? WHERE id = ?",
                    [.blob(try BackupStore.encode(saved)), .text(saved.id.uuidString)])
            }
        default: break
        }
        fixture.context.transform.withLock { transform in
            transform = { path, response in
                if path.hasSuffix("/verify") {
                    checked.withLock { $0 = true }
                    if block == .changedScope { authorized.withLock { $0 = false } }
                    if block == .serverHash {
                        var proof = try ServerAPI.decoder.decode(ServerAPI.Verification.self, from: response.body)
                        proof.resources[0].verified = false
                        return try DemoServer.json(proof)
                    }
                }
                if path.hasSuffix("/lookup"), [.compactHash, .compactRole, .compactAsset].contains(block) {
                    var matches = try ServerAPI.decoder.decode(ServerAPI.CopyLookupResponse.self, from: response.body)
                    if block == .compactHash { matches.matches.removeAll { !$0.isOriginal } }
                    else {
                        for index in matches.matches.indices where !matches.matches[index].isOriginal {
                            if block == .compactRole { matches.matches[index].role = .video }
                            else { matches.matches[index].assetID = String(repeating: "0", count: 64) }
                        }
                    }
                    return try DemoServer.json(matches)
                }
                if path.hasSuffix("/lookup"), block == .compactGeneration {
                    var data = try Data(contentsOf: compact.main); data.append(2); try data.write(to: compact.main)
                }
                if path.hasPrefix("/api/v1/assets/"), !path.hasSuffix("/verify"),
                   block == .trashBefore || block == .trashAfter && checked.withLock({ $0 }) {
                    var status = try ServerAPI.decoder.decode(ServerAPI.AssetStatus.self, from: response.body)
                    status.state = .trashed
                    return try DemoServer.json(status)
                }
                return response
            }
        }
        var remover = fixture.remover(mode: block == .immich ? .immich : .files)
        remover.current = { authorized.withLock { $0 } }
        let report = try await remover.removeEligible(limit: nil, only: nil) { _ in }
        #expect(report.removed.isEmpty && fixture.asked.withLock { $0 } == 0)
        #expect(fixture.library.existing(["demo:photo-0"], includeHidden: true) == ["demo:photo-0"])
        if block != .immich && block != .modern && block != .kept { #expect(!report.blocked.isEmpty) }
        try await fixture.close()
    }

    @Test func expiredProofIsRehashedBeforeTheGenerationFencedConfirmation() async throws {
        let fixture = try Fixture()
        try await fixture.pair()
        try await fixture.seed()
        let clock = Mutex(Date()), verified = Mutex(0)
        fixture.context.transform.withLock { $0 = { path, answer in
            if path.hasSuffix("/verify") {
                let count = verified.withLock { $0 += 1; return $0 }
                if count == 1 { clock.withLock { $0 = $0.addingTimeInterval(31) } }
            }
            return answer
        } }
        var remover = fixture.remover()
        remover.now = { clock.withLock { $0 } }
        let report = try await remover.removeEligible(limit: nil, only: nil) { _ in }
        #expect(report.removed.count == 1 && fixture.asked.withLock { $0 } == 1)
        #expect(verified.withLock { $0 } == 2)
        #expect(fixture.library.existing(["demo:photo-0"], includeHidden: true).isEmpty)
        try await fixture.close()
    }

    @Test(arguments: [false, true])
    func legacyRestoreVerifiesBytesAndRecordsKeptAndCrashIntentBlocksAnotherImport(_ upgraded: Bool) async throws {
        let fixture = try Fixture()
        try await fixture.pair()
        try await fixture.seed()
        let scope = fixture.scope
        if upgraded { await fixture.upgrade() }
        #expect(fixture.scope == scope)
        #expect(fixture.settings.needsBackupUpdate == !upgraded)
        _ = try await fixture.remover().removeEligible(limit: nil, only: nil) { _ in }
        let entry = try #require(try await fixture.ledger.entry(for: "demo:photo-0"))
        let item = OriginalRestorer.Item(key: "demo:photo-0", compact: entry.compactIdentifier,
            serverAssetID: entry.serverAssetID!, originalBytes: entry.originalBytes)
        let restorer = LegacyOriginalRestorer(client: fixture.client, ledger: fixture.ledger, photos: fixture.library,
            scope: fixture.scope, mode: .files, current: { true })
        let report = await restorer.restore([item]) { _ in }
        #expect(report.restored.count == 1 && !report.copiesKept && report.problems.isEmpty)
        let restored = try #require(report.restored.first)
        #expect(try await fixture.ledger.backedUpSnapshot()[restored]?.kept == true)
        let device = try await fixture.library.resourceFingerprints(restored)
        let server = try await fixture.client.verify(item.serverAssetID)
        #expect(device.allSatisfy { resource in server.resources.contains {
            $0.role == resource.role && $0.sha256 == resource.sha256 && $0.size == resource.size && $0.verified
        } })
        try await fixture.ledger.store.beginLegacyRestore(.init(item: item.key, scope: fixture.scope, startedAt: Date(),
            expected: device), namespace: fixture.ledger.namespace)
        try await fixture.ledger.store.close()
        let reopened = BackupStore(directory: fixture.ledger.store.files.root,
            legacyURL: fixture.folder.appendingPathComponent("ledger.json"))
        let retryEngine = LegacyOriginalRestorer(client: fixture.client, ledger: CompactLedger(store: reopened),
            photos: fixture.library, scope: scope, mode: .files, current: { true })
        let retry = await retryEngine.restore([item]) { _ in }
        #expect(retry.restored.isEmpty && retry.problems.first?.contains("Recents") == true)
        #expect(try await reopened.ledgerProjection(namespace: "photos").backedUp[restored]?.kept == true)
        try await reopened.close()
        try await fixture.close()
    }

    @Test func trashedLegacyRestoreDoesNotCreateOrDeleteAnything() async throws {
        let fixture = try Fixture()
        try await fixture.pair()
        try await fixture.seed()
        _ = try await fixture.remover().removeEligible(limit: nil, only: nil) { _ in }
        let entry = try #require(try await fixture.ledger.entry(for: "demo:photo-0"))
        fixture.context.transform.withLock { $0 = { path, answer in
            if path.hasPrefix("/api/v1/assets/"), !path.hasSuffix("/verify") {
                var status = try ServerAPI.decoder.decode(ServerAPI.AssetStatus.self, from: answer.body)
                status.state = .trashed
                return try DemoServer.json(status)
            }
            return answer
        } }
        let restorer = LegacyOriginalRestorer(client: fixture.client, ledger: fixture.ledger, photos: fixture.library,
            scope: fixture.scope, mode: .files, current: { true })
        let before = fixture.library.allIdentifiers(), asked = fixture.asked.withLock { $0 }
        let report = await restorer.restore([.init(key: "demo:photo-0", compact: entry.compactIdentifier,
            serverAssetID: entry.serverAssetID!, originalBytes: entry.originalBytes)]) { _ in }
        #expect(report.restored.isEmpty && !report.problems.isEmpty)
        #expect(fixture.library.allIdentifiers() == before && fixture.asked.withLock { $0 } == asked)
        try await fixture.close()
    }

    @Test func automaticKeepsPendingWithoutAttemptsAndAdmitsOnceAfterUpgrade() async throws {
        let fixture = try Fixture()
        try await fixture.pair()
        let automatic = AutomaticMode(url: fixture.folder.appendingPathComponent("automatic.json"), photos: fixture.library,
            system: false, refreshServerInfo: { _ in })
        await automatic.enable(existing: true)
        let premium = Premium(ownBuild: true, listens: false), job = CompactJob(settings: fixture.settings, ledger: fixture.ledger)
        for _ in 0..<2 {
            let summary = await automatic.run(settings: fixture.settings, job: job, premium: premium, notify: false)
            #expect(summary.queued == 0 && summary.skipped?.hasPrefix("Waiting for ") == true)
            #expect(automatic.state.pending.count == 3 && automatic.state.attempts.isEmpty)
            #expect(try await fixture.ledger.store.operations().isEmpty)
        }
        await fixture.server.stopAndWait()
        let probes = fixture.context.requests.withLock { $0.filter { $0 == "/api/v2/capabilities" }.count }
        let updated = DemoServer(folder: fixture.folder.appendingPathComponent("server"), pace: 0, bundledCompact: { _ in nil })
        fixture.context.server.withLock { $0 = updated }
        await fixture.settings.refreshServerInfo(forceBackupCheck: true)
        #expect(fixture.context.requests.withLock { $0.filter { $0 == "/api/v2/capabilities" }.count } == probes,
            "backup_api: 2 must skip the missing-capabilities probe")
        #expect(!fixture.settings.needsBackupUpdate)
        let summary = await automatic.run(settings: fixture.settings, job: job, premium: premium, notify: false)
        #expect(summary.queued == 3 && automatic.state.pending.isEmpty)
        let ids = Set(try await fixture.ledger.store.operations().map(\.id))
        _ = await automatic.run(settings: fixture.settings, job: job, premium: premium, notify: false)
        #expect(Set(try await fixture.ledger.store.operations().map(\.id)) == ids)
        await job.stopAndWait()
        try await fixture.close()
    }
}
