// SPDX-License-Identifier: Apache-2.0
import BackgroundTasks
import Foundation
import os

/// A backup the person started keeps going when they leave Homespun, with the system's progress
/// (and Stop) on the Lock Screen and in the Dynamic Island (DESIGN T18, iOS 26's continued
/// processing). Without it, iOS suspends the app and the run waits until it's opened again.
@MainActor
final class LongRun {
    static let shared = LongRun()
    private static let log = Logger(subsystem: "photos.homespun.app", category: "long-run")

    /// `<bundle id>.backup.*` in Info.plist; each run gets its own suffix.
    nonisolated static var prefix: String { (Bundle.main.bundleIdentifier ?? "photos.homespun.app") + ".backup" }
    /// Shorter runs finish while the person watches; they don't need the system's progress.
    static let minimumItems = 10

    private var running = false

    /// Registers the handler; must happen before the app finishes launching.
    nonisolated static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: prefix + ".*", using: nil) { task in
            guard let task = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            let box = TaskBox(task: task)
            Task { @MainActor in await LongRun.shared.follow(box, job: AppModel.shared.job) }
        }
    }

    /// Asks iOS to keep this run going in the background, if it's long enough to need it.
    func begin(items: Int, server: String) {
        guard items >= Self.minimumItems, !running else { return }
        let request = BGContinuedProcessingTaskRequest(identifier: Self.prefix + "." + UUID().uuidString.prefix(8),
                                                       title: "Backing up to \(server)",
                                                       subtitle: "\(items) items")
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
            running = true
        } catch {
            // Not available here (a simulator, or the system said no): the run carries on while open.
            Self.log.info("continued processing not available: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Reports the job's progress to the system until it ends; Stop from the system drops what
    /// hasn't started (items already backed up stay backed up).
    private func follow(_ box: TaskBox, job: CompactJob) async {
        let task = box.task
        let expiry = ExpiryBox()
        // iOS ended it (Stop on the Lock Screen, or out of time): drop what hasn't started and say
        // so at once, or iOS ends the app. The item in progress finishes when the app runs again.
        task.expirationHandler = {
            expiry.expired = true
            Task { @MainActor in
                job.stopWaiting(Set(job.items.filter { $0.state == .waiting }.map(\.assetIdentifier)))
            }
            task.setTaskCompleted(success: false)
        }
        defer { running = false }
        while !expiry.expired, job.isRunning || job.items.contains(where: { $0.state == .waiting }) {
            let items = job.runItems
            let total = items.count
            let done = items.filter { $0.state != .waiting && !$0.isWorking }.count
            task.progress.totalUnitCount = Int64(max(total, 1))
            task.progress.completedUnitCount = Int64(done)
            task.updateTitle(task.title, subtitle: "\(done) of \(total)")
            try? await Task.sleep(for: .seconds(1))
        }
        guard !expiry.expired else { return }
        task.progress.completedUnitCount = task.progress.totalUnitCount
        task.setTaskCompleted(success: true)
    }

    private final class ExpiryBox: @unchecked Sendable {
        var expired = false
    }

    private final class TaskBox: @unchecked Sendable {
        let task: BGContinuedProcessingTask
        init(task: BGContinuedProcessingTask) { self.task = task }
    }
}
