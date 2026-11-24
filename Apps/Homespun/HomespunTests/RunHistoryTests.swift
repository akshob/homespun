// SPDX-License-Identifier: Apache-2.0
import Foundation
import HomespunCore
import Testing
@testable import Homespun

/// A clock the tests move by hand.
@MainActor private final class Clock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
}

@MainActor private func temporaryURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID().uuidString).json")
}

private func item(_ id: String, _ result: RunHistory.Item.Result, original: Int? = nil, compact: Int? = nil,
                  reason: String? = nil) -> RunHistory.Item {
    RunHistory.Item(assetID: id, name: "\(id).HEIC", originalBytes: original, compactBytes: compact, result: result,
                    reason: reason)
}

private func backUp(_ items: [RunHistory.Item], at end: Date, trigger: RunHistory.Trigger = .manual) -> RunHistory.Run {
    RunHistory.Run(kind: .backUp, trigger: trigger, start: end.addingTimeInterval(-120), end: end, items: items)
}

private actor HistoryCompactor: Compacting {
    private struct Failure: Error {}
    private var calls = 0

    func compact(_ localIdentifier: String, compactNow: Bool,
                 progress: @escaping @Sendable (String) -> Void) async throws -> CompactOutcome {
        calls += 1
        progress("Uploading photo 50%")
        if calls == 2 { throw Failure() }
        return .saved(compactIdentifier: "synthetic-copy-\(calls)", originalBytes: calls * 100, compactBytes: calls * 25)
    }
}

private struct HistoryRemote: BackupRemote {
    private struct UnexpectedRequest: Error {}
    let baseURL: URL
    let origin: BackupAPI.Origin

    func changes(after cursor: Int64, epoch: String) async throws -> BackupAPI.Changes {
        .init(origin: origin, cursor: cursor, hasMore: false, changes: [])
    }

    func capabilities() async throws -> BackupAPI.Capabilities { throw UnexpectedRequest() }
    func submit(_ request: BackupAPI.Request) async throws -> BackupAPI.Receipt { throw UnexpectedRequest() }
    func lookup(operationID: UUID) async throws -> [BackupAPI.Receipt] { throw UnexpectedRequest() }
    func status(_ requestID: UUID) async throws -> BackupAPI.Receipt { throw UnexpectedRequest() }
    func command(requestID: UUID, _ command: BackupAPI.Command) async throws -> BackupAPI.Receipt { throw UnexpectedRequest() }
    func admitUpload(_ request: BackupAPI.UploadRequest) async throws -> BackupAPI.UploadAdmission { throw UnexpectedRequest() }
    func uploadPosition(_ uploadID: UUID) async throws -> BackupUploadPosition { throw UnexpectedRequest() }
    func append(_ bytes: Data, uploadID: UUID, offset: Int64) async throws -> Int64 { throw UnexpectedRequest() }
    func completeUpload(_ uploadID: UUID) async throws -> BackupAPI.Receipt { throw UnexpectedRequest() }
    func snapshot(continuation: String?) async throws -> BackupAPI.Snapshot { throw UnexpectedRequest() }
    func download(generation: UUID, resource: ServerAPI.CompactResource, to file: URL) async throws -> HTTPURLResponse {
        throw UnexpectedRequest()
    }
    func downloadOriginal(version: BackupAPI.Version, requestID: UUID,
                          resource: ServerAPI.ResourceDescriptor, to file: URL) async throws -> HTTPURLResponse {
        throw UnexpectedRequest()
    }
    func verify(_ version: BackupAPI.Version) async throws -> BackupAPI.OriginalProof { throw UnexpectedRequest() }
    func acknowledge(_ acknowledgement: BackupAPI.DeliveryAcknowledgement) async throws { throw UnexpectedRequest() }
}

@MainActor private func withSyntheticJob(
    compactor: (any Compacting)? = nil,
    _ body: @MainActor (CompactJob, [String]) async throws -> Void
) async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("history-job-\(UUID().uuidString)")
    let name = "history-job-\(UUID().uuidString)"
    defer {
        try? FileManager.default.removeItem(at: folder)
        UserDefaults.standard.removePersistentDomain(forName: name)
    }
    let library = DemoLibrary(folder: folder.appendingPathComponent("library"),
                              media: try await DemoTestMedia.ready.value, ask: { _ in true })
    let ids = Array(library.samples.filter { $0.kind == "photo" }.prefix(3).map(\.id))
    try #require(ids.count == 3)
    let defaults = try #require(UserDefaults(suiteName: name))
    let settings = AppSettings(defaults: defaults, photos: library,
                               tokens: DemoTokens(defaults: defaults, library: library), isDemo: true)
    let ledger = CompactLedger(url: folder.appendingPathComponent("ledger.json"))
    let job = CompactJob(settings: settings, ledger: ledger, compactor: compactor)
    do {
        try await body(job, ids)
    } catch let failure {
        await job.stopAndWait()
        do { try await ledger.store.close() } catch { Issue.record(error) }
        throw failure
    }
    await job.stopAndWait()
    try await ledger.store.close()
}

@MainActor private func waitForJob(_ condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition(), ContinuousClock.now < deadline { await Task.yield() }
    try #require(condition(), "The synthetic job did not reach its expected state")
}

@MainActor @Test func runHistoryRecordsRunsNewestFirstAndKeepsThem() async {
    let url = temporaryURL(), clock = Clock()
    defer { try? FileManager.default.removeItem(at: url) }
    let history = RunHistory(url: url, now: { clock.now })
    history.record(backUp([item("a", .saved, original: 12_400_000, compact: 2_300_000), item("b", .kept, reason: "Dolby Vision")],
                          at: clock.now.addingTimeInterval(-3_600), trigger: .automatic))
    history.record(backUp([item("c", .saved, original: 1_000_000, compact: 200_000)], at: clock.now))
    // A run with nothing in it isn't kept.
    history.record(backUp([], at: clock.now))
    history.recordFreed(["a.HEIC"], bytes: 12_400_000)

    #expect(history.runs.count == 3)
    #expect(history.runs.first?.kind == .freeUp)
    #expect(history.runs.map(\.trigger) == [.manual, .manual, .automatic])
    #expect(history.lastBackUp?.items.map(\.assetID) == ["c"])

    await history.flush()
    let reloaded = RunHistory(url: url, now: { clock.now })
    #expect(reloaded.runs == history.runs)
    #expect(reloaded.totals == RunHistory.Totals(backedUp: 2, originalBytes: 13_400_000, compactBytes: 2_500_000,
                                                 freedBytes: 12_400_000, freedCount: 1))
}

@MainActor @Test func runHistoryForgetsRunsAfter90Days() async {
    let url = temporaryURL(), clock = Clock()
    defer { try? FileManager.default.removeItem(at: url) }
    let history = RunHistory(url: url, now: { clock.now })
    let day: TimeInterval = 86_400
    history.record(backUp([item("old", .saved, original: 1, compact: 1)], at: clock.now.addingTimeInterval(-89 * day)))
    history.record(backUp([item("new", .saved, original: 1, compact: 1)], at: clock.now))
    #expect(history.runs.count == 2)

    // Two days later the first run is 91 days old: gone, also from the file.
    clock.now += 2 * day
    history.record(backUp([item("newer", .saved, original: 1, compact: 1)], at: clock.now))
    #expect(history.runs.flatMap(\.items).map(\.assetID) == ["newer", "new"])
    clock.now += 100 * day
    await history.flush()
    #expect(RunHistory(url: url, now: { clock.now }).runs.isEmpty)
}

@MainActor @Test func needsAttentionFollowsEachItemsLatestResult() {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let runs = [
        backUp([item("a", .saved, original: 1, compact: 1), item("b", .failed, reason: "Can't reach Home Mac")],
               at: start.addingTimeInterval(60)),
        backUp([item("a", .failed, reason: "The server is full"), item("b", .failed, reason: "full"),
                item("c", .notYet, reason: "Not in Immich yet"), item("d", .failed, reason: "Couldn't download from iCloud")],
               at: start),
    ]
    // b was tried again and failed again; a worked the second time.
    let items = RunHistory.needsAttention(runs)
    #expect(items.map(\.assetID).sorted() == ["b", "c", "d"])
    #expect(items.first { $0.assetID == "b" }?.reason == "Can't reach Home Mac")

    let groups = AttentionCause.group(items, server: "Home Mac")
    #expect(groups.map(\.cause.section) == ["Server", "Immich", "This iPhone"])
    #expect(groups.map(\.cause.title) == ["Couldn't reach Home Mac", "Not in Immich yet", "Couldn't download from iCloud"])
    #expect(AttentionCause.of(item("x", .failed, reason: "Home Mac is almost full (3.1 GB free)."), server: "Home Mac").title
            == "Home Mac is almost full")
}

@Test func runTitlesAndSummariesUseEverydayWords() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
    let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 21)))
    func at(day: Int, hour: Int) throws -> Date {
        try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: 12)))
    }
    let tonight = backUp([item("a", .saved, original: 1_400_000_000, compact: 300_000_000)], at: try at(day: 14, hour: 3),
                         trigger: .automatic)
    #expect(tonight.title(now: now, calendar: calendar) == "Last night · automatic")
    #expect(backUp([], at: try at(day: 11, hour: 9)).title(now: now, calendar: calendar) == "Nov 11")
    #expect(tonight.summary == "1 backed up · 1.4 GB → 300 MB")
    let mixed = backUp([item("a", .saved, original: 1, compact: 1), item("b", .kept), item("c", .kept), item("d", .failed)],
                       at: now)
    #expect(mixed.summary == "1 backed up · 2 kept as is · 1 needs attention")
    var freed = RunHistory.Run(kind: .freeUp, trigger: .manual, start: now, end: now,
                               items: Array(repeating: item("", .freed), count: 18))
    freed.freedBytes = 2_100_000_000
    #expect(freed.summary == "Freed 2.1 GB · 18 originals")

    let months = RunHistory.freedByMonth([freed, backUp([], at: now)], months: 3, now: now, calendar: calendar)
    #expect(months == [0, 0, 2_100_000_000])
}

/// The run's progress and each item's state are kept as items change (Activity, the accessory and
/// the Lock Screen read them on every progress message); they must match counting the items again.
@MainActor @Test func runProgressFollowsTheJobsItems() async throws {
    try await withSyntheticJob(compactor: HistoryCompactor()) { job, ids in
        #expect(await job.enqueue(Array(ids.prefix(2)), trigger: .manual) == Set(ids.prefix(2)))
        try await waitForJob { !job.isRunning }
        #expect(job.runProgress.total == 2 && job.runProgress.done == 2)
        #expect(job.runItems.count == 2 && job.runItems.filter { $0.state.phase == .failed }.count == 1)
        #expect(job.runItems.filter { $0.state.phase == .saved }.count == 1 && !job.hasWaiting)
        #expect(job.runProgress.originalBytes == 100 && job.runProgress.compactBytes == 25)
        // A new stand-in run resets its progress, not the earlier item outcomes.
        #expect(await job.enqueue([ids[2]], trigger: .manual) == [ids[2]])
        try await waitForJob { !job.isRunning }
        #expect(job.runProgress.total == 1 && job.runProgress.done == 1)
        #expect(job.runProgress.originalBytes == 300 && job.runProgress.compactBytes == 75)
        #expect(job.states.count == 3 && job.savedOriginalBytes == 400 && job.savedCompactBytes == 100)
        job.clearFinished()
        #expect(job.runProgress.total == 0 && job.states.isEmpty)
    }
}

@MainActor @Test func unpairedFacadeRejectsSelectionWithoutInventingItemFailures() async throws {
    try await withSyntheticJob { job, ids in
        #expect(await job.enqueue(Array(ids.prefix(2)), trigger: .manual).isEmpty)
        #expect(job.queueProblem != nil && job.items.isEmpty && job.states.isEmpty)
        #expect(job.runProgress.total == 0 && job.runProgress.done == 0 && !job.isPreparing && !job.isRunning)
        #expect(try await job.ledger.store.operations().isEmpty)
    }
}

/// Selection is durable before Photos preparation. Pausing keeps the IDs and prevents a lease.
@MainActor @Test func pausingBeforePhotosPreparationPreservesTheDurableSelection() async throws {
    try await withSyntheticJob { job, ids in
        let store = job.ledger.store
        let binding = BackupStore.Binding(id: UUID(),
            origin: .init(serverID: UUID().uuidString, historyEpoch: UUID().uuidString), trustEpoch: UUID(),
            baseURL: URL(string: "https://server.invalid")!, keychainReference: "synthetic-reference", mode: .files)
        try await store.bind(binding)
        let session = BackupStore.TransferSession(id: UUID(), bindingID: binding.id,
            identifier: "synthetic.history", installationID: UUID())
        try await store.registerSession(session)
        let capabilities = BackupAPI.Capabilities(origin: binding.origin, uploadProtocols: [.foregroundOffset],
            recipe: .init(profile: .standard, backend: "synthetic", pipelineVersion: 2))
        try await job.coordinator.activate(.init(binding: binding,
            information: .init(capabilities: capabilities, name: "Synthetic", namespace: job.ledger.namespace),
            session: session, remote: HistoryRemote(baseURL: binding.baseURL, origin: binding.origin)),
            policy: .init(maximumTransientBytes: 1 << 20, minimumAvailableBytes: 0,
                          finalizationReserveBytes: 0, maximumTransfers: 1))
        let batch = try await store.admit(Array(ids.prefix(2)), namespace: job.ledger.namespace,
                                         bindingID: binding.id, profile: .standard, compact: true)
        let paused = try #require(batch.operationIDs.first)
        job.stopWaiting([ids[0]])
        try await waitForJob { job.states[ids[0]]?.phase == .notYet && job.states[ids[1]]?.phase == .waiting }
        #expect(try await store.claim(paused, stage: .preparation) == nil)
        #expect(try await store.resources(paused).isEmpty)
        let unprepared = try #require(try await store.operation(paused))
        #expect(unprepared.manifest == nil && unprepared.backup == .selected)
        #expect(try await store.deviceRunnable(.preparation, binding: binding, namespace: job.ledger.namespace)
            .map(\.id) == Array(batch.operationIDs.dropFirst()))
        let additional = try await store.admit([ids[2]], namespace: job.ledger.namespace,
                                               bindingID: binding.id, profile: .standard, compact: true)
        job.stop()
        try await waitForJob { ids.allSatisfy { job.states[$0]?.phase == .notYet } }
        #expect(job.runProgress.total == 3 && job.items.count == 3 && job.states.count == 3)
        let reopened = CompactLedger(url: store.files.root.deletingLastPathComponent().appendingPathComponent("ledger.json"),
                                     namespace: job.ledger.namespace).store
        let remembered = try await reopened.currentOperations(ids, namespace: job.ledger.namespace)
        #expect(Set(remembered.map(\.id)) == Set(batch.operationIDs + additional.operationIDs) && remembered.count == 3)
        #expect(remembered.allSatisfy { $0.desired == .paused && $0.manifest == nil })
        #expect(try await reopened.deviceRunnable(.preparation, binding: binding, namespace: job.ledger.namespace)
            .isEmpty)
        try await reopened.close()
    }
}

/// The app reads the history in the background at launch; a run finished before that (a
/// background task) is added to what was in the file, never written over it.
@MainActor @Test func runsRecordedBeforeTheHistoryIsReadKeepTheFile() async {
    let url = temporaryURL(), clock = Clock()
    defer { try? FileManager.default.removeItem(at: url) }
    let earlier = RunHistory(url: url, now: { clock.now })
    earlier.record(backUp([item("old", .saved, original: 1, compact: 1)], at: clock.now.addingTimeInterval(-3_600)))
    await earlier.flush()
    let history = RunHistory(url: url, now: { clock.now }, load: false)
    history.record(backUp([item("new", .saved, original: 1, compact: 1)], at: clock.now))
    await history.flush()
    #expect(RunHistory(url: url, now: { clock.now }).runs.flatMap(\.items).map(\.assetID) == ["old"])
    await history.load()
    #expect(history.runs.flatMap(\.items).map(\.assetID) == ["new", "old"])
    await history.flush()
    #expect(RunHistory(url: url, now: { clock.now }).runs.flatMap(\.items).map(\.assetID) == ["new", "old"])
}

/// Only local work advances continued-processing progress; elapsed server wait is not progress.
@Test func longRunProgressMovesWithinAnItem() {
    let steps = ["Reading", "Contacting server", "Uploading photo 0%", "Uploading photo 50%", "Uploading photo 100%",
                 "Downloading compact copy", "Compressing motion", "Checking Live Photo", "Saving"]
    let fractions = steps.map { LongRun.fraction(step: $0, seconds: 0) }
    #expect(fractions == fractions.sorted() && fractions.allSatisfy { $0 < 1 })
    #expect(LongRun.fraction(step: "Uploading photo 50%", seconds: 0) == 0.35)
    let compressing = [0.0, 30, 60, 600].map { LongRun.fraction(step: "Compressing on server", seconds: $0) }
    #expect(compressing.allSatisfy { $0 == compressing[0] })
    #expect(compressing[0] < fractions[0])
}
