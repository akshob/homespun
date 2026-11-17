// SPDX-License-Identifier: Apache-2.0
import BackgroundTasks
import Foundation

/// Owns the app's long-lived objects, so the background task and the screen share them.
@MainActor
final class AppModel {
    static let shared = AppModel()
    let settings: AppSettings
    let job: CompactJob
    let premium = Premium()
    let automatic = AutomaticMode()
    let copyFinder = CopyFinder()
    /// Activity › History: backup runs (manual, automatic, the first task) and freed space.
    let history = RunHistory(load: false)
    let library: LibraryController
    /// Widget links waiting for the main screen.
    let router = AppRouter()
    /// Keeps the widgets and the Apple Watch current (started by the main screen).
    let status: StatusPublisher

    private init() {
        settings = AppSettings()
        job = CompactJob(settings: settings)
        job.history = history
        library = LibraryController(settings: settings, job: job, premium: premium, automatic: automatic,
                                    copyFinder: copyFinder)
        status = StatusPublisher(settings: settings, library: library, history: history, automatic: automatic,
                                 premium: premium)
        let history = history
        Task { await history.load() }
    }

    /// Registers the background run; must happen before the app finishes launching.
    nonisolated static func registerBackgroundRun() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: AutomaticMode.taskID, using: nil) { task in
            let box = TaskBox(task: task)
            let work = Task { @MainActor in
                let model = AppModel.shared
                await model.premium.refresh()
                let summary = await model.automatic.run(settings: model.settings, job: model.job, premium: model.premium,
                                                        notify: true)
                // The widgets and the watch show what the run did (the screen isn't there to start them).
                if summary.skipped == nil, model.settings.isPaired, !Task.isCancelled { await model.library.refreshReady() }
                await model.status.publishNow()
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
