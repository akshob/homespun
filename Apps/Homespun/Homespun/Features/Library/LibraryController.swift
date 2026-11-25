// SPDX-License-Identifier: Apache-2.0
import HomespunCore
import Observation
import Photos
import SwiftUI

/// What the Library, the status accessory and Activity share: the photo library and its badges,
/// backing up, and freeing up space. One for the app (`AppModel.library`), so every tab and the
/// accessory show the same state.
@MainActor @Observable
final class LibraryController {
    /// Freeing up space, from review to result (DESIGN 02·3.1–3.5).
    enum Removal: Equatable {
        case idle
        case checking(String)
        case done(OriginalRemover.Report)
    }

    /// Something ready to free up: originals still on this iPhone whose copies are safe at home.
    struct Ready: Equatable {
        var originals: [String] = []
        /// What removing them frees on this iPhone (their originals' sizes when backed up).
        var bytes = 0
        var count: Int { originals.count }
    }

    let settings: AppSettings
    let job: CompactJob
    let premium: Premium
    let automatic: AutomaticMode
    let copyFinder: CopyFinder
    let library: LibraryModel
    let journey: JourneyLog
    private(set) var access: PHAuthorizationStatus
    /// The grid has its first contents, so it can open scrolled to the newest items.
    private(set) var loaded = false
    /// Everything ready to free up now.
    private(set) var ready = Ready()
    /// `ready` has been worked out (a background run that launched the app may not have).
    private(set) var readyChecked = false
    /// What the last Back Up finished with, until it's freed or dismissed (02·2.3).
    private(set) var finished: Ready?
    private(set) var removal = Removal.idle
    /// The Library is in Select mode: the status accessory steps aside so it doesn't cover
    /// Select mode's Back Up.
    var isSelecting = false
    /// Bumped to bring the grid to the newest items (the Library tab tapped again).
    var newestRequests = 0
    /// The person is to pick items to try (setup, Get Started): the Library opens in Select mode on
    /// what isn't backed up, now or when it next appears (setup ends first).
    var choosePending = false
    /// Free space on this iPhone, for "almost full" (T15).
    private(set) var phoneFreeBytes: Int?
    /// Not backed up and created since the last backup, with the days since (T19).
    private(set) var newSinceBackup: (count: Int, days: Int)?
    /// Originals from the current Back Up; offered once the run finishes.
    private var batch = Set<String>()
    private var started = false
    /// Keep the running accessory until the finished/ready facts have arrived, without a hide/show.
    private var finishingBackups = 0
    private var retired = false
    private var suspended = false
    private var operations = 0
    private var retirementWaiters: [CheckedContinuation<Void, Never>] = []
    private var localRetirements: [UUID: @MainActor () async -> Void] = [:]

    func observeRetirement(_ retire: @escaping @MainActor () async -> Void) -> CatalogObservation? {
        guard !retired else { return nil }
        let id = UUID()
        localRetirements[id] = retire
        return CatalogObservation { [weak self] in
            Task { @MainActor [weak self] in self?.localRetirements[id] = nil }
        }
    }

    private func admit() -> Bool {
        guard !retired, !suspended else { return false }
        operations += 1
        return true
    }

    private func finishedOperation() {
        operations -= 1
        if operations == 0 {
            let waiters = retirementWaiters
            retirementWaiters = []
            waiters.forEach { $0.resume() }
        }
    }

    func retire() {
        retired = true
        job.onPhaseChange = nil
        job.onRunFinished = nil
        job.onBindingChanged = nil
        library.onChange = nil
        library.stopObserving()
        pendingRebuild?.cancel()
        restoreTask?.cancel()
        job.retire()
        copyFinder.retire()
    }

    func stopAndWait() async {
        retire()
        let local = Array(localRetirements.values)
        localRetirements = [:]
        for retire in local { await retire() }
        await job.stopAndWait()
        await restoreTask?.value
        await copyFinder.stopAndWait()
        await pendingRebuild?.value
        if operations > 0 { await withCheckedContinuation { retirementWaiters.append($0) } }
        await job.history?.load()
        await job.history?.flush()
    }

    func suspendAndWait() async {
        suspended = true
        pendingRebuild?.cancel()
        restoreTask?.cancel()
        await job.suspendAndWait()
        await restoreTask?.value
        await copyFinder.suspendAndWait()
        await pendingRebuild?.value
        if operations > 0 { await withCheckedContinuation { retirementWaiters.append($0) } }
        await job.history?.flush()
    }

    func resumeExecution() {
        guard !retired else { return }
        suspended = false
        copyFinder.resume()
        job.resumeExecution()
        scheduleRefreshGrid()
    }

    init(settings: AppSettings, job: CompactJob, premium: Premium, automatic: AutomaticMode, copyFinder: CopyFinder) {
        self.settings = settings
        self.job = job
        self.premium = premium
        self.automatic = automatic
        self.copyFinder = copyFinder
        // A library that lists its own items (the demo's) is read through it; Photos by the model itself.
        library = LibraryModel(catalog: settings.photos as? any ItemCatalog)
        journey = JourneyLog(defaults: settings.defaults, tips: !settings.isDemo)
        access = settings.photos.authorization()
        job.onPhaseChange = { [weak self] in self?.jobChanged() }
        job.onBindingChanged = { [weak self] in
            guard let self, !self.retired else { return }
            self.ready = Ready()
            self.readyChecked = false
            self.finished = nil
            self.scheduleRefreshGrid()
        }
        job.onRunFinished = { [weak self] in
            self?.finishingBackups += 1
            Task { [weak self] in
                guard let self, self.admit() else { return }
                defer { self.finishedOperation() }
                await self.jobFinished()
                self.finishingBackups -= 1
                if !self.settings.isDemo { await Telemetry.shared.flush() }
            }
        }
    }

    var isRemoving: Bool { if case .checking = removal { true } else { false } }

    /// The review shows this exact count before the person approves removal.
    var nextRemovalCount: Int { ready.count }

    /// The bytes the next Free Up Space frees.
    var nextRemovalBytes: Int { ready.bytes }

    /// Each ready original's size, for what a scoped Free Up Space frees.
    private(set) var readySizes: [String: Int] = [:]

    /// Why Back Up can't start now, if it can't.
    var backUpBlockedReason: String? {
        guard settings.backupAdmissionsEnabled else { return "New backup selections are paused; saved work remains recoverable." }
        guard settings.isPaired else { return "Set up your home computer first." }
        if case .blocked(let reason) = settings.connectionTrust { return reason }
        if case .unreachable = settings.serverStatus, !job.canAdmitOffline { return "Can't reach \(serverName)." }
        return nil
    }

    var serverName: String { settings.server?.name ?? "your server" }

    // MARK: Starting and refreshing

    /// Called once when the main screen appears. `loaded`: once what's ready to free up and Premium are
    /// known, before automatic mode catches up (which can take a while).
    func start(loaded: () -> Void = {}) async {
        guard admit() else { return }
        defer { finishedOperation() }
        guard !started else { return }
        started = true
        library.onChange = { @MainActor [weak self] in self?.scheduleRefreshGrid() }
        await refresh()
        // Only what this Apple Account owns; the product itself loads where the purchase is offered.
        await premium.refresh()
        loaded()
        await runAutomatic()
    }

    func refresh() async {
        guard admit() else { return }
        defer { finishedOperation() }
        let now = settings.photos.authorization()
        // The whole library is read at launch and when access changes; after that Photos' change
        // observer keeps it current (re-reading 35,000 items on every return to the app is slow).
        if !library.loaded || now != access {
            access = now
            await library.reload()
            // The grid shows now, from what's on this iPhone; the server's answer (slow away from
            // home) updates it after.
            await refreshGrid()
        }
        if settings.isPaired { await settings.refreshServerInfo() }
        await job.refreshQueue()
        await refreshReady()
        await refreshGrid()
    }

    func requestAccess() async {
        guard admit() else { return }
        defer { finishedOperation() }
        // `refresh` sees the new status (against `access`) and reads the library.
        _ = await settings.photos.requestAuthorization()
        await refresh()
    }

    func refreshGrid() async {
        guard !retired, !suspended else { return }
        do {
        let kept = try await job.ledger.decisions()
        let backed = try await job.ledger.backedUpSnapshot()
        let recovering = Set(backed.filter { $0.value.origin == nil || $0.value.version == nil || $0.value.origin != job.activeOrigin }.keys)
        automatic.useCanonicalDecisions(kept)
        var states = job.states
        for id in kept where states[id] == nil { states[id] = .unchanged(Self.keptAsIsReason) }
        await library.update(ledger: try await job.ledger.snapshot(), job: states,
                             backedUp: try await backedUpDue(), origin: job.activeOrigin, recovering: recovering)
        // Only once the library itself has been read (this also runs when a backup changes things).
        if library.loaded { loaded = true }
        let state = library.state
        if !settings.isDemo {
            TipState.notBackedUp = state.count(.notBackedUp)
            TipState.bothBadgesShown = state.count(.readyToFree) > 0 && state.count(.atHome) > 0
            TipState.automaticOn = automatic.enabled
            TipState.trialDone = settings.trialConfirmed
        }
        await refreshNewSinceBackup()
        } catch { job.showQueueProblem(error) }
    }

    /// Items backed up without a compact copy, with when automatic mode makes it (nil: a kept favorite).
    private func backedUpDue() async throws -> [String: Date?] {
        let backedUp = try await job.ledger.backedUpSnapshot().filter { $0.value.origin == job.activeOrigin && $0.value.version != nil }
        guard !backedUp.isEmpty else { return [:] }
        let ids = Array(backedUp.keys), photos = settings.photos
        let assets = await Task.detached(priority: .userInitiated) { photos.summaries(ids) }.value
        var due: [String: Date?] = [:]
        for (id, summary) in assets {
            let created = summary.created, favorite = summary.favorite
            // Kept full size: never (shown as such, unlike a favorite's).
            due[id] = backedUp[id]?.kept == true ? Date.distantFuture : automatic.due(created: created, id: id, favorite: favorite)
        }
        return due
    }

    /// The accessory's inputs, for the ladder (DESIGN §16.4).
    var accessoryInputs: AccessoryLadder.Inputs {
        var inputs = AccessoryLadder.Inputs()
        inputs.paired = settings.isPaired
        if case .unreachable = settings.serverStatus { inputs.unreachable = serverName }
        if case .checking(let message) = removal { inputs.removing = message }
        if job.isRunning || finishingBackups > 0 {
            let run = job.runProgress
            inputs.backingUp = (run.done, run.total, run.current?.name ?? (finishingBackups > 0 ? job.items.last?.name : nil))
        }
        if let finished { inputs.finished = (finished.count, finished.bytes, Set(finished.originals)) }
        inputs.readyCount = ready.count
        inputs.readyBytes = ready.bytes
        inputs.phoneFreeBytes = phoneFreeBytes
        inputs.newSinceBackup = automatic.enabled ? nil : newSinceBackup
        return inputs
    }

    private func refreshNewSinceBackup() async {
        phoneFreeBytes = await Task.detached(priority: .utility) {
            (try? URL.homeDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage.map(Int.init)
        }.value
        guard let last = journey.lastBackup else {
            newSinceBackup = nil
            return
        }
        let count = await newItems().count
        newSinceBackup = (count, Calendar.current.dateComponents([.day], from: last, to: .now).day ?? 0)
    }

    /// The items not backed up that were created since the last backup, in library order.
    func newItems() async -> [String] {
        guard let last = journey.lastBackup else { return [] }
        let created = await library.identifiers(createdAfter: last)
        let state = library.state
        return created.compactMap { id in state.cell(id).flatMap { $0.canCompact ? (state.positions[id], id) : nil } }
            .sorted { $0.0 ?? 0 < $1.0 ?? 0 }.map(\.1)
    }

    func refreshReady() async {
        guard !retired, !suspended else { return }
        if job.bindingContext == nil, settings.isPaired { await job.refreshQueue() }
        guard let remover = job.remover() else {
            ready = Ready()
            readyChecked = !settings.isPaired
            return
        }
        do {
        let candidates = try await remover.candidates()
        readyChecked = true
        readySizes = Dictionary(candidates.map { ($0.original, $0.entry.originalBytes) }, uniquingKeysWith: { a, _ in a })
        ready = Ready(originals: candidates.map(\.original), bytes: candidates.reduce(0) { $0 + $1.entry.originalBytes })
        if let finished {
            let still = finished.originals.filter { readySizes[$0] != nil }
            self.finished = still.isEmpty ? nil : Ready(originals: still, bytes: still.reduce(0) { $0 + (readySizes[$1] ?? 0) })
        }
        } catch {
            readyChecked = false
            job.showQueueProblem(error)
        }
    }

    // MARK: Backing up

    /// Starts backing up these items (oldest first). Each original goes home, then its compact
    /// copy comes back to Photos.
    func backUp(_ identifiers: [String]) {
        guard !retired, !identifiers.isEmpty else { return }
        finished = nil
        if case .done = removal { removal = .idle }
        Announce.say("Saving your backup selection.")
        // Picked now: the first task while setup is still going (it finishes setup right after).
        let trigger: RunHistory.Trigger = settings.onboardingComplete ? .manual : .firstTask
        Task {
            guard admit() else { return }
            defer { finishedOperation() }
            let accepted = await job.enqueue(identifiers, trigger: trigger)
            batch.formUnion(accepted)
            if !accepted.isEmpty {
                journey.backupStarted(manual: true)
                Announce.say("Queued \(accepted.count) \(accepted.count == 1 ? "item" : "items"). The selection is saved.")
            }
        }
    }

    /// The job changed: the items it touched change badge at once; an item that finished (its
    /// compact copy is in the ledger now) brings a full rebuild once things settle.
    func jobChanged() {
        guard !retired, !suspended else { return }
        let changes = job.takePhaseChanges()
        library.apply(job: changes)
        let finished = changes.values.contains { state in
            switch state {
            case .waiting?, .working?, .processing?: false
            default: true
            }
        }
        guard finished else { return }
        scheduleRefreshGrid()
    }

    private func scheduleRefreshGrid() {
        guard !retired, !suspended else { return }
        pendingRebuild?.cancel()
        pendingRebuild = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await refreshGrid()
        }
    }

    @ObservationIgnored private var pendingRebuild: Task<Void, Never>?

    func jobFinished() async {
        guard !retired else { return }
        jobChanged()
        journey.backupFinished()
        await refreshReady()
        let backedUp = batch
        guard !backedUp.isEmpty, settings.isPaired else { return }
        let originals = ready.originals.filter { backedUp.contains($0) }
        guard !originals.isEmpty else { return }
        batch.subtract(originals)
        let accumulated = Array(Set((finished?.originals ?? []) + originals))
        let bytes = accumulated.reduce(0) { $0 + (readySizes[$1] ?? 0) }
        finished = Ready(originals: accumulated, bytes: bytes)
        Announce.say("\(originals.count) backed up. \(Self.bytes(bytes)) can be freed.")
    }

    func dismissFinished() { finished = nil }

    @discardableResult
    func keepAsIs(_ id: String) async -> Bool {
        guard admit() else { return false }
        defer { finishedOperation() }
        keepProblem = nil
        guard case .failed? = job.states[id] else { return false }
        do {
            try await job.keepAsIs(id)
            automatic.useCanonicalDecisions(try await job.ledger.decisions())
            _ = job.resolveFailure(id)
            await refreshGrid()
            return true
        } catch {
            keepProblem = "Couldn't save this choice. The item still needs attention: \(error.localizedDescription)"
            job.showQueueProblem(error)
            return false
        }
    }

    private(set) var keepProblem: String?

    static let keptAsIsReason = AutomaticMode.keptAsIsReason

    /// Automatic mode catches up whenever the app opens (unless something is already running).
    func runAutomatic() async {
        guard admit() else { return }
        defer { finishedOperation() }
        guard automatic.enabled, premium.isUnlocked, !isRemoving, settings.onboardingComplete else { return }
        await automatic.run(settings: settings, job: job, premium: premium, notify: false)
        await refreshReady()
        await refreshGrid()
    }

    // MARK: Freeing up space

    /// Checks each original with the server again, then iOS asks; `only` limits it to these.
    func freeUp(only scope: Set<String>? = nil) async {
        guard admit() else { return }
        defer { finishedOperation() }
        guard !isRemoving else { return }
        guard let remover = job.remover() else {
            removal = .done(.init(blocked: ["Reconnect the known original server before freeing up space."]))
            return
        }
        journey.used(.freeUp)
        removal = .checking("Checking with \(serverName)")
        Announce.say("Checking with \(serverName).")
        let report: OriginalRemover.Report
        do {
            let limit = settings.trialConfirmed ? nil : AppSettings.trialLimit
            report = try await Signposts.measure(Signposts.freeUp, "FreeUp") {
                try await remover.removeEligible(limit: limit, only: scope) { message in
                    Task { @MainActor [weak self] in
                        if case .checking = self?.removal { self?.removal = .checking(message) }
                    }
                }
            }
        } catch {
            report = OriginalRemover.Report(blocked: [error.localizedDescription])
            Telemetry.shared.record(error: error, where: "freeup")
        }
        AppLog.job.info("free up: \(report.removed.count, privacy: .public) removed, \(report.blocked.count, privacy: .public) blocked")
        removal = .done(report)
        if !report.removed.isEmpty {
            settings.freedBytes += report.freedBytes
            job.history?.recordFreed(report.removed, bytes: report.freedBytes)
            settings.removalExplained = true
            Announce.say("Freed \(Self.bytes(report.freedBytes)).")
        } else if report.cancelled {
            Announce.say("Nothing was removed.")
        }
        finished = nil
        await refreshReady()
        await refreshGrid()
    }

    // MARK: Restoring originals

    enum Restoring: Equatable {
        case idle
        case running(OriginalRestorer.Progress)
        case done(OriginalRestorer.Report)
    }

    private(set) var restoring = Restoring.idle
    @ObservationIgnored private var restoreTask: Task<Void, Never>?

    var isRestoring: Bool {
        if case .running = restoring { return true }
        return false
    }

    /// Which of these compact copies can have their originals restored: known to this iPhone, with the
    /// original on Homespun Server (not in Immich) and not on this iPhone.
    func restorable(_ compacts: [String]) async -> [OriginalRestorer.Item] {
        do {
        guard settings.server?.mode != .immich else { return [] }
        let wanted = Set(compacts)
        let entries = try await job.ledger.snapshot().filter {
            wanted.contains($0.value.compactIdentifier) && $0.value.verifiedCompact && $0.value.origin == job.activeOrigin
        }
        let originals = entries.keys.filter { !$0.hasPrefix(CompactLedger.elsewhere("")) }
        let photos = settings.photos
        let present = await Task.detached { photos.existing(Array(originals), includeHidden: true) }.value
        return entries.filter { !present.contains($0.key) }
            .map { OriginalRestorer.Item(key: $0.key, compact: $0.value.compactIdentifier, serverAssetID: $0.value.serverAssetID!,
                                         originalBytes: $0.value.originalBytes) }
            .sorted { $0.compact < $1.compact }
        } catch {
            job.showQueueProblem(error)
            restoring = .done(.init(problems: [error.localizedDescription]))
            return []
        }
    }

    /// Restores these originals (see `OriginalRestorer`); `restoring` follows it.
    func restore(_ items: [OriginalRestorer.Item]) {
        guard !retired, !suspended, !isRestoring, !items.isEmpty, let restorer = job.restorer() else { return }
        restoring = .running(.init(done: 0, total: items.count, message: "Getting ready"))
        Announce.say(items.count == 1 ? "Restoring the original." : "Restoring \(items.count) originals.")
        restoreTask = Task {
            let report = await restorer.restore(items) { progress in
                Task { @MainActor [weak self] in
                    if self?.isRestoring == true { self?.restoring = .running(progress) }
                }
            }
            restoring = .done(report)
            if !report.restored.isEmpty {
                Announce.say(report.restored.count == 1 ? "Restored the original." : "Restored \(report.restored.count) originals.")
            }
            await refreshReady()
            await refreshGrid()
        }
    }

    /// Stops after the original being restored (those done stay done).
    func stopRestoring() { restoreTask?.cancel() }

    func dismissRestore() { if !isRestoring { restoring = .idle } }

    /// Keep Original (Free Up Space): the compact copies go (iOS asks first) and the originals stay
    /// on this iPhone, kept full size. False if nothing changed (cancelled, or nothing to keep).
    @discardableResult
    func keepOriginals(_ originals: [String]) async -> Bool {
        guard admit() else { return false }
        defer { finishedOperation() }
        do {
            let kept = try await BackupKeeper(ledger: job.ledger, photos: settings.photos).keep(originals)
            guard kept else { return false }
            automatic.useCanonicalDecisions(try await job.ledger.decisions())
            Announce.say(originals.count == 1 ? "Kept the original. Its compact copy is in Recently Deleted."
                         : "Kept the originals. Their compact copies are in Recently Deleted.")
            await refreshReady()
            await refreshGrid()
            return true
        } catch {
            keepProblem = "Photos may already have changed. The saved keep intent needs reconciliation: \(error.localizedDescription)"
            job.showQueueProblem(error)
            return false
        }
    }

    func dismissRemoval() {
        if !isRemoving { removal = .idle }
    }

    static func bytes(_ count: Int) -> String { count.formatted(.byteCount(style: .file)) }

    #if DEBUG
    @ObservationIgnored private var testingDeletionStarted = false

    /// UI tests: deletes the newest item backed up without a compact copy, as a person cleaning up
    /// recent photos would (iOS asks first). Permanent server retention is unchanged.
    func deleteNewestBackedUpForTesting() async {
        guard !testingDeletionStarted, admit() else { return }
        testingDeletionStarted = true
        defer { finishedOperation() }
        await job.refreshQueue()
        do {
            guard let origin = job.activeOrigin else { throw BackupStore.Failure.retiredBinding }
            let entries = try await job.ledger.backedUpSnapshot().filter {
                $0.value.origin == origin && $0.value.version != nil
            }
            var newest: (id: String, date: Date)?
            PHAsset.fetchAssets(withLocalIdentifiers: Array(entries.keys), options: nil).enumerateObjects { asset, _, _ in
                let date = asset.creationDate ?? .distantPast
                if newest.map({ date > $0.date }) ?? true { newest = (asset.localIdentifier, date) }
            }
            guard let newest else {
                throw BackupStageFailure.blocked("No current-server backed-up original is available for the test deletion.")
            }
            try Task.checkCancellation()
            try await Self.delete(newest.id)
            await refresh()
            await refreshGrid()
        } catch {
            job.showQueueProblem(error)
        }
    }

    private nonisolated static func delete(_ id: String) async throws {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
        try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.deleteAssets(assets) }
    }
    #endif
}
