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
    let library = LibraryModel()
    let journey = JourneyLog()
    private(set) var access = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    /// The grid has its first contents, so it can open scrolled to the newest items.
    private(set) var loaded = false
    /// Everything ready to free up now.
    private(set) var ready = Ready()
    /// What the last Back Up finished with, until it's freed or dismissed (02·2.3).
    private(set) var finished: Ready?
    private(set) var removal = Removal.idle
    /// The Library is in Select mode: the status accessory steps aside so it doesn't cover
    /// Select mode's Back Up.
    var isSelecting = false
    /// Free space on this iPhone, for "almost full" (T15).
    private(set) var phoneFreeBytes: Int?
    /// Not backed up and created since the last backup, with the days since (T19).
    private(set) var newSinceBackup: (count: Int, days: Int)?
    /// Originals from the current Back Up; offered once the run finishes.
    private var batch = Set<String>()
    private var started = false

    init(settings: AppSettings, job: CompactJob, premium: Premium, automatic: AutomaticMode, copyFinder: CopyFinder) {
        self.settings = settings
        self.job = job
        self.premium = premium
        self.automatic = automatic
        self.copyFinder = copyFinder
    }

    var isRemoving: Bool { if case .checking = removal { true } else { false } }

    /// How many the next Free Up Space removes: at most 10 until the user says copies look right.
    var nextRemovalCount: Int {
        settings.trialConfirmed ? ready.count : min(ready.count, AppSettings.trialLimit)
    }

    /// The bytes the next Free Up Space frees.
    var nextRemovalBytes: Int {
        guard !settings.trialConfirmed, ready.count > AppSettings.trialLimit else { return ready.bytes }
        return Array(ready.originals.prefix(AppSettings.trialLimit)).reduce(0) { $0 + (readySizes[$1] ?? 0) }
    }

    /// Each ready original's size, for what a scoped Free Up Space frees.
    private(set) var readySizes: [String: Int] = [:]

    /// Why Back Up can't start now, if it can't.
    var backUpBlockedReason: String? {
        guard settings.isPaired else { return "Set up your home computer first." }
        if case .unreachable = settings.serverStatus { return "Can't reach \(serverName)." }
        return nil
    }

    var serverName: String { settings.server?.name ?? "your server" }

    // MARK: Starting and refreshing

    /// Called once when the main screen appears.
    func start() async {
        guard !started else { return }
        started = true
        library.onChange = { @MainActor [weak self] in Task { await self?.refreshGrid() } }
        await refresh()
        // Only what this Apple Account owns; the product itself loads on the Premium screen.
        await premium.refresh()
        await runAutomatic()
    }

    func refresh() async {
        access = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        library.reload()
        if settings.isPaired { await settings.refreshServerInfo() }
        await refreshReady()
        await refreshGrid()
    }

    func requestAccess() async {
        access = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        await refresh()
    }

    func refreshGrid() async {
        library.update(ledger: await job.ledger.snapshot(), job: job.states)
        loaded = true
        let state = library.state
        TipState.notBackedUp = state.count(.notBackedUp)
        TipState.bothBadgesShown = state.count(.readyToFree) > 0 && state.count(.atHome) > 0
        TipState.automaticOn = automatic.enabled
        TipState.trialDone = settings.trialConfirmed
        refreshNewSinceBackup()
    }

    /// The accessory's inputs, for the ladder (DESIGN §16.4).
    var accessoryInputs: AccessoryLadder.Inputs {
        var inputs = AccessoryLadder.Inputs()
        inputs.paired = settings.isPaired
        if case .unreachable = settings.serverStatus { inputs.unreachable = serverName }
        if case .checking(let message) = removal { inputs.removing = message }
        if job.isRunning {
            let run = job.runItems
            let open = run.filter { $0.state == .waiting || $0.isWorking }.count
            inputs.backingUp = (run.count - open, run.count, run.first(where: \.isWorking)?.name)
        }
        if let finished { inputs.finished = (finished.count, finished.bytes, Set(finished.originals)) }
        inputs.readyCount = ready.count
        inputs.readyBytes = ready.bytes
        inputs.phoneFreeBytes = phoneFreeBytes
        inputs.newSinceBackup = automatic.enabled ? nil : newSinceBackup
        return inputs
    }

    private func refreshNewSinceBackup() {
        let values = try? URL.homeDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        phoneFreeBytes = values?.volumeAvailableCapacityForImportantUsage.map(Int.init)
        guard let last = journey.lastBackup else {
            newSinceBackup = nil
            return
        }
        let created = library.identifiers(createdAfter: last)
        let count = library.state.cells.reduce(0) { $0 + ($1.canCompact && created.contains($1.id) ? 1 : 0) }
        newSinceBackup = (count, Calendar.current.dateComponents([.day], from: last, to: .now).day ?? 0)
    }

    /// The items not backed up that were created since the last backup.
    var newItems: [String] {
        guard let last = journey.lastBackup else { return [] }
        let created = library.identifiers(createdAfter: last)
        return library.state.cells.filter { $0.canCompact && created.contains($0.id) }.map(\.id)
    }

    func refreshReady() async {
        guard let remover = settings.remover(ledger: job.ledger) else {
            ready = Ready()
            return
        }
        let candidates = await remover.candidates()
        readySizes = Dictionary(candidates.map { ($0.original, $0.entry.originalBytes) }, uniquingKeysWith: { a, _ in a })
        ready = Ready(originals: candidates.map(\.original), bytes: candidates.reduce(0) { $0 + $1.entry.originalBytes })
        if let finished {
            let still = finished.originals.filter { readySizes[$0] != nil }
            self.finished = still.isEmpty ? nil : Ready(originals: still, bytes: still.reduce(0) { $0 + (readySizes[$1] ?? 0) })
        }
    }

    // MARK: Backing up

    /// Starts backing up these items (oldest first). Each original goes home, then its compact
    /// copy comes back to Photos.
    func backUp(_ identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        finished = nil
        if case .done = removal { removal = .idle }
        batch.formUnion(identifiers)
        journey.backupStarted(manual: true)
        job.enqueue(identifiers)
        LongRun.shared.begin(items: identifiers.count, server: serverName)
        Announce.say("Backing up \(identifiers.count) \(identifiers.count == 1 ? "item" : "items").")
    }

    /// The job changed: badges follow, and when it ends, what it backed up is offered for freeing.
    func jobChanged() async {
        await refreshGrid()
    }

    func jobFinished() async {
        journey.backupFinished()
        await refreshReady()
        await refreshGrid()
        let backedUp = batch
        batch = []
        guard !backedUp.isEmpty, settings.isPaired else { return }
        let originals = ready.originals.filter { backedUp.contains($0) }
        guard !originals.isEmpty else { return }
        let bytes = originals.reduce(0) { $0 + (readySizes[$1] ?? 0) }
        finished = Ready(originals: originals, bytes: bytes)
        Announce.say("\(originals.count) backed up. \(Self.bytes(bytes)) can be freed.")
    }

    func dismissFinished() { finished = nil }

    /// Automatic mode catches up whenever the app opens (unless something is already running).
    func runAutomatic() async {
        guard automatic.enabled, premium.isUnlocked, !job.isRunning, !isRemoving, settings.onboardingComplete else { return }
        await automatic.run(settings: settings, job: job, premium: premium, notify: false)
        await refreshReady()
        await refreshGrid()
    }

    // MARK: Freeing up space

    /// Checks each original with the server again, then iOS asks; `only` limits it to these.
    func freeUp(only scope: Set<String>? = nil) async {
        guard !isRemoving, let remover = settings.remover(ledger: job.ledger) else { return }
        journey.used(.freeUp)
        removal = .checking("Checking with \(serverName)")
        Announce.say("Checking with \(serverName).")
        let report: OriginalRemover.Report
        do {
            report = try await remover.removeEligible(limit: settings.trialConfirmed ? nil : AppSettings.trialLimit,
                                                      only: scope) { message in
                Task { @MainActor [weak self] in
                    if case .checking = self?.removal { self?.removal = .checking(message) }
                }
            }
        } catch {
            report = OriginalRemover.Report(blocked: [error.localizedDescription])
        }
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

    func dismissRemoval() {
        if !isRemoving { removal = .idle }
    }

    static func bytes(_ count: Int) -> String { count.formatted(.byteCount(style: .file)) }
}
