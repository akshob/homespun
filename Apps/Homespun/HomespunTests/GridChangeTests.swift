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

struct GridChangeTests {
    @Test func jobDiffOnlyIncludesChangedBadges() {
        var state = LibraryState(cells: [gridCell("a"), gridCell("b", badge: .working),
                                        gridCell("copy", badge: .originalOnPhone, original: "c")])
        let changed = state.apply(job: ["a": .working("Uploading"), "b": .working("Verifying"), "copy": .failed("ignored")])
        #expect(changed == ["a"])
        let version = state.version
        #expect(state.apply(job: ["a": .working("More progress")]).isEmpty)
        #expect(state.version == version)
    }

    @Test func rebuiltDiffIncludesOriginalAndCopy() {
        let previous = LibraryState(cells: [gridCell("a"), gridCell("b")])
        let new = LibraryState(cells: [gridCell("copy", badge: .originalOnPhone, original: "a"), gridCell("b")])
        #expect(new.changedIDs(from: previous) == ["a", "copy"])
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
}
