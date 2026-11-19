// SPDX-License-Identifier: Apache-2.0
import Observation
import UIKit

/// Observed by UIKit, not the Library's body. Keep intermediate changes if several arrive in
/// one turn, so each delta is applied against the data it was built from.
@MainActor @Observable
final class GridStore {
    private(set) var data = GridData()
    private(set) var version = 0
    private(set) var isEmpty = true
    @ObservationIgnored private var pending: [(GridData, GridChange, Int)] = []

    func takeUpdates(after version: Int) -> [(GridData, GridChange, Int)] {
        defer { pending = [] }
        return pending.filter { $0.2 > version }
    }

    func apply(_ new: GridData, change: GridChange) {
        if case .same = change { return releaseInBackground(new) }
        let old = data
        data = new
        isEmpty = new.cells.isEmpty
        version &+= 1
        pending.append((new, change, version))
        releaseInBackground(old)
    }
}

/// Calculated off the main thread. A replacement represents the same photo, not an arbitrary
/// reorder with the same section sizes.
enum GridChange: Sendable {
    case same
    case swap([Int])
    case batch(Batch)
    case reload

    struct Batch: Sendable {
        var deletedSections = IndexSet()
        var insertedSections = IndexSet()
        var deleted: [IndexPath] = []
        var inserted: [IndexPath] = []
    }

    static func replacements(from old: GridData, to new: GridData) -> [Int]? {
        guard old.stateVersion >= 0, old.ids.count == new.ids.count,
              old.sections.map(\.id) == new.sections.map(\.id),
              old.sections.map(\.range) == new.sections.map(\.range) else { return nil }
        var replaced: [Int] = []
        for index in old.ids.indices where old.ids[index] != new.ids[index] {
            guard new.cells[index].original == old.ids[index] || old.cells[index].original == new.ids[index],
                  replaced.count < 200 else { return nil }
            replaced.append(index)
        }
        return replaced
    }

    static func between(_ old: GridData, _ new: GridData) -> Self {
        if let replaced = replacements(from: old, to: new) {
            return replaced.isEmpty ? .same : .swap(replaced)
        }
        guard old.stateVersion >= 0 else { return .reload }
        let oldSections = Dictionary(uniqueKeysWithValues: old.sections.enumerated().map { ($0.element.id, $0.offset) })
        let newSections = Dictionary(uniqueKeysWithValues: new.sections.enumerated().map { ($0.element.id, $0.offset) })
        let commonOld = old.sections.map(\.id).filter { newSections[$0] != nil }
        let commonNew = new.sections.map(\.id).filter { oldSections[$0] != nil }
        guard commonOld == commonNew else { return .reload }
        var batch = Batch(), edits = 0
        for (index, section) in old.sections.enumerated() where newSections[section.id] == nil {
            batch.deletedSections.insert(index)
            edits += section.range.count
        }
        for (index, section) in new.sections.enumerated() where oldSections[section.id] == nil {
            batch.insertedSections.insert(index)
            edits += section.range.count
        }
        for id in commonOld {
            guard let before = oldSections[id], let after = newSections[id] else { continue }
            let oldIDs = Array(old.ids[old.sections[before].range]), newIDs = Array(new.ids[new.sections[after].range])
            let oldSet = Set(oldIDs), newSet = Set(newIDs)
            guard oldIDs.filter({ newSet.contains($0) }) == newIDs.filter({ oldSet.contains($0) }) else { return .reload }
            batch.deleted += oldIDs.enumerated().compactMap {
                newSet.contains($0.element) ? nil : IndexPath(item: $0.offset, section: before)
            }
            batch.inserted += newIDs.enumerated().compactMap {
                oldSet.contains($0.element) ? nil : IndexPath(item: $0.offset, section: after)
            }
        }
        edits += batch.deleted.count + batch.inserted.count
        return edits <= 200 ? .batch(batch) : .reload
    }
}
