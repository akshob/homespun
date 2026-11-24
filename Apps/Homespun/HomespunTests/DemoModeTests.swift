// SPDX-License-Identifier: Apache-2.0
import Foundation
import HomespunCore
import Photos
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

        static func make() async throws -> Fixture { Fixture(media: try await DemoTestMedia.ready.value) }

        init(media: URL) {
            self.media = media
            let asked = asked
            session = DemoSession(folder: folder, defaults: UserDefaults(suiteName: settingsName)!, pace: 0, media: media) { asked.ask($0) }
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

        let messages = Messages()
        let observation = fixture.session.library.observe { messages.add() }
        let photo = try sample(fixture.session.library, "photo")
        _ = fixture.session.library.restore(photo.id)
        observation.cancel()
        observation.cancel()
        _ = fixture.session.library.restore(photo.id)
        #expect(messages.count == 1)
    }

    private final class Messages: @unchecked Sendable {
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
        await #expect(throws: ServerClient.Failure.self) { try await oldClient.info() }
        let current = ServerClient(baseURL: DemoServer.baseURL, trust: .demo)
        #expect(try await current.info().name == DemoServer.name)
        #expect(await next.snapshot.assets.isEmpty)
    }

    @Test func keepAsIsResolvesCurrentAttentionAndSurvivesReopeningUntilManualRetry() async throws {
        let fixture = try await Fixture.make()
        let model = AppModel(demo: fixture.session, premium: Premium(ownBuild: true, listens: false))
        await model.history.load()
        await model.library.library.reload()
        let id = try sample(fixture.session.library, "photo").id
        // No pairing: this manual attempt fails without contacting any server.
        await model.job.enqueue([id])
        let deadline = ContinuousClock.now + .seconds(10)
        while model.job.isRunning, ContinuousClock.now < deadline { await Task.yield() }
        try #require(!model.job.isRunning)
        await model.library.refreshGrid()
        #expect(model.job.states[id]?.phase == .failed && ActivityTab.attention(model).count == 1)
        #expect(await model.library.keepAsIs(id))
        #expect(model.library.library.state.cell(id)?.badge == .kept)
        #expect(ActivityTab.attention(model).isEmpty)

        let reopened = AutomaticMode(url: fixture.folder.appendingPathComponent("automatic.json"),
                                    photos: fixture.session.library, system: false)
        #expect(reopened.keptAsIs == [id])
        await reopened.enable(existing: true)
        #expect(reopened.keptAsIs == [id], "Turning Automatic Mode on must not discard an explicit user decision")
        reopened.retryKept([id])
        #expect(reopened.keptAsIs.isEmpty && !reopened.state.settled.contains(id))
        let blocked = fixture.folder.appendingPathComponent("not-a-directory")
        try Data().write(to: blocked)
        let unwritable = AutomaticMode(url: blocked.appendingPathComponent("automatic.json"),
                                       photos: fixture.session.library, system: false)
        #expect(!unwritable.keepAsIs(id) && unwritable.keptAsIs.isEmpty)
        await model.library.stopAndWait()
    }

    @Test func firstReviewUsesTheExactApprovedCountRatherThanAnObsoleteTenItemPromise() async throws {
        let fixture = try await Fixture.make()
        let model = AppModel(demo: fixture.session, premium: Premium(ownBuild: true, listens: false))
        let client = try await fixture.pairedClient()
        try model.settings.finishPairing(serverURL: DemoServer.baseURL,
                                        response: .init(deviceID: "demo", token: client.token!, server: DemoServer.info),
                                        pins: .init(pins: [DemoServer.fingerprint], source: "demo"))
        let compactor = DemoCompactor(client: client, library: fixture.session.library, ledger: model.job.ledger,
                                      pollInterval: .zero)
        let photos = Array(fixture.session.library.samples.filter { $0.kind == "photo" }.prefix(12))
        try #require(photos.count == 12)
        for photo in photos.prefix(11) { _ = try await compactor.compact(photo.id, compactNow: true) { _ in } }
        await model.library.refreshReady()
        #expect(!model.settings.trialConfirmed && model.library.nextRemovalCount == 11)
        let approved = Set(model.library.ready.originals)
        _ = try await compactor.compact(photos[11].id, compactNow: true) { _ in }
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
            let entry = try #require(await fixture.ledger.entry(for: original.id))
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
        #expect(await remover.candidates().count == 3)

        fixture.asked.answer = false
        let declined = try await remover.removeEligible(limit: nil, only: nil) { _ in }
        #expect(declined.cancelled && declined.removed.isEmpty && library.existing(photos.map(\.id), includeHidden: true).count == 3)

        fixture.asked.answer = true
        let report = try await remover.removeEligible(limit: 2, only: nil) { _ in }
        #expect(report.removed.count == 2 && report.blocked.isEmpty && report.freedBytes > 0)
        #expect(fixture.asked.all.last?.message.contains("nothing is deleted") == true)
        #expect(library.existing(photos.map(\.id), includeHidden: true).count == 1)
        // The drawn originals are still there: only the demo's record changed.
        #expect(photos.allSatisfy { FileManager.default.fileExists(atPath: fixture.media.appendingPathComponent($0.files["photo"]!).path) })

        let freed = try #require(photos.first { !library.existing([$0.id], includeHidden: true).contains($0.id) })
        let entry = try #require(await fixture.ledger.entry(for: freed.id))
        let restorer = DemoRestorer(client: client, library: library, ledger: fixture.ledger)
        let restored = await restorer.restore([.init(key: freed.id, compact: entry.compactIdentifier,
                                                      serverAssetID: entry.serverAssetID!, originalBytes: entry.originalBytes)]) { _ in }
        #expect(restored.restored == [freed.id] && restored.problems.isEmpty && !restored.copiesKept)
        #expect(library.demoItem(freed.id) != nil && library.demoItem(entry.compactIdentifier) == nil)
        #expect(await fixture.ledger.backedUpSnapshot()[freed.id]?.kept == true)
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
        let compactor = DemoCompactor(client: client, library: fixture.session.library, ledger: demo.job.ledger,
                                      pollInterval: .zero)
        _ = try await compactor.compact(photo.id, compactNow: true) { _ in }
        await demo.library.refreshReady()
        await demo.history.load()
        let end = Date()
        demo.history.record(.init(kind: .backUp, trigger: .manual, start: end - 60, end: end,
                                   items: [.init(assetID: photo.id, name: "Sample", result: .saved)]))

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
        #expect(shown.lastBackup?.count == 1 && shown.lastBackup?.date == end)
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
        let entry = try #require(await fixture.ledger.entry(for: original.id))
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
