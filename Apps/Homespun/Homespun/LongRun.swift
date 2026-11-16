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

    /// Asks iOS to keep this run going in the background, if it's long enough to need it. Never
    /// stops the run: if iOS says no (or raises), the run simply carries on while Homespun is open.
    /// Each run registers its own identifier just before it's submitted (continued processing tasks
    /// are registered when needed; a handler for the wildcard alone, registered at launch, made iOS
    /// raise "no launch handler" at submit on a device and end the app).
    enum Outcome: Equatable { case notNeeded, started, unavailable(String) }

    @discardableResult
    func begin(items: Int, server: String) -> Outcome {
        guard items >= Self.minimumItems, !running else { return .notNeeded }
        let identifier = Self.prefix + "." + UUID().uuidString.prefix(8).lowercased()
        var registered = false
        var failure: NSError?
        do {
            try HSObjC.catching {
                registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil,
                                                             launchHandler: Self.launchHandler())
            }
        } catch {
            failure = error as NSError
        }
        guard registered else {
            Self.unavailable("register", failure)
            return .unavailable("register: " + (failure?.localizedDescription ?? "refused"))
        }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: "Backing up to \(server)",
                                                       subtitle: "\(items) items")
        request.strategy = .fail
        do {
            try HSObjC.catching {
                do {
                    try BGTaskScheduler.shared.submit(request)
                } catch {
                    failure = error as NSError
                }
            }
        } catch {
            failure = error as NSError
        }
        if let failure {
            Self.unavailable("submit", failure)
            return .unavailable("submit: " + failure.localizedDescription)
        }
        running = true
        return .started
    }

    /// iOS calls the launch and expiration handlers on its own queue. A closure written in this
    /// main-actor class would be main-actor code, and Swift stops the app when it runs elsewhere
    /// (0.1.0 (202611151655) ended this way on a phone, as the system started the task). Made here,
    /// outside the main actor, they hop to it themselves.
    nonisolated private static func launchHandler() -> @Sendable (BGTask) -> Void {
        { task in
            guard let task = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            let box = TaskBox(task: task)
            Task { @MainActor in await LongRun.shared.follow(box, job: AppModel.shared.job) }
        }
    }

    nonisolated private static func expirationHandler(_ box: TaskBox, expiry: ExpiryBox, job: CompactJob)
        -> @Sendable () -> Void {
        {
            expiry.expired = true
            Task { @MainActor in
                job.stopWaiting(Set(job.items.filter { $0.state == .waiting }.map(\.assetIdentifier)))
            }
            box.task.setTaskCompleted(success: false)
        }
    }

    /// Not available here (a simulator, or the system said no): the run carries on while open.
    private static func unavailable(_ step: String, _ error: NSError?) {
        let reason = error?.localizedDescription ?? "the system said no"
        log.notice("continued processing \(step, privacy: .public) failed: \(reason, privacy: .public)")
        AppLog.job.notice("background continuation unavailable (\(step, privacy: .public)): \(reason, privacy: .public)")
        if let error { Telemetry.shared.record(error: error, where: "longrun.\(step)") }
    }

    /// Reports the job's progress to the system until it ends; Stop from the system drops what
    /// hasn't started (items already backed up stay backed up).
    private func follow(_ box: TaskBox, job: CompactJob) async {
        let task = box.task
        let expiry = ExpiryBox()
        // iOS ended it (Stop on the Lock Screen, or out of time): drop what hasn't started and say
        // so at once, or iOS ends the app. The item in progress finishes when the app runs again.
        task.expirationHandler = Self.expirationHandler(box, expiry: expiry, job: job)
        defer { running = false }
        while !expiry.expired, job.isRunning || job.hasWaiting {
            let total = job.runProgress.total
            let done = job.runProgress.done
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
