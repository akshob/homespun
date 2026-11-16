// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import Homespun

/// A clock the tests move by hand.
@MainActor private final class Clock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
}

@MainActor private func temporaryURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID().uuidString).json")
}

private func item(_ id: String, _ result: RunHistory.Item.Result, original: Int? = nil, compact: Int? = nil,
                  reason: String? = nil) -> RunHistory.Item {
    RunHistory.Item(assetID: id, name: "\(id).HEIC", originalBytes: original, compactBytes: compact, result: result,
                    reason: reason)
}

private func backUp(_ items: [RunHistory.Item], at end: Date, trigger: RunHistory.Trigger = .manual) -> RunHistory.Run {
    RunHistory.Run(kind: .backUp, trigger: trigger, start: end.addingTimeInterval(-120), end: end, items: items)
}

@MainActor @Test func runHistoryRecordsRunsNewestFirstAndKeepsThem() async {
    let url = temporaryURL(), clock = Clock()
    defer { try? FileManager.default.removeItem(at: url) }
    let history = RunHistory(url: url, now: { clock.now })
    history.record(backUp([item("a", .saved, original: 12_400_000, compact: 2_300_000), item("b", .kept, reason: "Dolby Vision")],
                          at: clock.now.addingTimeInterval(-3_600), trigger: .automatic))
    history.record(backUp([item("c", .saved, original: 1_000_000, compact: 200_000)], at: clock.now))
    // A run with nothing in it isn't kept.
    history.record(backUp([], at: clock.now))
    history.recordFreed(["a.HEIC"], bytes: 12_400_000)

    #expect(history.runs.count == 3)
    #expect(history.runs.first?.kind == .freeUp)
    #expect(history.runs.map(\.trigger) == [.manual, .manual, .automatic])
    #expect(history.lastBackUp?.items.map(\.assetID) == ["c"])

    await history.flush()
    let reloaded = RunHistory(url: url, now: { clock.now })
    #expect(reloaded.runs == history.runs)
    #expect(reloaded.totals == RunHistory.Totals(backedUp: 2, originalBytes: 13_400_000, compactBytes: 2_500_000,
                                                 freedBytes: 12_400_000, freedCount: 1))
}

@MainActor @Test func runHistoryForgetsRunsAfter90Days() async {
    let url = temporaryURL(), clock = Clock()
    defer { try? FileManager.default.removeItem(at: url) }
    let history = RunHistory(url: url, now: { clock.now })
    let day: TimeInterval = 86_400
    history.record(backUp([item("old", .saved, original: 1, compact: 1)], at: clock.now.addingTimeInterval(-89 * day)))
    history.record(backUp([item("new", .saved, original: 1, compact: 1)], at: clock.now))
    #expect(history.runs.count == 2)

    // Two days later the first run is 91 days old: gone, also from the file.
    clock.now += 2 * day
    history.record(backUp([item("newer", .saved, original: 1, compact: 1)], at: clock.now))
    #expect(history.runs.flatMap(\.items).map(\.assetID) == ["newer", "new"])
    clock.now += 100 * day
    await history.flush()
    #expect(RunHistory(url: url, now: { clock.now }).runs.isEmpty)
}

@MainActor @Test func needsAttentionFollowsEachItemsLatestResult() {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let runs = [
        backUp([item("a", .saved, original: 1, compact: 1), item("b", .failed, reason: "Can't reach polonium")],
               at: start.addingTimeInterval(60)),
        backUp([item("a", .failed, reason: "The server is full"), item("b", .failed, reason: "full"),
                item("c", .notYet, reason: "Not in Immich yet"), item("d", .failed, reason: "Couldn't download from iCloud")],
               at: start),
    ]
    // b was tried again and failed again; a worked the second time.
    let items = RunHistory.needsAttention(runs)
    #expect(items.map(\.assetID).sorted() == ["b", "c", "d"])
    #expect(items.first { $0.assetID == "b" }?.reason == "Can't reach polonium")

    let groups = AttentionCause.group(items, server: "polonium")
    #expect(groups.map(\.cause.section) == ["Server", "Immich", "This iPhone"])
    #expect(groups.map(\.cause.title) == ["Couldn't reach polonium", "Not in Immich yet", "Couldn't download from iCloud"])
    #expect(AttentionCause.of(item("x", .failed, reason: "polonium is almost full (3.1 GB free)."), server: "polonium").title
            == "polonium is almost full")
}

@Test func runTitlesAndSummariesUseEverydayWords() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
    let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 21)))
    func at(day: Int, hour: Int) throws -> Date {
        try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: 12)))
    }
    let tonight = backUp([item("a", .saved, original: 1_400_000_000, compact: 300_000_000)], at: try at(day: 14, hour: 3),
                         trigger: .automatic)
    #expect(tonight.title(now: now, calendar: calendar) == "Last night · automatic")
    #expect(backUp([], at: try at(day: 11, hour: 9)).title(now: now, calendar: calendar) == "Nov 11")
    #expect(tonight.summary == "1 backed up · 1.4 GB → 300 MB")
    let mixed = backUp([item("a", .saved, original: 1, compact: 1), item("b", .kept), item("c", .kept), item("d", .failed)],
                       at: now)
    #expect(mixed.summary == "1 backed up · 2 kept as is · 1 needs attention")
    var freed = RunHistory.Run(kind: .freeUp, trigger: .manual, start: now, end: now,
                               items: Array(repeating: item("", .freed), count: 18))
    freed.freedBytes = 2_100_000_000
    #expect(freed.summary == "Freed 2.1 GB · 18 originals")

    let months = RunHistory.freedByMonth([freed, backUp([], at: now)], months: 3, now: now, calendar: calendar)
    #expect(months == [0, 0, 2_100_000_000])
}

/// The run's progress and each item's state are kept as items change (Activity, the accessory and
/// the Lock Screen read them on every progress message); they must match counting the items again.
@MainActor @Test func runProgressFollowsTheJobsItems() async {
    let settings = AppSettings(defaults: UserDefaults(suiteName: "run-progress-\(UUID().uuidString)")!)
    let job = CompactJob(settings: settings, ledger: CompactLedger(url: temporaryURL()))
    // Items that aren't in the library fail as they're queued.
    await job.enqueue(["missing-a", "missing-b"], trigger: .manual)
    #expect(job.runProgress.total == 2 && job.runProgress.done == 2)
    #expect(job.states["missing-a"]?.phase == .failed && !job.hasWaiting)
    for _ in 0..<1_000 where job.isRunning { await Task.yield() }
    #expect(!job.isRunning)
    // The next run counts from zero; the earlier items keep their states.
    await job.enqueue(["missing-c"], trigger: .manual)
    #expect(job.runProgress.total == 1 && job.runProgress.done == 1)
    #expect(job.states.count == 3)
    for _ in 0..<1_000 where job.isRunning { await Task.yield() }
    job.clearFinished()
    #expect(job.runProgress.total == 0 && job.states.isEmpty)
}

/// Items are read from Photos before they're queued; Stop meanwhile means they never are.
@MainActor @Test func stopBeforeItemsAreQueuedDropsThem() async {
    let settings = AppSettings(defaults: UserDefaults(suiteName: "stop-early-\(UUID().uuidString)")!)
    let job = CompactJob(settings: settings, ledger: CompactLedger(url: temporaryURL()))
    async let queued: Void = job.enqueue(["missing-a", "missing-b"], trigger: .manual)
    for _ in 0..<100_000 where !job.isPreparing { await Task.yield() }
    #expect(job.isPreparing)
    job.stopWaiting(["missing-a"])
    await queued
    #expect(job.states["missing-a"] == nil && job.states["missing-b"] != nil)
    async let again: Void = job.enqueue(["missing-c"], trigger: .manual)
    for _ in 0..<100_000 where !job.isPreparing { await Task.yield() }
    #expect(job.isPreparing)
    job.stop()
    await again
    #expect(job.states["missing-c"] == nil)
}

/// The app reads the history in the background at launch; a run finished before that (a
/// background task) is added to what was in the file, never written over it.
@MainActor @Test func runsRecordedBeforeTheHistoryIsReadKeepTheFile() async {
    let url = temporaryURL(), clock = Clock()
    defer { try? FileManager.default.removeItem(at: url) }
    let earlier = RunHistory(url: url, now: { clock.now })
    earlier.record(backUp([item("old", .saved, original: 1, compact: 1)], at: clock.now.addingTimeInterval(-3_600)))
    await earlier.flush()
    let history = RunHistory(url: url, now: { clock.now }, load: false)
    history.record(backUp([item("new", .saved, original: 1, compact: 1)], at: clock.now))
    await history.flush()
    #expect(RunHistory(url: url, now: { clock.now }).runs.flatMap(\.items).map(\.assetID) == ["old"])
    await history.load()
    #expect(history.runs.flatMap(\.items).map(\.assetID) == ["new", "old"])
    await history.flush()
    #expect(RunHistory(url: url, now: { clock.now }).runs.flatMap(\.items).map(\.assetID) == ["new", "old"])
}
