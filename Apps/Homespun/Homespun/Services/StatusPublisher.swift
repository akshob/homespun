// SPDX-License-Identifier: Apache-2.0
import Foundation
import Observation
import UIKit
import WatchConnectivity
import WidgetKit

/// Keeps the widgets and the Apple Watch current. When what they show changes (a backup, freeing up
/// space, the server, Automatic Mode, Premium), it writes a `StatusSnapshot` into the App Group,
/// reloads the widgets if their facts changed, and sends it to the watch. Debounced and written off
/// the main thread; it starts once the main screen has loaded, so launch never waits for it.
@MainActor
final class StatusPublisher {
    private let settings: AppSettings
    private let library: LibraryController
    private let history: RunHistory
    private let automatic: AutomaticMode
    private let premium: Premium
    private let watch = WatchLink()
    private var started = false
    private var pending: Task<Void, Never>?
    /// What was last written, and what the widgets were last asked to draw (and when).
    private var written: StatusSnapshot?
    private var drawn: StatusSnapshot?
    private var reloadedAt: Date?
    private var trailingReload: Task<Void, Never>?
    /// What the watch last got, and when.
    private var sent: (snapshot: StatusSnapshot, at: Date)?

    static let debounce: Duration = .seconds(2)
    /// Widgets reload at most this often (WidgetKit gives each widget a daily budget).
    static let reloadInterval: TimeInterval = 30
    /// The watch gets unchanged facts again after this long, so it can say they're recent.
    static let resendInterval: TimeInterval = 15 * 60

    init(settings: AppSettings, library: LibraryController, history: RunHistory, automatic: AutomaticMode, premium: Premium) {
        self.settings = settings
        self.library = library
        self.history = history
        self.automatic = automatic
        self.premium = premium
    }

    /// From here on, every change is published (the first one shortly after).
    func start() {
        guard !started else { return }
        started = true
        #if DEBUG
        if let demo = Self.demo(UserDefaults.standard.string(forKey: "widgetDemo"), now: Date()) {
            StatusStore.write(demo)
            WidgetCenter.shared.reloadTimelines(ofKind: StatusStore.widgetKind)
            return
        }
        #endif
        observe()
        schedule()
    }

    #if DEBUG
    /// Screenshots and reviews: `-widgetDemo ready|away|nothing|locked|unpaired` shows made-up facts in the
    /// widgets instead of this iPhone's own.
    nonisolated static func demo(_ name: String?, now: Date) -> StatusSnapshot? {
        var snapshot = StatusSnapshot.sample(now: now)
        // This morning at 9:12 (yesterday's, before then).
        let calendar = Calendar.current
        var backup = calendar.date(bySettingHour: 9, minute: 12, second: 0, of: now) ?? now
        if backup > now { backup = calendar.date(byAdding: .day, value: -1, to: backup) ?? backup }
        snapshot.lastBackup?.date = backup
        switch name {
        case "ready": break
        case "away": snapshot.server?.reachable = false
        case "nothing":
            snapshot.ready = .init(bytes: 0, count: 0)
            snapshot.automatic.enabled = false
        case "locked": snapshot.unlocked = false
        case "unpaired": snapshot.server = nil
        default: return nil
        }
        return snapshot
    }
    #endif

    /// Publishes right away (the end of a background run, which may be suspended any moment).
    func publishNow() async {
        pending?.cancel()
        pending = nil
        await history.load()
        await publish()
        reloadPostponed()
    }

    /// Going to the background: a change still waiting for its turn is published now, and widgets
    /// redraw now rather than when the reload interval ends (the app is suspended before then).
    func publishInBackground() {
        let waiting = pending.map { !$0.isCancelled } ?? false
        pending?.cancel()
        pending = nil
        guard waiting else {
            reloadPostponed()
            return
        }
        let task = UIApplication.shared.beginBackgroundTask(withName: "Widgets")
        Task {
            await publish()
            reloadPostponed()
            UIApplication.shared.endBackgroundTask(task)
        }
    }

    // MARK: Watching for changes

    private func observe() {
        withObservationTracking {
            _ = inputs()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observe()
                self?.schedule()
            }
        }
    }

    /// Everything the snapshot is made of (reading it is what's observed).
    private func inputs() -> Inputs {
        let run = history.lastBackUp
        let ready = library.readyChecked ? (library.ready.bytes, library.ready.count) : nil
        return Inputs(unlocked: premium.isUnlocked, ready: ready,
                      lastBackup: run.map { ($0.end, Self.backedUp(in: $0)) }, historyLoaded: history.loaded,
                      serverName: settings.serverURL == nil ? nil : settings.server?.name, status: settings.serverStatus,
                      checkedAt: settings.serverCheckedAt, automatic: automatic.enabled, lastRun: automatic.state.lastRun)
    }

    struct Inputs: Sendable {
        var unlocked: Bool
        /// Nil until worked out in this process (the last snapshot's stays).
        var ready: (bytes: Int, count: Int)?
        var lastBackup: (date: Date, count: Int)?
        var historyLoaded: Bool
        var serverName: String?
        var status: AppSettings.ServerStatus
        var checkedAt: Date?
        var automatic: Bool
        var lastRun: Date?
    }

    private func schedule() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            self?.pending = nil
            await self?.publish()
        }
    }

    // MARK: Publishing

    /// Items that went home in a backup run (compacted, kept as they were, or compacted later).
    nonisolated static func backedUp(in run: RunHistory.Run) -> Int {
        run.count(.saved) + run.count(.kept) + run.count(.backedUp)
    }

    /// The snapshot for these inputs. While the server is being checked (or not yet), it keeps the
    /// last answer; so does what's ready to free up, until it's been worked out.
    nonisolated static func snapshot(_ inputs: Inputs, previous: StatusSnapshot?, now: Date) -> StatusSnapshot {
        var server: StatusSnapshot.Server?
        if let name = inputs.serverName {
            let reachable: Bool = switch inputs.status {
            case .reachable: true
            case .unreachable: false
            case .checking, .unknown: previous?.server?.reachable ?? true
            }
            server = StatusSnapshot.Server(name: name, reachable: reachable, checkedAt: inputs.checkedAt ?? previous?.server?.checkedAt)
        }
        let ready = inputs.ready.map { StatusSnapshot.Ready(bytes: $0.bytes, count: $0.count) } ?? previous?.ready
            ?? StatusSnapshot.Ready(bytes: 0, count: 0)
        return StatusSnapshot(unlocked: inputs.unlocked, ready: ready,
                              lastBackup: inputs.lastBackup.map { .init(date: $0.date, count: $0.count) }, server: server,
                              automatic: .init(enabled: inputs.automatic, lastRun: inputs.lastRun), updatedAt: now)
    }

    private func publish() async {
        let inputs = inputs()
        // Before the history is read, "no backups yet" would be wrong.
        guard inputs.historyLoaded else { return }
        let now = Date(), previous = written
        // Off the main thread: finding the App Group's folder, reading and writing are file system work.
        let (published, stored) = await Task.detached(priority: .utility) { () -> (StatusSnapshot?, StatusSnapshot?) in
            let stored = previous == nil ? StatusStore.read() : nil
            let snapshot = Self.snapshot(inputs, previous: previous ?? stored, now: now)
            return (StatusStore.write(snapshot) ? snapshot : nil, stored)
        }.value
        // No App Group (a build without its entitlement): nothing can show it.
        guard let snapshot = published else { return }
        written = snapshot
        // At launch: the widgets and the watch already have what an earlier session wrote.
        if drawn == nil { drawn = stored }
        if !snapshot.sameFacts(as: drawn) { reloadWidgets(snapshot) }
        let changed = !snapshot.sameFacts(as: sent?.snapshot ?? stored)
        if changed || now.timeIntervalSince(sent?.at ?? .distantPast) > Self.resendInterval,
           let data = StatusStore.encode(snapshot) {
            sent = (snapshot, now)
            await watch.send(data, complication: changed)
        }
    }

    /// At most one reload per interval; a change within it reloads when the interval ends.
    private func reloadWidgets(_ snapshot: StatusSnapshot) {
        let wait = (reloadedAt?.addingTimeInterval(Self.reloadInterval).timeIntervalSinceNow ?? 0)
        guard wait <= 0 else {
            guard trailingReload == nil else { return }
            trailingReload = Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard let self, !Task.isCancelled else { return }
                trailingReload = nil
                if let written, !written.sameFacts(as: drawn) { reloadWidgets(written) }
            }
            return
        }
        drawn = snapshot
        reloadedAt = Date()
        WidgetCenter.shared.reloadTimelines(ofKind: StatusStore.widgetKind)
    }

    /// A reload waiting for the interval to end happens now.
    private func reloadPostponed() {
        trailingReload?.cancel()
        trailingReload = nil
        guard let written, !written.sameFacts(as: drawn) else { return }
        drawn = written
        reloadedAt = Date()
        WidgetCenter.shared.reloadTimelines(ofKind: StatusStore.widgetKind)
    }
}

/// Sends the snapshot to Homespun on Apple Watch: as the application context (the latest wins), and
/// as complication data when the facts changed and the watch face shows Homespun (a few a day).
final class WatchLink: NSObject, WCSessionDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var activating = false
    private var waiting: [UUID: CheckedContinuation<Void, Never>] = [:]

    func send(_ data: Data, complication: Bool) async {
        guard WCSession.isSupported() else { return }
        await activate()
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        try? session.updateApplicationContext(["status": data])
        if complication, session.isComplicationEnabled, session.remainingComplicationUserInfoTransfers > 0 {
            session.transferCurrentComplicationUserInfo(["status": data])
        }
    }

    /// Returns once the session is active, couldn't be activated, or 10 s have passed. Asked for only
    /// when there's something to send, never at launch.
    private func activate() async {
        guard WCSession.default.activationState != .activated else { return }
        let id = UUID()
        await withCheckedContinuation { continuation in
            let start = lock.withLock {
                waiting[id] = continuation
                defer { activating = true }
                return !activating
            }
            // Whichever comes first resumes it, once: the session's answer or the time limit.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10) { [weak self] in
                self?.lock.withLock { self?.waiting.removeValue(forKey: id) }?.resume()
            }
            guard start else { return }
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: (any Error)?) {
        let resumed = lock.withLock {
            defer { waiting = [:]; activating = false }
            return Array(waiting.values)
        }
        for continuation in resumed { continuation.resume() }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    /// Another watch became the active one: start again with it.
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }
}
