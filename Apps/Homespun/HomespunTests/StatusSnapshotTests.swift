// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import Homespun

private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
    utc.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

private func time(_ date: Date) -> String {
    var style = Date.FormatStyle(date: .omitted, time: .shortened)
    style.calendar = utc
    style.timeZone = utc.timeZone
    return date.formatted(style)
}

private let now = date(2026, 11, 17, 15)

private func snapshot(unlocked: Bool = true, ready: Int = 0, readyBytes: Int = 0, backup: Date? = nil,
                      server: StatusSnapshot.Server? = .init(name: "Home Mac", reachable: true, checkedAt: now),
                      automatic: Bool = true, updatedAt: Date = now) -> StatusSnapshot {
    StatusSnapshot(unlocked: unlocked, ready: .init(bytes: readyBytes, count: ready),
                   lastBackup: backup.map { .init(date: $0, count: 12) }, server: server,
                   automatic: .init(enabled: automatic, lastRun: nil), updatedAt: updatedAt)
}

@Test func statusSnapshotRoundTripsThroughTheAppGroupFile() throws {
    let original = snapshot(ready: 48, readyBytes: 1_200_000_000, backup: date(2026, 11, 17, 9, 12))
    let data = try #require(StatusStore.encode(original))
    #expect(StatusStore.decode(data) == original)
    #expect(StatusStore.decode(Data("{}".utf8)) == nil)

    let url = FileManager.default.temporaryDirectory.appendingPathComponent("status-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(StatusStore.read(from: url) == nil)
    #expect(StatusStore.write(original, to: url))
    #expect(StatusStore.read(from: url) == original)
    // Nothing about the server but its name, and no photos.
    let text = String(decoding: data, as: UTF8.self)
    #expect(!text.contains("http") && !text.contains("HEIC"))
}

@Test func statusSnapshotFactsIgnoreWhenTheyWereWritten() {
    let first = snapshot(ready: 3, readyBytes: 9_000_000)
    var later = first
    later.updatedAt += 600
    later.server?.checkedAt = now + 600
    #expect(later.sameFacts(as: first))
    #expect(!later.sameFacts(as: nil))
    later.ready.count = 4
    #expect(!later.sameFacts(as: first))
    var unreachable = first
    unreachable.server?.reachable = false
    #expect(!unreachable.sameFacts(as: first))
}

@Test func statusWordsSayEachFact() {
    #expect(StatusWords.ready(.init(bytes: 1_200_000_000, count: 48)) == "1.2 GB · 48 items")
    #expect(StatusWords.ready(.init(bytes: 3_400_000, count: 1)) == "3.4 MB · 1 item")
    #expect(StatusWords.ready(.init(bytes: 0, count: 0)) == "Nothing to free up")
    #expect(StatusWords.readyHeadline(.init(bytes: 1_200_000_000, count: 48)) == "1.2 GB to free up")
    #expect(StatusWords.bytesParts(1_200_000_000) == ("1.2", "GB"))

    let today = date(2026, 11, 17, 9, 12), yesterday = date(2026, 11, 16, 23, 40)
    #expect(StatusWords.lastBackup(.init(date: today, count: 12), now: now, calendar: utc) == "Today, \(time(today)) · 12 items")
    #expect(StatusWords.lastBackup(.init(date: yesterday, count: 1), now: now, calendar: utc)
            == "Yesterday, \(time(yesterday)) · 1 item")
    #expect(StatusWords.lastBackup(.init(date: date(2026, 11, 11), count: 120), now: now, calendar: utc) == "Nov 11 · 120 items")
    #expect(StatusWords.lastBackup(.init(date: date(2025, 12, 30), count: 2), now: now, calendar: utc) == "Dec 30, 2025 · 2 items")
    #expect(StatusWords.lastBackup(nil, now: now) == "No backups yet")

    #expect(StatusWords.server(.init(name: "Home Mac", reachable: true)) == "Home Mac · Connected")
    #expect(StatusWords.server(.init(name: "Home Mac", reachable: false)) == "Can't reach Home Mac")
    #expect(StatusWords.server(nil) == "No server yet")
    #expect(StatusWords.automatic(.init(enabled: true)) == "Tonight while charging")
    #expect(StatusWords.automatic(.init(enabled: false)) == "Off")
}

@Test func statusWordsForEachState() {
    // Locked: no data, and a tap asks to unlock.
    let locked = snapshot(unlocked: false, ready: 48, readyBytes: 1_200_000_000)
    #expect(StatusWords.state(locked, now: now, watch: false) == .locked)
    #expect(StatusWords.headline(locked, now: now, watch: true) == "Unlock widgets")
    #expect(StatusWords.spoken(locked, now: now, watch: false) == "Homespun. Unlock widgets in the Homespun app.")
    #expect(StatusWords.link(locked) == .unlock(feature: "widgets"))
    #expect(StatusWords.relevance(locked, now: now, watch: true) == 0)

    // Nothing written yet; no server yet.
    #expect(StatusWords.state(nil, now: now, watch: false) == .notStarted)
    #expect(StatusWords.headline(nil, now: now, watch: true) == "Open Homespun on your iPhone")
    #expect(StatusWords.state(snapshot(server: nil), now: now, watch: false) == .notPaired)
    #expect(StatusWords.link(snapshot(server: nil)) == .server)

    // The watch's news gets old after 6 hours; the iPhone's own widgets don't.
    let old = snapshot(ready: 2, readyBytes: 10, updatedAt: now - 6 * 3600 - 1)
    #expect(StatusWords.state(old, now: now, watch: true) == .stale)
    #expect(StatusWords.headline(old, now: now, watch: true) == "Open Homespun on your iPhone")
    #expect(StatusWords.state(old, now: now, watch: false) == .facts)
    #expect(StatusWords.state(snapshot(updatedAt: now - 6 * 3600 + 60), now: now, watch: true) == .facts)

    // The headline and a tap go to what matters most.
    let away = snapshot(ready: 48, readyBytes: 1_200_000_000, server: .init(name: "Home Mac", reachable: false))
    #expect(StatusWords.headline(away, now: now, watch: false) == "Can't reach Home Mac")
    #expect(StatusWords.link(away) == .server)
    let ready = snapshot(ready: 48, readyBytes: 1_200_000_000, backup: date(2026, 11, 17, 9))
    #expect(StatusWords.headline(ready, now: now, watch: false) == "1.2 GB to free up")
    #expect(StatusWords.link(ready) == .freeUp)
    let done = snapshot(backup: date(2026, 11, 17, 9))
    #expect(StatusWords.headline(done, now: now, watch: false, calendar: utc) == "Backed up today")
    #expect(StatusWords.link(done) == .activity)
    #expect(StatusWords.headline(snapshot(), now: now, watch: false) == "Nothing to free up")

    let spoken = StatusWords.spoken(ready, now: now, watch: false, calendar: utc)
    #expect(spoken == "Ready to free up: 1.2 GB, 48 items. Last backup: Today, \(time(date(2026, 11, 17, 9))), 12 items. "
            + "Server: Home Mac, Connected. Automatic Mode: Tonight while charging.")
    #expect(StatusWords.spoken(old, now: now, watch: true).hasPrefix("Homespun. Open Homespun on your iPhone. Updated "))
}

@Test func statusRelevanceRisesWithSpaceToFreeAndAnUnreachableServer() {
    #expect(StatusWords.relevance(nil, now: now, watch: true) == 0)
    #expect(StatusWords.relevance(snapshot(server: nil), now: now, watch: true) == 0)
    #expect(StatusWords.relevance(snapshot(), now: now, watch: true) == 5)
    #expect(StatusWords.relevance(snapshot(server: .init(name: "Home Mac", reachable: false)), now: now, watch: true) == 60)
    let some = StatusWords.relevance(snapshot(ready: 48, readyBytes: 1_200_000_000), now: now, watch: true)
    let more = StatusWords.relevance(snapshot(ready: 480, readyBytes: 4_000_000_000), now: now, watch: true)
    #expect(abs(some - 42) < 0.01 && abs(more - 70) < 0.01)
    #expect(StatusWords.relevance(snapshot(ready: 9_000, readyBytes: 90_000_000_000), now: now, watch: true) == 80)
    // Old news on the watch matters less.
    #expect(abs(StatusWords.relevance(snapshot(ready: 480, readyBytes: 4_000_000_000, updatedAt: now - 7 * 3600), now: now,
                                      watch: true) - 17.5) < 0.01)
}

@Test func statusTimelineChangesAtMidnightAndWhenTheWatchsNewsGetsOld() {
    let fresh = snapshot(updatedAt: now - 3600)
    #expect(StatusWords.timelineDates(fresh, now: now, watch: false, calendar: utc)
            == [now, date(2026, 11, 18, 0), date(2026, 11, 19, 0)])
    #expect(StatusWords.timelineDates(fresh, now: now, watch: true, calendar: utc)
            == [now, now + 5 * 3600 + 1, date(2026, 11, 18, 0), date(2026, 11, 19, 0)])
    #expect(StatusWords.timelineDates(snapshot(updatedAt: now - 7 * 3600), now: now, watch: true, calendar: utc).count == 3)
}

@Test func appLinksRoundTrip() {
    for link in [AppLink.freeUp, .activity, .server, .automatic, .unlock(feature: "widgets")] {
        #expect(AppLink(link.url) == link)
    }
    #expect(AppLink.unlock(feature: "widgets").url.absoluteString == "homespun://unlock?feature=widgets")
    #expect(AppLink(URL(string: "homespun://unlock")!) == .unlock(feature: "premium"))
    #expect(AppLink(URL(string: "homespun://pair?server=home.local:8787&code=ABCD-EFGH")!) == nil)
    #expect(AppLink(URL(string: "https://homespun.photos/activity")!) == nil)
}

@Test func statusPublisherMakesTheSnapshotFromTheAppsState() {
    let run = RunHistory.Run(kind: .backUp, trigger: .automatic, start: now - 600, end: now, items: [
        .init(assetID: "a", name: "a", result: .saved), .init(assetID: "b", name: "b", result: .kept),
        .init(assetID: "c", name: "c", result: .backedUp), .init(assetID: "d", name: "d", result: .failed),
    ])
    #expect(StatusPublisher.backedUp(in: run) == 3)

    var inputs = StatusPublisher.Inputs(unlocked: true, readyBytes: 1_200_000_000, readyCount: 48,
                                        lastBackup: (run.end, StatusPublisher.backedUp(in: run)), historyLoaded: true,
                                        serverName: "Home Mac", status: .unreachable("Can't reach Home Mac."),
                                        checkedAt: now - 60, automatic: true, lastRun: now - 3600)
    let away = StatusPublisher.snapshot(inputs, previous: nil, now: now)
    #expect(away == StatusSnapshot(unlocked: true, ready: .init(bytes: 1_200_000_000, count: 48),
                                   lastBackup: .init(date: now, count: 3),
                                   server: .init(name: "Home Mac", reachable: false, checkedAt: now - 60),
                                   automatic: .init(enabled: true, lastRun: now - 3600), updatedAt: now))
    // While it's being checked again, the last answer stays.
    inputs.status = .checking
    inputs.checkedAt = nil
    #expect(StatusPublisher.snapshot(inputs, previous: away, now: now + 5).server
            == .init(name: "Home Mac", reachable: false, checkedAt: now - 60))
    inputs.serverName = nil
    #expect(StatusPublisher.snapshot(inputs, previous: away, now: now).server == nil)
}
