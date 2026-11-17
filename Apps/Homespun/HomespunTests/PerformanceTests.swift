// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import Homespun

// Performance budgets for the work behind the screens, on a library the size of a real one
// (35,000 items, most of them backed up). Each test takes the median of a few runs and fails past
// its budget. Run them in a Release build (ci/perf.sh): the budgets are for
// optimised code on the simulator, with headroom for a phone.

/// The median of `runs` timings of `body`, in milliseconds.
private func median(runs: Int = 5, _ body: () throws -> Void) rethrows -> Double {
    var times: [Double] = []
    for _ in 0..<runs {
        let start = ContinuousClock.now
        try body()
        let elapsed = ContinuousClock.now - start
        times.append(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
    }
    return times.sorted()[times.count / 2]
}

private func medianAsync(runs: Int = 5, isolation: isolated (any Actor)? = #isolation,
                         _ body: () async throws -> Void) async rethrows -> Double {
    var times: [Double] = []
    for _ in 0..<runs {
        let start = ContinuousClock.now
        try await body()
        let elapsed = ContinuousClock.now - start
        times.append(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
    }
    return times.sorted()[times.count / 2]
}

/// A library like a real one: `count` items, every other one with a compact copy whose original
/// is gone (backed up), a tenth with the original still here, and a few in a job.
fileprivate struct BigLibrary {
    var library: [String] = []
    var ledger: [String: CompactLedger.Entry] = [:]
    var album = Set<String>()
    var job: [String: CompactJob.State] = [:]
    var months: [String: Int] = [:]

    init(count: Int = 35_000) {
        let saved = Date(timeIntervalSince1970: 1_800_000_000)
        library.reserveCapacity(count)
        for index in 0..<count {
            let id = "asset-\(index)/L0/001"
            library.append(id)
            months[id] = 2015 * 12 + index / 300
            if index % 2 == 0 {
                // Its compact copy; the original was freed (not in the library).
                ledger["original-\(index)"] = .init(compactIdentifier: id, originalBytes: 4_000_000, compactBytes: 600_000,
                                                    savedAt: saved, serverAssetID: "sha-\(index)")
                album.insert(id)
            } else if index % 10 == 1 {
                // Backed up with its original still here: the copy is a separate item.
                let copy = "copy-\(index)/L0/001"
                library.append(copy)
                months[copy] = months[id]
                ledger[id] = .init(compactIdentifier: copy, originalBytes: 4_000_000, compactBytes: 600_000,
                                   savedAt: saved, serverAssetID: "sha-\(index)")
            }
        }
        for index in stride(from: 3, to: 3_000, by: 6) { job["asset-\(index)/L0/001"] = .waiting }
    }

    var state: LibraryState { LibraryState(library: library, ledger: ledger, album: album, job: job) }
}

/// Budgets for optimised code: the suite runs in the Profile configuration (`perf-unit.sh`) and is
/// skipped in Debug builds.
private let optimised: Bool = {
    #if DEBUG
    false
    #else
    true
    #endif
}()

@Suite("Performance", .serialized, .enabled(if: optimised, "Budgets are for optimised builds (the Profile configuration)."))
@MainActor
struct PerformanceTests {
    fileprivate let big = BigLibrary()

    @Test func buildingTheLibraryStateIsQuick() {
        var state = LibraryState()
        let ms = median { state = big.state }
        print("LibraryState of \(big.library.count) items: \(String(format: "%.1f", ms)) ms")
        #expect(state.cells.count > 30_000)
        #expect(ms < 120, "building the state took \(ms) ms")
    }

    @Test func countsAreFree() {
        let state = big.state
        var total = 0
        let ms = median {
            for _ in 0..<1_000 { for filter in LibraryState.Filter.allCases { total &+= state.count(filter) } }
        }
        #expect(total > 0)
        #expect(ms < 2, "6,000 counts took \(ms) ms")
        #expect(state.count(.all) == state.cells.count)
        #expect(state.count(.notBackedUp) == state.cells.filter { $0.matches(.notBackedUp) }.count)
        #expect(state.count(.readyToFree) == state.cells.filter(\.canFree).count)
    }

    @Test func jobChangesTouchOnlyTheirCells() {
        let base = big.state
        // One item at a time, as a backup goes: well under a frame.
        var state = base
        let single = median(runs: 9) {
            state.apply(job: ["asset-5/L0/001": .working("Uploading")])
            state.apply(job: ["asset-5/L0/001": .waiting])
        }
        #expect(single < 0.5, "one job change took \(single) ms")
        // Select All Not Backed Up queues everything at once.
        let everything = Dictionary(uniqueKeysWithValues: base.cells.filter(\.canCompact).map { ($0.id, CompactJob.State?.some(.waiting)) })
        let all = median(runs: 3) {
            var copy = base
            copy.apply(job: everything)
        }
        #expect(all < 60, "queueing \(everything.count) items took \(all) ms")
        var counted = base
        counted.apply(job: everything)
        #expect(counted.count(.notBackedUp) == counted.cells.filter { $0.matches(.notBackedUp) }.count)
        #expect(counted.version != base.version)
    }

    @Test func gridDataForEveryFilterIsQuick() {
        let state = big.state
        for filter in LibraryState.Filter.allCases {
            var data = GridData()
            let ms = median(runs: 3) { data = GridData(state: state, filter: filter, media: nil, months: big.months) }
            print("GridData \(filter.rawValue): \(data.cells.count) cells, \(data.sections.count) sections, \(String(format: "%.1f", ms)) ms")
            #expect(ms < 80, "grid data for \(filter.rawValue) took \(ms) ms")
        }
        let data = GridData(state: state, filter: .all, media: nil, months: big.months)
        #expect(data.sections.map(\.range.count).reduce(0, +) == data.cells.count)
        #expect(Set(data.sections.map(\.id)).count == data.sections.count, "section ids must be unique")
    }

    @Test func selectingTheWholeLibraryIsQuick() {
        let state = big.state
        let everything = Set(state.cells.map(\.id))
        var parts = SelectionParts()
        let ms = median(runs: 3) { parts = SelectionParts(state: state, selected: everything) }
        #expect(parts.backUp.count == state.cells.filter(\.canCompact).count)
        #expect(ms < 60, "sorting out a whole-library selection took \(ms) ms")
        let selectable = GridData(state: state, filter: .all, media: nil, months: big.months).selectable
        let subset = median(runs: 3) { _ = selectable.isSubset(of: everything) }
        #expect(subset < 20, "checking Select All took \(subset) ms")
    }

    @Test func automaticModePlansALibraryQuickly() {
        let candidates = big.library.enumerated().map { index, id in
            AutomaticCandidate(id: id, created: Date(timeIntervalSince1970: 1_500_000_000 + Double(index) * 3600),
                               favorite: index % 50 == 0)
        }
        var picked: [String] = []
        let pick = median(runs: 3) {
            picked = AutomaticMode.pick(candidates.map { ($0.id, $0.created) }, since: .distantPast, added: [],
                                        ledger: big.ledger, album: big.album, attempts: [:], settled: [], limit: .max)
        }
        #expect(!picked.isEmpty)
        #expect(pick < 120, "picking took \(pick) ms")
        let plan = median(runs: 3) {
            _ = AutomaticPlan.make(candidates, backedUp: [], firstSeen: [:], schedule: .standard, now: Date(),
                                   backsUp: true, limit: AutomaticMode.batch)
        }
        #expect(plan < 120, "planning took \(plan) ms")
    }

    /// The snapshot that shows the grid at launch: reading it must be far quicker than reading
    /// the library from Photos (which takes a second or more for 35,000 items).
    @Test func theLibrarySnapshotIsQuickToReadAndWrite() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("snapshot-perf-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: url) }
        var months: [String: Int] = [:], media: [String: MediaInfo] = [:]
        for (index, id) in big.library.enumerated() {
            months[id] = 24_000 + index / 300
            media[id] = MediaInfo(kind: index % 10 == 0 ? .video : .photo, seconds: index % 10 == 0 ? 30 : 0,
                                  created: Date(timeIntervalSince1970: 1_500_000_000 + Double(index) * 3600))
        }
        let snapshot = LibrarySnapshot(ids: big.library, months: months, media: media)
        let write = try median(runs: 3) { try snapshot.write(to: url) }
        var read: LibrarySnapshot?
        let readMs = median(runs: 3) { read = LibrarySnapshot.read(from: url) }
        print("library snapshot of \(big.library.count) items: write \(String(format: "%.0f", write)) ms, read \(String(format: "%.0f", readMs)) ms")
        #expect(read == snapshot)
        #expect(write < 250, "writing the snapshot took \(write) ms")
        #expect(readMs < 250, "reading the snapshot took \(readMs) ms")
    }

    @Test func theLedgerLoadsAndSavesALibraryInTheBackground() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-perf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("ledger.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(big.ledger).write(to: url)
        // Creating it reads nothing (the app creates it while launching, on the main thread).
        let create = median(runs: 9) { _ = CompactLedger(url: url) }
        #expect(create < 1, "creating the ledger took \(create) ms")
        let load = await medianAsync(runs: 3) { _ = await CompactLedger(url: url).snapshot() }
        print("ledger of \(big.ledger.count) entries: first read \(String(format: "%.0f", load)) ms")
        #expect(load < 400, "reading the ledger took \(load) ms")
        let ledger = CompactLedger(url: url)
        let save = try await medianAsync(runs: 3) {
            try await ledger.record(original: "new-\(UUID().uuidString)", compact: "copy", originalBytes: 1, compactBytes: 1,
                                    serverAssetID: "sha")
        }
        print("ledger save: \(String(format: "%.0f", save)) ms")
        #expect(save < 20, "saving one item to the ledger took \(save) ms")
    }

    @Test func historyRecordsWithoutHoldingTheMainThread() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("history-perf-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let items = (0..<200).map { RunHistory.Item(assetID: "a\($0)", name: "Photo", result: .saved) }
        let history = RunHistory(url: folder.appendingPathComponent("history.json"))
        // Each record is on the main thread: it must not write the file there.
        let ms = median(runs: 1) {
            for _ in 0..<200 { history.record(.init(kind: .backUp, trigger: .automatic, start: Date(), end: Date(), items: items)) }
        }
        #expect(history.runs.count == 200)
        #expect(ms < 400, "recording 200 runs of 200 items held the main thread \(ms) ms")
        await history.flush()
        #expect(RunHistory(url: folder.appendingPathComponent("history.json")).runs.count == 200)
    }
}
