// SPDX-License-Identifier: Apache-2.0
import Foundation

/// When automatic mode makes an item's compact copy (Server › Automatic Mode): recent items are
/// backed up at once but compacted only once they're older than the cutoff, so photos the person
/// cleans up in the meantime never come back as compact copies. Pure, so it's tested directly.
struct CompactSchedule: Codable, Equatable, Sendable {
    /// The slider's stops, in days: Right Away, 1 week, 1 month, 2 months, 3 months.
    static let stops = [0, 7, 30, 60, 90]
    static let standard = CompactSchedule()

    var days = 30
    /// Favorites are backed up but never compacted automatically.
    var keepFavorites = true

    /// The slider's position for `days` (the nearest stop).
    var stop: Int {
        get { Self.stops.enumerated().min { abs($0.element - days) < abs($1.element - days) }?.offset ?? 2 }
        set { days = Self.stops[min(max(newValue, 0), Self.stops.count - 1)] }
    }

    static func label(days: Int) -> String {
        switch days {
        case 0: "Right away"
        case 7: "After 1 week"
        case 30: "After 1 month"
        case 60: "After 2 months"
        case 90: "After 3 months"
        default: "After \(days) days"
        }
    }

    var label: String { Self.label(days: days) }

    /// When an item counts from: the later of when it was taken and when this iPhone first had it
    /// (an old photo saved or AirDropped today is as new as one taken today).
    static func recent(created: Date?, firstSeen: Date?) -> Date? {
        switch (created, firstSeen) {
        case let (created?, seen?): max(created, seen)
        case let (date?, nil), let (nil, date?): date
        case (nil, nil): nil
        }
    }

    /// When the item's compact copy is due, or nil if it never is automatically (a favorite).
    /// An item with no dates at all is due now.
    func due(created: Date?, firstSeen: Date?, favorite: Bool) -> Date? {
        if keepFavorites, favorite { return nil }
        guard let recent = Self.recent(created: created, firstSeen: firstSeen) else { return .distantPast }
        return recent.addingTimeInterval(TimeInterval(days) * 86_400)
    }
}

/// An item automatic mode may act on.
struct AutomaticCandidate: Equatable, Sendable {
    var id: String
    var created: Date?
    var favorite = false
}

/// What one automatic run does: compact what's due, back up what's recent (DESIGN 05·2.1).
struct AutomaticPlan: Equatable, Sendable {
    var compact: [String] = []
    var backUp: [String] = []

    /// `backedUp`: items whose originals are already at home without a compact copy. `backsUp`:
    /// whether recent items are backed up now (not in Immich mode, where the Immich app does it).
    static func make(_ candidates: [AutomaticCandidate], backedUp: Set<String>, firstSeen: [String: Date],
                     schedule: CompactSchedule, now: Date, backsUp: Bool, limit: Int) -> AutomaticPlan {
        var plan = AutomaticPlan()
        let ordered = candidates.sorted { ($0.created ?? .distantFuture) < ($1.created ?? .distantFuture) }
        for item in ordered {
            if let due = schedule.due(created: item.created, firstSeen: firstSeen[item.id], favorite: item.favorite), due <= now {
                plan.compact.append(item.id)
            } else if backsUp, !backedUp.contains(item.id) {
                plan.backUp.append(item.id)
            }
        }
        // Compact copies first (they free space), then what's left of the batch for backing up.
        plan.compact = Array(plan.compact.prefix(limit))
        plan.backUp = Array(plan.backUp.prefix(max(0, limit - plan.compact.count)))
        return plan
    }
}
