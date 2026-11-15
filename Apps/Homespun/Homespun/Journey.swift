// SPDX-License-Identifier: Apache-2.0
import Foundation
import Observation
import SwiftUI
import TipKit

/// What the app has seen happen, kept on this iPhone only, so messages start on events it can count
/// and stop when they're done (DESIGN §16). Homespun has no analytics.
@MainActor @Observable
final class JourneyLog {
    private let defaults: UserDefaults

    /// App launches into the foreground (sessions).
    private(set) var sessions: Int
    /// When a backup last finished, and the days the person started one themselves.
    private(set) var lastBackup: Date?
    private(set) var manualBackupDays: [Date]
    private(set) var selectUsed: Bool
    private(set) var freeUpUsed: Bool
    private(set) var compareUsed: Bool
    private(set) var badgeGuideOpened: Bool
    /// The session in which setup finished: no tips then.
    private(set) var setupSession: Int?
    var premiumMomentDismissed: Bool { didSet { defaults.set(premiumMomentDismissed, forKey: "journey.premiumDismissed") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        sessions = defaults.integer(forKey: "journey.sessions")
        lastBackup = defaults.object(forKey: "journey.lastBackup") as? Date
        manualBackupDays = (defaults.array(forKey: "journey.manualDays") as? [Date]) ?? []
        selectUsed = defaults.bool(forKey: "journey.select")
        freeUpUsed = defaults.bool(forKey: "journey.freeUp")
        compareUsed = defaults.bool(forKey: "journey.compare")
        badgeGuideOpened = defaults.bool(forKey: "journey.badgeGuide")
        setupSession = defaults.object(forKey: "journey.setupSession") as? Int
        premiumMomentDismissed = defaults.bool(forKey: "journey.premiumDismissed")
    }

    func sessionStarted() {
        sessions += 1
        defaults.set(sessions, forKey: "journey.sessions")
        Journey.updateTipParameters(self)
    }

    func setupFinished() {
        setupSession = sessions
        defaults.set(sessions, forKey: "journey.setupSession")
    }

    func backupStarted(manual: Bool, now: Date = .now) {
        guard manual else { return }
        let day = Calendar.current.startOfDay(for: now)
        if !manualBackupDays.contains(day) {
            manualBackupDays = (manualBackupDays + [day]).suffix(30)
            defaults.set(manualBackupDays, forKey: "journey.manualDays")
        }
    }

    func backupFinished(now: Date = .now) {
        lastBackup = now
        defaults.set(now, forKey: "journey.lastBackup")
    }

    func used(_ feature: Journey.Feature) {
        switch feature {
        case .select:
            selectUsed = true
            defaults.set(true, forKey: "journey.select")
            SelectTip().invalidate(reason: .actionPerformed)
        case .freeUp:
            freeUpUsed = true
            defaults.set(true, forKey: "journey.freeUp")
            FreeUpTip(server: "").invalidate(reason: .actionPerformed)
        case .compare:
            compareUsed = true
            defaults.set(true, forKey: "journey.compare")
            CompareTip().invalidate(reason: .actionPerformed)
        case .badgeGuide:
            badgeGuideOpened = true
            defaults.set(true, forKey: "journey.badgeGuide")
            BadgeTip().invalidate(reason: .actionPerformed)
        }
        Journey.updateTipParameters(self)
    }
}

enum Journey {
    enum Feature { case select, freeUp, compare, badgeGuide }

    /// TipKit with Homespun's rules: each tip at most once, at most one new tip a day.
    static func configureTips() {
        if ProcessInfo.processInfo.arguments.contains("-hideTips") {
            Tips.hideAllTipsForTesting()
        }
        try? Tips.configure([.displayFrequency(.daily), .datastoreLocation(.applicationDefault)])
    }

    @MainActor static func updateTipParameters(_ log: JourneyLog) {
        let fresh = log.setupSession == log.sessions
        TipState.sessions = fresh ? 0 : log.sessions
        TipState.selectUsed = log.selectUsed
        TipState.badgeGuideOpened = log.badgeGuideOpened
    }

    /// The Premium moment (T20): not owned, at least 1 GB freed, and at least two manual backups on
    /// different days within 14 days. Once; dismissing it means never again.
    static func premiumMomentDue(owned: Bool, freedBytes: Int, manualBackupDays: [Date], dismissed: Bool,
                                 now: Date = .now) -> Bool {
        guard !owned, !dismissed, freedBytes >= 1_000_000_000 else { return false }
        let recent = Set(manualBackupDays.filter { now.timeIntervalSince($0) <= 14 * 86_400 }
            .map { Calendar.current.startOfDay(for: $0) })
        return recent.count >= 2
    }
}

/// What tips are allowed to know, as TipKit parameters.
enum TipState {
    @Parameter static var sessions: Int = 0
    @Parameter static var selectUsed: Bool = false
    @Parameter static var badgeGuideOpened: Bool = false
    @Parameter static var notBackedUp: Int = 0
    @Parameter static var bothBadgesShown: Bool = false
    @Parameter static var automaticOn: Bool = false
    @Parameter static var trialDone: Bool = false
}

/// T6: the grid shows both badges; from the second session; until the Badge Guide is opened.
struct BadgeTip: Tip {
    var title: Text { Text("What the circles mean") }
    var message: Text? { Text("Half circle: ready to free up. Full circle: the original is at home.") }
    var image: Image? { Image(systemName: "circle.lefthalf.filled") }
    var actions: [Action] { [Action(id: "guide", title: "Badge Guide")] }
    var rules: [Rule] {
        #Rule(TipState.$sessions) { $0 >= 2 }
        #Rule(TipState.$bothBadgesShown) { $0 }
        #Rule(TipState.$badgeGuideOpened) { !$0 }
    }
    var options: [any TipOption] { [MaxDisplayCount(1)] }
}

/// T7: lots not backed up, Select never used, automatic mode off; from the third session.
struct SelectTip: Tip {
    var title: Text { Text("Back up a few at a time") }
    var message: Text? { Text("Tap Select, then tap or drag across photos.") }
    var image: Image? { Image(systemName: "checkmark.circle") }
    var rules: [Rule] {
        #Rule(TipState.$sessions) { $0 >= 3 }
        #Rule(TipState.$notBackedUp) { $0 >= 100 }
        #Rule(TipState.$selectUsed) { !$0 }
        #Rule(TipState.$automaticOn) { !$0 }
    }
    var options: [any TipOption] { [MaxDisplayCount(1)] }
}

/// T8: items are ready to free up outside the first task, and the trial isn't done.
struct FreeUpTip: Tip {
    var server: String
    var title: Text { Text("Checked before anything goes") }
    var message: Text? {
        Text("\(server) checks each original again before iOS asks you. The first time, 10 at most.")
    }
    var image: Image? { Image(systemName: "checkmark.shield") }
    var rules: [Rule] {
        #Rule(TipState.$sessions) { $0 >= 2 }
        #Rule(TipState.$trialDone) { !$0 }
    }
    var options: [any TipOption] { [MaxDisplayCount(1)] }
}

/// T9: the first time an item with a compact copy is opened.
struct CompareTip: Tip {
    var title: Text { Text("Compare") }
    var message: Text? { Text("See the compact copy next to its original.") }
    var image: Image? { Image(systemName: "rectangle.split.2x1") }
    var options: [any TipOption] { [MaxDisplayCount(1)] }
}

/// The accessory's one slot (DESIGN §16.4): the highest-priority state wins; the rest wait.
enum AccessoryLadder {
    struct Inputs {
        var paired = false
        var unreachable: String?
        var removing: String?
        var backingUp: (done: Int, total: Int, current: String?)?
        var finished: (count: Int, bytes: Int, originals: Set<String>)?
        var readyCount = 0
        var readyBytes = 0
        /// Free space on this iPhone, when known.
        var phoneFreeBytes: Int?
        /// Not backed up and created since the last backup, when automatic mode is off.
        var newSinceBackup: (count: Int, days: Int)?
    }

    enum State: Equatable {
        case unreachable(String)
        case removing(String)
        case backingUp(done: Int, total: Int, current: String?)
        case almostFull(bytes: Int)
        case finished(count: Int, bytes: Int, originals: Set<String>)
        case ready(count: Int, bytes: Int)
        case newPhotos(count: Int)
    }

    static func pick(_ inputs: Inputs) -> State? {
        // 1 · A blocking problem.
        if inputs.paired, let name = inputs.unreachable { return .unreachable(name) }
        // 2 · Running work.
        if let message = inputs.removing { return .removing(message) }
        if let run = inputs.backingUp { return .backingUp(done: run.done, total: run.total, current: run.current) }
        // 3 · Space pressure: almost full and something real to free (T15).
        if let free = inputs.phoneFreeBytes, free < 2_000_000_000, inputs.readyBytes >= 500_000_000 {
            return .almostFull(bytes: inputs.readyBytes)
        }
        // 4 · A decision is ready.
        if let finished = inputs.finished, finished.count > 0 {
            return .finished(count: finished.count, bytes: finished.bytes, originals: finished.originals)
        }
        if inputs.readyCount > 0 { return .ready(count: inputs.readyCount, bytes: inputs.readyBytes) }
        // 6 · New since the last backup, in manual mode (T19).
        if inputs.paired, let new = inputs.newSinceBackup, new.count >= 50, new.days >= 3 { return .newPhotos(count: new.count) }
        return nil
    }
}
