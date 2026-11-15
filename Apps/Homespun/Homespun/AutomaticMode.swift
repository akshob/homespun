// SPDX-License-Identifier: Apache-2.0
import BackgroundTasks
import Foundation
import Observation
import Photos
import UserNotifications

/// Automatic mode (Premium): new photos and videos are backed up and compacted without being
/// selected, in the background when iOS allows (usually overnight while charging) and when
/// the app opens. Removing originals still waits for the user, who gets a notification when
/// there is space to free up.
@MainActor @Observable
final class AutomaticMode {
    nonisolated static let taskID = "photos.homespun.app.automatic"
    /// At most this many items per run, so a run fits in the time iOS gives.
    nonisolated static let batch = 200
    /// A failing item is tried this many times, then left for the user to pick.
    nonisolated static let maximumAttempts = 3

    struct State: Codable, Equatable {
        var enabled = false
        /// Items created from here on are picked up (distant past: everything).
        var since = Date.distantPast
        /// Photos' change token, for items added later with older dates (synced, saved, AirDropped).
        var token: Data?
        var attempts: [String: Int] = [:]
        /// Kept as is (for example, already compact); not tried again.
        var settled: Set<String> = []
        var lastRun: Date?
        var lastSummary: String?
        /// Items Photos reported as added (possibly with older dates) and not handled yet, so
        /// moving the change token on never loses them.
        var pending: Set<String> = []
        /// Tell the user when an overnight run made space ready to free up.
        var notifies = true

        init() {}

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
            since = try values.decodeIfPresent(Date.self, forKey: .since) ?? .distantPast
            token = try values.decodeIfPresent(Data.self, forKey: .token)
            attempts = try values.decodeIfPresent([String: Int].self, forKey: .attempts) ?? [:]
            settled = try values.decodeIfPresent(Set<String>.self, forKey: .settled) ?? []
            lastRun = try values.decodeIfPresent(Date.self, forKey: .lastRun)
            lastSummary = try values.decodeIfPresent(String.self, forKey: .lastSummary)
            pending = try values.decodeIfPresent(Set<String>.self, forKey: .pending) ?? []
            notifies = try values.decodeIfPresent(Bool.self, forKey: .notifies) ?? true
        }
    }

    private(set) var state: State
    private(set) var running = false
    private let url: URL

    var enabled: Bool { state.enabled }
    /// Backs up everything not backed up yet, not only items added since it was turned on.
    var backsUpEverything: Bool { state.since == .distantPast }

    init(url: URL = URL.applicationSupportDirectory.appendingPathComponent("Homespun/automatic.json")) {
        self.url = url
        state = (try? JSONDecoder().decode(State.self, from: Data(contentsOf: url))) ?? State()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(state).write(to: url, options: .atomic)
    }

    // MARK: Turning it on and off

    /// `existing`: also back up what's already on the iPhone, not only new items.
    func enable(existing: Bool) async {
        state.enabled = true
        state.since = existing ? .distantPast : Date()
        state.token = Self.archive(PHPhotoLibrary.shared().currentChangeToken)
        state.attempts = [:]
        state.settled = []
        state.pending = []
        save()
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        schedule()
    }

    /// Changes what it backs up without starting over.
    func setScope(everything: Bool) {
        guard everything != backsUpEverything else { return }
        state.since = everything ? .distantPast : Date()
        save()
    }

    func setNotifies(_ on: Bool) {
        state.notifies = on
        save()
        if on { Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge]) } }
    }

    func disable() {
        state.enabled = false
        save()
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskID)
    }

    /// Asks iOS for a background run: on power and network, an hour or more from now.
    func schedule() {
        guard state.enabled else { return }
        let request = BGProcessingTaskRequest(identifier: Self.taskID)
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = true
        request.earliestBeginDate = Date().addingTimeInterval(3600)
        try? BGTaskScheduler.shared.submit(request)
    }

    // MARK: Choosing items

    /// Items not yet backed up, oldest first: created since `since` or added to the library
    /// later (`added`). Compact copies, items already backed up, items kept as is, and items
    /// that keep failing are skipped. (An old on-phone copy doesn't count as backed up.)
    nonisolated static func pick(_ assets: [(id: String, created: Date?)], since: Date, added: Set<String>,
                     ledger: [String: CompactLedger.Entry], album: Set<String>, attempts: [String: Int],
                     settled: Set<String>, limit: Int = batch) -> [String] {
        let copies = Set(ledger.values.map(\.compactIdentifier))
        let eligible = assets.filter { asset in
            guard (asset.created.map { $0 >= since } ?? false) || added.contains(asset.id) else { return false }
            return ledger[asset.id]?.serverAssetID == nil && !copies.contains(asset.id) && !album.contains(asset.id)
                && !settled.contains(asset.id) && (attempts[asset.id] ?? 0) < maximumAttempts
        }
        return Array(eligible.sorted { ($0.created ?? .distantFuture) < ($1.created ?? .distantFuture) }.prefix(limit).map(\.id))
    }

    /// Items Photos added since `token`. `read` is false if the changes couldn't be read, so
    /// the token must not move on. An expired token can't be read again either way.
    private static func inserted(since token: Data?) -> (ids: Set<String>, read: Bool) {
        guard let token = token.flatMap(unarchive) else { return ([], true) }
        var ids = Set<String>()
        do {
            for change in try PHPhotoLibrary.shared().fetchPersistentChanges(since: token) {
                ids.formUnion(try change.changeDetails(for: .asset).insertedLocalIdentifiers)
            }
            return (ids, true)
        } catch let error as PHPhotosError where error.code == .persistentChangeTokenExpired {
            return ([], true)
        } catch {
            return ([], false)
        }
    }

    private func candidates(ledger: [String: CompactLedger.Entry], added: Set<String>) -> [String] {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "(mediaType == %d OR mediaType == %d) AND creationDate >= %@",
                                        PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue, state.since as NSDate)
        var assets: [(id: String, created: Date?)] = []
        var seen = Set<String>()
        PHAsset.fetchAssets(with: options).enumerateObjects { asset, _, _ in
            assets.append((asset.localIdentifier, asset.creationDate))
            seen.insert(asset.localIdentifier)
        }
        let late = Array(added.subtracting(seen))
        if !late.isEmpty {
            PHAsset.fetchAssets(withLocalIdentifiers: late, options: nil).enumerateObjects { asset, _, _ in
                if [.image, .video].contains(asset.mediaType) { assets.append((asset.localIdentifier, asset.creationDate)) }
            }
        }
        return Self.pick(assets, since: state.since, added: added, ledger: ledger, album: PhotoLibrary.albumMembers(),
                         attempts: state.attempts, settled: state.settled)
    }

    // MARK: Running

    struct Summary: Equatable {
        var compacted = 0
        var kept = 0
        var failed = 0
        /// Originals ready to remove after this run.
        var removable = 0
        var newlyRemovable = 0
        /// Not done yet for a reason that may pass (for example, not in Immich yet).
        var notYet = 0
        var skipped: String?
    }

    /// One run: picks items, backs them up and compacts them through `job`, then tells the user
    /// if there's space to free up. Stops early (leaving the rest for next time) when cancelled.
    @discardableResult
    func run(settings: AppSettings, job: CompactJob, premium: Premium, notify: Bool) async -> Summary {
        var summary = Summary()
        guard state.enabled, premium.isUnlocked, !running else { return summary }
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            summary.skipped = "Homespun needs Full Access to Photos."
            return finish(summary)
        }
        guard settings.usesServer else {
            summary.skipped = "Connect a server first."
            return finish(summary)
        }
        await settings.refreshServerInfo()
        guard settings.serverStatus == .reachable else {
            summary.skipped = "The server wasn't reachable."
            return finish(summary)
        }
        running = true
        defer { running = false }
        let remover = settings.remover(ledger: job.ledger)
        let before = Set(await remover?.candidates().map(\.original) ?? [])

        // The token as of now: items added while this run works are found next time.
        let token = PHPhotoLibrary.shared().currentChangeToken
        let inserted = Self.inserted(since: state.token)
        state.pending.formUnion(inserted.ids)
        let picked = candidates(ledger: await job.ledger.snapshot(), added: state.pending)
        if !picked.isEmpty {
            job.enqueue(picked, trigger: .automatic)
            // Wait for these items (the job may also hold items the user picked).
            func busy() -> Bool {
                let states = job.states
                return picked.contains { [.waiting, .working].contains(states[$0]?.phase) }
            }
            while busy(), !Task.isCancelled { try? await Task.sleep(for: .milliseconds(500)) }
            if Task.isCancelled { job.stopWaiting(Set(picked)) }
            let states = job.states
            var failed: [String] = []
            for id in picked {
                switch states[id] {
                case .saved?: summary.compacted += 1
                case .unchanged?:
                    summary.kept += 1
                    state.settled.insert(id)
                case .notYet?: summary.notYet += 1
                case .failed?: failed.append(id)
                default: break
                }
            }
            // Failures count against an item only while the server was there; a server that
            // went to sleep isn't the item's fault.
            if !failed.isEmpty {
                summary.failed = failed.count
                await settings.refreshServerInfo()
                if settings.serverStatus == .reachable {
                    for id in failed { state.attempts[id, default: 0] += 1 }
                }
            }
        }
        // Forget added items that are done, gone, or given up on.
        let ledger = await job.ledger.snapshot()
        let copies = Set(ledger.values.map(\.compactIdentifier)), album = PhotoLibrary.albumMembers()
        let existing = PhotoLibrary.existing(Array(state.pending))
        state.pending = state.pending.filter { id in
            existing.contains(id) && ledger[id]?.serverAssetID == nil && !copies.contains(id) && !album.contains(id)
                && !state.settled.contains(id) && (state.attempts[id] ?? 0) < Self.maximumAttempts
        }
        if inserted.read { state.token = Self.archive(token) }
        let after = Set(await remover?.candidates().map(\.original) ?? [])
        summary.removable = after.count
        summary.newlyRemovable = after.subtracting(before).count
        if notify, state.notifies, summary.newlyRemovable > 0 { await Self.notify(summary) }
        return finish(summary)
    }

    private func finish(_ summary: Summary) -> Summary {
        state.lastRun = Date()
        state.lastSummary = Self.describe(summary)
        save()
        schedule()
        return summary
    }

    nonisolated static func describe(_ summary: Summary) -> String {
        if let skipped = summary.skipped { return "Skipped: \(skipped)" }
        var parts: [String] = []
        if summary.compacted > 0 { parts.append("\(summary.compacted) backed up and compacted") }
        if summary.kept > 0 { parts.append("\(summary.kept) kept as is") }
        if summary.notYet > 0 { parts.append("\(summary.notYet) to try again later") }
        if summary.failed > 0 { parts.append("\(summary.failed) didn't work") }
        return parts.isEmpty ? "Nothing new." : parts.joined(separator: ", ") + "."
    }

    static func notify(_ summary: Summary) async {
        let content = UNMutableNotificationContent()
        content.title = "Ready to free up space"
        let count = summary.removable
        content.body = "\(count) original\(count == 1 ? " is" : "s are") backed up on your server. "
            + "Open Homespun to remove \(count == 1 ? "it" : "them") from this iPhone."
        content.sound = .default
        let request = UNNotificationRequest(identifier: "homespun.removable", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    private static func archive(_ token: PHPersistentChangeToken) -> Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
    }

    private static func unarchive(_ data: Data) -> PHPersistentChangeToken? {
        try? NSKeyedUnarchiver.unarchivedObject(ofClass: PHPersistentChangeToken.self, from: data)
    }
}

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
    let history = RunHistory()
    let library: LibraryController

    private init() {
        settings = AppSettings()
        job = CompactJob(settings: settings)
        job.history = history
        library = LibraryController(settings: settings, job: job, premium: premium, automatic: automatic,
                                    copyFinder: copyFinder)
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
