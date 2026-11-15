// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import HomespunCore
import Logging

/// The server's trash for originals of recent items that were removed on the phone before they got
/// a compact copy (the person cleaned them up). They wait in `<originals>/.trash/` with the same
/// relative paths, so backing the item up again puts them back, and are deleted after 30 days.
/// Only items waiting as `stored` (or still uploading) go there: anything with a compact copy, or
/// kept as is, is a backup the person relies on and is never trashed.
struct Trash: Sendable {
    static let keep: TimeInterval = 30 * 86_400
    static let folder = ".trash"

    let catalog: Catalog
    let originals: OriginalsStore
    let storage: Storage

    static func trashed(_ path: String) -> String { folder + "/" + path }

    static func restored(_ path: String) -> String? {
        path.hasPrefix(folder + "/") ? String(path.dropFirst(folder.count + 1)) : nil
    }

    /// Moves the asset's originals to the trash (and drops any partial uploads).
    func remove(_ asset: AssetRecord, now: Date = Date()) async throws {
        let resources = try await catalog.resources(asset.id)
        let catalog = catalog, storage = storage
        try await originals.place { root in
            var paths: [Role: String] = [:]
            for resource in resources {
                try? FileManager.default.removeItem(at: storage.partial(asset.id, resource.role))
                guard let path = resource.storedPath, Self.restored(path) == nil,
                      let from = OriginalsStore.resolve(path, in: root),
                      let to = OriginalsStore.resolve(Self.trashed(path), in: root) else { continue }
                try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: to.path) { try FileManager.default.removeItem(at: to) }
                try FileManager.default.moveItem(at: from, to: to)
                paths[resource.role] = Self.trashed(path)
            }
            try await catalog.setTrashed(asset.id, paths: paths, at: Timestamp.string(now), state: .trashed)
        }
    }

    /// Puts a trashed asset's originals back; it waits as `stored` again.
    func restore(_ asset: AssetRecord) async throws {
        let resources = try await catalog.resources(asset.id)
        let catalog = catalog
        try await originals.place { root in
            var paths: [Role: String] = [:]
            for resource in resources {
                guard let path = resource.storedPath, let original = Self.restored(path),
                      let from = OriginalsStore.resolve(path, in: root),
                      let to = OriginalsStore.resolve(original, in: root) else { continue }
                try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: to.path) { try FileManager.default.moveItem(at: from, to: to) }
                paths[resource.role] = original
            }
            try await catalog.setTrashed(asset.id, paths: paths, at: nil, state: .stored)
        }
    }

    /// Deletes what has been in the trash for 30 days. Returns how many items went.
    @discardableResult
    func empty(now: Date = Date(), logger: Logger? = nil) async throws -> Int {
        let due = try await catalog.trashed(before: Timestamp.string(now.addingTimeInterval(-Self.keep)))
        let catalog = catalog
        for id in due {
            let resources = try await catalog.resources(id)
            try await originals.place { root in
                for resource in resources {
                    guard let path = resource.storedPath, Self.restored(path) != nil,
                          let url = OriginalsStore.resolve(path, in: root) else { continue }
                    try? FileManager.default.removeItem(at: url)
                }
                try await catalog.deleteAsset(id)
            }
            logger?.info("trash: deleted the originals of \(id), removed on the phone 30 days ago")
        }
        return due.count
    }
}
