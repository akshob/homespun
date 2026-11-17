// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import HomespunCore
import Hummingbird
import Logging

/// The server's trash for originals of recent items that were removed on the phone before they got
/// a compact copy (the person cleaned them up). Each item's files wait in its own folder,
/// `<originals>/.trash/<asset id>/<relative path>` (so two items with the same file names, such as
/// edits' `FullSizeRender.heic`, never collide), are put back if the item is backed up again, and
/// are deleted after 30 days. Only items waiting as `stored` (or still uploading) go there: anything
/// with a compact copy, or kept as is, is a backup the person relies on and is never trashed.
struct Trash: Sendable {
    static let keep: TimeInterval = 30 * 86_400
    static let folder = ".trash"

    let catalog: Catalog
    let originals: OriginalsStore
    let storage: Storage

    static func itemFolder(_ assetID: String) -> String { folder + "/" + Storage.sanitized(assetID) }

    static func trashed(_ path: String, assetID: String) -> String { itemFolder(assetID) + "/" + path }

    /// The path a trashed file came from (nil: not in the trash).
    static func restored(_ path: String) -> String? {
        guard path.hasPrefix(folder + "/") else { return nil }
        let rest = path.dropFirst(folder.count + 1)
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        return String(rest[rest.index(after: slash)...])
    }

    /// A disconnected disk must not look like files someone deleted.
    static func requireRoot(_ root: URL) throws {
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw HTTPError(.serviceUnavailable, message: "The originals folder \(root.path) isn't available (is its disk connected?).")
        }
    }

    /// `url`, or (if another file is already there) a free name next to it; never overwrites.
    static func free(_ url: URL, sha256: String) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let directory = url.deletingLastPathComponent(), name = url.lastPathComponent
        let stem = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var counter = 1
        while true {
            let suffix = "_" + sha256.prefix(12) + (counter > 1 ? "_\(counter)" : "")
            let candidate = directory.appendingPathComponent(stem + suffix + (ext.isEmpty ? "" : "." + ext))
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            counter += 1
        }
    }

    /// Moves the asset's originals to the trash (and drops any partial uploads).
    func remove(_ asset: AssetRecord, now: Date = Date()) async throws {
        let catalog = catalog, storage = storage
        try await originals.place { root in
            // Read where the files move: a rename of the phone may have just moved its folder.
            let resources = try await catalog.resources(asset.id)
            try Self.requireRoot(root)
            var paths: [Role: String] = [:]
            for resource in resources {
                if resource.state != .verified {
                    try? FileManager.default.removeItem(at: storage.partial(asset.id, resource.role))
                    try await catalog.setReceived(asset.id, role: resource.role, bytes: 0)
                }
                guard let path = resource.storedPath, Self.restored(path) == nil,
                      let from = OriginalsStore.resolve(path, in: root),
                      FileManager.default.fileExists(atPath: from.path),
                      var to = OriginalsStore.resolve(Self.trashed(path, assetID: asset.id), in: root) else { continue }
                try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                to = Self.free(to, sha256: resource.sha256)
                try FileManager.default.moveItem(at: from, to: to)
                paths[resource.role] = OriginalsStore.relative(to, to: root)
            }
            try await catalog.setTrashed(asset.id, paths: paths, at: Timestamp.string(now), state: .trashed)
        }
    }

    /// Puts a trashed asset's originals back; it waits as `stored` again (or `receiving` while
    /// files are missing). A file that's no longer in the trash (someone emptied it by hand) is
    /// forgotten, so the phone uploads it again instead of the item failing for good.
    func restore(_ asset: AssetRecord) async throws {
        let catalog = catalog
        try await originals.place { root in
            // Read where the files move: a rename of the phone may have just moved its folder.
            let resources = try await catalog.resources(asset.id)
            try Self.requireRoot(root)
            var paths: [Role: String] = [:]
            var complete = true
            for resource in resources {
                guard let path = resource.storedPath, let original = Self.restored(path) else {
                    if resource.state != .verified { complete = false }
                    continue
                }
                guard let from = OriginalsStore.resolve(path, in: root), FileManager.default.fileExists(atPath: from.path),
                      var to = OriginalsStore.resolve(original, in: root) else {
                    try await catalog.forgetStored(asset.id, role: resource.role)
                    complete = false
                    continue
                }
                try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                // Another item may have the same name by now: never overwrite it.
                to = Self.free(to, sha256: resource.sha256)
                try FileManager.default.moveItem(at: from, to: to)
                paths[resource.role] = OriginalsStore.relative(to, to: root)
            }
            try await catalog.setTrashed(asset.id, paths: paths, at: nil, state: complete ? .stored : .receiving)
            // Its folder goes once no files are left in it (only empty month folders).
            if let folder = OriginalsStore.resolve(Self.itemFolder(asset.id), in: root),
               let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]),
               !files.contains(where: { ((try? ($0 as? URL)?.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile) ?? false }) {
                try? FileManager.default.removeItem(at: folder)
            }
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
                try Self.requireRoot(root)
                for resource in resources {
                    guard let path = resource.storedPath, Self.restored(path) != nil,
                          let url = OriginalsStore.resolve(path, in: root) else { continue }
                    try? FileManager.default.removeItem(at: url)
                }
                if let folder = OriginalsStore.resolve(Self.itemFolder(id), in: root) {
                    try? FileManager.default.removeItem(at: folder)
                }
                try await catalog.deleteAsset(id)
            }
            logger?.info("trash: deleted the originals of \(id), removed on the phone 30 days ago")
        }
        return due.count
    }
}
