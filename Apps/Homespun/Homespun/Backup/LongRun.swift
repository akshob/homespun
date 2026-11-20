// SPDX-License-Identifier: Apache-2.0
import BackgroundTasks
import Foundation
import os
import UIKit

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
                // Open on screen, the run simply carries on (it doesn't need the system's time). In
                // the background, what hasn't started is dropped, or iOS ends the app.
                guard UIApplication.shared.applicationState != .active else {
                    LongRun.log.notice("continued processing expired while open; the run carries on")
                    return
                }
                job.stopWaiting(Set(job.items.filter { $0.state == .waiting }.map(\.assetIdentifier)))
            }
            box.task.setTaskCompleted(success: false)
        }
    }

    /// How far along the item being worked on is (0–1), from its step: iOS ends a continued task
    /// whose progress stops moving, and a video can take minutes on the server, so that step creeps
    /// forward with time.
    nonisolated static func fraction(step: String, seconds: Double) -> Double {
        switch step {
        case let step where step.hasPrefix("Uploading"):
            let percent = step.split(separator: " ").last.flatMap { Double($0.dropLast()) } ?? 0
            return 0.1 + 0.5 * min(max(percent, 0), 100) / 100
        case "Reading": return 0.02
        case "Contacting server": return 0.08
        case "Queued on server", "Compressing on server": return min(0.6 + seconds / 400, 0.85)
        case "Downloading compact copy": return 0.88
        case "Compressing motion": return 0.9
        case "Checking Live Photo": return 0.93
        case "Saving": return 0.96
        default: return 0
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
        // Hundredths of an item, never going backwards.
        var reported: Int64 = 0, step = "", stepStarted = Date()
        while !expiry.expired, job.isRunning || job.hasWaiting {
            let progress = job.runProgress
            let current = progress.current.map { "\($0.asset) \(job.currentMessage)" } ?? ""
            if current != step {
                step = current
                stepStarted = Date()
            }
            let fraction = progress.current == nil ? 0
                : Self.fraction(step: job.currentMessage, seconds: Date().timeIntervalSince(stepStarted))
            reported = max(reported, Int64(progress.done) * 100 + Int64(fraction * 100))
            task.progress.totalUnitCount = Int64(max(progress.total, 1)) * 100
            task.progress.completedUnitCount = min(reported, task.progress.totalUnitCount)
            task.updateTitle(task.title, subtitle: "\(progress.done) of \(progress.total)")
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
