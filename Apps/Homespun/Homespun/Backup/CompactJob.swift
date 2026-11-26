// SPDX-License-Identifier: Apache-2.0
import Foundation
import HomespunCore
import Observation
import UIKit

/// The queue of items the user picked, processed one at a time.
@MainActor @Observable
final class CompactJob {
    enum State: Equatable, Sendable {
        case waiting
        case working(String)
        case saved(originalBytes: Int, compactBytes: Int)
        case unchanged(String)
        /// Not done yet for a reason that may pass; automatic mode tries again later.
        case notYet(String)
        case failed(String)
        /// Backed up; its compact copy comes later (a recent item, automatic mode).
        case backedUp(originalBytes: Int)
        case processing(String)

        /// Waiting or being worked on.
        var isOpen: Bool { if case .waiting = self { true } else if case .working = self { true } else { false } }

        var isFinished: Bool {
            switch self {
            case .waiting, .working, .processing: false
            default: true
            }
        }

        /// The state without its message or sizes; enough for the grid's badges.
        var phase: Phase {
            switch self {
            case .waiting: .waiting
            case .working: .working
            case .saved: .saved
            case .unchanged: .unchanged
            case .notYet: .notYet
            case .failed: .failed
            case .backedUp: .backedUp
            case .processing: .processing
            }
        }
    }

    enum Phase: Equatable { case waiting, working, saved, unchanged, notYet, failed, backedUp, processing }

    struct Item: Identifiable {
        let id = UUID()
        let assetIdentifier: String
        var name: String
        var symbol: String
        var state: State
        var trigger: RunHistory.Trigger = .manual
        /// Back the originals up but don't make the compact copy yet (a recent item).
        var backUpOnly = false

        var isWorking: Bool { if case .working = state { true } else { false } }
        var isLive: Bool { symbol == PhotoLibrary.Kind.livePhoto.symbol }
    }

    /// How the run in progress (or the last run) is going, kept as items change so the views
    /// showing it don't go through every item of a whole-library run for each progress message.
    struct RunProgress: Equatable {
        struct Current: Equatable {
            var asset: String
            var name: String
        }

        var total = 0
        /// Items finished, whatever the result.
        var done = 0
        var current: Current?
        /// Of items saved with a compact copy.
        var originalBytes = 0
        var compactBytes = 0
    }

    private(set) var items: [Item] = []
    /// The latest state of each item picked this session.
    private(set) var states: [String: State] = [:]
    private(set) var runProgress = RunProgress()
    private(set) var currentMessage = ""
    @ObservationIgnored var onPhaseChange: (@MainActor () -> Void)?
    @ObservationIgnored var onRunFinished: (@MainActor () -> Void)?
    @ObservationIgnored var onBindingChanged: (@MainActor () -> Void)?
    @ObservationIgnored private var phaseNoticePending = false
    /// Items before this one aren't waiting (items are appended, and never go back to waiting).
    @ObservationIgnored private var nextWaiting = 0
    /// Picks being read from Photos (`enqueue`), and what Stop dropped meanwhile: those items
    /// aren't queued when the read finishes.
    @ObservationIgnored private var preparing = 0
    @ObservationIgnored private var droppedWhilePreparing = Set<String>()
    @ObservationIgnored private var stoppedWhilePreparing = false
    var isPreparing: Bool { preparing > 0 }
    /// Bumped when an item's phase or retained grid fact changes (not for progress messages);
    /// the Library applies `takePhaseChanges()` then, touching only those items' badges.
    private(set) var phaseVersion = 0
    @ObservationIgnored private var phaseChanges: [String: State?] = [:]
    /// The item being worked on, so progress messages find it without searching every item.
    @ObservationIgnored private var current: (id: UUID, index: Int)?
    @ObservationIgnored private var runner: Task<Void, Never>?
    @ObservationIgnored private var retired = false
    @ObservationIgnored private var suspended = false
    @ObservationIgnored private var preparationWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var isRunning = false
    /// Paused between items: the item being worked on finishes, the rest wait (Activity 2.1).
    private(set) var isPaused = false
    /// When the current run started, and its items in order (kept until the next run starts).
    private(set) var runStarted: Date?
    private var runIDs: [UUID] = []
    private var compactIDs: [UUID: String] = [:]
    /// Finished runs are recorded here for Activity › History.
    var history: RunHistory?
    let settings: AppSettings
    let ledger: CompactLedger
    private let suppliedCompactor: (any Compacting)?
    @ObservationIgnored private(set) var coordinator: BackupCoordinator
    @ObservationIgnored private var contextWork: Task<Void, Error>?
    @ObservationIgnored private var controlWork: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var projected: [UUID: BackupStore.Operation] = [:]
    @ObservationIgnored private var positions: [UUID: Int] = [:]
    @ObservationIgnored private var projectionWork: Task<Void, Never>?
    @ObservationIgnored private var pendingProjection = Set<UUID>()
    @ObservationIgnored private var reloadProjection = false
    @ObservationIgnored private var historyWork: Task<Void, Never>?
    @ObservationIgnored private var pendingHistory = Set<UUID>()
    @ObservationIgnored private var recordedHistory: Set<UUID>?
    @ObservationIgnored private var currentOperationByItem: [String: UUID] = [:]
    /// Current-server originals retained while their compact copies are made or saved to Photos.
    @ObservationIgnored private(set) var compactInProgress = Set<String>()
    @ObservationIgnored private var retainedIDs = Set<UUID>()
    @ObservationIgnored private var remoteIDs = Set<UUID>()
    @ObservationIgnored private var pendingIDs = Set<UUID>()
    /// Committed admissions not yet reconciled; a reused ID gets a new coverage token.
    @ObservationIgnored private(set) var admissionSeeds: [UUID: UUID] = [:]
    @ObservationIgnored private var pausedIDs = Set<UUID>()
    private(set) var pausedCount = 0
    private(set) var queueProblem: String?
    private(set) var queueLoaded = false
    private(set) var remoteCount = 0
    private(set) var hasRemoteWork = false
    /// Current-server selections still pending, independent of local execution leases.
    private(set) var hasPendingWork = false
    /// Owns the foreground episode; PerfMonitor itself records only when opted in.
    @ObservationIgnored private(set) var measuresBackupFrames = false
    private(set) var retainedCount = 0
    var activeOrigin: BackupAPI.Origin? {
        guard let context = coordinator.context, settings.matchesBackupBinding(context.binding) else { return nil }
        return context.binding.origin
    }
    var bindingContext: BackupBindingContext? { coordinator.context }
    var canAdmitOffline: Bool { coordinator.context.map { settings.matchesBackupBinding($0.binding) } ?? false }

    init(settings: AppSettings, ledger: CompactLedger = CompactLedger(), compactor: (any Compacting)? = nil,
         discoverySleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.settings = settings
        self.ledger = ledger
        suppliedCompactor = compactor
        coordinator = BackupCoordinator(store: ledger.store, photos: settings.photos, namespace: ledger.namespace,
                                        discoverySleep: discoverySleep)
        coordinator.changed = { [weak self] ids in self?.project(ids) }
        coordinator.admitted = { [weak self] ids, bindingID in
            guard let self, !self.retired, !self.suspended, let origin = self.activeOrigin,
                  let binding = self.coordinator.context?.binding, binding.id == bindingID,
                  binding.origin == origin else { return }
            for id in ids { self.admissionSeeds[id] = UUID() }
            self.refreshPending()
        }
        coordinator.progress = { [weak self] id, message in self?.stageProgress(id, message: message) }
        coordinator.localWork = { [weak self] count in
            guard let self, !self.retired else { return }
            let wasRunning = self.isRunning
            self.isRunning = count > 0
            if !wasRunning, self.isRunning, !self.settings.isDemo {
                _ = LongRun.shared.begin(items: self.runProgress.total, server: self.settings.server?.name ?? "your server")
            }
        }
        coordinator.failed = { [weak self] error in self?.showQueueProblem(error) }
        coordinator.notifyReady = { [weak self] context in
            guard let self, !self.settings.isDemo, !self.retired, !self.suspended else { return false }
            return try await BackupReadyAlerts.post(context: context, ledger: self.ledger, photos: self.settings.photos,
                current: { !self.retired && !self.suspended && self.settings.matchesBackupBinding(context.binding) })
        }
        settings.backupBindingChanged = { [weak self] in self?.invalidateBinding() }
    }

    func showQueueProblem(_ error: Error) {
        guard !retired else { return }
        queueProblem = error.localizedDescription
    }

    private func project(_ ids: Set<UUID>) {
        if ids.isEmpty { reloadProjection = true } else { pendingProjection.formUnion(ids) }
        guard projectionWork == nil, !retired else { return }
        projectionWork = Task {
            defer {
                projectionWork = nil
                if retired || Task.isCancelled {
                    admissionSeeds = [:]
                    refreshPending()
                }
            }
            do {
                repeat {
                    guard !retired, !Task.isCancelled else { return }
                    if reloadProjection || !queueLoaded {
                        let covered = admissionSeeds
                        reloadProjection = false
                        pendingProjection = []
                        var cursor: Int64 = 0
                        repeat {
                            let page = try await ledger.store.operationPage(namespace: ledger.namespace, after: cursor)
                            cursor = page.cursor
                            try await applyProjection(page.operations)
                            guard !retired else { return }
                            if !page.hasMore { break }
                            await Task.yield()
                        } while !Task.isCancelled
                        guard !Task.isCancelled else { return }
                        queueLoaded = true
                        reconcileAdmissionSeeds(covered)
                    } else {
                        let requested = pendingProjection
                        let covered = Dictionary(uniqueKeysWithValues: requested.compactMap { id in
                            admissionSeeds[id].map { (id, $0) }
                        })
                        pendingProjection = []
                        var operations: [BackupStore.Operation] = []
                        for id in requested {
                            if let operation = try await ledger.store.operation(id) { operations.append(operation) }
                            else { pendingIDs.remove(id) }
                        }
                        try await applyProjection(operations)
                        guard !retired, !Task.isCancelled else { return }
                        reconcileAdmissionSeeds(covered)
                    }
                } while reloadProjection || !pendingProjection.isEmpty
            } catch {
                admissionSeeds = [:]
                refreshPending()
                showQueueProblem(error)
            }
        }
    }

    private func reconcileAdmissionSeeds(_ covered: [UUID: UUID]) {
        for (id, token) in covered where admissionSeeds[id] == token { admissionSeeds[id] = nil }
        refreshPending()
    }

    private func refreshPending() {
        let pending = !pendingIDs.isEmpty || !admissionSeeds.isEmpty
        if hasPendingWork != pending { hasPendingWork = pending }
        updateBackupFrames()
    }

    private func applyProjection(_ operations: [BackupStore.Operation]) async throws {
        let kept = try await ledger.decisions()
        let current = try await ledger.store.currentOperations(Array(Set(operations.map(\.itemID))), namespace: ledger.namespace)
        let unknown = current.filter { positions[$0.id] == nil }.map(\.itemID)
        let photos = settings.photos
        let descriptions = await Task.detached {
            Dictionary(Self.prepare(unknown, trigger: .manual, backUpOnly: [], photos: photos).map { ($0.assetIdentifier, $0) },
                       uniquingKeysWith: { first, _ in first })
        }.value
        guard !retired else { return }
        var progress = runProgress
        var terminal = false
        for operation in current {
            let wasCompactInProgress = compactInProgress.contains(operation.itemID)
            if let oldID = currentOperationByItem[operation.itemID], oldID != operation.id {
                retainedIDs.remove(oldID); remoteIDs.remove(oldID); pausedIDs.remove(oldID)
                pendingIDs.remove(oldID)
                compactInProgress.remove(operation.itemID)
                if let index = positions[oldID] {
                    let old = items[index].state, superseded = State.notYet("An earlier request is preserved; a newer selection owns this item.")
                    updateProgress(&progress, old: old, new: superseded)
                    items[index].state = superseded
                }
            }
            currentOperationByItem[operation.itemID] = operation.id
            projected[operation.id] = operation
            var state = Self.project(operation, kept: kept.contains(operation.itemID))
            if case .saved(let original, _) = state, let intent = try await ledger.store.importIntent(operation.id) {
                state = .saved(originalBytes: original, compactBytes: intent.expected.reduce(0) { $0 + $1.size })
            }
            guard !retired else { return }
            pendingIDs.remove(operation.id)
            if Self.presentsPendingWork(operation, state: state, origin: activeOrigin,
                                        bindingID: coordinator.context?.binding.id) {
                pendingIDs.insert(operation.id)
            }
            let inProgress = Self.presentsCompactInProgress(operation, origin: activeOrigin,
                                                          bindingID: coordinator.context?.binding.id)
            if inProgress { compactInProgress.insert(operation.itemID) }
            else { compactInProgress.remove(operation.itemID) }
            let previous = positions[operation.id].map { items[$0].state }
            let index: Int
            if let old = positions[operation.id] {
                index = old
                let before = items[index].state
                updateProgress(&progress, old: before, new: state)
                items[index].state = state
                states[operation.itemID] = state
                if before.phase != state.phase || wasCompactInProgress != inProgress {
                    noteChange(operation.itemID, state)
                    if before.phase != state.phase, state.phase == .saved { terminal = true }
                }
            } else {
                let description = descriptions[operation.itemID]
                let item = Item(assetIdentifier: operation.itemID, name: description?.name ?? "Item",
                                symbol: description?.symbol ?? "photo", state: state,
                                trigger: try await ledger.store.admissionInformation(operation.id)?.trigger ?? .manual,
                                backUpOnly: !operation.wantsCompact)
                index = items.count
                items.append(item)
                runIDs.append(item.id)
                updateProgress(&progress, old: nil, new: state)
                positions[operation.id] = index
                states[operation.itemID] = state
                noteChange(operation.itemID, state)
                if state.phase == .saved { terminal = true }
            }
            if state.isFinished, previous?.isFinished != true, previous != nil || queueLoaded {
                RenderProbe.count("job.finished")
            }
            retainedIDs.remove(operation.id); remoteIDs.remove(operation.id); pausedIDs.remove(operation.id)
            if operation.origin == activeOrigin {
                if operation.backup == .retained { retainedIDs.insert(operation.id) }
                if operation.wantsCompact, operation.backup == .retained,
                   [.requested, .queued, .processing].contains(operation.compact), operation.delivery != .importedVerified {
                    remoteIDs.insert(operation.id)
                }
                if operation.desired == .paused, operation.delivery != .importedVerified { pausedIDs.insert(operation.id) }
            }
            if operation.delivery == .importedVerified || operation.attention
                || operation.compact == .held || (operation.backup == .retained && !operation.wantsCompact) {
                pendingHistory.insert(operation.id)
            }
        }
        remoteCount = remoteIDs.count
        if hasRemoteWork != !remoteIDs.isEmpty { hasRemoteWork = !remoteIDs.isEmpty }
        retainedCount = retainedIDs.count
        pausedCount = pausedIDs.count
        progress.total = items.count
        runProgress = progress
        refreshPending()
        if isRunning, !settings.isDemo {
            _ = LongRun.shared.begin(items: progress.total, server: settings.server?.name ?? "your server")
        }
        if terminal { onRunFinished?() }
        scheduleHistory()
    }

    private func updateProgress(_ progress: inout RunProgress, old: State?, new: State) {
        if let old, old.isFinished { progress.done -= 1 }
        if new.isFinished { progress.done += 1 }
        func adding(_ value: Int, _ delta: Int) -> Int {
            let (next, overflow) = value.addingReportingOverflow(delta)
            return overflow ? (delta >= 0 ? Int.max : 0) : max(0, next)
        }
        if case .saved(let original, let compact)? = old {
            progress.originalBytes = adding(progress.originalBytes, -original)
            progress.compactBytes = adding(progress.compactBytes, -compact)
        }
        if case .saved(let original, let compact) = new {
            progress.originalBytes = adding(progress.originalBytes, original)
            progress.compactBytes = adding(progress.compactBytes, compact)
        }
    }

    static func project(_ operation: BackupStore.Operation, kept: Bool) -> State {
        if operation.delivery == .importedVerified, let manifest = operation.manifest {
            return .saved(originalBytes: manifest.resources.reduce(0) { $0 + $1.size },
                          compactBytes: operation.receipt?.derivative?.resources.reduce(0) { $0 + $1.size } ?? 0)
        }
        if kept { return .unchanged(AutomaticMode.keptAsIsReason) }
        if operation.attention { return .failed(operation.problem?.message ?? "The previous Photos action needs reconciliation before continuing.") }
        if operation.desired == .paused { return .notYet("Paused. This selection is saved and resumes when you choose Resume.") }
        if operation.desired == .cancelled { return .unchanged("Processing was cancelled. Verified originals remain retained.") }
        if operation.backup == .retained {
            if operation.compact == .held { return .unchanged(operation.receipt?.message ?? "Kept as is; the original is backed up.") }
            if operation.compact == .failed { return .failed(operation.receipt?.message ?? "The server couldn't make the compact copy. Its original backup remains.") }
            if !operation.wantsCompact { return .backedUp(originalBytes: operation.manifest?.resources.reduce(0) { $0 + $1.size } ?? 0) }
            if operation.compact != .ready { return .processing("Original backed up; compact copy processing on the server.") }
            return .working(operation.problem?.message ?? "Saving compact copy")
        }
        if operation.backup == .blocked || operation.backup == .failed { return .failed(operation.problem?.message ?? "This backup needs attention.") }
        // A durable stage survives lease handoffs; local execution ownership is tracked separately.
        if operation.lease != nil || operation.backup != .selected {
            return .working(operation.problem?.message ?? "Backing up original")
        }
        return .waiting
    }

    static func presentsCompactInProgress(_ operation: BackupStore.Operation, origin: BackupAPI.Origin?,
                                         bindingID: UUID?) -> Bool {
        origin != nil && operation.origin == origin && bindingID != nil && operation.bindingID == bindingID
            && operation.desired == .active && !operation.attention && operation.backup == .retained
            && operation.wantsCompact && operation.delivery != .importedVerified
            && operation.compact != .held && operation.compact != .failed
    }

    static func presentsPendingWork(_ operation: BackupStore.Operation, state: State, origin: BackupAPI.Origin?,
                                    bindingID: UUID?) -> Bool {
        origin != nil && operation.origin == origin && bindingID != nil && operation.bindingID == bindingID
            && !state.isFinished
    }

    private func stageProgress(_ id: UUID, message: String) {
        guard !retired, !suspended, let index = positions[id], let operation = projected[id],
              currentOperationByItem[operation.itemID] == id else { return }
        let state = State.working(message)
        if items[index].state.phase != .working { noteChange(operation.itemID, state) }
        items[index].state = state
        states[operation.itemID] = state
        currentMessage = message
        runProgress.current = .init(asset: operation.itemID, name: items[index].name)
    }

    func refreshQueue() async {
        guard !retired, !suspended, suppliedCompactor == nil else { return }
        do {
            try await ensureContext()
            try await coordinator.reconcile()
            project([])
        } catch { showQueueProblem(error) }
    }

    private func ensureContext() async throws {
        guard !retired, !suspended else { throw CancellationError() }
        if let context = coordinator.context, settings.matchesBackupBinding(context.binding) { return }
        if let contextWork { try await contextWork.value; return }
        let work = Task {
            let context: BackupBindingContext
            if let cached = try await settings.cachedBackupContext(store: ledger.store, namespace: ledger.namespace) {
                context = cached
            } else {
                context = try await settings.backupContext(store: ledger.store, namespace: ledger.namespace)
            }
            let policy = try await settings.backupSpacePolicy(store: ledger.store)
            guard !retired, !suspended, !Task.isCancelled, settings.matchesBackupBinding(context.binding) else { throw CancellationError() }
            try await coordinator.activate(context, policy: policy)
            if !settings.isDemo {
                control { [weak self] in
                    guard let self, !self.retired, !self.suspended, self.settings.matchesBackupBinding(context.binding),
                          self.coordinator.context?.binding.id == context.binding.id else { return }
                    do {
                        try await WakeSystem.enrollment.configure(.init(bindingID: context.binding.id,
                            enroll: { sender in try await context.remote.enrollWake(sender) },
                            reconcile: { [weak self] in
                                guard let self, !self.retired, !self.suspended,
                                      self.settings.matchesBackupBinding(context.binding) else { return false }
                                let changed = try await self.coordinator.reconcileHint(bindingID: context.binding.id)
                                if changed { AppModel.schedulePendingBackup() }
                                return changed
                            }))
                        WakeSystem.updateRegistration()
                    } catch { WakeSystem.enrollment.enrollmentFailed() }
                }
            }
            queueProblem = nil
        }
        contextWork = work
        defer { contextWork = nil }
        try await work.value
    }

    func runOpportunity() async throws {
        try await ensureContext()
        try await coordinator.runOpportunity()
    }

    func setVisible(_ visible: Bool) {
        coordinator.setVisible(visible)
        updateBackupFrames()
    }

    private func updateBackupFrames() {
        let wanted = suppliedCompactor == nil && !retired && !suspended && coordinator.isForegroundActive
            && activeOrigin != nil && hasPendingWork
        guard wanted != measuresBackupFrames else { return }
        measuresBackupFrames = wanted
        if wanted { PerfMonitor.shared.framesBegan("backup") }
        else { PerfMonitor.shared.framesEnded("backup") }
    }

    func suspendAndWait() async {
        suspended = true
        updateBackupFrames()
        contextWork?.cancel()
        coordinator.suspend()
        _ = try? await contextWork?.value
        do { try await coordinator.suspendAndWait() } catch { showQueueProblem(error) }
        let controls = Array(controlWork.values)
        for control in controls { await control.value }
        await projectionWork?.value
        historyWork?.cancel()
        await historyWork?.value
        do { try await flushHistory() } catch { showQueueProblem(error) }
        if preparing > 0 { await withCheckedContinuation { preparationWaiters.append($0) } }
    }

    func resumeExecution() {
        guard !retired else { return }
        suspended = false
        coordinator.resumeExecution()
        project([])
    }

    func invalidateBinding() {
        guard !retired, coordinator.context != nil || contextWork != nil else { return }
        contextWork?.cancel()
        coordinator.suspend()
        resetPresentationFacts()
        onBindingChanged?()
        control { [self] in
            _ = try? await contextWork?.value
            try await coordinator.detach()
            resetPresentationFacts()
            remoteIDs = []; retainedIDs = []; pausedIDs = []
            remoteCount = 0; retainedCount = 0; pausedCount = 0
            hasRemoteWork = false
            if !settings.isDemo { try await WakeSystem.enrollment.configure(nil); WakeSystem.updateRegistration() }
            if !suspended, settings.isPaired { await refreshQueue() }
            onBindingChanged?()
        }
    }

    private func resetPresentationFacts() {
        let previous = compactInProgress
        compactInProgress = []
        pendingIDs = []
        admissionSeeds = [:]
        refreshPending()
        for id in previous { noteChange(id, states[id]) }
    }

    func remover() -> DurableOriginalRemover? {
        guard let context = coordinator.context, settings.matchesBackupBinding(context.binding) else { return nil }
        let settings = settings
        return .init(context: context, ledger: ledger, photos: settings.photos,
                     current: { settings.matchesBackupBinding(context.binding) })
    }

    func restorer() -> DurableOriginalRestorer? {
        guard let context = coordinator.context, settings.matchesBackupBinding(context.binding),
              let workspace = coordinator.currentWorkspace else { return nil }
        return .init(context: context, ledger: ledger, photos: settings.photos, workspace: workspace)
    }

    private func control(_ operation: @escaping @MainActor () async throws -> Void) {
        let id = UUID()
        controlWork[id] = Task {
            defer { controlWork[id] = nil }
            do { try await operation() } catch { showQueueProblem(error) }
        }
    }

    private func scheduleHistory() {
        guard !pendingHistory.isEmpty, historyWork == nil, !retired else { return }
        historyWork = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            do { try await flushHistory() } catch { showQueueProblem(error) }
            historyWork = nil
        }
    }

    private func flushHistory() async throws {
        guard let history else { return }
        await history.load()
        if recordedHistory == nil { recordedHistory = Set(history.runs.flatMap { $0.items.map(\.id) }) }
        let pending = pendingHistory
        pendingHistory = []
        var records: [RunHistory.Item] = []
        for id in pending where recordedHistory?.contains(id) != true {
            guard let operation = projected[id], let index = positions[id],
                  operation.updatedAt >= Date().addingTimeInterval(-90 * 86_400) else { continue }
            var item = Self.historyItem(items[index])
            item.id = operation.id
            records.append(item)
            recordedHistory?.insert(id)
        }
        if !records.isEmpty {
            history.record(.init(kind: .backUp, trigger: .manual, start: runStarted ?? Date(), end: Date(), items: records))
        }
    }

    /// Items whose phase or retained grid fact changed (nil: no longer in the job), latest state each.
    func takePhaseChanges() -> [String: State?] {
        defer { phaseChanges = [:] }
        return phaseChanges
    }

    private func noteChange(_ id: String, _ state: State?) {
        phaseChanges[id] = .some(state)
        bumpPhase()
    }

    private func bumpPhase() {
        phaseVersion &+= 1
        guard !phaseNoticePending else { return }
        phaseNoticePending = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            phaseNoticePending = false
            onPhaseChange?()
        }
    }

    /// Only the newest item of an asset changes state (an asset is never queued twice at once), and
    /// only items of the current run finish.
    private func setState(_ index: Int, _ state: State) {
        let old = items[index].state
        items[index].state = state
        states[items[index].assetIdentifier] = state
        if old.isOpen, !state.isOpen {
            RenderProbe.count("job.finished")
            runProgress.done += 1
            if case .saved(let original, let compact) = state {
                runProgress.originalBytes += original
                runProgress.compactBytes += compact
            }
        }
        if old.phase != state.phase { noteChange(items[index].assetIdentifier, state) }
    }

    /// After items are removed: states and progress counted again.
    private func resync() {
        nextWaiting = 0
        states = Dictionary(items.map { ($0.assetIdentifier, $0.state) }, uniquingKeysWith: { _, latest in latest })
        let run = runItems
        var progress = RunProgress(total: run.count, current: runProgress.current)
        for item in run where !item.state.isOpen {
            progress.done += 1
            if case .saved(let original, let compact) = item.state {
                progress.originalBytes += original
                progress.compactBytes += compact
            }
        }
        runProgress = progress
    }

    /// The first item waiting, searching on from the last one found.
    private func waitingIndex() -> Int? {
        if nextWaiting > items.count { nextWaiting = 0 }
        guard let index = items[nextWaiting...].firstIndex(where: { $0.state == .waiting }) else { return nil }
        nextWaiting = index
        return index
    }

    var hasWaiting: Bool { suppliedCompactor != nil && waitingIndex() != nil }

    var savedOriginalBytes: Int { items.reduce(0) { if case .saved(let o, _) = $1.state { $0 + o } else { $0 } } }
    var savedCompactBytes: Int { items.reduce(0) { if case .saved(_, let c) = $1.state { $0 + c } else { $0 } } }

    /// The items of the run in progress, or of the last run until the next one starts.
    var runItems: [Item] {
        let ids = Set(runIDs)
        return items.filter { ids.contains($0.id) }
    }

    /// Queues items oldest first, skipping any already waiting or working. Reading them from Photos
    /// (dates, kinds, names) happens in the background: selecting a whole library is tens of
    /// thousands of items. File names are filled in as each starts.
    /// Without a `trigger`, items picked during setup count as the first task, later ones as manual.
    /// `backUpOnly`: of these, the recent items automatic mode backs up now and compacts later.
    @discardableResult
    func enqueue(_ assetIdentifiers: [String], trigger: RunHistory.Trigger? = nil, backUpOnly: Set<String> = [],
                 authorized: @MainActor () -> Bool = { true }) async -> Set<String> {
        if suppliedCompactor != nil {
            await enqueueStandIn(assetIdentifiers, trigger: trigger, backUpOnly: backUpOnly)
            return Set(assetIdentifiers.filter { states[$0] != nil })
        }
        guard !retired, !suspended, !assetIdentifiers.isEmpty, authorized() else { return [] }
        guard settings.backupAdmissionsEnabled else {
            queueProblem = "New backup selections are paused. Previously saved work still reconciles and can be recovered."
            return []
        }
        preparing += 1
        defer {
            preparing -= 1
            if preparing == 0 {
                let waiters = preparationWaiters
                preparationWaiters = []
                waiters.forEach { $0.resume() }
            }
        }
        var accepted = Set<String>()
        do {
            try await ensureContext()
            guard !retired, !suspended, authorized(), settings.backupAdmissionsEnabled, !Task.isCancelled else { return [] }
            let trigger = trigger ?? (settings.onboardingComplete ? .manual : .firstTask)
            runStarted = runStarted ?? Date()
            let immediate = assetIdentifiers.filter { !backUpOnly.contains($0) }
            let deferred = assetIdentifiers.filter { backUpOnly.contains($0) }
            if !immediate.isEmpty {
                _ = try await coordinator.admit(immediate, compact: true, trigger: trigger,
                    authorized: { authorized() && settings.backupAdmissionsEnabled && !suspended })
                accepted.formUnion(immediate)
            }
            if !deferred.isEmpty {
                _ = try await coordinator.admit(deferred, compact: false, trigger: trigger,
                    authorized: { authorized() && settings.backupAdmissionsEnabled && !suspended })
                accepted.formUnion(deferred)
            }
            queueProblem = nil
            if !accepted.isEmpty, !settings.isDemo { AppModel.schedulePendingBackup() }
        } catch { showQueueProblem(error) }
        return accepted
    }

    private func enqueueStandIn(_ assetIdentifiers: [String], trigger: RunHistory.Trigger? = nil,
                                backUpOnly: Set<String> = []) async {
        guard !retired else { return }
        let trigger = trigger ?? (settings.onboardingComplete ? .manual : .firstTask)
        let wanted = assetIdentifiers.filter { states[$0]?.isOpen != true }
        guard !wanted.isEmpty else { return }
        preparing += 1
        let photos = settings.photos
        let prepared = await Task.detached(priority: .userInitiated) {
            Self.prepare(wanted, trigger: trigger, backUpOnly: backUpOnly, photos: photos)
        }.value
        preparing -= 1
        if preparing == 0 {
            let waiters = preparationWaiters
            preparationWaiters = []
            waiters.forEach { $0.resume() }
        }
        let stopped = stoppedWhilePreparing, dropped = droppedWhilePreparing
        if preparing == 0 {
            stoppedWhilePreparing = false
            droppedWhilePreparing = []
        }
        guard !stopped, !retired else { return }
        // Queued meanwhile by another pick: once is enough.
        let added = prepared.filter { states[$0.assetIdentifier]?.isOpen != true && !dropped.contains($0.assetIdentifier) }
        guard !added.isEmpty else { return }
        // A new run starts: Activity's Now card counts from here.
        if !isRunning {
            runIDs = []
            runStarted = Date()
            runProgress = RunProgress()
        }
        items += added
        runIDs += added.map(\.id)
        runProgress.total += added.count
        runProgress.done += added.count { !$0.state.isOpen }
        for item in added {
            states[item.assetIdentifier] = item.state
            phaseChanges[item.assetIdentifier] = .some(item.state)
        }
        bumpPhase()
        if !isRunning {
            isRunning = true
            runner = Task { await run() }
        }
    }

    /// The items to queue, oldest first; items no longer in the library fail at once.
    private nonisolated static func prepare(_ identifiers: [String], trigger: RunHistory.Trigger,
                                            backUpOnly: Set<String>, photos: any PhotoSource) -> [Item] {
        let assets = photos.summaries(identifiers)
        var added: [Item] = []
        added.reserveCapacity(identifiers.count)
        for identifier in PhotoLibrary.chronological(identifiers, dates: assets.compactMapValues(\.created)) {
            guard let asset = assets[identifier], let kind = asset.kind else {
                added.append(Item(assetIdentifier: identifier, name: "Item", symbol: "questionmark.square",
                                  state: .failed(PhotoLibrary.Failure.notFound.localizedDescription), trigger: trigger))
                continue
            }
            let date = asset.created?.formatted(date: .abbreviated, time: .shortened)
            added.append(Item(assetIdentifier: identifier, name: date.map { "\(kind.name), \($0)" } ?? kind.name,
                              symbol: kind.symbol, state: .waiting, trigger: trigger,
                              backUpOnly: backUpOnly.contains(identifier)))
        }
        return added
    }

    /// Drops these items if they haven't started (when iOS ends a background run); an item
    /// being worked on finishes, and items the user queued are left alone.
    func stopWaiting(_ identifiers: Set<String>) {
        if suppliedCompactor == nil {
            control { [self] in
                try await coordinator.pause(only: identifiers)
                project([])
            }
            return
        }
        if preparing > 0 { droppedWhilePreparing.formUnion(identifiers) }
        let dropped = items.filter { $0.state == .waiting && identifiers.contains($0.assetIdentifier) }
        guard !dropped.isEmpty else { return }
        items.removeAll { $0.state == .waiting && identifiers.contains($0.assetIdentifier) }
        current = nil
        resync()
        for item in dropped { phaseChanges[item.assetIdentifier] = .some(states[item.assetIdentifier]) }
        bumpPhase()
    }

    /// Stops after the item being worked on: items waiting are dropped, and everything already
    /// backed up stays backed up.
    func stop() {
        if suppliedCompactor == nil {
            isPaused = true
            control { [self] in try await coordinator.pause(); project([]) }
            return
        }
        if preparing > 0 { stoppedWhilePreparing = true }
        let dropped = items.filter { $0.state == .waiting }.map(\.assetIdentifier)
        items.removeAll { $0.state == .waiting }
        current = nil
        isPaused = false
        guard !dropped.isEmpty else { return }
        resync()
        for id in dropped { phaseChanges[id] = .some(states[id]) }
        bumpPhase()
    }

    /// Rejects new work immediately. The current item finishes its admitted side effects.
    func retire() {
        retired = true
        resetPresentationFacts()
        coordinator.retire()
        contextWork?.cancel()
        historyWork?.cancel()
        if suppliedCompactor != nil { stop() }
    }

    /// A lifetime boundary, unlike Stop: no admitted writer remains when this returns.
    func stopAndWait() async {
        retire()
        _ = try? await contextWork?.value
        let controls = controlWork.values
        for control in controls { await control.value }
        do { try await coordinator.stopAndWait() } catch { queueProblem = error.localizedDescription }
        await projectionWork?.value
        await historyWork?.value
        do { try await flushHistory() } catch { queueProblem = error.localizedDescription }
        await runner?.value
        if preparing > 0 { await withCheckedContinuation { preparationWaiters.append($0) } }
    }

    func pause() {
        if suppliedCompactor == nil { stop(); return }
        guard isRunning else { return }
        isPaused = true
        UIApplication.shared.isIdleTimerDisabled = false
        Announce.say("Paused.")
    }

    func resume() {
        if suppliedCompactor == nil {
            isPaused = false
            control { [self] in try await coordinator.resume(); project([]) }
            return
        }
        guard isPaused else { return }
        isPaused = false
        UIApplication.shared.isIdleTimerDisabled = true
    }

    func clearFinished() {
        if suppliedCompactor == nil { return }
        items.removeAll { item in
            switch item.state {
            case .waiting, .working: false
            default: true
            }
        }
        resync()
    }

    /// Projects the person's Keep As Is decision into the current attention state.
    @discardableResult
    func resolveFailure(_ identifier: String) -> Bool {
        guard case .failed? = states[identifier],
              let index = items.lastIndex(where: { $0.assetIdentifier == identifier }) else { return false }
        setState(index, .unchanged(AutomaticMode.keptAsIsReason))
        return true
    }

    func keepAsIs(_ identifier: String) async throws {
        try await ledger.store.setKeptDecision([identifier], namespace: ledger.namespace, kept: true)
        project([])
    }

    private func run() async {
        isRunning = true
        // Encoding stops if the phone locks; keep the screen on while working.
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            record()
            isPaused = false
            isRunning = false
            UIApplication.shared.isIdleTimerDisabled = false
            PerfMonitor.shared.framesEnded("backup")
            onRunFinished?()
        }
        PerfMonitor.shared.framesBegan("backup")
        if settings.usesServer { await settings.refreshServerInfo() }
        while true {
            while isPaused, hasWaiting {
                try? await Task.sleep(for: .milliseconds(300))
            }
            guard let index = waitingIndex() else { break }
            let id = items[index].id
            setState(index, .working("Starting"))
            current = (id, index)
            if let name = settings.photos.describe(items[index].assetIdentifier)?.name { items[index].name = name }
            currentMessage = "Starting"
            runProgress.current = .init(asset: items[index].assetIdentifier, name: items[index].name)
            let state: State
            do {
                guard let compactor = suppliedCompactor ?? settings.compactor(ledger: ledger) else {
                    throw ServerClient.Failure(status: 0, message: "Connect your Homespun Server first.")
                }
                let asset = items[index].assetIdentifier, compactNow = !items[index].backUpOnly
                let outcome = try await Signposts.measure(Signposts.backUp, "Item") {
                    try await compactor.compact(asset, compactNow: compactNow) { [weak self] message in
                        Task { @MainActor in self?.report(message, for: id) }
                    }
                }
                switch outcome {
                case .saved(let copy, let original, let compact):
                    compactIDs[id] = copy
                    state = .saved(originalBytes: original, compactBytes: compact)
                case .unchanged(let reason): state = .unchanged(reason)
                case .notYet(let reason): state = .notYet(reason)
                case .backedUp(let original): state = .backedUp(originalBytes: original)
                }
            } catch {
                state = .failed(error.localizedDescription)
                let code = Telemetry.Event.code(error)
                AppLog.job.error("item failed: \(code, privacy: .public)")
                Telemetry.shared.record(error: error, where: "backup")
            }
            if let position = position(of: id) { setState(position, state) }
            current = nil
            runProgress.current = nil
            currentMessage = ""
        }
    }

    /// Adds the run that just ended to the history: its trigger is manual if anything in it was.
    private func record() {
        let finished = runItems
        guard let history, let started = runStarted, !finished.isEmpty else { return }
        let triggers = Set(finished.map(\.trigger))
        let trigger: RunHistory.Trigger = triggers.contains(.manual) ? .manual
            : triggers.contains(.firstTask) ? .firstTask : .automatic
        AppLog.job.info("run finished: \(finished.count, privacy: .public) items, trigger \(trigger.rawValue, privacy: .public)")
        history.record(RunHistory.Run(kind: .backUp, trigger: trigger, start: started, end: Date(),
                                      items: finished.map { Self.historyItem($0, compactID: compactIDs[$0.id]) }))
        for item in finished { compactIDs[item.id] = nil }
    }

    static func historyItem(_ item: Item, compactID: String? = nil) -> RunHistory.Item {
        var entry = RunHistory.Item(id: item.id, assetID: item.assetIdentifier, name: item.name, live: item.isLive,
                                    result: .waiting)
        switch item.state {
        case .waiting, .working: break
        case .saved(let original, let compact):
            entry.result = .saved
            entry.originalBytes = original
            entry.compactBytes = compact
            entry.compactID = compactID
        case .unchanged(let reason):
            entry.result = .kept
            entry.reason = reason
        case .notYet(let reason):
            entry.result = .notYet
            entry.reason = reason
        case .failed(let reason):
            entry.result = .failed
            entry.reason = reason
        case .backedUp(let original):
            entry.result = .backedUp
            entry.originalBytes = original
        case .processing(let reason):
            entry.result = .backedUp
            entry.reason = reason
        }
        return entry
    }

    private func report(_ message: String, for id: UUID) {
        guard let index = position(of: id), case .working = items[index].state else { return }
        items[index].state = .working(message)
        states[items[index].assetIdentifier] = .working(message)
        currentMessage = message
    }

    /// Where an item is: the one being worked on at once, others by search.
    private func position(of id: UUID) -> Int? {
        if let current, current.index < items.count, items[current.index].id == id { return current.index }
        return items.firstIndex { $0.id == id }
    }
}
