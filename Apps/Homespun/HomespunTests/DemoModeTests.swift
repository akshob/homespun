// SPDX-License-Identifier: Apache-2.0
import Foundation
import HomespunCore
import Photos
import Synchronization
import Testing
import UIKit
@testable import Homespun

/// Try the Demo's pretend server and sample library: the whole backup, free up and restore cycle runs
/// through `ServerClient` against `DemoServer`, with the same outcome every time, and the demo's records
/// stay in its own folder and settings.
@MainActor @Suite(.serialized) struct DemoModeTests {
    /// A demo in a folder of its own, its server answering at once, and its question answered by `answer`.
    final class Fixture {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("demo-\(UUID().uuidString)")
        let settingsName = "demo-test-\(UUID().uuidString)"
        let session: DemoSession
        let media: URL
        let ledger: CompactLedger
        let asked = Asked()

        final class Asked: @unchecked Sendable {
            private let lock = NSLock()
            private var questions: [DemoLibrary.Question] = []
            var answer = true
            func ask(_ question: DemoLibrary.Question) -> Bool {
                lock.lock()
                defer { lock.unlock() }
                questions.append(question)
                return answer
            }
            var all: [DemoLibrary.Question] { lock.withLock { questions } }
        }

        static func make(processingDelay: (@Sendable (ServerAPI.AssetKind) -> TimeInterval)? = nil) async throws -> Fixture {
            Fixture(media: try await DemoTestMedia.ready.value, processingDelay: processingDelay)
        }

        init(media: URL, processingDelay: (@Sendable (ServerAPI.AssetKind) -> TimeInterval)? = nil) {
            self.media = media
            let asked = asked
            session = DemoSession(folder: folder, defaults: UserDefaults(suiteName: settingsName)!, pace: 0,
                                  media: media, processingDelay: processingDelay) { asked.ask($0) }
            ledger = CompactLedger(url: folder.appendingPathComponent("ledger.json"))
            DemoServer.running.withLock { $0 = session.server }
            // Setup's pages reach it through the shared session, as while the demo is on.
            URLProtocol.registerClass(DemoURLProtocol.self)
        }

        deinit {
            URLProtocol.unregisterClass(DemoURLProtocol.self)
            DemoServer.running.withLock { $0 = nil }
            try? FileManager.default.removeItem(at: folder)
            UserDefaults.standard.removePersistentDomain(forName: settingsName)
        }

        func pairedClient() async throws -> ServerClient {
            let pairing = try await ServerPairing.pair(link: .init(serverURL: DemoServer.baseURL, code: "DEMO-2468"),
                deviceName: "Test iPhone", installID: try DefaultsInstallation(defaults: session.defaults).load().id)
            return ServerClient(baseURL: DemoServer.baseURL, token: pairing.response.token, trust: .demo)
        }
    }

    private actor DiscoveryClock {
        private var pending: [UUID: CheckedContinuation<Void, Error>] = [:]
        private(set) var intervals: [Duration] = []
        var waiting: Int { pending.count }

        func sleep(_ duration: Duration) async throws {
            let id = UUID()
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                    else {
                        intervals.append(duration)
                        pending[id] = continuation
                    }
                }
            } onCancel: {
                Task { await self.cancel(id) }
            }
        }

        func advance() -> Bool {
            guard let id = pending.keys.first, let continuation = pending.removeValue(forKey: id) else { return false }
            continuation.resume()
            return true
        }

        private func cancel(_ id: UUID) { pending.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
    }

    private actor ControlledRemote: BackupRemote {
        nonisolated let baseURL: URL
        private let base: any BackupRemote
        private let beforeVerify: @Sendable (BackupAPI.Version) async -> Void
        private var released: Bool
        private(set) var held = 0
        private(set) var verified: [BackupAPI.Version] = []

        init(_ base: any BackupRemote, delaysReady: Bool = false,
             beforeVerify: @escaping @Sendable (BackupAPI.Version) async -> Void = { _ in }) {
            self.base = base
            baseURL = base.baseURL
            released = !delaysReady
            self.beforeVerify = beforeVerify
        }
        func release() { released = true }
        func changes(after cursor: Int64, epoch: String) async throws -> BackupAPI.Changes {
            let page = try await base.changes(after: cursor, epoch: epoch)
            if !released, page.changes.contains(where: { $0.receipt.compact == .ready }) {
                held += 1
                return .init(origin: page.origin, cursor: cursor, hasMore: false, changes: [])
            }
            return page
        }
        func capabilities() async throws -> BackupAPI.Capabilities { try await base.capabilities() }
        func submit(_ request: BackupAPI.Request) async throws -> BackupAPI.Receipt { try await base.submit(request) }
        func lookup(operationID: UUID) async throws -> [BackupAPI.Receipt] { try await base.lookup(operationID: operationID) }
        func status(_ requestID: UUID) async throws -> BackupAPI.Receipt { try await base.status(requestID) }
        func command(requestID: UUID, _ command: BackupAPI.Command) async throws -> BackupAPI.Receipt {
            try await base.command(requestID: requestID, command)
        }
        func admitUpload(_ request: BackupAPI.UploadRequest) async throws -> BackupAPI.UploadAdmission { try await base.admitUpload(request) }
        func uploadPosition(_ uploadID: UUID) async throws -> BackupUploadPosition { try await base.uploadPosition(uploadID) }
        func append(_ bytes: Data, uploadID: UUID, offset: Int64) async throws -> Int64 { try await base.append(bytes, uploadID: uploadID, offset: offset) }
        func completeUpload(_ uploadID: UUID) async throws -> BackupAPI.Receipt { try await base.completeUpload(uploadID) }
        func snapshot(continuation: String?) async throws -> BackupAPI.Snapshot { try await base.snapshot(continuation: continuation) }
        func download(generation: UUID, resource: ServerAPI.CompactResource, to file: URL) async throws -> HTTPURLResponse {
            try await base.download(generation: generation, resource: resource, to: file)
        }
        func downloadOriginal(version: BackupAPI.Version, requestID: UUID,
                              resource: ServerAPI.ResourceDescriptor, to file: URL) async throws -> HTTPURLResponse {
            try await base.downloadOriginal(version: version, requestID: requestID, resource: resource, to: file)
        }
        func verify(_ version: BackupAPI.Version) async throws -> BackupAPI.OriginalProof {
            await beforeVerify(version)
            let proof = try await base.verify(version)
            verified.append(version)
            return proof
        }
        func acknowledge(_ acknowledgement: BackupAPI.DeliveryAcknowledgement) async throws { try await base.acknowledge(acknowledgement) }
    }

    private func eventually(_ condition: @MainActor () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if try await condition() { return }
            await Task.yield()
        }
        try #require(try await condition(), "The synthetic delivery did not reach its expected state")
    }

    private actor OneShotBarrier {
        private let pauseAt: Int
        private(set) var arrivals = 0
        private var released = false
        private var waiter: CheckedContinuation<Void, Never>?

        init(pauseAt: Int = 1) { self.pauseAt = pauseAt }

        func pause() async {
            arrivals += 1
            guard arrivals == pauseAt, !released else { return }
            await withCheckedContinuation { waiter = $0 }
        }

        func release() {
            released = true
            waiter?.resume()
            waiter = nil
        }
    }

    private func automaticRunHoldingRefresh(
        premium: Premium,
        exercise: @MainActor (Fixture, AppSettings, CompactJob, AutomaticMode) async throws -> Void
    ) async throws -> (summary: AutomaticMode.Summary, operations: [BackupStore.Operation]) {
        let fixture = try await Fixture.make(), barrier = OneShotBarrier()
        let settings = AppSettings(defaults: fixture.session.defaults, photos: fixture.session.library,
            tokens: fixture.session.tokens, session: fixture.session.server.clientSession, isDemo: true)
        let client = try await fixture.pairedClient()
        try settings.finishPairing(serverURL: DemoServer.baseURL,
            response: .init(deviceID: "demo", token: client.token!, server: DemoServer.info),
            pins: .init(pins: [DemoServer.fingerprint], source: "demo"))
        let job = CompactJob(settings: settings, ledger: fixture.ledger)
        let automatic = AutomaticMode(url: fixture.folder.appendingPathComponent("automatic.json"),
            photos: fixture.session.library, system: false, refreshServerInfo: {
                await $0.refreshServerInfo()
                await barrier.pause()
            })
        let photo = try sample(fixture.session.library, "photo")
        try await job.ledger.store.setKeptDecision(
            fixture.session.library.allIdentifiers().filter { $0 != photo.id },
            namespace: job.ledger.namespace, kept: true)
        await automatic.enable(existing: true)
        let run = Task { await automatic.run(settings: settings, job: job, premium: premium, notify: false) }
        do {
            try await eventually { await barrier.arrivals > 0 }
            #expect(automatic.running && settings.serverStatus == .reachable)
            try await exercise(fixture, settings, job, automatic)
            #expect(await barrier.arrivals == 1)
            await barrier.release()
            let summary = await run.value
            #expect(!automatic.running)
            let operations = try await job.ledger.store.operations()
            await job.stopAndWait()
            try await job.ledger.store.close()
            return (summary, operations)
        } catch {
            await barrier.release()
            _ = await run.value
            await job.stopAndWait()
            try? await job.ledger.store.close()
            throw error
        }
    }

    @Test func automaticRunOwnsSelectionBeforeItsFirstSuspension() async throws {
        let premium = Premium(ownBuild: true, listens: false)
        let result = try await automaticRunHoldingRefresh(premium: premium) { _, settings, job, automatic in
            let overlap = await automatic.run(settings: settings, job: job, premium: premium, notify: false)
            #expect(overlap == AutomaticMode.Summary())
            #expect(automatic.running, "The overlapping call must not release the first run's ownership")
            let admitted = try await job.ledger.store.operations()
            #expect(admitted.isEmpty)
        }
        #expect(result.summary.queued == 1 && result.summary.skipped == nil)
        #expect(result.operations.count == 1, "The owning run must still be able to admit its selection")
    }

    enum AutomaticInvalidation: CaseIterable, Sendable { case disableReenable, repaired, premiumRevoked }

    @Test(arguments: AutomaticInvalidation.allCases)
    func automaticRunCannotAdmitObsoleteWorkAfterARefresh(_ change: AutomaticInvalidation) async throws {
        let owned = Mutex(true)
        let premium = Premium(ownBuild: false, owned: { owned.withLock { $0 } },
            testFlightWithoutProduct: { false }, listens: false)
        await premium.refresh()
        try #require(premium.isUnlocked)
        let result = try await automaticRunHoldingRefresh(premium: premium) { fixture, settings, job, automatic in
            switch change {
            case .disableReenable:
                automatic.disable()
                await automatic.enable(existing: true)
                #expect(automatic.enabled && premium.isUnlocked)
            case .repaired:
                let oldToken = settings.client?.token
                let client = try await fixture.pairedClient()
                try settings.finishPairing(serverURL: DemoServer.baseURL,
                    response: .init(deviceID: "demo", token: client.token!, server: DemoServer.info),
                    pins: .init(pins: [DemoServer.fingerprint], source: "demo"))
                #expect(settings.client?.token != oldToken && settings.serverStatus == .reachable)
            case .premiumRevoked:
                owned.withLock { $0 = false }
                await premium.refresh()
                #expect(!premium.isUnlocked && automatic.enabled)
            }
            #expect(try await job.ledger.store.operations().isEmpty)
        }
        #expect(result.summary.queued == 0 && result.summary.skipped == nil)
        #expect(result.operations.isEmpty, "A stale producer must not create even a durable admission")
    }

    @Test func foregroundDiscoveryDeliversAfterItsInitialBackoffAndPublishesTheFreeUpOffer() async throws {
        let fixture = try await Fixture.make(), clock = DiscoveryClock()
        let settings = AppSettings(defaults: fixture.session.defaults, photos: fixture.session.library,
            tokens: fixture.session.tokens, session: fixture.session.server.clientSession, isDemo: true)
        let job = CompactJob(settings: settings, ledger: fixture.ledger,
                             discoverySleep: { try await clock.sleep($0) })
        let automatic = AutomaticMode(url: fixture.folder.appendingPathComponent("automatic.json"),
                                      photos: fixture.session.library, system: false)
        let finder = CopyFinder(url: fixture.folder.appendingPathComponent("finder.json"), photos: fixture.session.library)
        let controller = LibraryController(settings: settings, job: job,
            premium: Premium(ownBuild: false, listens: false), automatic: automatic, copyFinder: finder)
        do {
            let client = try await fixture.pairedClient()
            try settings.finishPairing(serverURL: DemoServer.baseURL,
                response: .init(deviceID: "demo", token: client.token!, server: DemoServer.info),
                pins: .init(pins: [DemoServer.fingerprint], source: "demo"))
            var context = try await settings.backupContext(store: job.ledger.store, namespace: job.ledger.namespace)
            let remote = ControlledRemote(context.remote, delaysReady: true)
            context.remote = remote
            let policy = try await settings.backupSpacePolicy(store: job.ledger.store)
            try await job.coordinator.activate(context, policy: policy)
            await controller.library.reload()
            job.setVisible(true)
            let photo = try sample(fixture.session.library, "photo")
            controller.backUp([photo.id])
            try await eventually {
                let operation = try await job.ledger.store.currentOperations([photo.id], namespace: job.ledger.namespace).first
                return operation?.backup == .retained && !job.isRunning
            }
            for attempt in 1...7 {
                try await eventually { await clock.waiting == 1 }
                #expect(await clock.advance())
                try await eventually { await remote.held == attempt }
                #expect(!job.isRunning && controller.ready.count == 0 && controller.finished == nil)
            }
            try await eventually { await clock.waiting == 1 }
            let sleeps = await clock.intervals.count
            job.setVisible(false)
            job.setVisible(true)
            try await eventually {
                let count = await clock.intervals.count, waiting = await clock.waiting
                return count > sleeps && waiting == 1
            }
            await remote.release()
            #expect(await clock.advance())
            try await eventually { controller.finished?.originals == [photo.id] && controller.ready.count == 1 }
            let entry = try #require(try await job.ledger.entry(for: photo.id))
            #expect(entry.verifiedCompact && fixture.session.library.isCopy(entry.compactIdentifier))
            #expect(!job.isRunning && job.queueProblem == nil)
        } catch let failure {
            await controller.stopAndWait()
            do { try await job.ledger.store.close() } catch { Issue.record(error) }
            throw failure
        }
        await controller.stopAndWait()
        try await job.ledger.store.close()
        #expect(await clock.waiting == 0)
    }

    @Test func catalogObservationCancelsAndDoesNotRetainTheCatalog() async throws {
        let fixture = try await Fixture.make()
        var catalog: DemoLibrary? = DemoLibrary(folder: fixture.folder.appendingPathComponent("observed"),
                                                media: fixture.media, ask: { _ in true })
        weak var weakCatalog = catalog
        var model: LibraryModel? = LibraryModel(catalog: catalog!)
        weak var weakModel = model
        await model?.reload()
        model = nil
        catalog = nil
        #expect(weakModel == nil && weakCatalog == nil)

        let messages = ObservationCount()
        let observation = fixture.session.library.observe { messages.add() }
        let photo = try sample(fixture.session.library, "photo")
        _ = fixture.session.library.restore(photo.id)
        observation.cancel()
        observation.cancel()
        _ = fixture.session.library.restore(photo.id)
        #expect(messages.count == 1)
    }

    private final class ObservationCount: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func add() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }

    @Test func freeUpThumbnailsHaveItemIdentityAndKeepTheirActivationOverride() async throws {
        let fixture = try await Fixture.make()
        let library = LibraryModel(catalog: fixture.session.library)
        await library.reload()
        let samples = Array(fixture.session.library.samples.prefix(2))
        let pairs = samples.map { FreeUpPair(original: "original-\($0.id)", compact: $0.id) }
        let items = FreeUpThumbnails.items(pairs, selected: pairs[1])
        let spoken = FreeUpThumbnails.accessibility(library: library, count: pairs.count)
        #expect(spoken(items[0], 0).label.contains(samples[0].itemKind.name))
        #expect(spoken(items[0], 0).value == "Compact copy, item 1 of 2")
        #expect(spoken(items[1], 1).value == "Compact copy, item 2 of 2")
        let collection = ThumbnailCollection()
        let view = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewFlowLayout())
        collection.attach(to: view, library: library, side: 72, scale: 1)
        var activated: Int?
        collection.update(items: items, accessibility: (FreeUpThumbnails.label, FreeUpThumbnails.identifier),
                          itemAccessibility: spoken) { activated = $0 }
        let cell = ThumbnailCell(frame: CGRect(x: 0, y: 0, width: 72, height: 72))
        collection.configure(cell, at: 1)
        let element = try #require(cell.contentView.subviews.first { $0.isAccessibilityElement })
        #expect(element.accessibilityLabel == spoken(items[1], 1).label)
        #expect(element.accessibilityHint?.contains("Compare with the original") == true)
        #expect(element.accessibilityTraits.contains(.selected))
        #expect(element.accessibilityActivate() && activated == 1)
    }

    private actor HeldCompactor: Compacting {
        let marker: URL
        private var entered = false
        private var release: CheckedContinuation<Void, Never>?
        private var startWaiter: CheckedContinuation<Void, Never>?

        init(marker: URL) { self.marker = marker }

        func compact(_ localIdentifier: String, compactNow: Bool,
                     progress: @escaping @Sendable (String) -> Void) async throws -> CompactOutcome {
            entered = true
            startWaiter?.resume()
            startWaiter = nil
            await withCheckedContinuation { release = $0 }
            try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("finished".utf8).write(to: marker)
            return .unchanged("Synthetic completion")
        }

        func waitForStart() async {
            if entered { return }
            await withCheckedContinuation { startWaiter = $0 }
        }

        func finish() { release?.resume(); release = nil }
    }

    @Test func retirementJoinsTheAdmittedWriterAndRejectsNewWork() async throws {
        let fixture = try await Fixture.make()
        let marker = fixture.folder.appendingPathComponent("writer-finished")
        let held = HeldCompactor(marker: marker)
        let settings = AppSettings(defaults: fixture.session.defaults, photos: fixture.session.library,
                                   tokens: fixture.session.tokens, isDemo: true)
        let job = CompactJob(settings: settings, ledger: fixture.ledger, compactor: held)
        let ids = fixture.session.library.samples.prefix(2).map(\.id)
        await job.enqueue([ids[0]])
        await held.waitForStart()
        job.retire()
        var joined = false
        let retirement = Task {
            await job.stopAndWait()
            joined = true
        }
        await Task.yield()
        #expect(!joined && !FileManager.default.fileExists(atPath: marker.path))
        await job.enqueue([ids[1]])
        #expect(job.items.count == 1)
        await held.finish()
        await retirement.value
        #expect(joined && !job.isRunning && FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func retiredDemoCannotWriteOrRouteAnOldClientIntoANewSession() async throws {
        let fixture = try await Fixture.make()
        let oldClient = try await fixture.pairedClient()
        fixture.session.library.retire()
        await fixture.session.server.stopAndWait()
        let photo = try sample(fixture.session.library, "photo")
        #expect(fixture.session.library.restore(photo.id) == nil)
        await #expect(throws: CancellationError.self) { try await fixture.session.library.delete([photo.id]) }
        #expect(fixture.asked.all.isEmpty)
        #expect(throws: CancellationError.self) { try fixture.session.tokens.setToken("late", for: "old") }

        let next = DemoServer(folder: fixture.folder.appendingPathComponent("next-server"), pace: 0, bundledCompact: { _ in nil })
        DemoServer.running.withLock { $0 = next }
        await #expect(throws: ServerClient.Failure.self) { try await oldClient.health() }
        let current = ServerClient(baseURL: DemoServer.baseURL, trust: .demo)
        #expect(try await current.health().tls == true)
        #expect(await next.snapshot.assets.isEmpty)
    }

    @Test func keepAsIsResolvesCurrentAttentionAndSurvivesReopeningUntilManualRetry() async throws {
        let fixture = try await Fixture.make()
        let model = AppModel(demo: fixture.session, premium: Premium(ownBuild: true, listens: false))
        await model.history.load()
        await model.library.library.reload()
        let id = try sample(fixture.session.library, "photo").id
        let client = try await fixture.pairedClient()
        try model.settings.finishPairing(serverURL: DemoServer.baseURL,
            response: .init(deviceID: "demo", token: client.token!, server: DemoServer.info),
            pins: .init(pins: [DemoServer.fingerprint], source: "demo"))
        await model.job.refreshQueue()
        let context = try #require(model.job.bindingContext)
        let batch = try await model.job.ledger.store.admit([id], namespace: model.job.ledger.namespace,
            bindingID: context.binding.id, profile: .standard, compact: true)
        let operation = try #require(batch.operationIDs.first)
        let lease = try #require(try await model.job.ledger.store.claim(operation, stage: .preparation))
        try await model.job.ledger.store.fail(lease, code: "test_failure", message: "Synthetic attention")
        await model.job.refreshQueue()
        await model.library.refreshGrid()
        let deadline = ContinuousClock.now + .seconds(10)
        while (model.job.states[id]?.phase != .failed || ActivityTab.attention(model).count != 1),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(!model.job.isRunning)
        #expect(model.job.states[id]?.phase == .failed && ActivityTab.attention(model).count == 1)
        #expect(await model.library.keepAsIs(id))
        #expect(model.library.library.state.cell(id)?.badge == .kept)
        #expect(ActivityTab.attention(model).isEmpty)

        let reopened = AutomaticMode(url: fixture.folder.appendingPathComponent("automatic.json"),
                                    photos: fixture.session.library, system: false)
        reopened.useCanonicalDecisions(try await model.job.ledger.decisions())
        #expect(reopened.keptAsIs == [id])
        await reopened.enable(existing: true)
        #expect(reopened.keptAsIs == [id], "Turning Automatic Mode on must not discard an explicit user decision")
        try await reopened.retryKept([id], ledger: model.job.ledger)
        #expect(reopened.keptAsIs.isEmpty && !reopened.state.settled.contains(id))
        let blocked = fixture.folder.appendingPathComponent("not-a-directory")
        try Data().write(to: blocked)
        let unwritable = AutomaticMode(url: blocked.appendingPathComponent("automatic.json"),
                                       photos: fixture.session.library, system: false)
        let blockedLedger = CompactLedger(url: blocked.appendingPathComponent("ledger.json"))
        await #expect(throws: Error.self) { try await unwritable.keepAsIs(id, ledger: blockedLedger) }
        #expect(unwritable.keptAsIs.isEmpty)
        await model.library.stopAndWait()
    }

    @Test func firstReviewUsesTheExactApprovedCountRatherThanAnObsoleteTenItemPromise() async throws {
        let fixture = try await Fixture.make()
        let model = AppModel(demo: fixture.session, premium: Premium(ownBuild: true, listens: false))
        let client = try await fixture.pairedClient()
        try model.settings.finishPairing(serverURL: DemoServer.baseURL,
                                        response: .init(deviceID: "demo", token: client.token!, server: DemoServer.info),
                                        pins: .init(pins: [DemoServer.fingerprint], source: "demo"))
        let photos = Array(fixture.session.library.samples.filter { $0.kind == "photo" }.prefix(12))
        try #require(photos.count == 12)
        #expect(await model.job.enqueue(photos.prefix(11).map(\.id)).count == 11)
        try await model.job.runOpportunity()
        try await model.job.runOpportunity()
        await model.library.refreshReady()
        #expect(!model.settings.trialConfirmed && model.library.nextRemovalCount == 11)
        let approved = Set(model.library.ready.originals)
        #expect(await model.job.enqueue([photos[11].id]) == [photos[11].id])
        try await model.job.runOpportunity()
        try await model.job.runOpportunity()
        await model.library.refreshReady()
        // The review's explicit They Look Right approval, scoped to what it displayed.
        model.settings.trialConfirmed = true
        await model.library.freeUp(only: approved)
        #expect(fixture.session.library.existing(Array(approved), includeHidden: true).isEmpty)
        #expect(fixture.session.library.demoItem(photos[11].id) != nil)
        await model.library.stopAndWait()
    }

    private func sample(_ library: DemoLibrary, _ kind: String) throws -> DemoSample {
        try #require(library.samples.first { $0.kind == kind })
    }

    @Test func versionedLookupUsesTheServersNotFoundAndSingleReceiptWireContract() async throws {
        let fixture = try await Fixture.make()
        let model = AppModel(demo: fixture.session, premium: Premium(ownBuild: false, listens: false))
        let client = try await fixture.pairedClient()
        try model.settings.finishPairing(serverURL: DemoServer.baseURL,
            response: .init(deviceID: "demo", token: client.token!, server: DemoServer.info),
            pins: .init(pins: [DemoServer.fingerprint], source: "demo"))
        let photo = try sample(fixture.session.library, "photo")
        #expect(await model.job.enqueue([photo.id]) == [photo.id])
        let operations = try await model.job.ledger.store.currentOperations([photo.id], namespace: model.job.ledger.namespace)
        let operation = try #require(operations.first)
        let missingID = UUID()
        let missingRequest = try client.request("backup-requests", apiVersion: 2,
            query: [.init(name: "operation_id", value: missingID.uuidString)])
        let remote = ServerClientV2(client)
        let (_, missing) = try await client.data(for: missingRequest)
        #expect((missing as? HTTPURLResponse)?.statusCode == 404)
        #expect(try await remote.lookup(operationID: missingID).isEmpty)

        try await model.job.runOpportunity()
        try await model.job.runOpportunity()
        let request = try client.request("backup-requests", apiVersion: 2,
            query: [.init(name: "operation_id", value: operation.id.uuidString)])
        let (data, found) = try await client.data(for: request)
        #expect((found as? HTTPURLResponse)?.statusCode == 200)
        let receipt = try ServerAPI.decoder.decode(BackupAPI.Receipt.self, from: data)
        #expect(receipt.operationID == operation.id)
        #expect(try await remote.lookup(operationID: operation.id) == [receipt])

        let unpaired = ServerClientV2(ServerClient(baseURL: DemoServer.baseURL, trust: .demo))
        do {
            _ = try await unpaired.lookup(operationID: operation.id)
            Issue.record("An authorization failure must not look like a missing request")
        } catch let failure as ServerClient.Failure {
            #expect(failure.status == 401)
        }
        await model.library.stopAndWait()
        try await model.closeDemoStore()
    }

    @Test func slowServerVideoDoesNotBlockALaterPhotoOrOwnLocalExecution() async throws {
        let fixture = try await Fixture.make(processingDelay: { $0 == .video ? 3_600 : 0 })
        let model = AppModel(demo: fixture.session, premium: Premium(ownBuild: false, listens: false))
        let client = try await fixture.pairedClient()
        try model.settings.finishPairing(serverURL: DemoServer.baseURL,
            response: .init(deviceID: "demo", token: client.token!, server: DemoServer.info),
            pins: .init(pins: [DemoServer.fingerprint], source: "demo"))
        let video = try sample(fixture.session.library, "video"), photo = try sample(fixture.session.library, "photo")
        #expect(await model.job.enqueue([video.id, photo.id]) == [video.id, photo.id])
        try await model.job.runOpportunity()
        try await model.job.runOpportunity()
        let operations = try await model.job.ledger.store.currentOperations([video.id, photo.id], namespace: model.job.ledger.namespace)
        let held = try #require(operations.first { $0.itemID == video.id })
        let finished = try #require(operations.first { $0.itemID == photo.id })
        #expect(held.backup == .retained && held.compact == .processing)
        #expect(finished.delivery == .importedVerified)
        #expect(!model.job.isRunning && !model.premium.isUnlocked)
        await model.library.stopAndWait()
        try await model.closeDemoStore()
    }

    @Test func queuedManualWorkSurvivesJoinedRetirementWithoutPremiumOrBlindReimport() async throws {
        let fixture = try await Fixture.make()
        let first = AppModel(demo: fixture.session, premium: Premium(ownBuild: false, listens: false))
        let client = try await fixture.pairedClient()
        try first.settings.finishPairing(serverURL: DemoServer.baseURL,
            response: .init(deviceID: "demo", token: client.token!, server: DemoServer.info),
            pins: .init(pins: [DemoServer.fingerprint], source: "demo"))
        let photo = try sample(fixture.session.library, "photo")
        #expect(await first.job.enqueue([photo.id]) == [photo.id])
        first.settings.defaults.set(true, forKey: "backupAdmissionsDisabled")
        let other = try #require(fixture.session.library.samples.first { $0.kind == "photo" && $0.id != photo.id })
        #expect(await first.job.enqueue([other.id]).isEmpty)
        #expect(try await first.job.ledger.store.currentOperations([other.id], namespace: first.job.ledger.namespace).isEmpty)
        try await first.job.runOpportunity()
        let before = try #require(try await first.job.ledger.store.currentOperations([photo.id], namespace: first.job.ledger.namespace).first)
        await first.library.stopAndWait()
        try await first.closeDemoStore()
        await #expect(throws: BackupStore.Failure.storageClosed) { try await first.job.ledger.snapshot() }
        let resumed = AppModel(demo: fixture.session, premium: Premium(ownBuild: false, listens: false))
        try await resumed.job.runOpportunity()
        let after = try #require(try await resumed.job.ledger.store.currentOperations([photo.id], namespace: resumed.job.ledger.namespace).first)
        #expect(before.id == after.id && after.delivery == .importedVerified)
        let copies = fixture.session.library.albumMembers()
        try await resumed.job.runOpportunity()
        #expect(fixture.session.library.albumMembers() == copies && copies.count == 1)
        let receipt = try #require(after.receipt), context = try #require(resumed.job.bindingContext)
        let cancel = BackupAPI.Command(operationID: UUID(), version: receipt.version, action: .cancel)
        let accepted = try await context.remote.command(requestID: receipt.requestID, cancel)
        let retry = try await context.remote.command(requestID: receipt.requestID,
            .init(operationID: UUID(), version: receipt.version, action: .retry))
        let replay = try await context.remote.command(requestID: receipt.requestID, cancel)
        #expect(replay == accepted && retry.revision > accepted.revision)
        await resumed.library.stopAndWait()
        try await resumed.closeDemoStore()
    }

    @Test func keepingAnOriginalDoesNotDeleteASameIDCompactCopyThatChanged() async throws {
        let fixture = try await Fixture.make()
        let model = AppModel(demo: fixture.session, premium: Premium(ownBuild: false, listens: false))
        let client = try await fixture.pairedClient()
        try model.settings.finishPairing(serverURL: DemoServer.baseURL,
            response: .init(deviceID: "demo", token: client.token!, server: DemoServer.info),
            pins: .init(pins: [DemoServer.fingerprint], source: "demo"))
        let photo = try sample(fixture.session.library, "photo")
        #expect(await model.job.enqueue([photo.id]) == [photo.id])
        try await model.job.runOpportunity()
        try await model.job.runOpportunity()
        let entry = try #require(try await model.job.ledger.entry(for: photo.id))
        let copy = try #require(fixture.session.library.demoItem(entry.compactIdentifier))
        try Data("a newer compact edit".utf8).write(to: copy.main)
        let before = fixture.asked.all.count
        await #expect(throws: BackupStageFailure.self) {
            try await BackupKeeper(ledger: model.job.ledger, photos: fixture.session.library).keep([photo.id])
        }
        #expect(fixture.asked.all.count == before)
        #expect(fixture.session.library.existing([photo.id, entry.compactIdentifier], includeHidden: true).count == 2)
        await model.library.stopAndWait()
        try await model.closeDemoStore()
    }

    private func withDurablePhotos(
        count: Int,
        exercise: @MainActor (Fixture, AppModel, [DemoSample]) async throws -> Void
    ) async throws {
        let fixture = try await Fixture.make()
        let model = AppModel(demo: fixture.session, premium: Premium(ownBuild: false, listens: false))
        do {
            let client = try await fixture.pairedClient()
            try model.settings.finishPairing(serverURL: DemoServer.baseURL,
                response: .init(deviceID: "demo", token: client.token!, server: DemoServer.info),
                pins: .init(pins: [DemoServer.fingerprint], source: "demo"))
            let photos = Array(fixture.session.library.samples.filter { $0.kind == "photo" }.prefix(count))
            try #require(photos.count == count)
            let ids = Set(photos.map(\.id))
            try #require(await model.job.enqueue(photos.map(\.id)) == ids)
            try await model.job.runOpportunity()
            try await model.job.runOpportunity()
            let entries = try await model.job.ledger.snapshot()
            try #require(ids.allSatisfy { entries[$0]?.verifiedCompact == true })
            await model.library.stopAndWait()
            try await exercise(fixture, model, photos)
        } catch {
            await model.library.stopAndWait()
            try? await model.closeDemoStore()
            throw error
        }
        try await model.closeDemoStore()
    }

    enum CompactChange: CaseIterable, Sendable { case deleted, changed }

    @Test(arguments: CompactChange.allCases)
    func originalRemovalRechecksAnEarlierCompactAfterAnotherItemsRemoteProof(_ change: CompactChange) async throws {
        try await withDurablePhotos(count: 2) { fixture, model, photos in
            let library = fixture.session.library, ledger = model.job.ledger
            var context = try #require(model.job.bindingContext)
            let barrier = OneShotBarrier(pauseAt: 2)
            let remote = ControlledRemote(context.remote, beforeVerify: { _ in await barrier.pause() })
            context.remote = remote
            let remover = DurableOriginalRemover(context: context, ledger: ledger, photos: library, batchLimit: 2)
            let candidates = try await remover.candidates(only: Set(photos.map(\.id)))
            try #require(candidates.count == 2)
            let removal = Task {
                try await remover.removeEligible(limit: nil, only: Set(photos.map(\.id)), progress: { _ in })
            }
            do {
                try await eventually { await barrier.arrivals == 2 }
                // The first complete proof succeeded; a different item's proof is still suspended.
                let proved = await remote.verified
                try #require(proved.count == 1)
                let first = try #require(candidates.first { $0.entry.version == proved[0] })
                let second = try #require(candidates.first { $0.original != first.original })
                let secondName = try #require(library.describe(second.original)?.name)
                let compactID = first.entry.compactIdentifier
                let before = try library.sourceGeneration(compactID)
                switch change {
                case .deleted:
                    try await library.delete([compactID])
                    #expect(library.item(compactID) == nil)
                case .changed:
                    let compact = try #require(library.demoItem(compactID))
                    var edited = try Data(contentsOf: compact.main)
                    edited.append(0)
                    try edited.write(to: compact.main)
                    #expect(try library.sourceGeneration(compactID) != before)
                }
                let questions = fixture.asked.all.count
                await barrier.release()
                let report = try await removal.value
                #expect(report.removed == [secondName])
                #expect(report.blocked.count == 1 && !report.cancelled)
                #expect(report.freedBytes == second.entry.originalBytes)
                #expect(library.existing(photos.map(\.id), includeHidden: true) == [first.original])
                #expect(library.item(second.entry.compactIdentifier) != nil)
                #expect(fixture.asked.all.count == questions + 1)
                let effect = try #require(try await ledger.store.effects(namespace: ledger.namespace, unfinished: false)
                    .first { $0.kind == .removeOriginal })
                #expect(effect.phase == .verified && effect.approvals.count == 2)
                #expect(effect.approvals.first { $0.compact.identifier == compactID }?.compact == before)
                #expect(effect.submitted == [second.original],
                        "A previously checked but now invalid pair must never be submitted for original deletion")
            } catch {
                await barrier.release()
                _ = try? await removal.value
                throw error
            }
        }
    }

    enum KeepPersistenceFault: CaseIterable, Sendable {
        case recordPhotosSuccess, completeDecision

        var trigger: String {
            switch self {
            case .recordPhotosSuccess:
                """
                CREATE TRIGGER fail_keep_persistence BEFORE UPDATE OF phase ON photo_effects
                WHEN NEW.kind = 'keepOriginal' AND NEW.phase = 'created'
                BEGIN SELECT RAISE(ABORT, 'injected Photos outcome write failure'); END
                """
            case .completeDecision:
                """
                CREATE TRIGGER fail_keep_persistence BEFORE INSERT ON decisions WHEN NEW.kept = 1
                BEGIN SELECT RAISE(ABORT, 'injected Keep Original finalization failure'); END
                """
            }
        }
    }

    @Test(arguments: KeepPersistenceFault.allCases)
    func keepOriginalSurfacesPersistenceFailureAndReconcilesAfterRestartWithoutDeletingAgain(
        _ fault: KeepPersistenceFault
    ) async throws {
        try await withDurablePhotos(count: 1) { fixture, model, photos in
            let library = fixture.session.library, ledger = model.job.ledger, store = ledger.store
            let original = try #require(photos.first).id
            let mapping = try #require(try await store.mappings(namespace: ledger.namespace)[original])
            let compactID = mapping.entry.compactIdentifier
            let generation = try library.sourceGeneration(original)
            let questions = fixture.asked.all.count
            // SQLite aborts the real transaction, not a stand-in for the keeper's result.
            try await store.mutateState { try $0.execute(fault.trigger) }
            await #expect(throws: BackupDatabase.Failure.self) {
                try await BackupKeeper(ledger: ledger, photos: library).keep([original])
            }
            #expect(fixture.asked.all.count == questions + 1)
            #expect(library.existing([original, compactID], includeHidden: true) == [original])
            #expect(try library.sourceGeneration(original) == generation)
            let intent = try #require(try await store.effects(namespace: ledger.namespace).first { $0.kind == .keepOriginal })
            #expect(intent.phase == (fault == .recordPhotosSuccess ? .uncertain : .created))
            #expect(intent.problem != nil && intent.mappings.map(\.id) == [mapping.id])
            #expect(intent.approvals.map(\.original) == [generation])
            #expect(intent.submitted == (fault == .recordPhotosSuccess ? [] : [compactID]))
            #expect(try await store.mappings(namespace: ledger.namespace)[original]?.id == mapping.id)
            #expect(try await ledger.decisions().isEmpty)
            #expect(try await store.readState { try $0.rows("SELECT 1 FROM legacy_backed_up").isEmpty },
                    "A failed finalization must roll back even the writes before its decision")

            try await store.close()
            let reopened = BackupStore(directory: store.files.root, legacyURL: nil, processID: UUID())
            do {
                try await reopened.open()
                #expect(try await reopened.effect(intent.id) == intent)
                try await reopened.mutateState { try $0.execute("DROP TRIGGER fail_keep_persistence") }
                let resumedLedger = CompactLedger(store: reopened, namespace: ledger.namespace)
                let asked = fixture.asked
                let resumedPhotos = DemoLibrary(folder: library.folder, media: fixture.media, ask: { asked.ask($0) })
                #expect(resumedPhotos.existing([original, compactID], includeHidden: true) == [original])
                let keeper = BackupKeeper(ledger: resumedLedger, photos: resumedPhotos)
                try await keeper.reconcile()
                let completed = try #require(try await reopened.effect(intent.id))
                #expect(completed.phase == .verified && completed.submitted == [compactID])
                #expect(try await resumedLedger.entry(for: original) == nil)
                #expect(try await resumedLedger.decisions() == [original])
                let kept = try #require(try await resumedLedger.backedUpSnapshot()[original])
                #expect(kept.kept == true && kept.version == mapping.proof?.version && kept.origin == mapping.origin)
                #expect(kept.originalBytes == mapping.entry.originalBytes && kept.operationID != nil)
                #expect(try resumedPhotos.sourceGeneration(original) == generation)
                #expect(try await reopened.effects(namespace: ledger.namespace).isEmpty)
                #expect(!(try await keeper.keep([original])))
                try await keeper.reconcile()
                #expect(try await reopened.effect(intent.id) == completed)
                #expect(try await reopened.effects(namespace: ledger.namespace, unfinished: false).count == 1)
                #expect(fixture.asked.all.count == questions + 1, "Recovery must not ask Photos to delete again")
                try await reopened.close()
            } catch {
                try? await reopened.close()
                throw error
            }
        }
    }

    @Test func copyFinderRevalidatesThroughTheRealV2WireContractWithoutUploadingOrInventingHistoricalProvenance() async throws {
        let fixture = try await Fixture.make()
        let model = AppModel(demo: fixture.session, premium: Premium(ownBuild: false, listens: false))
        let client = try await fixture.pairedClient()
        try model.settings.finishPairing(serverURL: DemoServer.baseURL,
            response: .init(deviceID: "demo", token: client.token!, server: DemoServer.info),
            pins: .init(pins: [DemoServer.fingerprint], source: "demo"))
        let photo = try sample(fixture.session.library, "photo")
        #expect(await model.job.enqueue([photo.id]) == [photo.id])
        try await model.job.runOpportunity()
        try await model.job.runOpportunity()
        let originalEntry = try #require(try await model.job.ledger.entry(for: photo.id))
        let source = try #require(fixture.session.library.demoItem(photo.id))
        let metadata = try fixture.session.library.backupMetadata(photo.id)
        let descriptors = try await fixture.session.library.resourceFingerprints(photo.id)
        let originalFiles = try source.files.map { role, url in
            PreparedPhotoResource(fileID: UUID(), url: url,
                descriptor: try #require(descriptors.first { $0.role == role }))
        }
        try await fixture.session.library.delete([photo.id])
        let context = try #require(model.job.bindingContext)
        let recovery = BackupStore(directory: fixture.folder.appendingPathComponent("copy-recovery"), legacyURL: nil)
        try await recovery.bind(context.binding)
        try await recovery.rememberBinding(context.binding.id, information: context.information)
        let ledger = CompactLedger(store: recovery)
        let finderURL = fixture.folder.appendingPathComponent("copy-recovery-finder.json")
        let finder = CopyFinder(url: finderURL, photos: fixture.session.library)
        let before = try await client.storage()
        await finder.run(lookup: { try await client.lookupCopies($0) }, ledger: ledger, context: context)
        #expect(finder.error == nil && finder.summary?.found == 1 && finder.summary?.readyToFree == 0)
        let key = CompactLedger.elsewhere(originalEntry.compactIdentifier)
        let entry = try #require(try await ledger.entry(for: key))
        #expect(entry.verifiedCompact && entry.revalidatedCopy == true && entry.origin == context.binding.origin)
        #expect(entry.version?.manifestID == originalEntry.version?.manifestID)
        let state = LibraryState(library: fixture.session.library.allIdentifiers(), ledger: try await ledger.snapshot(),
            album: fixture.session.library.albumMembers(), job: [:], origin: context.binding.origin)
        #expect(state.cells(.all).first { $0.id == entry.compactIdentifier }?.badge == .backedUp)
        let remover = DurableOriginalRemover(context: context, ledger: ledger, photos: fixture.session.library)
        #expect(try await remover.candidates(only: nil).isEmpty)
        var checking = context
        checking.session.id = UUID()
        checking.session.identifier = "foreground.copy-recovery"
        try await recovery.registerSession(checking.session)
        let coordinator = BackupCoordinator(store: recovery, photos: fixture.session.library, namespace: ledger.namespace)
        try await coordinator.activate(checking, policy: .init(maximumTransientBytes: 100_000_000,
            minimumAvailableBytes: 0, finalizationReserveBytes: 1_000_000, maximumTransfers: 1))
        let count = try await recovery.operations().count
        await #expect(throws: BackupStageFailure.self) {
            _ = try await coordinator.admit([entry.compactIdentifier], compact: true, trigger: .manual)
        }
        #expect(try await recovery.operations().count == count)
        try await coordinator.stopAndWait()

        // A later original must match every resource; it is linked using the same real proof
        // contract, not by turning a legacy asset ID into a trusted deletion record.
        let restored = try await fixture.session.library.restoreResources(originalFiles, metadata: metadata)
        await finder.run(lookup: { try await client.lookupCopies($0) }, ledger: ledger, context: context)
        #expect(finder.error == nil && finder.summary?.readyToFree == 1)
        let paired = try #require(try await ledger.entry(for: restored))
        #expect(paired.verifiedCompact && paired.compactIdentifier == entry.compactIdentifier)
        #expect(try await ledger.entry(for: key) == nil)
        #expect(try await remover.candidates(only: [restored]).count == 1)
        #expect(try await client.storage().storedBytes == before.storedBytes)
        let operations = try await recovery.operations()
        let receipts = try await context.remote.snapshot(continuation: nil).receipts
        let reloaded = CopyFinder(url: finderURL, photos: fixture.session.library)
        await reloaded.run(lookup: { try await client.lookupCopies($0) }, ledger: ledger, context: context)
        #expect(reloaded.total == 0)
        #expect(try await recovery.operations().count == operations.count)
        #expect(try await context.remote.snapshot(continuation: nil).receipts.count == receipts.count)

        // A full compact changed under the same ID cannot cause a Photos deletion, even though
        // a previously verified canonical badge still exists.
        let copy = try #require(fixture.session.library.demoItem(paired.compactIdentifier))
        var changed = try Data(contentsOf: copy.main)
        changed[0] ^= 1
        try changed.write(to: copy.main)
        let questions = fixture.asked.all.count
        let report = try await remover.removeEligible(limit: nil, only: [restored], progress: { _ in })
        #expect(report.removed.isEmpty && !report.blocked.isEmpty)
        #expect(fixture.asked.all.count == questions)
        #expect(fixture.session.library.existing([restored], includeHidden: true) == [restored])
        try await recovery.close()
        await model.library.stopAndWait()
        try await model.closeDemoStore()
    }

    @Test func durablePreparationIsBoundedAndUncertainImportsRequireAUniqueCompleteMatch() async throws {
        let fixture = try await Fixture.make()
        let library = fixture.session.library
        let photo = try sample(library, "photo")
        let files = BackupFiles(root: fixture.folder.appendingPathComponent("prepared"))
        try files.prepare()
        let id = UUID(), directory = try files.prepareStaging(operationID: id)
        let size = try library.preparationBytes(photo.id, mode: .files)
        await #expect(throws: PhotoLibrary.Failure.self) {
            try await library.prepareBackup(photo.id, mode: .files, directory: directory,
                                            maximumBytes: size - 1, progress: { _ in })
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        let observation = try library.observePhotosEffect(restoring: false)
        let prepared = try await library.prepareBackup(photo.id, mode: .files, directory: directory,
                                                       maximumBytes: size, progress: { _ in })
        for resource in prepared.resources {
            #expect(resource.url == files.stagedFile(operationID: id, fileID: resource.fileID))
        }
        #expect(PhotoKitSource.sameResources(prepared.manifest.resources, try await library.resourceFingerprints(photo.id)))
        let first = try await library.importCompact(prepared.resources, metadata: prepared.metadata)
        guard case .unique(let recovered, _) = try await library.reconcilePhotosEffect(
            expected: prepared.manifest.resources, observation: observation, createdIdentifier: nil)
        else { Issue.record("The single complete import wasn't recovered"); return }
        #expect(recovered == first)

        let next = try files.prepareStaging(operationID: UUID())
        let again = try await library.prepareBackup(photo.id, mode: .files, directory: next,
                                                    maximumBytes: size, progress: { _ in })
        _ = try await library.importCompact(again.resources, metadata: again.metadata)
        guard case .blocked = try await library.reconcilePhotosEffect(
            expected: prepared.manifest.resources, observation: observation, createdIdentifier: nil)
        else { Issue.record("Ambiguous complete matches must not be guessed"); return }
        guard case .unique(let known, _) = try await library.reconcilePhotosEffect(
            expected: prepared.manifest.resources, observation: observation, createdIdentifier: first)
        else { Issue.record("The recorded creation fact should remain usable"); return }
        #expect(known == first)
    }

    /// The samples are drawn or cloned for this launch: 30 photos and videos over several years, a Live Photo with
    /// its motion, videos, a screenshot; oldest first, with months for the grid's headers.
    @Test func samplesAreListedOldestFirst() async throws {
        let fixture = try await Fixture.make()
        let library = fixture.session.library
        #expect(library.samples.count == 30)
        let contents = library.contents()
        #expect(contents.ids.count == library.samples.count && contents.ids.count >= 25)
        let dates = contents.ids.compactMap { contents.media[$0]?.created }
        #expect(dates == dates.sorted() && Set(contents.months.values).count >= 6)
        #expect(contents.media.values.contains { $0.kind == .livePhoto } && contents.media.values.filter { $0.kind == .video }.count >= 2)
        #expect(library.samples.contains { $0.screenshot == true })
        let live = try sample(library, "live_photo")
        #expect(library.demoItem(live.id)?.motion != nil)
        #expect(contents.album.isEmpty && library.authorization() == .authorized)
    }

    /// Backing up a photo, a video and the Live Photo: uploaded in pieces and checked on the pretend
    /// server, compact copies made smaller (a photo shrunk; a video's and the Live Photo's from the app),
    /// recorded in the ledger, and shown in the library in their originals' places.
    @Test func backingUpMakesCompactCopies() async throws {
        let fixture = try await Fixture.make()
        let library = fixture.session.library
        let client = try await fixture.pairedClient()
        let compactor = DemoCompactor(client: client, library: library, ledger: fixture.ledger, pollInterval: .zero)
        let progress = Messages()
        for kind in ["photo", "video", "live_photo"] {
            let original = try sample(library, kind)
            let outcome = try await compactor.compact(original.id, compactNow: true) { progress.add($0) }
            guard case .saved(let copy, let originalBytes, let compactBytes) = outcome else {
                Issue.record("\(kind): \(outcome)")
                continue
            }
            #expect(compactBytes > 0 && compactBytes < originalBytes, "\(kind): \(compactBytes) of \(originalBytes)")
            #expect(library.isCopy(copy) && library.demoItem(copy)?.creationDate == original.created)
            let entry = try #require(try await fixture.ledger.entry(for: original.id))
            #expect(entry.compactIdentifier == copy && entry.serverAssetID != nil)
            // Again: it already has its compact copy.
            #expect(try await compactor.compact(original.id, compactNow: true) { _ in } == .unchanged("Already has a compact copy"))
        }
        #expect(["Uploading photo", "Uploading video", "Uploading motion"].allSatisfy { label in progress.all.contains { $0.hasPrefix(label) } }
                 && progress.all.contains("Compressing on server"), "\(progress.all)")
        #expect(library.albumMembers().count == 3)
        let assets = await fixture.session.server.snapshot.assets.values
        #expect(assets.count == 3 && assets.allSatisfy { $0.state == .imported && $0.resources.allSatisfy { $0.state == .verified } })
        let live = try #require(library.demoItem(library.albumMembers().first { library.demoItem($0)?.kind == .livePhoto } ?? ""))
        #expect(live.motion != nil, "the Live Photo's copy lost its motion")
    }

    /// Free Up Space checks each original with the pretend server through the real deletion gate, asks
    /// with the demo's question (saying nothing is deleted), and then the originals leave only the demo.
    /// Saying no keeps everything. Restore Original brings one back and its compact copy goes.
    @Test func freeingUpAndRestoringOnlyChangeTheDemo() async throws {
        let fixture = try await Fixture.make()
        let library = fixture.session.library
        let client = try await fixture.pairedClient()
        let compactor = DemoCompactor(client: client, library: library, ledger: fixture.ledger, pollInterval: .zero)
        let photos = library.samples.filter { $0.kind == "photo" }.prefix(3)
        for photo in photos { _ = try await compactor.compact(photo.id, compactNow: true) { _ in } }
        let remover = DemoRemover(client: client, library: library, ledger: fixture.ledger)
        #expect(try await remover.candidates().isEmpty, "Unversioned legacy records must require recovery")
        #expect(try await remover.removeEligible(limit: nil, only: nil) { _ in }.removed.isEmpty)
    }

    @Test func legacyRestorationPreservesTheOriginalBytesWithoutManufacturingProvenance() async throws {
        let fixture = try await Fixture.make()
        let library = fixture.session.library
        let client = try await fixture.pairedClient()
        let compactor = DemoCompactor(client: client, library: library, ledger: fixture.ledger, pollInterval: .zero)
        let photos = Array(library.samples.filter { $0.kind == "photo" }.prefix(3))
        for photo in photos { _ = try await compactor.compact(photo.id, compactNow: true) { _ in } }

        fixture.asked.answer = false
        do { try await library.delete(photos.map(\.id)) } catch {}
        #expect(library.existing(photos.map(\.id), includeHidden: true).count == 3)

        fixture.asked.answer = true
        try await library.delete(Array(photos.prefix(2).map(\.id)))
        #expect(fixture.asked.all.last?.message.contains("nothing is deleted") == true)
        #expect(library.existing(photos.map(\.id), includeHidden: true).count == 1)
        // The drawn originals are still there: only the demo's record changed.
        #expect(photos.allSatisfy { FileManager.default.fileExists(atPath: fixture.media.appendingPathComponent($0.files["photo"]!).path) })

        let freed = try #require(photos.first { !library.existing([$0.id], includeHidden: true).contains($0.id) })
        let entry = try #require(try await fixture.ledger.entry(for: freed.id))
        let restorer = DemoRestorer(client: client, library: library, ledger: fixture.ledger)
        let restored = await restorer.restore([.init(key: freed.id, compact: entry.compactIdentifier,
                                                      serverAssetID: entry.serverAssetID!, originalBytes: entry.originalBytes)]) { _ in }
        #expect(restored.restored == [freed.id] && restored.problems.isEmpty && !restored.copiesKept)
        #expect(library.demoItem(freed.id) != nil && library.demoItem(entry.compactIdentifier) == nil)
        #expect(try await fixture.ledger.backedUpSnapshot()[freed.id]?.kept == true)
    }

    /// The same backup gives the same files and fingerprints every time (no randomness in what's shown).
    @Test func outcomesAreTheSameEachTime() async throws {
        var results: [[String]] = []
        for _ in 0..<2 {
            let fixture = try await Fixture.make()
            let library = fixture.session.library
            let client = try await fixture.pairedClient()
            let compactor = DemoCompactor(client: client, library: library, ledger: fixture.ledger, pollInterval: .zero)
            let video = try sample(library, "video")
            _ = try await compactor.compact(video.id, compactNow: true) { _ in }
            let assets = await fixture.session.server.snapshot.assets.values.sorted { $0.id < $1.id }
            results.append(assets.flatMap { [$0.id] + $0.compact.map(\.sha256) })
        }
        #expect(results[0] == results[1] && !results[0].isEmpty)
    }

    /// An upload that doesn't match its fingerprint is refused, as the real server does.
    @Test func mismatchedUploadIsRefused() async throws {
        let fixture = try await Fixture.make()
        let client = try await fixture.pairedClient()
        let file = fixture.folder.appendingPathComponent("photo.jpg")
        try FileManager.default.createDirectory(at: fixture.folder, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 1000).write(to: file)
        let wrong = String(repeating: "a", count: 64)
        let request = ServerAPI.RegisterAssetRequest(kind: .photo, captureDate: nil,
                                                     resources: [.init(role: .photo, filename: "photo.jpg", size: 1000, sha256: wrong)])
        _ = try await client.register(request)
        await #expect(throws: ServerClient.Failure.self) {
            try await client.upload(file, assetID: wrong, role: .photo, size: 1000) { _ in }
        }
        #expect(await fixture.session.server.snapshot.assets[wrong]?.resources.first?.state == .mismatch)
    }

    /// The demo's model keeps its settings, pairing and records apart: the person's own settings and
    /// Keychain aren't touched, and leaving deletes the demo's folder and settings and nothing else.
    @Test func demoStateIsKeptApartAndWiped() async throws {
        let fixture = try await Fixture.make()
        let own = UserDefaults.standard.object(forKey: "onboardingComplete") as? Bool
        let model = AppModel(demo: fixture.session, premium: Premium(ownBuild: true, listens: false))
        #expect(model.settings.isDemo && model.library.library.catalog != nil)
        model.settings.onboardingComplete = true
        let client = try await fixture.pairedClient()
        try model.settings.finishPairing(serverURL: DemoServer.baseURL,
                                          response: .init(deviceID: "demo-iphone", token: client.token!, server: DemoServer.info),
                                          pins: ServerPins(pins: [DemoServer.fingerprint], source: "code"))
        #expect(model.settings.isPaired && model.settings.client?.session === DemoServer.session)
        #expect(Keychain.token(for: DemoServer.baseURL.absoluteString) == nil, "the demo's token went to the Keychain")
        #expect(UserDefaults.standard.object(forKey: "onboardingComplete") as? Bool == own, "the demo changed the app's own setting")
        #expect(UserDefaults.standard.object(forKey: "serverURL") as? URL != DemoServer.baseURL)
        await model.library.library.reload()
        #expect(model.library.library.count == fixture.session.library.samples.count)

        // Leaving: DemoMode's own folder and settings domain go; the app's own records stay.
        let mine = URL.applicationSupportDirectory.appendingPathComponent("Homespun/demo-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mine.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: mine)
        defer { try? FileManager.default.removeItem(at: mine) }
        try FileManager.default.createDirectory(at: DemoMode.folder, withIntermediateDirectories: true)
        try Data("demo".utf8).write(to: DemoMode.folder.appendingPathComponent("ledger.json"))
        UserDefaults(suiteName: DemoMode.settingsName)?.set(true, forKey: "onboardingComplete")
        DemoMode.wipe()
        #expect(!FileManager.default.fileExists(atPath: DemoMode.folder.path))
        #expect(UserDefaults(suiteName: DemoMode.settingsName)?.object(forKey: "onboardingComplete") == nil)
        #expect(FileManager.default.fileExists(atPath: mine.path))
    }

    private final class WatchMessages: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [StatusSnapshot] = []
        func receive(_ data: Data) {
            if let value = StatusStore.decode(data) { lock.withLock { values.append(value) } }
        }
        var all: [StatusSnapshot] { lock.withLock { values } }
    }

    @Test func demoStatusReachesWidgetsAndWatchAndLeavingClearsIt() async throws {
        let fixture = try await Fixture.make()
        let ownName = "demo-status-own-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: ownName) }
        let ownSession = DemoSession(folder: fixture.folder.appendingPathComponent("own"),
                                     defaults: UserDefaults(suiteName: ownName)!, pace: 0, media: fixture.media)
        let locked = Premium(ownBuild: false, owned: { false }, testFlightWithoutProduct: { false }, listens: false)
        let own = AppModel(demo: ownSession, premium: locked)
        let demo = AppModel(demo: fixture.session, premium: locked)
        let client = try await fixture.pairedClient()
        try demo.settings.finishPairing(serverURL: DemoServer.baseURL,
                                        response: .init(deviceID: "demo", token: client.token!, server: DemoServer.info),
                                        pins: .init(pins: [DemoServer.fingerprint], source: "demo"))
        let photo = try sample(fixture.session.library, "photo")
        #expect(await demo.job.enqueue([photo.id]) == [photo.id])
        try await demo.job.runOpportunity()
        try await demo.job.runOpportunity()
        await demo.library.refreshReady()
        await demo.history.load()
        let deadline = ContinuousClock.now + .seconds(10)
        while demo.history.lastBackUp == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let run = try #require(demo.history.lastBackUp)

        let url = fixture.folder.appendingPathComponent("status.json"), messages = WatchMessages()
        let destination = StatusPublisher.Destination(read: { StatusStore.read(from: url) },
                                                       write: { StatusStore.write($0, to: url) }, reload: {},
                                                       send: { data, _ in messages.receive(data) })
        let publisher = StatusPublisher(settings: own.settings, library: own.library, history: own.history,
                                         automatic: own.automatic, premium: locked, destination: destination)
        publisher.showDemo(demo)
        await publisher.publishNow()
        let shown = try #require(StatusStore.read(from: url))
        #expect(shown.demo == true && shown.unlocked && !locked.isUnlocked)
        #expect(shown.server?.name == "Homespun Demo" && shown.server?.reachable == true)
        #expect(shown.ready.count == 1 && shown.ready.bytes == demo.library.ready.bytes && shown.ready.bytes > 0)
        #expect(shown.lastBackup?.count == 1 && shown.lastBackup?.date == run.end)
        #expect(messages.all.last?.sameFacts(as: shown) == true)

        publisher.showDemo(nil)
        await publisher.publishNow()
        let cleared = try #require(StatusStore.read(from: url))
        #expect(cleared.demo == nil && !cleared.unlocked && cleared.server == nil)
        #expect(cleared.ready == .init(bytes: 0, count: 0) && cleared.lastBackup == nil && !cleared.automatic.enabled)
        #expect(messages.all.last?.sameFacts(as: cleared) == true)

        // A terminated process can leave its demo snapshot behind. Welcome clears it too, without
        // starting a PhotoKit-backed library or waiting for setup to finish.
        #expect(StatusStore.write(shown, to: url))
        let relaunched = StatusPublisher(settings: own.settings, library: own.library, history: own.history,
                                          automatic: own.automatic, premium: locked, destination: destination)
        await relaunched.clearDepartedDemo()
        #expect(StatusStore.read(from: url)?.sameFacts(as: cleared) == true)
        #expect(messages.all.last?.sameFacts(as: cleared) == true)
    }

    @Test func demoNeverReplacesAPairedPersonsStatus() async throws {
        let fixture = try await Fixture.make()
        let ownName = "demo-status-paired-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: ownName) }
        let ownSession = DemoSession(folder: fixture.folder.appendingPathComponent("own"),
                                     defaults: UserDefaults(suiteName: ownName)!, pace: 0, media: fixture.media)
        let premium = Premium(ownBuild: true, listens: false)
        let own = AppModel(demo: ownSession, premium: premium)
        try own.settings.finishPairing(serverURL: DemoServer.baseURL,
                                       response: .init(deviceID: "own", token: "own-token", server: DemoServer.info),
                                       pins: .init(pins: [DemoServer.fingerprint], source: "demo"))
        let demo = AppModel(demo: fixture.session, premium: premium)
        let original = StatusSnapshot.sample(), url = fixture.folder.appendingPathComponent("status.json")
        try FileManager.default.createDirectory(at: fixture.folder, withIntermediateDirectories: true)
        #expect(StatusStore.write(original, to: url))
        let messages = WatchMessages()
        let publisher = StatusPublisher(settings: own.settings, library: own.library, history: own.history,
                                         automatic: own.automatic, premium: premium,
                                         destination: .init(read: { StatusStore.read(from: url) },
                                                            write: { StatusStore.write($0, to: url) }, reload: {},
                                                            send: { data, _ in messages.receive(data) }))
        publisher.showDemo(demo)
        publisher.showDemo(nil)
        #expect(StatusStore.read(from: url) == original && messages.all.isEmpty)
    }

    /// The demo is found without looking on the network, as Homespun Demo, ready to pair.
    @Test func pretendServerIsFound() async throws {
        let fixture = try await Fixture.make()
        defer { withExtendedLifetime(fixture) {} }
        let discovery = ServerDiscovery(pretend: [(DemoServer.name, DemoServer.baseURL)])
        discovery.start()
        let deadline = Date().addingTimeInterval(10)
        while discovery.ready.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        discovery.stop()
        let found = try #require(discovery.ready.first)
        #expect(found.name == DemoServer.name && found.options?.canApprove == true && found.url == DemoServer.baseURL)
    }

    @Test func demoPairsByCommitRevealAndVerifiesItsIdentity() async throws {
        let fixture = try await Fixture.make()
        defer { withExtendedLifetime(fixture) {} }
        var number: String?
        let paired = try await ServerPairing.approve(url: DemoServer.baseURL, deviceName: "Test iPhone",
            installID: try DefaultsInstallation(defaults: fixture.session.defaults).load().id,
            onNumber: { value, _ in number = value }, confirmNumber: { _ in
                #expect(await fixture.session.server.snapshot.devices.allSatisfy { $0.installID == nil })
                return true
            })
        #expect(number?.count == 6 && paired.pins.pins == [DemoServer.fingerprint])
        let verified = try await ServerPairing.verify(url: DemoServer.baseURL, token: paired.response.token)
        #expect(verified.fingerprint == DemoServer.fingerprint && verified.url.scheme == "https")
    }

    @Test func compareDownloadsThroughItsOwnDemoSession() async throws {
        let fixture = try await Fixture.make()
        let client = try await fixture.pairedClient()
        let original = try sample(fixture.session.library, "photo")
        let compactor = DemoCompactor(client: client, library: fixture.session.library, ledger: fixture.ledger, pollInterval: .zero)
        _ = try await compactor.compact(original.id, compactNow: true) { _ in }
        let entry = try #require(try await fixture.ledger.entry(for: original.id))
        let asset = try #require(entry.serverAssetID)
        let file = try await CompareModel.fetch(client, assetID: asset, role: .photo,
                                                to: fixture.folder.appendingPathComponent("compare"), name: "original.jpg") { _, _ in }
        #expect(try Fingerprint.sha256(of: file) == asset)
    }

    @Test func rejectingTheNumberNeverDisclosesTheInstallationOrCreatesADevice() async throws {
        let fixture = try await Fixture.make()
        do {
            _ = try await ServerPairing.approve(url: DemoServer.baseURL, deviceName: "Test iPhone",
                installID: UUID().uuidString, onNumber: { _, _ in }, confirmNumber: { _ in false })
            Issue.record("An unconfirmed server received an installation identity")
        } catch is ServerPairing.IdentityFailure {}
        #expect(await fixture.session.server.snapshot.devices.allSatisfy { $0.installID == nil && $0.token == nil })
    }

    @Test func rePairSendsThePersistentInstallIDAndConfirmedName() async throws {
        let fixture = try await Fixture.make()
        let installation = DefaultsInstallation(defaults: fixture.session.defaults)
        let original = try installation.load()
        try installation.confirm(name: "Family Phone")
        let settings = AppSettings(defaults: fixture.session.defaults, photos: fixture.session.library,
                                   tokens: fixture.session.tokens, isDemo: true)
        let link = PairingLink(serverURL: DemoServer.baseURL, code: "DEMO-2468")
        try await settings.pair(link)
        let first = try #require(await fixture.session.server.snapshot.devices.first { $0.token != nil })
        #expect(first.name == "Family Phone" && first.installID == original.id)
        settings.unpair()
        #expect(try settings.pairingIdentity().id == original.id && settings.pairingName == "Family Phone")
        try await settings.pair(link)
        let again = try #require(await fixture.session.server.snapshot.devices.first { $0.token != nil })
        #expect(again.id == first.id && again.name == "Family Phone" && settings.pairingName == "Family Phone")
        #expect(await fixture.session.server.snapshot.devices.filter { $0.token != nil }.count == 1)
    }

    @Test func demoMigratesItsOwnHTTPPairingWithoutReadingTheKeychain() async throws {
        let fixture = try await Fixture.make()
        let old = "http://\(DemoServer.host):8787"
        fixture.session.defaults.set(URL(string: old)!, forKey: "serverURL")
        try fixture.session.tokens.setToken("demo token", for: old)
        let settings = AppSettings(defaults: fixture.session.defaults, photos: fixture.session.library,
                                   tokens: fixture.session.tokens, isDemo: true)
        #expect(settings.serverURL == DemoServer.baseURL && settings.pins?.pins == [DemoServer.fingerprint])
        #expect(fixture.session.tokens.token(for: old) == nil)
        #expect(fixture.session.tokens.token(for: DemoServer.baseURL.absoluteString) == "demo token")
    }

    final class Messages: @unchecked Sendable {
        private let lock = NSLock()
        private var messages: [String] = []
        func add(_ message: String) { lock.withLock { messages.append(message) } }
        var all: [String] { lock.withLock { messages } }
    }
}
