// SPDX-License-Identifier: Apache-2.0
import Foundation
import Observation

/// Activity's history (DESIGN 03·2.1–2.4): every backup run with each item's result, and every
/// time space was freed. Kept for 90 days as JSON in Application Support.
@MainActor @Observable
final class RunHistory {
    /// What started a run.
    enum Trigger: String, Codable, Sendable {
        case manual, automatic
        /// The first task in setup: the 10 newest items.
        case firstTask
    }

    struct Item: Codable, Equatable, Sendable, Identifiable {
        enum Result: String, Codable, Sendable {
            case saved, kept, notYet, failed, waiting
            /// Removed from this iPhone by Free Up Space.
            case freed
        }

        var id = UUID()
        /// The original's Photos identifier (empty for freed items, which are gone).
        var assetID: String
        var name: String
        var live = false
        var originalBytes: Int?
        var compactBytes: Int?
        /// The compact copy in Photos, for a thumbnail once the original is gone.
        var compactID: String?
        var result: Result
        var reason: String?
    }

    struct Run: Codable, Equatable, Sendable, Identifiable {
        enum Kind: String, Codable, Sendable { case backUp, freeUp }

        var id = UUID()
        var kind: Kind
        var trigger: Trigger
        var start: Date
        var end: Date
        var items: [Item]
        /// What Free Up Space freed on this iPhone.
        var freedBytes = 0

        func count(_ result: Item.Result) -> Int { items.reduce(0) { $0 + ($1.result == result ? 1 : 0) } }
        /// The originals backed up, and their compact copies.
        var originalBytes: Int { items.reduce(0) { $0 + ($1.result == .saved ? $1.originalBytes ?? 0 : 0) } }
        var compactBytes: Int { items.reduce(0) { $0 + ($1.result == .saved ? $1.compactBytes ?? 0 : 0) } }
    }

    struct Totals: Equatable {
        var backedUp = 0
        var originalBytes = 0
        var compactBytes = 0
        var freedBytes = 0
        var freedCount = 0
    }

    static let keptDays = 90

    /// Newest first.
    private(set) var runs: [Run]
    private let url: URL
    private let now: () -> Date

    static var defaultURL: URL {
        URL.applicationSupportDirectory.appendingPathComponent("Homespun/history.json")
    }

    init(url: URL = RunHistory.defaultURL, now: @escaping () -> Date = Date.init) {
        self.url = url
        self.now = now
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        runs = ((try? decoder.decode([Run].self, from: Data(contentsOf: url))) ?? []).sorted { $0.end > $1.end }
        if prune() { save() }
    }

    /// Adds a finished run (a backup with at least one item, or freed space).
    func record(_ run: Run) {
        guard !run.items.isEmpty || run.freedBytes > 0 else { return }
        runs.insert(run, at: runs.firstIndex { $0.end <= run.end } ?? runs.endIndex)
        prune()
        save()
    }

    /// Free Up Space removed these originals (their names) and freed `bytes`.
    func recordFreed(_ names: [String], bytes: Int) {
        let date = now()
        record(Run(kind: .freeUp, trigger: .manual, start: date, end: date,
                   items: names.map { Item(assetID: "", name: $0, result: .freed) }, freedBytes: bytes))
    }

    var totals: Totals {
        runs.reduce(into: Totals()) { totals, run in
            totals.backedUp += run.count(.saved)
            totals.originalBytes += run.originalBytes
            totals.compactBytes += run.compactBytes
            totals.freedBytes += run.freedBytes
            totals.freedCount += run.kind == .freeUp ? run.items.count : 0
        }
    }

    var lastBackUp: Run? { runs.first { $0.kind == .backUp } }

    /// Items whose latest result is a failure or "not yet", newest first: what still needs attention.
    var needsAttention: [Item] { Self.needsAttention(runs) }

    nonisolated static func needsAttention(_ runs: [Run]) -> [Item] {
        var seen = Set<String>(), items: [Item] = []
        for run in runs.sorted(by: { $0.end > $1.end }) where run.kind == .backUp {
            for item in run.items.reversed() where !item.assetID.isEmpty && seen.insert(item.assetID).inserted {
                if [.failed, .notYet].contains(item.result) { items.append(item) }
            }
        }
        return items
    }

    /// Space freed in each of the last `months` calendar months, oldest first (Activity's chart).
    func freedByMonth(_ months: Int = 8, calendar: Calendar = .current) -> [Int] {
        Self.freedByMonth(runs, months: months, now: now(), calendar: calendar)
    }

    nonisolated static func freedByMonth(_ runs: [Run], months: Int, now: Date, calendar: Calendar) -> [Int] {
        guard let thisMonth = calendar.dateInterval(of: .month, for: now)?.start else { return [] }
        return (0..<months).reversed().map { back in
            guard let start = calendar.date(byAdding: .month, value: -back, to: thisMonth),
                  let end = calendar.date(byAdding: .month, value: 1, to: start) else { return 0 }
            return runs.reduce(0) { $0 + ($1.end >= start && $1.end < end ? $1.freedBytes : 0) }
        }
    }

    /// Drops runs older than 90 days; true if any were dropped.
    @discardableResult private func prune() -> Bool {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -Self.keptDays, to: now()) else { return false }
        let count = runs.count
        runs.removeAll { $0.end < cutoff }
        return runs.count != count
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(runs) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: Words

extension RunHistory.Run {
    /// "Today, 9:12 AM", "Last night · automatic", "Nov 11" (DESIGN 03·2.1–2.2).
    func title(now: Date = Date(), calendar: Calendar = .current) -> String {
        var title: String
        let time = end.formatted(date: .omitted, time: .shortened)
        let hour = calendar.component(.hour, from: end)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now).map { calendar.isDate(end, inSameDayAs: $0) } ?? false
        if calendar.isDate(end, inSameDayAs: now) {
            title = hour < 6 && trigger == .automatic ? "Last night" : "Today, \(time)"
        } else if yesterday {
            title = hour >= 20 && trigger == .automatic ? "Last night" : "Yesterday, \(time)"
        } else if calendar.isDate(end, equalTo: now, toGranularity: .year) {
            title = end.formatted(.dateTime.month(.abbreviated).day())
        } else {
            title = end.formatted(.dateTime.month(.abbreviated).day().year())
        }
        switch trigger {
        case .automatic: title += " · automatic"
        case .firstTask: title += " · your 10 newest"
        case .manual: break
        }
        return title
    }

    /// "12 backed up · 1.4 GB → 0.3 GB", "48 backed up · 3 kept as is", "Freed 2.1 GB · 18 originals".
    var summary: String {
        if kind == .freeUp {
            let count = items.count
            return "Freed \(Self.bytes(freedBytes)) · \(count) original\(count == 1 ? "" : "s")"
        }
        var parts: [String] = []
        let saved = count(.saved), kept = count(.kept), attention = count(.failed) + count(.notYet)
        if saved > 0 || (kept == 0 && attention == 0) { parts.append("\(saved) backed up") }
        if kept > 0 { parts.append("\(kept) kept as is") }
        if attention > 0 { parts.append("\(attention) need\(attention == 1 ? "s" : "") attention") }
        if parts.count == 1, saved > 0 { parts.append("\(Self.bytes(originalBytes)) → \(Self.bytes(compactBytes))") }
        return parts.joined(separator: " · ")
    }

    static func bytes(_ count: Int) -> String { count.formatted(.byteCount(style: .file)) }
}

/// Why items need attention, grouped so one fix clears many (DESIGN 03·2.4).
struct AttentionCause: Hashable, Identifiable {
    /// "Server", "Immich", "This iPhone" or "Other".
    var section: String
    var title: String
    var detail: String
    var symbol: String
    var id: String { section + "/" + title }

    static func of(_ item: RunHistory.Item, server: String) -> AttentionCause {
        let reason = item.reason ?? ""
        let text = reason.lowercased()
        if text.contains("immich") {
            return .init(section: "Immich", title: item.result == .notYet ? "Not in Immich yet" : "Immich had a problem",
                         detail: item.result == .notYet ? "back them up with the Immich app first" : reason,
                         symbol: "hourglass")
        }
        if text.contains("full") || text.contains("space") || text.contains("disk") {
            return .init(section: "Server", title: "\(server) is almost full",
                         detail: "free up space on \(server), then try again", symbol: "externaldrive")
        }
        if text.contains("icloud") {
            return .init(section: "This iPhone", title: "Couldn't download from iCloud", detail: "check your connection",
                         symbol: "icloud")
        }
        if ["reach", "connect", "network", "timed out", "offline"].contains(where: text.contains) {
            return .init(section: "Server", title: "Couldn't reach \(server)",
                         detail: "is this iPhone on your home Wi‑Fi?", symbol: "wifi.exclamationmark")
        }
        let first = reason.split(separator: ".", maxSplits: 1).first.map(String.init) ?? reason
        return .init(section: "Other", title: first.isEmpty ? "Something went wrong" : first, detail: "",
                     symbol: "exclamationmark.triangle")
    }

    /// Causes in a stable order (Server, Immich, This iPhone, Other) with their items.
    static func group(_ items: [RunHistory.Item], server: String) -> [(cause: AttentionCause, items: [RunHistory.Item])] {
        let order = ["Server", "Immich", "This iPhone", "Other"]
        var groups: [AttentionCause: [RunHistory.Item]] = [:], causes: [AttentionCause] = []
        for item in items {
            let cause = of(item, server: server)
            if groups[cause] == nil { causes.append(cause) }
            groups[cause, default: []].append(item)
        }
        return causes.enumerated().sorted { a, b in
            let (x, y) = (order.firstIndex(of: a.element.section) ?? 9, order.firstIndex(of: b.element.section) ?? 9)
            return x == y ? a.offset < b.offset : x < y
        }.map { ($0.element, groups[$0.element] ?? []) }
    }
}
