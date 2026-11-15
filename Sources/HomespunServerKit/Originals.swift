// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import HomespunCore
import Logging

/// Where originals are kept: `<root>/<phone folder>/YYYY/MM/<name>`. The root is a setting of its
/// own, apart from the data folder (`--originals`, or moved from the app), so the catalog stores
/// paths relative to it and moving every original only changes the root.
actor OriginalsStore {
    /// Catalog setting holding a root chosen from the app (it wins over `--originals`).
    static let setting = "originals.root"

    private(set) var root: URL
    private var placing = 0
    private var frozen = false

    init(root: URL) { self.root = root.standardizedFileURL }

    /// A catalog path resolved inside the root; nil if it would escape it.
    func url(_ relative: String) -> URL? { Self.resolve(relative, in: root) }

    static func resolve(_ relative: String, in root: URL) -> URL? {
        let url = root.appendingPathComponent(relative).standardizedFileURL
        return url.path.hasPrefix(root.standardizedFileURL.path + "/") ? url : nil
    }

    static func relative(_ url: URL, to root: URL) -> String {
        let rootPath = root.standardizedFileURL.path, path = url.standardizedFileURL.path
        return path.hasPrefix(rootPath + "/") ? String(path.dropFirst(rootPath.count + 1)) : path
    }

    /// Puts a new original in place (`body` gets the root to use) while no move is switching roots.
    func place<T: Sendable>(_ body: @Sendable (URL) async throws -> T) async throws -> T {
        while frozen { try await Task.sleep(for: .milliseconds(50)) }
        placing += 1
        defer { placing -= 1 }
        return try await body(root)
    }

    /// Holds new originals until `unfreeze`, once those being placed are in.
    func freeze() async {
        frozen = true
        while placing > 0 { try? await Task.sleep(for: .milliseconds(20)) }
    }

    func unfreeze(switchingTo newRoot: URL? = nil) {
        if let newRoot { root = newRoot.standardizedFileURL }
        frozen = false
    }

    /// `<folder>/YYYY/MM/<name>` (by capture month) in `root`, adding part of the SHA-256 if
    /// another file already has the name.
    static func destination(root: URL, folder: String?, filename: String, sha256: String, captureDate: Date?) -> URL {
        let parts = captureDate.map { Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: $0) }
        let month = parts.map { String(format: "%04d/%02d", $0.year ?? 0, $0.month ?? 0) } ?? "undated"
        var directory = root
        if let folder { directory.appendPathComponent(Storage.sanitized(folder), isDirectory: true) }
        directory.appendPathComponent(month, isDirectory: true)
        let name = Storage.sanitized(filename)
        var candidate = directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: candidate.path) {
            let stem = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
            candidate = directory.appendingPathComponent("\(stem)_\(sha256.prefix(12))" + (ext.isEmpty ? "" : ".\(ext)"))
        }
        return candidate
    }

    /// Free space and size of the disk holding `path` (or its nearest existing parent).
    static func space(at path: String) -> (free: Int64?, capacity: Int64?) {
        var url = URL(fileURLWithPath: path)
        while !FileManager.default.fileExists(atPath: url.path), url.path != "/" { url.deleteLastPathComponent() }
        guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: url.path) else { return (nil, nil) }
        return ((attributes[.systemFreeSize] as? NSNumber)?.int64Value, (attributes[.systemSize] as? NSNumber)?.int64Value)
    }

    /// The device number of the disk holding `path` (or its nearest existing parent).
    static func device(of path: String) -> Int? {
        var url = URL(fileURLWithPath: path)
        while !FileManager.default.fileExists(atPath: url.path), url.path != "/" { url.deleteLastPathComponent() }
        return (try? FileManager.default.attributesOfItem(atPath: url.path)[.systemNumber] as? NSNumber)?.intValue
    }
}

/// Moves every stored original to a new originals folder: copy and check each one, hold new
/// originals for a moment, copy any that arrived meanwhile, switch, and only then delete the old
/// files. Interrupted, it starts again when the server does (files already copied and checked
/// are kept).
actor OriginalsMover {
    /// Catalog setting naming the move under way (`from` and `to`), so it resumes after a restart.
    static let setting = "originals.move"

    struct Failure: Error, CustomStringConvertible { var description: String }
    /// The new folder's disk isn't there: the move waits for it (the plan is kept).
    struct TargetMissing: Error, CustomStringConvertible { var description: String }

    private struct Plan: Codable { var from: String, to: String }

    let catalog: Catalog
    let store: OriginalsStore
    let dataDirectory: URL
    let logger: Logger
    private(set) var status: ServerAPI.MoveStatus?
    private var task: Task<Void, Never>?
    private var starting = false

    init(catalog: Catalog, store: OriginalsStore, dataDirectory: URL, logger: Logger) {
        self.catalog = catalog
        self.store = store
        self.dataDirectory = dataDirectory
        self.logger = logger
    }

    var isMoving: Bool { status.map { [.copying, .finishing].contains($0.state) } ?? false }

    /// Checks the new folder and starts moving there.
    func start(to path: String) async throws {
        guard !isMoving, !starting else { throw Failure(description: "Originals are already being moved.") }
        starting = true
        defer { starting = false }
        let from = await store.root
        let target = try Self.validate(path, current: from, dataDirectory: dataDirectory)
        let originals = try await catalog.storedOriginals()
        let needed = originals.reduce(Int64(0)) { $0 + Int64($1.size) }
        // On the same APFS disk copies are clones and take no space; elsewhere they need room.
        #if os(macOS)
        let clones = OriginalsStore.device(of: from.path) == OriginalsStore.device(of: target.path)
        #else
        let clones = false
        #endif
        if !clones, let free = OriginalsStore.space(at: target.path).free, free < needed + (1 << 30) {
            throw Failure(description: "That disk has \(Self.bytes(free)) free; the originals need \(Self.bytes(needed)) plus room to spare.")
        }
        do {
            if !FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            }
        } catch {
            throw Failure(description: "Homespun Server can't make \(target.path): \(error.localizedDescription)")
        }
        let probe = target.appendingPathComponent(".homespun-write-test")
        guard FileManager.default.createFile(atPath: probe.path, contents: Data()) else {
            throw Failure(description: "Homespun Server can't write to \(target.path).")
        }
        try? FileManager.default.removeItem(at: probe)
        let plan = Plan(from: from.path, to: target.path)
        try await catalog.setSetting(Self.setting, String(decoding: try JSONEncoder().encode(plan), as: UTF8.self))
        launch(plan)
    }

    /// Picks up a move the server was making when it stopped.
    func resume() async {
        guard let text = try? await catalog.setting(Self.setting),
              let plan = try? JSONDecoder().decode(Plan.self, from: Data(text.utf8)) else { return }
        logger.notice("resuming the move of originals to \(plan.to)")
        launch(plan)
    }

    /// Waits for the move under way to end (for tests and tools).
    func wait() async { await task?.value }

    private func launch(_ plan: Plan) {
        status = .init(state: .copying, from: plan.from, to: plan.to, copied: 0, total: 0, copiedBytes: 0, totalBytes: 0)
        task = Task { await run(plan) }
    }

    private func run(_ plan: Plan) async {
        let from = URL(fileURLWithPath: plan.from), to = URL(fileURLWithPath: plan.to)
        var copied = Set<String>()
        do {
            guard FileManager.default.fileExists(atPath: to.path) else {
                throw TargetMissing(description: "\(to.path) isn't there (is its disk connected?)")
            }
            // Copy until nothing new arrived, then hold new originals for the last few and switch.
            for _ in 0..<3 {
                let pending = try await pendingOriginals(excluding: copied)
                if pending.isEmpty { break }
                try await copy(pending, from: from, to: to, into: &copied)
            }
            status?.state = .finishing
            await store.freeze()
            do {
                // The switch happens only when every stored original is among those copied.
                var switched = false
                for _ in 0..<5 where !switched {
                    try await copy(try await pendingOriginals(excluding: copied), from: from, to: to, into: &copied)
                    switched = try await catalog.switchOriginals(to: to.path, copied: copied).isEmpty
                }
                guard switched else { throw Failure(description: "new originals kept arriving; try again") }
            } catch {
                await store.unfreeze()
                throw error
            }
            await store.unfreeze(switchingTo: to)
            await catalog.log("originals_moved", detail: "\(from.path) -> \(to.path) (\(copied.count) files)")
            logger.notice("moved \(copied.count) originals to \(to.path)")

            // Readers that resolved an old path a moment ago can finish first.
            try? await Task.sleep(for: .seconds(2))
            let kept = Set(copied.compactMap { OriginalsStore.resolve($0, in: to)?.path })
            for path in copied {
                guard let old = OriginalsStore.resolve(path, in: from), !kept.contains(old.path),
                      let new = OriginalsStore.resolve(path, in: to), !Self.sameFile(old, new) else { continue }
                try? FileManager.default.removeItem(at: old)
            }
            Self.removeEmptyFolders(in: from, keeping: [dataDirectory, to])
            status?.state = .done
            status?.finishedAt = Date()
        } catch {
            logger.error("moving originals to \(to.path) failed: \(error)")
            // Nothing switched, so the originals are all still where they were. A missing disk
            // keeps the plan, so the move continues when the server starts with it connected.
            if !(error is TargetMissing) { try? await catalog.setSetting(Self.setting, nil) }
            status?.state = .failed
            status?.message = "\(error)"
            status?.finishedAt = Date()
        }
    }

    private func pendingOriginals(excluding copied: Set<String>) async throws
        -> [(assetID: String, role: ServerAPI.ResourceRole, path: String, size: Int, sha256: String)] {
        let all = try await catalog.storedOriginals()
        status?.total = all.count
        status?.totalBytes = all.reduce(Int64(0)) { $0 + Int64($1.size) }
        return all.filter { !copied.contains($0.path) }
    }

    private func copy(_ originals: [(assetID: String, role: ServerAPI.ResourceRole, path: String, size: Int, sha256: String)],
                      from: URL, to: URL, into copied: inout Set<String>) async throws {
        for original in originals {
            guard let source = OriginalsStore.resolve(original.path, in: from),
                  let target = OriginalsStore.resolve(original.path, in: to) else {
                throw Failure(description: "\(original.path) is not a safe path")
            }
            try await detached { try Self.copyChecked(source, to: target, root: to, sha256: original.sha256, size: original.size) }
            copied.insert(original.path)
            status?.copied = copied.count
            status?.copiedBytes += Int64(original.size)
        }
    }

    /// Copies one file into `root` and checks the copy byte for byte. A right copy already there is
    /// kept; a different file in the way is left alone and stops the move.
    static func copyChecked(_ source: URL, to target: URL, root: URL, sha256: String, size: Int) throws {
        let files = FileManager.default
        if files.fileExists(atPath: target.path) {
            if (try? Fingerprint.sha256(of: target)) == sha256, (try? JobRunner.size(of: target)) == size { return }
            throw Failure(description: "A different file is already at \(target.path); move it out of the way and try again.")
        }
        guard (try? JobRunner.size(of: source)) == size else {
            throw Failure(description: "The original \(source.path) is missing or changed, so it wasn't moved.")
        }
        // Only folders inside a root that's there: never the root itself, which a disk that
        // went away would turn into a folder on the startup disk.
        guard files.fileExists(atPath: root.path) else {
            throw TargetMissing(description: "\(root.path) isn't there (is its disk connected?)")
        }
        try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent).partial")
        try? files.removeItem(at: partial)
        try files.copyItem(at: source, to: partial)
        guard try Fingerprint.sha256(of: partial) == sha256, try JobRunner.size(of: partial) == size else {
            try? files.removeItem(at: partial)
            throw Failure(description: "The copy of \(source.lastPathComponent) didn't match the original.")
        }
        try files.setAttributes([.posixPermissions: 0o440], ofItemAtPath: partial.path)
        try files.moveItem(at: partial, to: target)
    }

    /// A folder the originals may move to, as an absolute URL.
    static func validate(_ path: String, current: URL, dataDirectory: URL) throws -> URL {
        let trimmed = (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        guard trimmed.hasPrefix("/") else { throw Failure(description: "Enter a full path, starting with /.") }
        let target = URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL
        guard target.path != current.standardizedFileURL.path else {
            throw Failure(description: "The originals are already in \(target.path).")
        }
        let data = dataDirectory.standardizedFileURL.path
        guard target.path != data, !target.path.hasPrefix(data + "/") else {
            throw Failure(description: "That's inside Homespun Server's own data folder; pick another folder.")
        }
        guard FileManager.default.fileExists(atPath: target.deletingLastPathComponent().path) else {
            throw Failure(description: "\(target.deletingLastPathComponent().path) doesn't exist (is the disk connected?).")
        }
        let resolved = target.resolvingSymlinksInPath().path
        guard resolved != data, !resolved.hasPrefix(data + "/") else {
            throw Failure(description: "That's inside Homespun Server's own data folder; pick another folder.")
        }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw Failure(description: "\(target.path) is a file, not a folder.") }
            // The same folder by another name (letter case, a link) would be "moved" onto itself.
            guard !sameFile(target, current) else { throw Failure(description: "The originals are already in that folder.") }
            for marker in [".git", "Package.swift"]
            where FileManager.default.fileExists(atPath: target.appendingPathComponent(marker).path) {
                throw Failure(description: "\(target.path) holds source code, so originals there could be deleted.")
            }
        }
        return target
    }

    /// Removes folders left empty under `root` (not `root` itself, nor the kept folders or their parents).
    static func removeEmptyFolders(in root: URL, keeping: [URL]) {
        let kept = keeping.map(\.standardizedFileURL.path)
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        var folders: [URL] = []
        for case let url as URL in enumerator where (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            folders.append(url.standardizedFileURL)
        }
        for folder in folders.sorted(by: { $0.path.count > $1.path.count })
        where !kept.contains(where: { $0 == folder.path || $0.hasPrefix(folder.path + "/") || folder.path.hasPrefix($0 + "/") }) {
            if (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
                try? FileManager.default.removeItem(at: folder)
            }
        }
    }

    static func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }

    /// Whether two paths are the same file or folder on disk (not just the same spelling).
    static func sameFile(_ a: URL, _ b: URL) -> Bool {
        // Following links: attributesOfItem describes a link itself, not what it points to.
        guard let first = try? FileManager.default.attributesOfItem(atPath: a.resolvingSymlinksInPath().path),
              let second = try? FileManager.default.attributesOfItem(atPath: b.resolvingSymlinksInPath().path) else { return false }
        return (first[.systemNumber] as? NSNumber) == (second[.systemNumber] as? NSNumber)
            && (first[.systemFileNumber] as? NSNumber) == (second[.systemFileNumber] as? NSNumber)
    }
}

/// Folders on this computer the app can offer for originals: its disks, with free space.
enum OriginalsLocations {
    static func suggestions(current: URL) -> [ServerAPI.StorageLocation] {
        var candidates: [(path: String, name: String)] = [(current.path, "Current folder")]
        let home = FileManager.default.homeDirectoryForCurrentUser
        #if os(macOS)
        candidates.append((home.appendingPathComponent("Pictures/Homespun").path, "Pictures folder on this Mac"))
        let skipped: Set<String> = ["Macintosh HD", "Recovery", "Preboot", "Update", "VM", "Data"]
        let volumes = (try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? []
        for volume in volumes.sorted() where !volume.hasPrefix(".") && !skipped.contains(volume) {
            let path = "/Volumes/\(volume)"
            guard (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) == nil else { continue }
            candidates.append((volume == "Homespun" ? path : path + "/Homespun", volume))
        }
        #else
        candidates.append((home.appendingPathComponent("Homespun").path, "Home folder"))
        let real: Set<String> = ["ext4", "ext3", "xfs", "btrfs", "zfs", "hfsplus", "exfat", "vfat", "ntfs", "ntfs3",
                                 "fuseblk", "cifs", "nfs", "nfs4"]
        let mounts = (try? String(contentsOfFile: "/proc/mounts", encoding: .utf8)) ?? ""
        for line in mounts.split(separator: "\n") {
            let fields = line.split(separator: " ")
            guard fields.count > 2, real.contains(String(fields[2])) else { continue }
            let point = String(fields[1]).replacingOccurrences(of: "\\040", with: " ")
            guard ["/mnt/", "/media/", "/srv/", "/data"].contains(where: { point.hasPrefix($0) }) else { continue }
            candidates.append((point + "/Homespun", (point as NSString).lastPathComponent))
        }
        #endif
        var seen = Set<String>()
        return candidates.compactMap { candidate in
            let path = URL(fileURLWithPath: candidate.path).standardizedFileURL.path
            guard seen.insert(path).inserted else { return nil }
            let space = OriginalsStore.space(at: path)
            return .init(path: path, name: candidate.name, freeBytes: space.free, capacityBytes: space.capacity,
                         isCurrent: path == current.standardizedFileURL.path)
        }
    }
}

extension Optional {
    func asyncMap<T>(_ transform: (Wrapped) async throws -> T) async rethrows -> T? {
        guard let value = self else { return nil }
        return try await transform(value)
    }
}
