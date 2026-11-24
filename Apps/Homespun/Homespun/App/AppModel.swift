// SPDX-License-Identifier: Apache-2.0
import BackgroundTasks
import Foundation

/// Owns the app's long-lived objects, so the background task and the screen share them. The person's
/// own is `shared`; Try the Demo makes another (`DemoMode`), on the demo's sample photos and pretend
/// server, with its own settings and records, so nothing of the person's is touched.
@MainActor
final class AppModel {
    static let shared = AppModel()
    /// The model on screen: the demo's while it's on, else the person's own.
    static var current: AppModel { DemoMode.shared.model ?? shared }

    let settings: AppSettings
    let job: CompactJob
    /// The App Store purchase is the person's own, in the demo too.
    let premium: Premium
    let automatic: AutomaticMode
    let copyFinder: CopyFinder
    /// Activity › History: backup runs (manual, automatic, the first task) and freed space.
    let history: RunHistory
    let library: LibraryController
    /// Widget links waiting for the main screen.
    let router = AppRouter()
    /// Keeps the widgets and the Apple Watch current. The demo shares the publisher, which shows
    /// demo facts only when the person's own Homespun has no paired server.
    let status: StatusPublisher?

    private init() {
        premium = Premium()
        automatic = AutomaticMode()
        copyFinder = CopyFinder()
        history = RunHistory(load: false)
        settings = AppSettings()
        job = CompactJob(settings: settings)
        job.history = history
        library = LibraryController(settings: settings, job: job, premium: premium, automatic: automatic,
                                    copyFinder: copyFinder)
        status = ReleaseFeatures.widgets || ReleaseFeatures.watch
            ? StatusPublisher(settings: settings, library: library, history: history, automatic: automatic,
                              premium: premium) : nil
        let history = history
        Task { await history.load() }
    }

    /// The demo's: everything kept in its folder and settings (`DemoSession`).
    init(demo: DemoSession, premium: Premium, status: StatusPublisher? = nil) {
        settings = AppSettings(defaults: demo.defaults, photos: demo.library, tokens: demo.tokens, session: demo.server.clientSession,
                               isDemo: true)
        job = CompactJob(settings: settings, ledger: CompactLedger(url: demo.folder.appendingPathComponent("ledger.json")))
        self.premium = premium
        automatic = AutomaticMode(url: demo.folder.appendingPathComponent("automatic.json"), photos: demo.library, system: false)
        copyFinder = CopyFinder(url: demo.folder.appendingPathComponent("copy-finder.json"), photos: demo.library)
        history = RunHistory(url: demo.folder.appendingPathComponent("history.json"), load: false)
        job.history = history
        library = LibraryController(settings: settings, job: job, premium: premium, automatic: automatic,
                                    copyFinder: copyFinder)
        self.status = status
        let history = history
        Task { await history.load() }
    }

    /// Registers the background run; must happen before the app finishes launching.
    nonisolated static func registerBackgroundRun() {
        guard ReleaseFeatures.automaticMode else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: AutomaticMode.taskID)
            return
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: AutomaticMode.taskID, using: nil) { task in
            let box = TaskBox(task: task)
            let work = Task { @MainActor in
                let model = AppModel.shared
                await model.premium.refresh()
                let summary = await model.automatic.run(settings: model.settings, job: model.job, premium: model.premium,
                                                        notify: true)
                // The widgets and the watch show what the run did (the screen isn't there to start them).
                if model.settings.isPaired, !Task.isCancelled { await model.library.refreshReady() }
                await model.status?.publishNow()
                box.task.setTaskCompleted(success: summary.skipped == nil)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    private final class TaskBox: @unchecked Sendable {
        let task: BGTask
        init(task: BGTask) { self.task = task }
    }
}
