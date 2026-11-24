// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import HomespunCore

/// Renames a paired phone: its name, and the folder its originals are in (`<originals>/<folder>`,
/// and its items' folders in the server's trash), so the folder always reads as the name the person
/// chose. Safe to stop at any point: a journal goes into the catalog first, the folders move, then
/// one transaction updates the catalog and ends the journal. A journal found at startup means the
/// catalog never changed, so `recover` moves the folders back.
struct DeviceRename: Sendable {
    static let journal = "device.rename"

    struct Plan: Codable, Equatable, Sendable {
        var device: String
        var from: String
        var to: String
        /// Trash folders (`.trash/<item>`) holding a `from` folder of this phone's items.
        var trash: [String]
        /// A rename that changes only letter case goes through this name (case-insensitive disks).
        var via: String?
        var hadFolder: Bool? = nil
    }

    enum Failure: Error, CustomStringConvertible {
        case invalid(String), notFound, taken(String), busy(String), unavailable(String)

        var description: String {
            switch self {
            case .invalid(let message), .taken(let message), .busy(let message), .unavailable(let message): message
            case .notFound: "No such device."
            }
        }
    }

    let catalog: Catalog
    let originals: OriginalsStore
    let mover: OriginalsMover

    /// `path` with the phone's folder `from` changed to `to`, stored or in the trash; nil if it isn't in it.
    static func moved(_ path: String, from: String, to: String) -> String? {
        if path.hasPrefix(from + "/") { return to + path.dropFirst(from.count) }
        if let original = Trash.restored(path), original.hasPrefix(from + "/") {
            return String(path.dropLast(original.count)) + to + original.dropFirst(from.count)
        }
        return nil
    }

    func rename(device id: String, to typed: String) async throws -> DeviceRecord {
        let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = Storage.folderName(name)
        guard !name.isEmpty, name.count <= ServerAPI.RenameDeviceRequest.maximumLength, !folder.isEmpty else {
            throw Failure.invalid("Use a name of 1 to \(ServerAPI.RenameDeviceRequest.maximumLength) characters, with letters or numbers.")
        }
        let owner: OriginalsStore.Mutation
        do { owner = try await originals.reserveMutation() }
        catch { throw Failure.busy("The originals folder is already being changed or needs recovery.") }
        do {
            try await originals.makeExclusive(owner)
            // Read only after admission: an earlier rename may have changed both names.
            guard let device = try await catalog.devices().first(where: { $0.id == id && $0.revokedAt == nil }) else {
                throw Failure.notFound
            }
            guard try await catalog.setting(Self.journal) == nil,
                  try await catalog.setting(OriginalsMover.setting) == nil,
                  try await catalog.trashJournals().isEmpty else {
                throw Failure.busy("An originals folder change needs to finish before renaming this device.")
            }
            let renamed = try await renameFrozen(device, name: name, folder: folder)
            await originals.releaseMutation(owner)
            return renamed
        } catch {
            await originals.releaseMutation(owner)
            throw error
        }
    }

    private func renameFrozen(_ device: DeviceRecord, name: String, folder: String) async throws -> DeviceRecord {
        let id = device.id
        let root = await originals.root
        let catalog = catalog
        let others = try await catalog.devices().filter { $0.id != id && $0.revokedAt == nil }
        if let other = others.first(where: { $0.folder?.lowercased() == folder.lowercased() }) {
            throw Failure.taken("\(other.name) already uses the name “\(folder)”. Choose another.")
        }
        let from = device.folder
        guard let from, from != folder else {
            try await catalog.renameDevice(id, name: name, folder: folder, from: from, journal: Self.journal)
            return try await updated(id)
        }
        let fileManager = FileManager.default
        let source = root.appendingPathComponent(from, isDirectory: true)
        let target = root.appendingPathComponent(folder, isDirectory: true)
        let data = catalog.dataDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        let moving = source.resolvingSymlinksInPath().standardizedFileURL.path
        guard data != moving, !data.hasPrefix(moving + "/") else {
            throw Failure.unavailable("That phone folder contains the server's data directory; it cannot be renamed.")
        }
        let caseOnly = from.lowercased() == folder.lowercased()
        let hasFolder = fileManager.fileExists(atPath: source.path)
        if !fileManager.fileExists(atPath: root.path), try await catalog.storedOriginalCount() > 0 {
            throw Failure.unavailable("The originals folder \(root.path) isn't available (is its disk connected?).")
        }
        if fileManager.fileExists(atPath: target.path),
           !caseOnly || !OriginalsMover.sameFile(source, target) {
            throw Failure.taken("There's already a folder named “\(folder)” in \(root.path). Choose another name.")
        }
        let trash = try await catalog.trashFolders(device: id).filter {
            fileManager.fileExists(atPath: root.appendingPathComponent($0).appendingPathComponent(from).path)
        }
        let plan = Plan(device: id, from: from, to: folder, trash: trash,
                        via: caseOnly ? ".homespun-rename-\(UUID().uuidString)" : nil, hadFolder: hasFolder)
        try await catalog.setSetting(Self.journal, String(decoding: try JSONEncoder().encode(plan), as: UTF8.self))
        do {
            if hasFolder { try Self.move(source, to: target, via: plan.via.map { root.appendingPathComponent($0) }) }
            for item in trash {
                let base = root.appendingPathComponent(item, isDirectory: true)
                try Self.move(base.appendingPathComponent(from), to: base.appendingPathComponent(folder),
                              via: plan.via.map { base.appendingPathComponent($0) })
            }
            try await catalog.renameDevice(id, name: name, folder: folder, from: from, journal: Self.journal)
        } catch {
            do {
                try await Self.recover(catalog: catalog, root: root)
            } catch let recovery {
                await originals.requireRecovery("An interrupted device rename needs recovery: \(recovery)")
                throw Failure.unavailable("The rename could not be rolled back; its recovery journal was kept. \(recovery)")
            }
            throw error
        }
        return try await updated(id)
    }

    private func updated(_ id: String) async throws -> DeviceRecord {
        guard let device = try await catalog.devices().first(where: { $0.id == id }) else { throw Failure.notFound }
        return device
    }

    /// The journal describes both steps of a case-only move, including its intermediate name.
    private static func move(_ from: URL, to: URL, via: URL?) throws {
        if let via {
            try FileManager.default.moveItem(at: from, to: via)
            try FileManager.default.moveItem(at: via, to: to)
        } else {
            try FileManager.default.moveItem(at: from, to: to)
        }
    }

    /// At startup: a journal means the server stopped mid-rename before the catalog changed, so
    /// the folders go back where the catalog says they are.
    static func recover(catalog: Catalog, root: URL) async throws {
        guard let saved = try await catalog.setting(journal) else { return }
        let plan = try JSONDecoder().decode(Plan.self, from: Data(saved.utf8))
        guard Storage.folderName(plan.from) == plan.from, !plan.from.isEmpty,
              Storage.folderName(plan.to) == plan.to, !plan.to.isEmpty,
              plan.via.map({ $0.hasPrefix(".homespun-rename-") && !$0.contains("/") }) ?? true else {
            throw Failure.unavailable("The device rename journal has unsafe paths; it was kept for repair.")
        }
        try Trash.requireRoot(root)
        var bases = plan.hadFolder == false ? [] : [root]
        for path in plan.trash {
            guard path.hasPrefix(".trash/"), path.split(separator: "/").count == 2,
                  let base = OriginalsStore.resolve(path, in: root) else {
                throw Failure.unavailable("The device rename journal has an unsafe trash path.")
            }
            bases.append(base)
        }
        for base in bases {
            let original = base.appendingPathComponent(plan.from), renamed = base.appendingPathComponent(plan.to)
            let files = FileManager.default
            let names = try files.contentsOfDirectory(atPath: base.path)
            let oldExists = names.contains(plan.from), newExists = names.contains(plan.to)
            let via = plan.via.map { base.appendingPathComponent($0) }
            let viaExists = via.map { files.fileExists(atPath: $0.path) } ?? false
            guard [oldExists, newExists, viaExists].filter({ $0 }).count == 1 else {
                throw Failure.unavailable("Cannot reconcile \(base.path): the rename paths are missing or collide. The journal was kept.")
            }
            if oldExists { continue }
            if viaExists, let via {
                try files.moveItem(at: via, to: original)
            } else if let via {
                try files.moveItem(at: renamed, to: via)
                try files.moveItem(at: via, to: original)
            } else {
                try files.moveItem(at: renamed, to: original)
            }
        }
        try await catalog.setSetting(journal, nil)
        await catalog.log("device_rename_undone", device: nil, detail: saved)
    }
}
