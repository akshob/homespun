// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import HomespunCore
import Hummingbird
import Logging

/// Expiry belongs only to newly admitted explicit compact-later requests. A permanent claim
/// from any request dominates it, regardless of delivery/import acknowledgements.
struct Trash: Sendable {
    static let keep: TimeInterval = 30 * 86_400
    static let folder = ".trash"
    struct Failure: Error, CustomStringConvertible { var description: String }

    let catalog: Catalog
    let originals: OriginalsStore
    let storage: Storage

    static func journal(_ id: String) -> String { "trash.mutation." + id }
    static func itemFolder(_ assetID: String) -> String { folder + "/" + Storage.sanitized(assetID) }
    static func trashed(_ path: String, assetID: String) -> String { itemFolder(assetID) + "/" + path }

    static func restored(_ path: String) -> String? {
        guard path.hasPrefix(folder + "/") else { return nil }
        let rest = path.dropFirst(folder.count + 1)
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        return String(rest[rest.index(after: slash)...])
    }

    static func requireRoot(_ root: URL) throws {
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw HTTPError(.serviceUnavailable, message: "The originals folder \(root.path) isn't available (is its disk connected?).")
        }
    }

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

    struct Plan: Codable, Sendable {
        enum Action: String, Codable, Sendable { case remove, restore, purge }
        struct Entry: Codable, Sendable {
            var role: Role
            var from: String
            var to: String?
            var sha256: String
            var size: Int
            var copy: Bool
        }
        var asset: String
        var generation: Int
        var action: Action
        var entries: [Entry]
        var missing: [Role] = []
        var at: String?
    }

    func remove(_ observed: AssetRecord, now: Date = Date()) async throws {
        try await claimed(observed.id) {
            try await originals.mutate { root in
                try Self.requireRoot(root)
                guard let asset = try await catalog.asset(observed.id),
                      asset.generation == observed.generation, !asset.permanent, !asset.purging,
                      asset.holdCompact, [.stored, .receiving].contains(asset.state) else {
                    throw APIError(.conflict, code: ServerAPI.ErrorCode.keptOriginal,
                                   message: "This original stays on the server: it is a permanent backup or its state changed.")
                }
                let resources = try await catalog.resources(asset.id)
                var entries: [Plan.Entry] = []
                for resource in resources {
                    guard let path = resource.storedPath, Self.restored(path) == nil,
                          let from = OriginalsStore.resolve(path, in: root),
                          let target = OriginalsStore.resolve(Self.trashed(path, assetID: asset.id), in: root) else { continue }
                    guard FileManager.default.fileExists(atPath: from.path) else {
                        throw Failure(description: "An original is missing; the item was not moved to the trash.")
                    }
                    let to = Self.free(target, sha256: resource.sha256)
                    entries.append(.init(role: resource.role, from: path, to: OriginalsStore.relative(to, to: root),
                                         sha256: resource.sha256, size: resource.size,
                                         copy: try await catalog.pathReferenceCount(path) > 1))
                }
                let plan = Plan(asset: asset.id, generation: asset.generation, action: .remove,
                                entries: entries, at: Timestamp.string(now))
                try await save(plan)
                try await apply(plan, root: root)
                for resource in resources where resource.state != .verified {
                    try? FileManager.default.removeItem(at: storage.partial(asset.id, resource.role))
                    try await catalog.setReceived(asset.id, role: resource.role, bytes: 0)
                }
            }
        }
    }

    func restore(_ observed: AssetRecord) async throws {
        try await claimed(observed.id) { try await restoreClaimed(observed.id) }
    }

    /// Registration already holds the asset claim; never recursively acquire it.
    func restoreClaimed(_ id: String) async throws {
        try await originals.mutate { root in
            try Self.requireRoot(root)
            guard let asset = try await catalog.asset(id), !asset.purging else {
                throw Failure(description: "This item's expired trash is being purged.")
            }
            let resources = try await catalog.resources(id)
            var entries: [Plan.Entry] = [], missing: [Role] = []
            for resource in resources {
                guard let path = resource.storedPath, let restored = Self.restored(path) else { continue }
                guard let from = OriginalsStore.resolve(path, in: root),
                      let target = OriginalsStore.resolve(restored, in: root) else {
                    throw Failure(description: "An unsafe stored path needs repair.")
                }
                guard FileManager.default.fileExists(atPath: from.path) else { missing.append(resource.role); continue }
                let to = Self.free(target, sha256: resource.sha256)
                entries.append(.init(role: resource.role, from: path, to: OriginalsStore.relative(to, to: root),
                                     sha256: resource.sha256, size: resource.size,
                                     copy: try await catalog.pathReferenceCount(path) > 1))
            }
            let plan = Plan(asset: id, generation: asset.generation, action: .restore, entries: entries, missing: missing)
            try await save(plan)
            try await apply(plan, root: root)
        }
    }

    @discardableResult
    func empty(now: Date = Date(), logger: Logger? = nil) async throws -> Int {
        let cutoff = Timestamp.string(now.addingTimeInterval(-Self.keep))
        let due = try await catalog.trashed(before: cutoff)
        var deleted = 0
        for id in due {
            let purged = try await claimed(id) {
                try await originals.mutate { root in
                    try Self.requireRoot(root)
                    // The expiry list is only a hint. Restore/registration may have won the claim.
                    guard let asset = try await catalog.asset(id), !asset.permanent,
                          asset.state == .trashed, let date = asset.trashedAt, date < cutoff else { return false }
                    let resources = try await catalog.resources(id)
                    guard resources.allSatisfy({ $0.storedPath == nil || $0.storedPath.flatMap(Self.restored) != nil }) else {
                        throw Failure(description: "An item in the trash has non-trash originals; cleanup was refused.")
                    }
                    let entries = resources.compactMap { resource -> Plan.Entry? in
                        guard let path = resource.storedPath else { return nil }
                        return .init(role: resource.role, from: path, sha256: resource.sha256,
                                     size: resource.size, copy: false)
                    }
                    let plan = Plan(asset: id, generation: asset.generation, action: .purge, entries: entries)
                    try await save(plan)
                    try await apply(plan, root: root)
                    return true
                }
            }
            if purged {
                deleted += 1
                logger?.info("trash: expired deferred item \(id); any historical/shared originals were retained")
            }
        }
        return deleted
    }

    /// Called only with exclusive serving/offline ownership, before requests/workers start.
    func recover() async throws {
        for saved in try await catalog.trashJournals() {
            let plan = try JSONDecoder().decode(Plan.self, from: Data(saved.utf8))
            try await claimed(plan.asset) {
                try await originals.mutate { root in try await apply(plan, root: root) }
            }
        }
    }

    private func claimed<T: Sendable>(_ id: String, _ body: @Sendable () async throws -> T) async throws -> T {
        try await catalog.mutations.withClaim(id) {
            do { return try await body() }
            catch {
                let pending: Bool
                do { pending = try await catalog.setting(Self.journal(id)) != nil }
                catch { pending = true }
                if pending {
                    await originals.requireRecovery("An interrupted trash mutation needs recovery; restart with the originals disk connected.")
                }
                if let failure = error as? OriginalsMover.Failure {
                    throw HTTPError(.serviceUnavailable, message: failure.description)
                }
                throw error
            }
        }
    }

    private func save(_ plan: Plan) async throws {
        try await catalog.saveTrashMutation(plan.asset, generation: plan.generation, action: plan.action,
                                            text: String(decoding: try JSONEncoder().encode(plan), as: UTF8.self))
    }

    private func apply(_ plan: Plan, root: URL) async throws {
        try Self.requireRoot(root)
        guard let asset = try await catalog.asset(plan.asset), asset.generation == plan.generation,
              plan.action != .purge || (!asset.permanent && asset.purging) else {
            throw Failure(description: "The trash mutation no longer matches this item; its journal was kept.")
        }
        var paths: [Role: String] = [:]
        let files = FileManager.default
        for entry in plan.entries {
            guard let from = OriginalsStore.resolve(entry.from, in: root) else {
                throw Failure(description: "Unsafe trash mutation source.")
            }
            if plan.action == .purge {
                guard Self.restored(entry.from) != nil else { throw Failure(description: "Purge refused a non-trash path.") }
                // A historical or another asset's reference owns the same object too.
                let ownedReferences = plan.entries.filter { $0.from == entry.from }.count
                if try await catalog.pathReferenceCount(entry.from) == ownedReferences, files.fileExists(atPath: from.path) {
                    try files.removeItem(at: from)
                }
                continue
            }
            guard let path = entry.to, let to = OriginalsStore.resolve(path, in: root) else {
                throw Failure(description: "Unsafe trash mutation destination.")
            }
            if files.fileExists(atPath: to.path) {
                guard (try JobRunner.size(of: to)) == entry.size, try Fingerprint.sha256(of: to) == entry.sha256,
                      entry.copy || !files.fileExists(atPath: from.path) else {
                    throw Failure(description: "The trash mutation destination collides; its journal was kept.")
                }
            } else {
                guard files.fileExists(atPath: from.path) else {
                    throw Failure(description: "Both trash mutation paths are missing; its journal was kept.")
                }
                try files.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                if entry.copy {
                    try await catalog.preserveSharedOriginal(plan.asset, role: entry.role, path: entry.from)
                    try files.copyItem(at: from, to: to)
                } else { try files.moveItem(at: from, to: to) }
            }
            paths[entry.role] = path
        }
        if plan.action == .purge {
            try await catalog.deleteAsset(plan.asset, generation: plan.generation)
        } else {
            for role in plan.missing { try await catalog.forgetStored(plan.asset, role: role) }
            let complete = try await catalog.resources(plan.asset).allSatisfy { $0.state == .verified }
            let permanentlyRetained = try await catalog.asset(plan.asset)?.permanent == true
            try await catalog.setTrashed(plan.asset, generation: plan.generation, paths: paths,
                                        at: plan.action == .remove && permanentlyRetained ? nil : plan.at,
                                        state: plan.action == .remove ? .trashed : complete ? .stored : .receiving)
        }
        // Never recursively delete a folder that might still hold indexed historical originals.
        if let folder = OriginalsStore.resolve(Self.itemFolder(plan.asset), in: root) {
            OriginalsMover.removeEmptyFolders(in: folder, keeping: [])
            if (try? files.contentsOfDirectory(atPath: folder.path))?.isEmpty == true { try files.removeItem(at: folder) }
        }
    }
}
