// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
import UIKit
@testable import Homespun

private func gridCell(_ id: String, badge: Badge = .none, original: String? = nil) -> LibraryState.Cell {
    .init(id: id, badge: badge, original: original, canFree: original != nil)
}

private func gridData(_ cells: [LibraryState.Cell], months: [String: Int] = [:]) -> GridData {
    GridData(state: LibraryState(cells: cells), filter: .all, media: nil, months: months)
}

private func badgeCatalog() async throws -> DemoLibrary {
    let media = try await DemoTestMedia.ready.value
    return DemoLibrary(folder: URL.cachesDirectory.appendingPathComponent("badge-build-\(UUID().uuidString)"),
                       media: media, ask: { _ in true })
}

struct GridChangeTests {
    private actor BadgeBuildGate {
        private var entered = false
        private var arrivals: [CheckedContinuation<Void, Never>] = []
        private var held: CheckedContinuation<Void, Never>?

        func pause() async {
            entered = true
            let arrivals = arrivals
            self.arrivals = []
            arrivals.forEach { $0.resume() }
            await withCheckedContinuation { held = $0 }
        }

        func waitUntilEntered() async {
            if entered { return }
            await withCheckedContinuation { arrivals.append($0) }
        }

        func release() {
            held?.resume()
            held = nil
        }
    }

    @Test @MainActor func firstBadgeBuildLoadsWithTheLatestJobPages() async throws {
        let catalog = try await badgeCatalog()
        let ids = Array(catalog.contents().ids.prefix(3))
        try #require(ids.count == 3)
        let library = LibraryModel(catalog: catalog)
        defer { library.stopObserving() }
        library.apply(job: [ids[0]: .working("Uploading"), ids[1]: .waiting])
        let gate = BadgeBuildGate()
        library.badgeBuildGate = { await gate.pause() }
        let reload = Task { await library.reload() }
        await gate.waitUntilEntered()
        #expect(!library.loaded)
        library.apply(job: [ids[0]: .waiting, ids[1]: .failed("Earlier page")])
        library.apply(job: [ids[0]: .working("Later page"), ids[2]: .working("Downloading")],
                      compactInProgress: [ids[2]])
        library.apply(job: [ids[0]: .failed("Latest page"), ids[1]: nil], compactInProgress: [ids[2]])
        await gate.release()
        await reload.value
        library.badgeBuildGate = nil

        #expect(library.loaded)
        let contents = catalog.contents()
        let expected = LibraryState(library: contents.ids, ledger: [:], album: contents.album,
            job: [ids[0]: .failed("Latest page"), ids[2]: .working("Downloading")], compactInProgress: [ids[2]])
        #expect(library.state == expected)
        #expect(library.state.cell(ids[0])?.badge == .failed)
        #expect(library.state.cell(ids[1])?.badge == Badge.none)
        #expect(library.state.cell(ids[2])?.badge == .processing)
        #expect(library.state.cells.allSatisfy { !$0.canFree && !$0.canRestore })
        #expect(LibraryState.Filter.allCases.map { library.state.count($0) }
            == LibraryState.Filter.allCases.map { expected.count($0) })
        await library.reload()
        #expect(library.state == expected, "Removed job states must also leave the rebuild inputs")
    }

    @Test(arguments: [false, true])
    @MainActor func badgeRebuildPreservesLiveUpdatesAndVersions(changesLedger: Bool) async throws {
        let catalog = try await badgeCatalog()
        let ids = Array(catalog.contents().ids.prefix(2))
        try #require(ids.count == 2)
        let library = LibraryModel(catalog: catalog)
        defer { library.stopObserving() }
        await library.reload()
        let initial: [String: CompactJob.State] = [ids[0]: .working("Uploading"), ids[1]: .waiting]
        library.apply(job: initial.mapValues { Optional($0) })
        let backed: [String: Date?] = changesLedger ? [ids[0]: Date(timeIntervalSince1970: 2_000_000_000)] : [:]
        let gate = BadgeBuildGate()
        library.badgeBuildGate = { await gate.pause() }
        let rebuild = Task { await library.update(ledger: [:], job: initial, backedUp: backed) }
        await gate.waitUntilEntered()
        library.apply(job: [ids[0]: .waiting, ids[1]: .failed("Earlier page")])
        library.apply(job: [ids[0]: .working("Saving compact copy"), ids[1]: nil], compactInProgress: [ids[0]])
        let liveVersion = library.state.version
        await gate.release()
        await rebuild.value
        library.badgeBuildGate = nil

        let contents = catalog.contents()
        let expected = LibraryState(library: contents.ids, ledger: [:], album: contents.album,
            job: [ids[0]: .working("Saving compact copy")], backedUp: backed, compactInProgress: [ids[0]])
        #expect(library.loaded && library.state == expected)
        #expect(changesLedger ? library.state.version > liveVersion : library.state.version == liveVersion)
        #expect(LibraryState.Filter.allCases.map { library.state.count($0) }
            == LibraryState.Filter.allCases.map { expected.count($0) })
    }

    @Test @MainActor func inFlightBuildReplaysTheBadgeBeforeSavedRatherThanSkippingIt() async throws {
        let catalog = try await badgeCatalog()
        let id = try #require(catalog.contents().ids.first)
        let library = LibraryModel(catalog: catalog)
        defer { library.stopObserving() }
        let gate = BadgeBuildGate()
        library.badgeBuildGate = { await gate.pause() }
        let reload = Task { await library.reload() }
        await gate.waitUntilEntered()
        library.apply(job: [id: .working("Saving compact copy")], compactInProgress: [id])
        library.apply(job: [id: .saved(originalBytes: 100, compactBytes: 10)])
        await gate.release()
        await reload.value
        library.badgeBuildGate = nil
        #expect(library.loaded && library.state.cell(id)?.badge == .processing)
        #expect(library.state.cell(id)?.canFree == false)
    }

    @Test @MainActor func equalCellsStillReplayAgainstNewBackingFacts() async throws {
        let catalog = try await badgeCatalog()
        let id = try #require(catalog.contents().ids.first)
        let library = LibraryModel(catalog: catalog)
        defer { library.stopObserving() }
        await library.reload()
        library.apply(job: [id: .backedUp(originalBytes: 100)])
        _ = library.takeChangedIDs()
        let backed: [String: Date?] = [id: nil]
        let gate = BadgeBuildGate()
        library.badgeBuildGate = { await gate.pause() }
        let rebuild = Task {
            await library.update(ledger: [:], job: [id: .backedUp(originalBytes: 100)], backedUp: backed)
        }
        await gate.waitUntilEntered()
        library.apply(job: [id: nil])
        #expect(library.state.cell(id)?.badge == Badge.none)
        let liveVersion = library.state.version
        _ = library.takeChangedIDs()
        await gate.release()
        await rebuild.value
        library.badgeBuildGate = nil
        let contents = catalog.contents()
        let expected = LibraryState(library: contents.ids, ledger: [:], album: contents.album, job: [:], backedUp: backed)
        #expect(library.state == expected && library.state.cell(id)?.badge == .copyLater)
        #expect(library.loaded && library.state.version > liveVersion)
        #expect(library.takeChangedIDs()?.contains(id) == true)
    }

    @Test @MainActor func cellConfigurationTracksDirectSelectionAndReuseWithoutRepeatingUnchangedWork() {
        let cell = GridCell(frame: .zero), state = gridCell("original", badge: .working)
        #expect(!cell.isConfigured(for: state, selecting: true, selected: false, serverName: "Home"))
        cell.update(state: state, selecting: true, selected: false, serverName: "Home")
        #expect(cell.isConfigured(for: state, selecting: true, selected: false, serverName: "Home"))
        cell.updateSelection(selecting: true, selected: true)
        #expect(cell.accessibilityTraits.contains(.selected))
        #expect(cell.isConfigured(for: state, selecting: true, selected: true, serverName: "Home"))
        #expect(!cell.isConfigured(for: state, selecting: true, selected: false, serverName: "Home"))
        #expect(!cell.isConfigured(for: state, selecting: true, selected: true, serverName: "Other"))
        cell.prepareForReuse()
        #expect(!cell.isConfigured(for: state, selecting: true, selected: true, serverName: "Home"))
        cell.update(state: state, selecting: true, selected: true, serverName: "Home")
        #expect(cell.isConfigured(for: state, selecting: true, selected: true, serverName: "Home"))
    }

    @Test @MainActor func cellConfigurationUsesVisibleMeaningRatherThanUnrenderedProvenance() {
        let cell = GridCell(frame: .zero), state = gridCell("original", badge: .kept)
        cell.update(state: state, selecting: false, selected: false, serverName: "Home")
        var metadata = state
        metadata.serverOrigin = .init(serverID: UUID().uuidString, historyEpoch: UUID().uuidString)
        metadata.serverName = "Confirmed server"
        metadata.compactAfter = Date(timeIntervalSince1970: 2_000_000_000)
        #expect(cell.isConfigured(for: metadata, selecting: false, selected: false, serverName: "Home"))
        var actionable = gridCell("copy", badge: .originalOnPhone, original: "original")
        actionable.canFree = false
        cell.update(state: actionable, selecting: true, selected: false, serverName: "Home")
        actionable.canFree = true
        #expect(!cell.isConfigured(for: actionable, selecting: true, selected: false, serverName: "Home"))
        cell.update(state: gridCell("recent", badge: .copyLater), selecting: false, selected: false, serverName: "Home")
        var scheduled = gridCell("recent", badge: .copyLater)
        scheduled.compactAfter = metadata.compactAfter
        #expect(!cell.isConfigured(for: scheduled, selecting: false, selected: false, serverName: "Home"))
    }

    @Test func jobDiffOnlyIncludesChangedBadges() {
        var state = LibraryState(cells: [gridCell("a"), gridCell("b", badge: .working),
                                        gridCell("copy", badge: .originalOnPhone, original: "c")])
        let changed = state.apply(job: ["a": .working("Uploading"), "b": .working("Verifying"), "copy": .failed("ignored")])
        #expect(changed == ["a"])
        let version = state.version
        #expect(state.apply(job: ["a": .working("More progress")]).isEmpty)
        #expect(state.version == version)
    }

    @Test(arguments: [false, true])
    func savedJobWaitsForTheVerifiedLedgerSwap(hasBackup: Bool) {
        let backedUp: [String: Date?] = hasBackup ? ["original": Date(timeIntervalSince1970: 2_000_000_000)] : [:]
        for job in [CompactJob.State.working("Saving compact copy"), .processing("Making compact copy")] {
            var state = LibraryState(library: ["original"], ledger: [:], album: [], job: ["original": job], backedUp: backedUp)
            let before = state
            let version = state.version
            let counts = LibraryState.Filter.allCases.map { state.count($0) }
            #expect(state.apply(job: ["original": .saved(originalBytes: 100, compactBytes: 10)]).isEmpty)
            #expect(state == before && state.version == version)
            #expect(LibraryState.Filter.allCases.map { state.count($0) } == counts)
        }
    }

    @Test @MainActor func retainedCompactWorkHasOneBadgeWithoutBecomingActionableOrReenteringNotBackedUp() throws {
        let downloading = CompactJob.State.working("Downloading 40%")
        var state = LibraryState(library: ["retained", "uploading"], ledger: [:], album: [],
            job: ["retained": downloading, "uploading": .working("Uploading 62%")], compactInProgress: ["retained"])
        #expect(state.cell("retained")?.badge == .processing)
        #expect(state.cell("uploading")?.badge == .working)
        #expect(state.cells(.notBackedUp).map(\.id) == ["uploading"])
        #expect(state.cell("retained")?.canCompact == false && state.cell("retained")?.canFree == false)
        let cell = GridCell(frame: .zero)
        cell.update(state: try #require(state.cell("retained")), selecting: false, selected: false, serverName: "Home")
        #expect(cell.accessibilityValue == "Compact copy in progress")
        let version = state.version
        #expect(state.apply(job: ["retained": .processing("Making compact copy")]).isEmpty)
        #expect(state.apply(job: ["retained": .working("Verifying saved copy")]).isEmpty)
        #expect(state.version == version && state.count(.notBackedUp) == 1)

        var incremental = LibraryState(library: ["retained"], ledger: [:], album: [], job: ["retained": downloading])
        #expect(incremental.count(.notBackedUp) == 1)
        #expect(incremental.apply(job: ["retained": downloading], compactInProgress: ["retained"]) == ["retained"])
        #expect(incremental.cell("retained")?.badge == .processing && incremental.count(.notBackedUp) == 0)
        #expect(incremental.version == 1)
        #expect(incremental.apply(job: ["retained": downloading], compactInProgress: []) == ["retained"])
        #expect(incremental.cell("retained")?.badge == .working && incremental.count(.notBackedUp) == 1)
    }

    @Test func rebuiltDiffIncludesOriginalAndCopy() {
        let previous = LibraryState(cells: [gridCell("a"), gridCell("b")])
        let new = LibraryState(cells: [gridCell("copy", badge: .originalOnPhone, original: "a"), gridCell("b")])
        #expect(new.changedIDs(from: previous) == ["a", "copy"])
    }

    @Test func importingCopyDoesNotInsertATemporaryDuplicateOrConcealUnownedCopies() {
        let pending = LibraryState(library: ["original", "new-copy", "unowned-copy"], ledger: [:],
            album: ["new-copy", "unowned-copy"], job: ["original": .working("Verifying saved copy")],
            pendingImports: ["new-copy"])
        #expect(pending.cells.map(\.id) == ["original", "unowned-copy"])
        #expect(pending.cell("original")?.badge == .working)
        #expect(pending.cell("unowned-copy")?.badge == .compactCopy)
        let entry = CompactLedger.Entry(compactIdentifier: "new-copy", originalBytes: 100, compactBytes: 10,
                                       savedAt: Date(), serverAssetID: "original-hash")
        let published = LibraryState(library: ["original", "new-copy", "unowned-copy"], ledger: ["original": entry],
            album: ["new-copy", "unowned-copy"], job: [:], pendingImports: ["new-copy"])
        #expect(published.cells.map(\.id) == ["new-copy", "unowned-copy"])
        #expect(GridChange.replacements(from: gridData(pending.cells), to: gridData(published.cells)) == [0])
    }

    @Test func replacementsRequireSamePhotoAndShape() {
        let old = gridData([gridCell("a"), gridCell("b")])
        let new = gridData([gridCell("copy", badge: .originalOnPhone, original: "a"), gridCell("b")])
        #expect(GridChange.replacements(from: old, to: new) == [0])
        #expect(GridChange.replacements(from: old, to: old) == [])
        #expect(GridChange.replacements(from: old, to: gridData([gridCell("b"), gridCell("a")])) == nil)
        #expect(GridChange.replacements(from: old, to: gridData([gridCell("a")])) == nil)
        var regrouped = new
        regrouped.sections[0].range = 0..<1
        #expect(GridChange.replacements(from: old, to: regrouped) == nil)
        let many = (0..<201).map { gridCell("original-\($0)") }
        let copies = many.map { gridCell("copy-\($0.id)", original: $0.id) }
        #expect(GridChange.replacements(from: gridData(many), to: gridData(copies)) == nil)
    }

    @Test func smallFilteredRemovalUsesBatchIncludingDisappearingMonth() {
        let old = gridData([gridCell("a"), gridCell("b"), gridCell("c")], months: ["a": 1, "b": 2, "c": 2])
        let new = gridData([gridCell("c")], months: ["c": 2])
        guard case .batch(let change) = GridChange.between(old, new) else { Issue.record("expected batch"); return }
        #expect(change.deletedSections == IndexSet(integer: 0))
        #expect(change.deleted == [IndexPath(item: 0, section: 1)])
        #expect(change.inserted.isEmpty && change.insertedSections.isEmpty)
        guard case .reload = GridChange.between(gridData((0..<201).map { gridCell("\($0)") }), gridData([])) else {
            Issue.record("large changes must reload")
            return
        }
    }

    @Test @MainActor func equalCountsDoNotNotifyHeaders() {
        let counts = SectionCounts()
        let data = gridData([gridCell("a")])
        counts.update(data)
        let version = counts.version
        counts.update(data)
        #expect(counts.version == version)
        counts.update(gridData([gridCell("a", badge: .copyLater)]))
        #expect(counts.version == version + 1)
        #expect(counts.changedSections == [0])
    }

    @Test @MainActor func photosContentChangesAreSeparateFromBadgeAndStructureChanges() async {
        let library = LibraryModel()
        let old = library.state
        library.invalidateContent(["edited"])
        #expect(library.changedContent(since: 0) == ["edited"])
        let version = library.contentVersion
        library.apply(job: ["other": .working("Uploading")])
        #expect(library.contentVersion == version && library.state == old)
        library.invalidateContent(["another"])
        #expect(library.changedContent(since: version) == ["another"])
        #expect(library.changedContent(since: 0) == ["edited", "another"])

        let images = ItemImages()
        images.invalidate(["edited"])
        #expect(images.revision("edited") == 1 && images.revision("untouched") == 0)
    }

    @Test @MainActor func connectionProblemChangesTheMeasuredNoticeIdentity() {
        let clear = LibraryView.noticeKey(problem: nil, limited: false, paired: true)
        let blocked = LibraryView.noticeKey(problem: "Key changed", limited: false, paired: true)
        let updated = LibraryView.noticeKey(problem: "Update the server", limited: false, paired: true)
        #expect(clear != blocked && blocked != updated)
        #expect(LibraryView.noticeKey(problem: "Key changed", limited: true, paired: false) == blocked)
        #expect(LibraryView.noticeKey(problem: nil, limited: true, paired: false) == "limited")
    }
}
