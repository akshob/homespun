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
    private var historyLoad: Task<Void, Never>?

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
        historyLoad = Task { await history.load() }
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
        historyLoad = Task { await history.load() }
    }

    func suspendForDemo() async {
        automatic.suspendAdmissions()
        await job.suspendAndWait()
        await WakeSystem.enrollment.pauseAndWait()
        WakeSystem.updateRegistration()
    }

    func resumeAfterDemo() async {
        job.resumeExecution()
        automatic.resumeAdmissions()
        do { try await WakeSystem.resume() } catch { WakeSystem.enrollment.enrollmentFailed() }
    }

    func closeDemoStore() async throws {
        await historyLoad?.value
        try await job.ledger.store.close()
    }

    nonisolated static func schedulePendingBackup() {
        let request = BGProcessingTaskRequest(identifier: AutomaticMode.taskID)
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = true
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Registers the background run; must happen before the app finishes launching.
    nonisolated static func registerBackgroundRun() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: AutomaticMode.taskID, using: nil) { task in
            let box = TaskBox(task: task)
            let completion = LongRun.Completion { success in box.task.setTaskCompleted(success: success) }
            let work = Task { @MainActor in
                guard DemoMode.shared.model == nil, DemoMode.shared.origin == nil, !DemoMode.shared.settling else {
                    completion.finish(success: false)
                    return
                }
                let model = AppModel.shared
                do {
                    try await model.job.runOpportunity()
                    if model.automatic.enabled, !Task.isCancelled {
                        await model.premium.refresh()
                        _ = await model.automatic.run(settings: model.settings, job: model.job, premium: model.premium, notify: true)
                        try await model.job.runOpportunity()
                    }
                } catch { model.job.showQueueProblem(error) }
                // The widgets and the watch show what the run did (the screen isn't there to start them).
                if model.settings.isPaired, !Task.isCancelled { await model.library.refreshReady() }
                await model.status?.publishNow()
                if !Task.isCancelled { model.automatic.schedule() }
                completion.finish(success: !Task.isCancelled)
            }
            task.expirationHandler = { if completion.finish(success: false) { work.cancel() } }
        }
    }

    private final class TaskBox: @unchecked Sendable {
        let task: BGTask
        init(task: BGTask) { self.task = task }
    }
}
