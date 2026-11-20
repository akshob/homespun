// SPDX-License-Identifier: Apache-2.0
import Foundation
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

        /// Waiting or being worked on.
        var isOpen: Bool { if case .waiting = self { true } else if case .working = self { true } else { false } }

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
            }
        }
    }

    enum Phase: Equatable { case waiting, working, saved, unchanged, notYet, failed, backedUp }

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
    @ObservationIgnored private var phaseNoticePending = false
    /// Items before this one aren't waiting (items are appended, and never go back to waiting).
    @ObservationIgnored private var nextWaiting = 0
    /// Picks being read from Photos (`enqueue`), and what Stop dropped meanwhile: those items
    /// aren't queued when the read finishes.
    @ObservationIgnored private var preparing = 0
    @ObservationIgnored private var droppedWhilePreparing = Set<String>()
    @ObservationIgnored private var stoppedWhilePreparing = false
    var isPreparing: Bool { preparing > 0 }
    /// Bumped when an item's phase changes (not for progress messages); the Library applies
    /// `takePhaseChanges()` then, touching only those items' badges.
    private(set) var phaseVersion = 0
    @ObservationIgnored private var phaseChanges: [String: State?] = [:]
    /// The item being worked on, so progress messages find it without searching every item.
    @ObservationIgnored private var current: (id: UUID, index: Int)?
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

    init(settings: AppSettings, ledger: CompactLedger = CompactLedger(), initialStates: [String: State] = [:]) {
        self.settings = settings
        self.ledger = ledger
        states = initialStates
    }

    /// The items whose phase changed since the last call (nil: no longer in the job), latest state each.
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

    var hasWaiting: Bool { waitingIndex() != nil }

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
    func enqueue(_ assetIdentifiers: [String], trigger: RunHistory.Trigger? = nil, backUpOnly: Set<String> = []) async {
        let trigger = trigger ?? (settings.onboardingComplete ? .manual : .firstTask)
        let wanted = assetIdentifiers.filter { states[$0]?.isOpen != true }
        guard !wanted.isEmpty else { return }
        preparing += 1
        let photos = settings.photos
        let prepared = await Task.detached(priority: .userInitiated) {
            Self.prepare(wanted, trigger: trigger, backUpOnly: backUpOnly, photos: photos)
        }.value
        preparing -= 1
        let stopped = stoppedWhilePreparing, dropped = droppedWhilePreparing
        if preparing == 0 {
            stoppedWhilePreparing = false
            droppedWhilePreparing = []
        }
        guard !stopped else { return }
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
            Task { await run() }
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

    func pause() {
        guard isRunning else { return }
        isPaused = true
        UIApplication.shared.isIdleTimerDisabled = false
        Announce.say("Paused.")
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        UIApplication.shared.isIdleTimerDisabled = true
    }

    func clearFinished() {
        items.removeAll { item in
            switch item.state {
            case .waiting, .working: false
            default: true
            }
        }
        resync()
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
                guard let compactor = settings.compactor(ledger: ledger) else {
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
