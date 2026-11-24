// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import HomespunCore
import Hummingbird
import Logging

/// Where originals are kept: `<root>/<phone folder>/YYYY/MM/<name>`. The root is a setting of its
/// own, apart from the data folder (`--originals`, or moved from the app), so the catalog stores
/// paths relative to it and moving every original only changes the root.
actor OriginalsStore {
    /// Catalog setting holding a root chosen from the app (it wins over `--originals`).
    static let setting = "originals.root"

    private(set) var root: URL
    private var placing = 0
    struct Mutation: Equatable, Sendable { fileprivate let owner: UUID }
    private var mutation: Mutation?
    private var exclusive = false
    private var recoveryFailure: String?

    init(root: URL) { self.root = root.standardizedFileURL }

    /// A catalog path resolved inside the root; nil if it would escape it.
    func url(_ relative: String) -> URL? { Self.resolve(relative, in: root) }

    static func resolve(_ relative: String, in root: URL) -> URL? {
        let url = root.appendingPathComponent(relative).standardizedFileURL
        let realRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        let realPath = url.resolvingSymlinksInPath().standardizedFileURL.path
        return url.path.hasPrefix(root.standardizedFileURL.path + "/") && realPath.hasPrefix(realRoot + "/") ? url : nil
    }

    static func relative(_ url: URL, to root: URL) -> String {
        let rootPath = root.standardizedFileURL.path, path = url.standardizedFileURL.path
        return path.hasPrefix(rootPath + "/") ? String(path.dropFirst(rootPath.count + 1)) : path
    }

    /// Puts a new original in place (`body` gets the root to use) while no move is switching roots.
    func place<T: Sendable>(_ body: @Sendable (URL) async throws -> T) async throws -> T {
        while exclusive {
            if let recoveryFailure { throw HTTPError(.serviceUnavailable, message: recoveryFailure) }
            try await Task.sleep(for: .milliseconds(20))
        }
        if let recoveryFailure { throw HTTPError(.serviceUnavailable, message: recoveryFailure) }
        try Task.checkCancellation()
        placing += 1
        defer { placing -= 1 }
        return try await body(root)
    }

    /// Reserve exactly one rename/move owner. A mover can copy while placements continue,
    /// then upgrade its own reservation for the final switch. A second owner is refused.
    func reserveMutation() throws -> Mutation {
        if let recoveryFailure { throw OriginalsMover.Failure(description: recoveryFailure) }
        guard mutation == nil else { throw OriginalsMover.Failure(description: "The originals folder is already being changed.") }
        let lease = Mutation(owner: UUID())
        mutation = lease
        return lease
    }

    func makeExclusive(_ lease: Mutation) async throws {
        guard mutation == lease else { throw OriginalsMover.Failure(description: "The originals mutation lease expired.") }
        exclusive = true
        while placing > 0 { try await Task.sleep(for: .milliseconds(20)) }
        try Task.checkCancellation()
    }

    func releaseMutation(_ lease: Mutation, switchingTo newRoot: URL? = nil) {
        guard mutation == lease else { return }
        if let newRoot { root = newRoot.standardizedFileURL }
        mutation = nil
        exclusive = false
    }

    func requireRecovery(_ message: String) {
        recoveryFailure = message
        exclusive = true
    }

    func mutate<T: Sendable>(_ body: @Sendable (URL) async throws -> T) async throws -> T {
        let owner = try reserveMutation()
        do {
            try await makeExclusive(owner)
            let result = try await body(root)
            releaseMutation(owner)
            return result
        } catch {
            releaseMutation(owner)
            throw error
        }
    }

    /// An instance can have been constructed before another server moved the root.
    /// Only call while holding serving/offline ownership, before admitting other work.
    func refreshRoot(catalog: Catalog) async throws {
        guard let path = try await catalog.setting(Self.setting) else { return }
        let owner = try reserveMutation()
        do {
            try await makeExclusive(owner)
            releaseMutation(owner, switchingTo: URL(fileURLWithPath: path, isDirectory: true))
        } catch {
            releaseMutation(owner)
            throw error
        }
    }

    /// `<folder>/YYYY/MM/<name>` (by capture month) in `root`, adding part of the SHA-256 if
    /// another file already has the name.
    static func destination(root: URL, folder: String?, filename: String, sha256: String, captureDate: Date?) -> URL {
        let parts = captureDate.map { Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: $0) }
        let month = parts.map { String(format: "%04d/%02d", $0.year ?? 0, $0.month ?? 0) } ?? "undated"
        var directory = root
        if let folder {
            let safe = Storage.folderName(folder)
            directory.appendPathComponent(safe.isEmpty ? "iPhone" : safe, isDirectory: true)
        }
        directory.appendPathComponent(month, isDirectory: true)
        let name = Storage.sanitized(filename)
        return Trash.free(directory.appendingPathComponent(name), sha256: sha256)
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
/// originals for a moment, copy any that arrived meanwhile, then switch. Old good copies stay
/// until a separate, durable retirement policy can be established. Interrupted copies resume.
actor OriginalsMover {
    /// Catalog setting naming the move under way (`from` and `to`), so it resumes after a restart.
    static let setting = "originals.move"
    static let previousRootsSetting = "originals.previous_roots"

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
        let owner = try await store.reserveMutation()
        do {
            guard try await catalog.setting(DeviceRename.journal) == nil,
                  try await catalog.trashJournals().isEmpty else {
                throw Failure(description: "An interrupted rename or trash change needs recovery before moving originals.")
            }
            let from = await store.root
            let target = try Self.validate(path, current: from, dataDirectory: dataDirectory)
            if let saved = try await catalog.setting(Self.setting) {
                guard let plan = try? JSONDecoder().decode(Plan.self, from: Data(saved.utf8)),
                      plan.from == from.path, plan.to == target.path else {
                    throw Failure(description: "An interrupted originals move has a different destination; resume it before starting another.")
                }
            }
            let originals = try await catalog.storedOriginals()
            let needed = try StorageBytes.sum(originals.map(\.size))
            // On the same APFS disk copies are clones and take no space; elsewhere they need room.
            #if os(macOS)
            let clones = OriginalsStore.device(of: from.path) == OriginalsStore.device(of: target.path)
            #else
            let clones = false
            #endif
            if !clones, let free = OriginalsStore.space(at: target.path).free, free < (try StorageBytes.add(needed, 1 << 30)) {
                throw Failure(description: "That disk has \(Self.bytes(free)) free; the originals need \(Self.bytes(needed)) plus room to spare.")
            }
            do {
                if !FileManager.default.fileExists(atPath: target.path) {
                    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
                }
            } catch {
                throw Failure(description: "Homespun Server can't make \(target.path): \(error.localizedDescription)")
            }
            let probe = target.appendingPathComponent(".homespun-write-test-\(UUID().uuidString)")
            guard FileManager.default.createFile(atPath: probe.path, contents: Data()) else {
                throw Failure(description: "Homespun Server can't write to \(target.path).")
            }
            try FileManager.default.removeItem(at: probe)
            let plan = Plan(from: from.path, to: target.path)
            try await catalog.setSetting(Self.setting, String(decoding: try JSONEncoder().encode(plan), as: UTF8.self))
            launch(plan, owner: owner)
        } catch {
            await store.releaseMutation(owner)
            throw error
        }
    }

    /// Picks up a move the server was making when it stopped.
    func resume() async {
        guard !isMoving, !starting else { return }
        starting = true
        defer { starting = false }
        if let saved = try? await catalog.setting(Self.previousRootsSetting),
           let previous = try? JSONDecoder().decode([String].self, from: Data(saved.utf8)), !previous.isEmpty {
            logger.notice("previous originals folders are retained; cleanup is pending: \(previous.joined(separator: ", "))")
        }
        guard let text = try? await catalog.setting(Self.setting),
              let plan = try? JSONDecoder().decode(Plan.self, from: Data(text.utf8)) else { return }
        guard let owner = try? await store.reserveMutation() else { return }
        logger.notice("resuming the move of originals to \(plan.to)")
        launch(plan, owner: owner)
    }

    /// Waits for the move under way to end (for tests and tools).
    func wait() async { await task?.value }

    func stop() async {
        task?.cancel()
        await task?.value
    }

    private func launch(_ plan: Plan, owner: OriginalsStore.Mutation) {
        status = .init(state: .copying, from: plan.from, to: plan.to, copied: 0, total: 0, copiedBytes: 0, totalBytes: 0)
        task = Task { await run(plan, owner: owner) }
    }

    private func run(_ plan: Plan, owner: OriginalsStore.Mutation) async {
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
            try await store.makeExclusive(owner)
            // The switch happens only when every stored original is among those copied.
            var switched = false
            for _ in 0..<5 where !switched {
                try await copy(try await pendingOriginals(excluding: copied), from: from, to: to, into: &copied)
                switched = try await catalog.switchOriginals(to: to.path, copied: copied).isEmpty
            }
            guard switched else { throw Failure(description: "new originals kept arriving; try again") }
            await store.releaseMutation(owner, switchingTo: to)
            await catalog.log("originals_moved", detail: "\(from.path) -> \(to.path) (\(copied.count) files)")
            logger.notice("moved \(copied.count) originals to \(to.path)")

            // Keep the previous good copies. A delay/hash readback is not a filesystem
            // durability barrier, and readers may still have the old paths open.
            status?.state = .done
            status?.message = "Originals now use the new folder. Previous copies remain in \(from.path); cleanup is pending."
            status?.finishedAt = Date()
        } catch {
            logger.error("moving originals to \(to.path) failed: \(error)")
            // Nothing switched, so the originals are all still where they were. A missing disk
            // keeps the plan, so the move continues when the server starts with it connected.
            // The plan is also useful after I/O errors or cancellation; never discard it.
            status?.state = .failed
            status?.message = "\(error)"
            status?.finishedAt = Date()
        }
        await store.releaseMutation(owner)
    }

    private func pendingOriginals(excluding copied: Set<String>) async throws
        -> [(assetID: String, role: ServerAPI.ResourceRole, path: String, size: Int, sha256: String)] {
        let all = try await catalog.storedOriginals()
        status?.total = all.count
        status?.totalBytes = try StorageBytes.sum(all.map(\.size))
        return all.filter { !copied.contains($0.path) }
    }

    private func copy(_ originals: [(assetID: String, role: ServerAPI.ResourceRole, path: String, size: Int, sha256: String)],
                      from: URL, to: URL, into copied: inout Set<String>) async throws {
        for original in originals {
            try Task.checkCancellation()
            guard let source = OriginalsStore.resolve(original.path, in: from),
                  let target = OriginalsStore.resolve(original.path, in: to) else {
                throw Failure(description: "\(original.path) is not a safe path")
            }
            try await detached { try Self.copyChecked(source, to: target, root: to, sha256: original.sha256, size: original.size) }
            copied.insert(original.path)
            status?.copied = copied.count
            let previouslyCopied = status?.copiedBytes ?? 0
            status?.copiedBytes = try StorageBytes.add(previouslyCopied, Int64(original.size))
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
        let partial = target.deletingLastPathComponent().appendingPathComponent(".homespun-move-\(UUID().uuidString).partial")
        defer { try? files.removeItem(at: partial) }
        try files.copyItem(at: source, to: partial)
        guard try Fingerprint.sha256(of: partial) == sha256, try JobRunner.size(of: partial) == size else {
            try? files.removeItem(at: partial)
            throw Failure(description: "The copy of \(source.lastPathComponent) didn't match the original.")
        }
        try files.setAttributes([.posixPermissions: 0o440], ofItemAtPath: partial.path)
        try files.moveItem(at: partial, to: target)
    }

    /// A folder the originals may move to, as an absolute URL. In a container, it must be on a volume
    /// mounted from the host (`mounts`, from /proc/self/mountinfo): anywhere else is the container's
    /// own disk, which goes away when the container is recreated, with every original in it.
    static func validate(_ path: String, current: URL, dataDirectory: URL,
                         container: Bool = HostPlatform.hardware.kind == .container,
                         mounts: [String] = ContainerMounts.read()) throws -> URL {
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
        let source = current.resolvingSymlinksInPath().standardizedFileURL.path
        guard !resolved.hasPrefix(source + "/"), !source.hasPrefix(resolved + "/") else {
            throw Failure(description: "The old and new originals folders must not contain one another.")
        }
        guard resolved != data, !resolved.hasPrefix(data + "/") else {
            throw Failure(description: "That's inside Homespun Server's own data folder; pick another folder.")
        }
        if container, !ContainerMounts.isOnVolume(resolved, mounts: mounts) {
            throw Failure(description: "\(target.path) isn't on a folder shared with the container, so originals there "
                + "would be lost when the container is updated. Map a folder from the NAS in compose.yaml "
                + "(volumes) and move them there.")
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

/// The folders mounted into a container from the host (volumes and binds).
enum ContainerMounts {
    /// Mount points from /proc/self/mountinfo, except the container's own root and system folders.
    static func read(_ text: String? = try? String(contentsOfFile: "/proc/self/mountinfo", encoding: .utf8)) -> [String] {
        guard let text else { return [] }
        let system = ["/", "/proc", "/sys", "/dev", "/etc/hosts", "/etc/hostname", "/etc/resolv.conf"]
        return text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ")
            guard fields.count > 4 else { return nil }
            // Field 5 is the mount point, with spaces and the like escaped as octal (\040).
            let point = String(fields[4]).replacingOccurrences(of: "\\040", with: " ")
            guard !system.contains(point), !system.dropFirst().contains(where: { point.hasPrefix($0 + "/") }) else { return nil }
            return point
        }
    }

    static func isOnVolume(_ path: String, mounts: [String]) -> Bool {
        mounts.contains { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }
}
