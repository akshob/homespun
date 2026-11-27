// SPDX-License-Identifier: Apache-2.0
import Foundation

/// The words, links and prominence of a snapshot in the widgets and on the watch. Plain functions
/// of the snapshot and the time, so every state can be checked in tests.
enum StatusWords {
    /// The watch can't ask the server itself: after this long without word from the iPhone, it says so.
    static let staleAfter: TimeInterval = 6 * 3600

    static let locked = "Unlock widgets in the Homespun app"
    static let lockedShort = "Unlock widgets"
    /// Nothing written yet (the app hasn't run since it was installed).
    static let notStarted = "Open Homespun to get started"
    static let openOnPhone = "Open Homespun on your iPhone"
    static let notPaired = "Set up your home computer in Homespun"
    /// Between two parts of a fact; it stays with the part before it, so a line breaks after the dot.
    static let separator = "\u{00A0}· "

    static func isStale(_ snapshot: StatusSnapshot, now: Date) -> Bool {
        now.timeIntervalSince(snapshot.updatedAt) > staleAfter
    }

    // MARK: The four facts

    /// "1.2 GB · 48 items", "Nothing to free up".
    static func ready(_ ready: StatusSnapshot.Ready) -> String {
        ready.count > 0 ? "\(bytes(ready.bytes))\(separator)\(items(ready.count))" : "Nothing to free up"
    }

    /// "1.2 GB to free up", "Nothing to free up".
    static func readyHeadline(_ ready: StatusSnapshot.Ready) -> String {
        ready.count > 0 ? "\(bytes(ready.bytes)) to free up" : "Nothing to free up"
    }

    /// "Today, 9:12 AM · 12 items", "No backups yet".
    static func lastBackup(_ backup: StatusSnapshot.Backup?, now: Date, calendar: Calendar = .current) -> String {
        guard let backup else { return "No backups yet" }
        return "\(day(backup.date, now: now, calendar: calendar))\(separator)\(items(backup.count))"
    }

    /// "Home Mac · Connected", "Can't reach Home Mac", "No server yet".
    static func server(_ server: StatusSnapshot.Server?) -> String {
        guard let server else { return "No server yet" }
        if server.needsUpdate == true, server.reachable { return "Update \(server.name)" }
        return server.reachable ? "\(server.name)\(separator)Connected" : "Can't reach \(server.name)"
    }

    /// Automatic Mode runs in the background when iOS allows, usually overnight while charging.
    static func automatic(_ automatic: StatusSnapshot.Automatic) -> String {
        automatic.enabled ? "Tonight while charging" : "Off"
    }

    static func automaticShort(_ automatic: StatusSnapshot.Automatic) -> String {
        automatic.enabled ? "Tonight" : "Off"
    }

    /// A fact as VoiceOver reads it: "1.2 GB, 48 items".
    static func spokenFact(_ text: String) -> String { text.replacingOccurrences(of: separator, with: ", ") }

    // MARK: Pieces

    static func bytes(_ count: Int) -> String { count.formatted(.byteCount(style: .file)) }

    /// A size's number and unit apart, for a round widget: ("1.2", "GB").
    static func bytesParts(_ count: Int) -> (number: String, unit: String) {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.includesUnit = false
        let number = formatter.string(fromByteCount: Int64(count))
        formatter.includesUnit = true
        formatter.includesCount = false
        return (number, formatter.string(fromByteCount: Int64(count)))
    }

    static func items(_ count: Int) -> String { count == 1 ? "1 item" : "\(count.formatted()) items" }

    /// "Today, 9:12 AM", "Yesterday, 11:40 PM", "Nov 11", "Nov 11, 2025".
    static func day(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        var time = Date.FormatStyle(date: .omitted, time: .shortened)
        time.calendar = calendar
        time.timeZone = calendar.timeZone
        if calendar.isDate(date, inSameDayAs: now) { return "Today, \(date.formatted(time))" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday, \(date.formatted(time))"
        }
        var style = Date.FormatStyle().month(.abbreviated).day()
        if !calendar.isDate(date, equalTo: now, toGranularity: .year) { style = style.year() }
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }

    /// "today", "yesterday", "Nov 11": when, inside a sentence.
    static func when(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "yesterday"
        }
        return day(date, now: now, calendar: calendar)
    }

    /// "7 hours ago", for VoiceOver (the screen shows the system's own, always current, version).
    static func ago(_ date: Date, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: min(date, now), relativeTo: now)
    }

    // MARK: The whole widget

    enum State: Equatable {
        /// The app hasn't written anything yet.
        case notStarted
        case locked
        /// On the watch, nothing heard from the iPhone for a while.
        case stale
        case notPaired
        case facts
    }

    static func state(_ snapshot: StatusSnapshot?, now: Date, watch: Bool) -> State {
        guard let snapshot else { return .notStarted }
        if !snapshot.unlocked { return .locked }
        if watch, isStale(snapshot, now: now) { return .stale }
        return snapshot.server == nil ? .notPaired : .facts
    }

    /// The one line that matters most (Lock Screen and watch inline).
    static func headline(_ snapshot: StatusSnapshot?, now: Date, watch: Bool, calendar: Calendar = .current) -> String {
        switch state(snapshot, now: now, watch: watch) {
        case .notStarted: return watch ? openOnPhone : "Open Homespun"
        case .locked: return lockedShort
        case .stale: return openOnPhone
        case .notPaired: return "Set up Homespun"
        case .facts:
            guard let snapshot, let server = snapshot.server else { return "Homespun" }
            if !server.reachable { return "Can't reach \(server.name)" }
            if server.needsUpdate == true { return "Update \(server.name)" }
            if snapshot.ready.count > 0 { return readyHeadline(snapshot.ready) }
            if let backup = snapshot.lastBackup { return "Backed up \(when(backup.date, now: now, calendar: calendar))" }
            return "Nothing to free up"
        }
    }

    /// What VoiceOver reads for a widget that is one element.
    static func spoken(_ snapshot: StatusSnapshot?, now: Date, watch: Bool, calendar: Calendar = .current) -> String {
        switch state(snapshot, now: now, watch: watch) {
        case .notStarted: return "Homespun. " + (watch ? openOnPhone : notStarted) + "."
        case .locked: return "Homespun. \(locked)."
        case .notPaired: return "Homespun. \(notPaired)."
        case .stale:
            guard let snapshot else { return "Homespun." }
            return "Homespun. \(openOnPhone). Updated \(ago(snapshot.updatedAt, now: now))."
        case .facts:
            guard let snapshot else { return "Homespun." }
            var parts = ["Ready to free up: \(ready(snapshot.ready))",
                         "Last backup: \(lastBackup(snapshot.lastBackup, now: now, calendar: calendar))",
                         "Server: \(server(snapshot.server))",
                         "Automatic Mode: \(automatic(snapshot.automatic))"]
            if watch { parts.append("Updated \(ago(snapshot.updatedAt, now: now))") }
            return parts.map(spokenFact).joined(separator: ". ") + "."
        }
    }

    /// Where a tap on the whole widget leads: the most pressing fact.
    static func link(_ snapshot: StatusSnapshot?) -> AppLink {
        guard let snapshot else { return .activity }
        guard snapshot.unlocked else { return .unlock(feature: "widgets") }
        guard let server = snapshot.server, server.reachable else { return .server }
        return snapshot.ready.count > 0 ? .freeUp : .activity
    }

    /// How far up a Smart Stack the widget belongs (0–100): space to free (more for more space) or a
    /// server that can't be reached; little otherwise, and less once the watch's news is old.
    static func relevance(_ snapshot: StatusSnapshot?, now: Date, watch: Bool) -> Float {
        guard let snapshot, snapshot.unlocked, let server = snapshot.server else { return 0 }
        var score: Float = 5
        if !server.reachable { score = max(score, 60) }
        if snapshot.ready.count > 0 {
            score = max(score, 30 + min(50, Float(snapshot.ready.bytes) / 1_000_000_000 * 10))
        }
        if watch, isStale(snapshot, now: now) { score /= 4 }
        return score
    }

    /// When the words change without new data: now, the next two midnights ("Today" becomes
    /// "Yesterday", then a date) and, on the watch, when the news gets old.
    static func timelineDates(_ snapshot: StatusSnapshot?, now: Date, watch: Bool, calendar: Calendar = .current) -> [Date] {
        var dates = [now]
        if let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) {
            dates.append(midnight)
            if let next = calendar.date(byAdding: .day, value: 1, to: midnight) { dates.append(next) }
        }
        if watch, let snapshot {
            let stale = snapshot.updatedAt.addingTimeInterval(staleAfter + 1)
            if stale > now { dates.append(stale) }
        }
        return Array(Set(dates)).sorted()
    }
}
