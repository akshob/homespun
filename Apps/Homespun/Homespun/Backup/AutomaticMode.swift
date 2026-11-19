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
        /// When compact copies are made: recent items are backed up first, compacted later.
        var schedule = CompactSchedule.standard
        /// When this iPhone first had an item (Photos reported it added), so an old photo saved
        /// today counts as recent.
        var firstSeen: [String: Date] = [:]
        /// Where reading Photos' deletions continues from (separate from `token`: removals are also
        /// checked when the app comes to the foreground).
        var removalToken: Data?
        /// Items Photos reported deleted (and when), not told to the server yet. Kept a few days even
        /// if not backed up yet: an item deleted while its upload runs is reported once it's done.
        var removed: [String: Date] = [:]

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
            schedule = try values.decodeIfPresent(CompactSchedule.self, forKey: .schedule) ?? .standard
            firstSeen = try values.decodeIfPresent([String: Date].self, forKey: .firstSeen) ?? [:]
            removalToken = try values.decodeIfPresent(Data.self, forKey: .removalToken)
            removed = try values.decodeIfPresent([String: Date].self, forKey: .removed) ?? [:]
        }
    }

    private(set) var state: State
    private(set) var running = false
    private let url: URL
    private let photos: any PhotoSource
    /// Runs in the background, and notifies, through iOS (off for the demo, whose runs happen only
    /// while it's on screen).
    private let system: Bool

    var enabled: Bool { ReleaseFeatures.automaticMode && state.enabled }
    /// Backs up everything not backed up yet, not only items added since it was turned on.
    var backsUpEverything: Bool { state.since == .distantPast }

    init(url: URL = URL.applicationSupportDirectory.appendingPathComponent("Homespun/automatic.json"),
         photos: any PhotoSource = PhotoKitSource(), system: Bool = true) {
        self.url = url
        self.photos = photos
        self.system = system
        state = (try? JSONDecoder().decode(State.self, from: Data(contentsOf: url))) ?? State()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(state).write(to: url, options: .atomic)
    }

    // MARK: Turning it on and off

    /// `existing`: also back up what's already on the iPhone, not only new items.
    func enable(existing: Bool) async {
        guard ReleaseFeatures.automaticMode else { return }
        Telemetry.shared.record(.featureUsed("automatic", existing ? "on.everything" : "on.new"))
        state.enabled = true
        state.since = existing ? .distantPast : Date()
        state.token = photos.changeToken()
        if state.removalToken == nil { state.removalToken = state.token }
        state.attempts = [:]
        state.settled = []
        state.pending = []
        save()
        guard system else { return }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        schedule()
    }

    /// Changes what it backs up without starting over.
    func setScope(everything: Bool) {
        guard everything != backsUpEverything else { return }
        state.since = everything ? .distantPast : Date()
        save()
    }

    var compactSchedule: CompactSchedule { state.schedule }

    /// The slider: shorter compacts more on the next run; longer only affects items not compacted yet.
    func setCompactSchedule(_ schedule: CompactSchedule) {
        guard schedule != state.schedule else { return }
        Telemetry.shared.record(.featureUsed("cutoff", "\(schedule.days)d" + (schedule.keepFavorites ? ".favorites" : "")))
        state.schedule = schedule
        save()
    }

    /// When an item's compact copy is due under the current schedule (nil: a kept favorite).
    func due(created: Date?, id: String, favorite: Bool) -> Date? {
        state.schedule.due(created: created, firstSeen: state.firstSeen[id], favorite: favorite)
    }

    func setNotifies(_ on: Bool) {
        state.notifies = on
        save()
        if ReleaseFeatures.automaticMode, on, system {
            Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge]) }
        }
    }

    func disable() {
        Telemetry.shared.record(.featureUsed("automatic", "off"))
        state.enabled = false
        save()
        if system { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskID) }
    }

    /// The user chose Keep As Is for an item that couldn't be backed up: it isn't tried again.
    func keepAsIs(_ id: String) {
        state.settled.insert(id)
        save()
    }

    /// Asks iOS for a background run: on power and network, an hour or more from now.
    func schedule() {
        guard enabled, system else { return }
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

    /// What this run does: compact copies for items whose time came (backed up already or not),
    /// and backing up recent ones (files mode only; in Immich mode they wait). Reads the library
    /// since the cutoff, so it runs in the background (it's the whole library at first).
    private nonisolated static func plan(_ state: State, ledger: [String: CompactLedger.Entry],
                                         backedUp: [String: CompactLedger.BackedUp], added: Set<String>,
                                         backsUp: Bool, photos: any PhotoSource) -> AutomaticPlan {
        // Added later with older dates, and backed up earlier: wherever their dates fall.
        let assets = photos.candidates(since: state.since, also: Array(added.union(backedUp.keys)))
        let eligible = Set(Self.pick(assets.map { ($0.id, $0.created) }, since: state.since,
                                     added: added.union(backedUp.keys), ledger: ledger, album: photos.albumMembers(),
                                     attempts: state.attempts, settled: state.settled, limit: .max))
        // Kept full size (Keep Original): never compacted automatically.
        let kept = Set(backedUp.filter { $0.value.kept == true }.keys)
        return AutomaticPlan.make(assets.filter { eligible.contains($0.id) && !kept.contains($0.id) }, backedUp: Set(backedUp.keys),
                                  firstSeen: state.firstSeen, schedule: state.schedule, now: Date(), backsUp: backsUp,
                                  limit: Self.batch)
    }

    /// Recent items backed up without a compact copy that the person deleted on this iPhone (cleaned
    /// them up): the server moves their originals to its trash, and they're never compacted. Only
    /// what Photos reports as deleted counts, and only while it still can't be found (hidden items
    /// included): an item Homespun merely can't see (hidden, limited access, a restored backup with
    /// other identifiers) is never reported. Needs Full Access.
    func reportRemoved(settings: AppSettings, ledger: CompactLedger) async {
        guard ReleaseFeatures.automaticMode else { return }
        let photos = photos
        guard photos.authorization() == .authorized, let client = settings.client else { return }
        let backedUp = await ledger.backedUpSnapshot()
        let token = photos.changeToken()
        let since = state.removalToken
        let deleted = await Task.detached(priority: .utility) { photos.deleted(since: since) }.value
        let before = state, now = Date()
        for id in deleted.ids where state.removed[id] == nil { state.removed[id] = now }
        if deleted.read { state.removalToken = token }
        // Recovered from Recently Deleted (or never gone): nothing to tell.
        let removed = Array(state.removed.keys)
        let back = await Task.detached(priority: .utility) { photos.existing(removed, includeHidden: true) }.value
        for id in back { state.removed[id] = nil }
        state.removed = state.removed.filter { id, date in backedUp[id] != nil || now.timeIntervalSince(date) < 7 * 86_400 }
        var reported: [String] = []
        for id in state.removed.keys {
            guard let entry = backedUp[id] else { continue }
            // Not reachable now: told next time.
            guard (try? await client.removedOnDevice(entry.serverAssetID)) != nil else { continue }
            reported.append(id)
            state.firstSeen[id] = nil
        }
        for id in reported { state.removed[id] = nil }
        try? await ledger.forgetBackedUp(reported)
        if state.removed != before.removed || state.removalToken != before.removalToken || !reported.isEmpty { save() }
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
        /// Recent items backed up now, compacted later.
        var backedUp = 0
        var skipped: String?
    }

    /// One run: picks items, backs them up and compacts them through `job`, then tells the user
    /// if there's space to free up. Stops early (leaving the rest for next time) when cancelled.
    @discardableResult
    func run(settings: AppSettings, job: CompactJob, premium: Premium, notify: Bool) async -> Summary {
        var summary = Summary()
        guard enabled, premium.isUnlocked, !running else { return summary }
        let photos = photos
        guard photos.authorization() == .authorized else {
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
        let token = photos.changeToken()
        let since = state.token
        let inserted = await Task.detached(priority: .utility) { photos.inserted(since: since) }.value
        state.pending.formUnion(inserted.ids)
        let now = Date()
        for id in inserted.ids where state.firstSeen[id] == nil { state.firstSeen[id] = now }
        await reportRemoved(settings: settings, ledger: job.ledger)
        let planLedger = await job.ledger.snapshot(), planBackedUp = await job.ledger.backedUpSnapshot()
        let snapshot = state, backsUp = settings.server?.mode != .immich
        let plan = await Task.detached(priority: .utility) {
            Self.plan(snapshot, ledger: planLedger, backedUp: planBackedUp, added: snapshot.pending, backsUp: backsUp, photos: photos)
        }.value
        let picked = plan.compact + plan.backUp
        if !picked.isEmpty {
            await job.enqueue(picked, trigger: .automatic, backUpOnly: Set(plan.backUp))
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
                case .backedUp?: summary.backedUp += 1
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
        // Forget added items that are done, gone, backed up (they're tracked there), or given up on.
        let ledger = await job.ledger.snapshot(), backedUp = await job.ledger.backedUpSnapshot()
        let pending = Array(state.pending)
        let (copies, album, existing) = await Task.detached(priority: .utility) {
            (Set(ledger.values.map(\.compactIdentifier)), photos.albumMembers(),
             photos.existing(pending, includeHidden: true))
        }.value
        state.pending = state.pending.filter { id in
            existing.contains(id) && ledger[id]?.serverAssetID == nil && backedUp[id] == nil && !copies.contains(id)
                && !album.contains(id) && !state.settled.contains(id) && (state.attempts[id] ?? 0) < Self.maximumAttempts
        }
        // First-seen dates matter only until the compact copy (and never beyond the longest cutoff).
        let oldest = now.addingTimeInterval(-Double((CompactSchedule.stops.last ?? 90) + 10) * 86_400)
        state.firstSeen = state.firstSeen.filter { id, date in ledger[id] == nil && date > oldest }
        if inserted.read { state.token = token }
        let after = Set(await remover?.candidates().map(\.original) ?? [])
        summary.removable = after.count
        summary.newlyRemovable = after.subtracting(before).count
        if notify, system, state.notifies, summary.newlyRemovable > 0 { await Self.notify(summary) }
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
        if summary.backedUp > 0 { parts.append("\(summary.backedUp) backed up, compact copies later") }
        if summary.kept > 0 { parts.append("\(summary.kept) kept as is") }
        if summary.notYet > 0 { parts.append("\(summary.notYet) to try again later") }
        if summary.failed > 0 { parts.append("\(summary.failed) didn't work") }
        return parts.isEmpty ? "Nothing new." : parts.joined(separator: ", ") + "."
    }

    /// The Server tab's value for its row: "Off", "On", or when it last ran ("On · ran last night").
    nonisolated static func status(on: Bool, lastRun: Date?, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard on else { return "Off" }
        guard let lastRun else { return "On" }
        let hour = calendar.component(.hour, from: lastRun)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now).map { calendar.isDate(lastRun, inSameDayAs: $0) }
        let date = Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).month(.abbreviated).day()
        let when: String
        if calendar.isDate(lastRun, inSameDayAs: now) {
            when = hour < 6 ? "last night" : "today"
        } else if yesterday == true {
            when = hour >= 20 ? "last night" : "yesterday"
        } else if calendar.isDate(lastRun, equalTo: now, toGranularity: .year) {
            when = lastRun.formatted(date)
        } else {
            when = lastRun.formatted(date.year())
        }
        return "On · ran \(when)"
    }

    static func notify(_ summary: Summary) async {
        guard ReleaseFeatures.automaticMode else { return }
        let content = UNMutableNotificationContent()
        content.title = "Ready to free up space"
        let count = summary.removable
        content.body = "\(count) original\(count == 1 ? " is" : "s are") backed up on your server. "
            + "Open Homespun to remove \(count == 1 ? "it" : "them") from this iPhone."
        content.sound = .default
        let request = UNNotificationRequest(identifier: "homespun.removable", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}
