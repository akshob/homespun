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

    private init() {
        settings = AppSettings()
        job = CompactJob(settings: settings)
        job.history = history
        library = LibraryController(settings: settings, job: job, premium: premium, automatic: automatic,
                                    copyFinder: copyFinder)
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
