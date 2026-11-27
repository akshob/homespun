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
    /// Originals from the current Back Up; offered as each item's compact copy is verified.
    private var batch = Set<String>()
    private var started = false
    /// Keep the running accessory until the finished/ready facts have arrived, without a hide/show.
    private var finishingBackups = 0
    private var retired = false
    private var suspended = false
    private var operations = 0
    private var retirementWaiters: [CheckedContinuation<Void, Never>] = []
    private var localRetirements: [UUID: @MainActor () async -> Void] = [:]
    @ObservationIgnored private var legacyCheckTask: Task<Void, Never>?
    private var legacyCheckAttempt: Date?
    private var legacyCount = 0
    private var dismissedLegacyNotice: String?
    @ObservationIgnored private var legacyChecksInvalidated = false
    private(set) var legacyCheckFinished = false
    var checkingEarlierBackups: Bool { !legacyCheckFinished && settings.isPaired && !settings.isDemo }

    var legacyNotice: String? {
        guard legacyCount > 0, let scope = settings.currentLegacyScope,
              dismissedLegacyNotice != scope, !settings.needsBackupUpdate else { return nil }
        return "\(legacyCount.formatted()) earlier backups are confirmed on \(serverName). "
            + "Homespun checks them again before freeing up or restoring."
    }

    func dismissLegacyNotice() { dismissedLegacyNotice = settings.currentLegacyScope }
    var updateMessage: String {
        let earlier = legacyCount > 0
            ? "Your \(legacyCount.formatted()) earlier backups are safe there and work as before."
            : "Homespun checks your earlier backups with it; originals and compact copies stay as they are."
        return "\(serverName) runs an earlier Homespun Server. \(earlier) New photos wait here until \(serverName) is updated."
    }

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
        legacyCheckTask?.cancel()
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
        await legacyCheckTask?.value
        await pendingRebuild?.value
        if operations > 0 { await withCheckedContinuation { retirementWaiters.append($0) } }
        await job.history?.load()
        await job.history?.flush()
    }

    func suspendAndWait() async {
        suspended = true
        pendingRebuild?.cancel()
        legacyCheckTask?.cancel()
        restoreTask?.cancel()
        await job.suspendAndWait()
        await restoreTask?.value
        await copyFinder.suspendAndWait()
        await legacyCheckTask?.value
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
            self.legacyCheckTask?.cancel()
            self.legacyCheckAttempt = nil
            self.legacyCount = 0
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
        observeLegacyTrust()
    }

    private func observeLegacyTrust() {
        guard !retired, !settings.isDemo else { return }
        withObservationTracking {
            if case .blocked = settings.connectionTrust { legacyChecksInvalidated = true }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.retired else { return }
                self.observeLegacyTrust()
                guard self.admit() else { return }
                defer { self.finishedOperation() }
                self.legacyCheckTask?.cancel()
                self.legacyCheckAttempt = nil
                await self.refreshGrid()
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
        legacyCheckAttempt = nil
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
        if settings.isPaired { await settings.refreshServerInfo(forceBackupCheck: true) }
        await job.refreshQueue()
        await refreshLegacyBinding()
        await refreshReady()
        await refreshGrid()
        #if DEBUG
        await seedLegacyBackupsForTesting()
        #endif
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
        let blocked: Bool = if case .blocked = settings.connectionTrust { true } else { false }
        if !settings.isDemo && (blocked || legacyChecksInvalidated) {
            try await job.ledger.store.discardLegacyChecks()
            legacyChecksInvalidated = false
        }
        let projection = try await job.ledger.projection()
        let kept = projection.kept, backed = projection.backedUp
        let scope = settings.currentLegacyScope
        if let scope { try await job.ledger.store.discardLegacyChecks(exceptScope: scope) }
        let confirmed = !settings.isDemo ? scope.map {
            projection.legacyConfirmed(scope: $0, origin: settings.legacyOrigin)
        } ?? [:] : [:]
        let recovering = Set(backed.filter { $0.value.origin == nil || $0.value.version == nil || $0.value.origin != job.activeOrigin }.keys)
            .subtracting(confirmed.keys)
        automatic.useCanonicalDecisions(kept)
        var states = job.states
        let compactInProgress = job.compactInProgress
        for id in kept where states[id] == nil { states[id] = .unchanged(Self.keptAsIsReason) }
        await library.update(ledger: projection.entries, job: states,
                             backedUp: await backedUpDue(backed), origin: job.activeOrigin, recovering: recovering,
                             pendingImports: projection.pendingImports, compactInProgress: compactInProgress,
                             legacyConfirmed: confirmed, legacyServerName: serverName,
                             legacyActions: settings.server?.mode == .files && scope != nil,
                             checkingLegacy: checkingEarlierBackups, legacyKept: kept)
        // Only once the library itself has been read (this also runs when a backup changes things).
        if library.loaded { loaded = true }
        let state = library.state
        legacyCount = state.cells.reduce(0) { $0 + ($1.legacy ? 1 : 0) }
        scheduleLegacyCheck(projection)
        if !settings.isDemo {
            TipState.notBackedUp = state.count(.notBackedUp)
            TipState.bothBadgesShown = state.count(.readyToFree) > 0 && state.count(.atHome) > 0
            TipState.automaticOn = automatic.enabled
            TipState.trialDone = settings.trialConfirmed
        }
        await refreshNewSinceBackup()
        } catch { job.showQueueProblem(error) }
    }

    private func rejectLegacyBinding(_ binding: BackupStore.Binding) async {
        try? await job.ledger.store.discardLegacyChecks(origin: binding.origin)
        if job.bindingContext?.binding.id == binding.id { job.invalidateBinding() }
    }

    /// A cached engine context may predate a server history restore. Learn its current epoch even
    /// when every legacy observation is still within its seven-day display lifetime.
    private func refreshLegacyBinding() async {
        guard !settings.isDemo, settings.backupAPI == .current,
              let context = job.bindingContext, settings.matchesBackupBinding(context.binding),
              var client = settings.client else { return }
        client.timeout = 6
        do {
            let projection = try await job.ledger.projection()
            guard projection.entries.values.contains(where: { $0.origin == nil && $0.serverAssetID != nil })
                || projection.backedUp.values.contains(where: { $0.origin == nil }) else { return }
            let origin = try await ServerClientV2(client).capabilities().origin
            guard !retired, !suspended, !Task.isCancelled, settings.matchesBackupBinding(context.binding),
                  job.bindingContext?.binding == context.binding else { return }
            if origin != context.binding.origin { await rejectLegacyBinding(context.binding) }
            settings.rememberBackupSupport(.current, origin: origin)
        } catch {
            // Offline observations remain displayable until expiry, but cannot authorize actions.
        }
    }

    private func scheduleLegacyCheck(_ projection: BackupStore.LedgerProjection) {
        guard !settings.isDemo, !retired, !suspended, !Task.isCancelled, legacyCheckTask == nil,
              settings.isPaired,
              var client = settings.client,
              legacyCheckAttempt.map({ Date().timeIntervalSince($0) >= 60 }) ?? true else { return }
        client.timeout = 6
        let lookupClient = client
        let candidates = LegacyCheck.candidates(projection) { id in
            guard let kind = library.info(id)?.kind else { return nil }
            return kind == .video ? .video : .photo
        }
        if case .blocked = settings.connectionTrust { return }
        let initialScope = settings.currentLegacyScope
        let origin = settings.legacyOrigin
        let pending = initialScope.map {
            LegacyCheck.pending(candidates, projection: projection, scope: $0, origin: origin, now: Date())
        } ?? candidates
        guard !pending.isEmpty else { legacyCheckFinished = true; return }
        legacyCheckAttempt = Date()
        legacyCheckTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.legacyCheckTask = nil
                self.legacyCheckFinished = true
                self.scheduleRefreshGrid()
            }
            do {
                let scope = try await self.settings.legacyScope()
                guard initialScope == nil || scope == initialScope else { throw CancellationError() }
                let authorization = self.settings.legacyCheckAuthorization(scope: scope)
                try await LegacyCheck.run(pending, ledger: self.job.ledger, scope: scope, origin: origin,
                    lookup: { try await lookupClient.lookupCopies($0) }, current: { [weak self] in
                        guard let self else { return false }
                        return !self.retired && !self.suspended && self.settings.currentLegacyScope == scope
                            && self.settings.legacyOrigin == origin
                    }, authorized: authorization, serverOrigin: {
                        origin == nil ? nil : try await ServerClientV2(lookupClient).capabilities().origin
                    })
                self.legacyCheckAttempt = nil
                await self.refreshReady()
            } catch LegacyCheck.Failure.serverChanged {
                if let binding = self.job.bindingContext?.binding { await self.rejectLegacyBinding(binding) }
            } catch {
                // This display check is best effort. Missing/expired observations remain recovery;
                // transport errors are retried on a later refresh, never recorded as a catalog answer.
            }
        }
    }

    /// Items backed up without a compact copy, with when automatic mode makes it (nil: a kept favorite).
    private func backedUpDue(_ all: [String: CompactLedger.BackedUp]) async -> [String: Date?] {
        let backedUp = all.filter { $0.value.origin == job.activeOrigin && $0.value.version != nil }
        var due: [String: Date?] = Dictionary(uniqueKeysWithValues: all.compactMap { id, entry in
            entry.origin == nil && entry.kept == true ? (id, Date?.some(.distantFuture)) : nil
        })
        guard !backedUp.isEmpty else { return due }
        let ids = Array(backedUp.keys), photos = settings.photos
        let assets = await Task.detached(priority: .userInitiated) { photos.summaries(ids) }.value
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
        if job.isRunning || job.hasPendingWork || finishingBackups > 0 {
            let run = job.runProgress
            let detail = job.isRunning ? (run.current?.name ?? "Preparing")
                : job.hasRemoteWork ? "Processing on \(serverName)"
                : finishingBackups > 0 ? "Finishing compact copies" : "Waiting to continue"
            inputs.backingUp = (run.done, run.total, detail)
        }
        if let finished { inputs.finished = (finished.count, finished.bytes, Set(finished.originals)) }
        inputs.readyCount = ready.count
        inputs.readyBytes = ready.bytes
        inputs.phoneFreeBytes = phoneFreeBytes
        inputs.newSinceBackup = automatic.enabled ? nil : newSinceBackup
        return inputs
    }

    var showsRemoteNotice: Bool { job.hasRemoteWork && !job.hasPendingWork }

    /// Read at tap time, not captured from an earlier row's offer or its source.
    var freeUpOffer: AccessoryLadder.Offer? {
        guard !retired, !suspended else { return nil }
        let current = finished.flatMap { $0.count > 0 ? $0 : nil } ?? ready
        guard current.count > 0 else { return nil }
        return .init(count: current.count, bytes: current.bytes, originals: Set(current.originals))
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
        do {
            var candidates: [(original: String, entry: CompactLedger.Entry)] = []
            if let remover = job.remover() { candidates += try await remover.candidates() }
            if let remover = legacyRemover() { candidates += try await remover.candidates() }
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

    private func legacyRemover() -> LegacyOriginalRemover? {
        guard !settings.isDemo, !retired, !suspended, settings.server?.mode == .files,
              let client = settings.client, let scope = settings.currentLegacyScope else { return nil }
        let settings = settings, origin = settings.legacyOrigin
        return .init(client: client, ledger: job.ledger, photos: settings.photos, scope: scope, mode: .files,
            origin: origin, current: { [weak self] in
                self?.retired == false && self?.suspended == false && settings.currentLegacyScope == scope
                    && settings.server?.mode == .files && (origin == nil || settings.legacyOrigin == origin)
            })
    }

    private func legacyRestorer() -> LegacyOriginalRestorer? {
        guard let remover = legacyRemover() else { return nil }
        return .init(client: remover.client, ledger: remover.ledger, photos: remover.photos, scope: remover.scope,
            mode: remover.mode, origin: remover.origin, current: remover.current)
    }

    // MARK: Backing up

    /// Starts backing up these items (oldest first). Each original goes home, then its compact
    /// copy comes back to Photos.
    func backUp(_ identifiers: [String]) {
        guard !retired, !identifiers.isEmpty else { return }
        guard !settings.needsBackupUpdate else { settings.showingBackUpUpdate = true; return }
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
        library.apply(job: changes, compactInProgress: job.compactInProgress)
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
        var removers: [any RemovingOriginals] = []
        if let remover = job.remover() { removers.append(remover) }
        if let remover = legacyRemover() { removers.append(remover) }
        guard !removers.isEmpty else {
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
                var combined = OriginalRemover.Report()
                var remaining = limit ?? Int.max
                for remover in removers where remaining > 0 {
                    do {
                        let candidates = Array(try await remover.candidates(only: scope).prefix(remaining))
                        remaining -= candidates.count
                        let next = try await remover.removeEligible(limit: candidates.count, only: Set(candidates.map(\.original))) { message in
                            Task { @MainActor [weak self] in
                                if case .checking = self?.removal { self?.removal = .checking(message) }
                            }
                        }
                        combined.removed += next.removed
                        combined.blocked += next.blocked
                        combined.freedBytes += next.freedBytes
                        combined.cancelled = combined.cancelled || next.cancelled
                        if next.cancelled { break }
                    } catch {
                        combined.blocked.append(error.localizedDescription)
                        if AppSettings.isCancellation(error) { break }
                    }
                }
                return combined
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
        let projection = try await job.ledger.projection()
        let confirmed = settings.currentLegacyScope.map {
            projection.legacyConfirmed(scope: $0, origin: settings.legacyOrigin)
        } ?? [:]
        let entries = projection.entries.filter {
            wanted.contains($0.value.compactIdentifier)
                && ($0.value.verifiedCompact && $0.value.origin == job.activeOrigin && job.restorer() != nil
                    || $0.value.origin == nil && confirmed[$0.key] != nil && legacyRestorer() != nil)
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
        guard !retired, !suspended, !isRestoring, !items.isEmpty else { return }
        restoring = .running(.init(done: 0, total: items.count, message: "Getting ready"))
        Announce.say(items.count == 1 ? "Restoring the original." : "Restoring \(items.count) originals.")
        restoreTask = Task {
            var report = OriginalRestorer.Report()
            do {
                let entries = try await job.ledger.snapshot()
                let legacy = items.filter { entries[$0.key]?.origin == nil }
                let modern = items.filter { entries[$0.key]?.origin != nil }
                var engines: [(any RestoringOriginals, [OriginalRestorer.Item])] = []
                if let restorer = legacyRestorer(), !legacy.isEmpty { engines.append((restorer, legacy)) }
                if let restorer = job.restorer(), !modern.isEmpty { engines.append((restorer, modern)) }
                for (restorer, selected) in engines {
                    let next = await restorer.restore(selected) { progress in
                        Task { @MainActor [weak self] in
                            if self?.isRestoring == true { self?.restoring = .running(progress) }
                        }
                    }
                    report.restored += next.restored
                    report.problems += next.problems
                    report.bytes += next.bytes
                    report.copiesKept = report.copiesKept || next.copiesKept
                    if Task.isCancelled { break }
                }
                if engines.reduce(0, { $0 + $1.1.count }) != items.count {
                    report.problems.append("Reconnect the server holding the remaining originals before restoring.")
                }
            } catch { report.problems.append(error.localizedDescription) }
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
    @ObservationIgnored private var seedingLegacy = false

    private func seedLegacyBackupsForTesting() async {
        let count = settings.defaults.integer(forKey: "legacyBackUp")
        guard count > 0, !seedingLegacy, !settings.isDemo, settings.needsBackupUpdate,
              settings.defaults.string(forKey: "legacyBackUpSeeded") != settings.currentLegacyScope,
              let compactor = settings.compactor(ledger: job.ledger) else { return }
        seedingLegacy = true
        defer { seedingLegacy = false }
        let summaries = settings.photos.summaries(settings.photos.allIdentifiers())
        let identifiers = summaries.keys.filter {
            settings.photos.describe($0)?.name.hasPrefix("IMG_200") == true
        }.sorted {
            let lhs = summaries[$0]?.created ?? .distantPast, rhs = summaries[$1]?.created ?? .distantPast
            return lhs == rhs ? $0 < $1 : lhs > rhs
        }.prefix(min(count, 3))
        do {
            for id in identifiers {
                _ = try await compactor.compact(id, compactNow: true) { _ in }
            }
            settings.defaults.set(settings.currentLegacyScope, forKey: "legacyBackUpSeeded")
            legacyCheckAttempt = nil
            legacyCheckFinished = false
            await refreshGrid()
        } catch { AppLog.job.error("Legacy fixture setup failed: \(error.localizedDescription)") }
    }

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
