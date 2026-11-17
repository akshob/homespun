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
        guard let device = try await catalog.devices().first(where: { $0.id == id && $0.revokedAt == nil }) else {
            throw Failure.notFound
        }
        guard await !mover.isMoving else {
            throw Failure.busy("The originals are moving to another folder. Rename this device once that's done.")
        }
        // No new original is placed while the folder moves (an upload finishing now waits, then
        // goes into the new folder).
        await originals.freeze()
        do {
            let renamed = try await renameFrozen(device, name: name, folder: folder)
            await originals.unfreeze()
            return renamed
        } catch {
            await originals.unfreeze()
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
        let caseOnly = from.lowercased() == folder.lowercased()
        let hasFolder = fileManager.fileExists(atPath: source.path)
        if !fileManager.fileExists(atPath: root.path), try await catalog.storedOriginalCount() > 0 {
            throw Failure.unavailable("The originals folder \(root.path) isn't available (is its disk connected?).")
        }
        if !caseOnly, fileManager.fileExists(atPath: target.path) {
            throw Failure.taken("There's already a folder named “\(folder)” in \(root.path). Choose another name.")
        }
        let trash = try await catalog.trashFolders(device: id).filter {
            fileManager.fileExists(atPath: root.appendingPathComponent($0).appendingPathComponent(from).path)
        }
        let plan = Plan(device: id, from: from, to: folder, trash: trash,
                        via: caseOnly ? ".homespun-rename-\(UUID().uuidString)" : nil)
        try await catalog.setSetting(Self.journal, String(decoding: try JSONEncoder().encode(plan), as: UTF8.self))
        var done: [(URL, URL)] = []
        do {
            if hasFolder { try Self.move(source, to: target, via: plan.via.map { root.appendingPathComponent($0) }, done: &done) }
            for item in trash {
                let base = root.appendingPathComponent(item, isDirectory: true)
                try Self.move(base.appendingPathComponent(from), to: base.appendingPathComponent(folder),
                              via: plan.via.map { base.appendingPathComponent($0) }, done: &done)
            }
            try await catalog.renameDevice(id, name: name, folder: folder, from: from, journal: Self.journal)
        } catch {
            for (moved, back) in done.reversed() { try? fileManager.moveItem(at: moved, to: back) }
            try? await catalog.setSetting(Self.journal, nil)
            throw error
        }
        return try await updated(id)
    }

    private func updated(_ id: String) async throws -> DeviceRecord {
        guard let device = try await catalog.devices().first(where: { $0.id == id }) else { throw Failure.notFound }
        return device
    }

    /// Moves a folder (through `via` when only the letter case changes), recording each step.
    private static func move(_ from: URL, to: URL, via: URL?, done: inout [(URL, URL)]) throws {
        if let via {
            try FileManager.default.moveItem(at: from, to: via)
            done.append((via, from))
            try FileManager.default.moveItem(at: via, to: to)
            done.append((to, via))
        } else {
            try FileManager.default.moveItem(at: from, to: to)
            done.append((to, from))
        }
    }

    /// At startup: a journal means the server stopped mid-rename before the catalog changed, so
    /// the folders go back where the catalog says they are.
    static func recover(catalog: Catalog, root: URL) async throws {
        guard let saved = try await catalog.setting(journal) else { return }
        if let plan = try? JSONDecoder().decode(Plan.self, from: Data(saved.utf8)) {
            let bases = [root] + plan.trash.map { root.appendingPathComponent($0, isDirectory: true) }
            for base in bases {
                let original = base.appendingPathComponent(plan.from), renamed = base.appendingPathComponent(plan.to)
                let fileManager = FileManager.default
                if let via = plan.via.map({ base.appendingPathComponent($0) }), fileManager.fileExists(atPath: via.path) {
                    try? fileManager.moveItem(at: via, to: original)
                } else if plan.via == nil, fileManager.fileExists(atPath: renamed.path),
                          !fileManager.fileExists(atPath: original.path) {
                    try? fileManager.moveItem(at: renamed, to: original)
                } else if plan.via != nil, fileManager.fileExists(atPath: renamed.path),
                          (try? fileManager.contentsOfDirectory(atPath: base.path))?.contains(plan.to) == true {
                    // Case-only: the folder has the new case already; put the old case back.
                    let via = base.appendingPathComponent(".homespun-rename-recover")
                    try? fileManager.moveItem(at: renamed, to: via)
                    try? fileManager.moveItem(at: via, to: original)
                }
            }
        }
        try await catalog.setSetting(journal, nil)
        await catalog.log("device_rename_undone", device: nil, detail: saved)
    }
}
