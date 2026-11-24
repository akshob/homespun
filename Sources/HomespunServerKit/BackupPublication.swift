// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import HomespunCore
import Hummingbird

enum BackupPublication {
    static func partial(_ id: String, storage: Storage) -> URL {
        storage.staging.appendingPathComponent("v2-" + id + ".partial")
    }

    /// The caller owns the object/upload claims and a root placement lease. The journal
    /// participates in root moves/renames even if publication stops before its catalog commit.
    static func finish(_ upload: BackupUpload, catalog: Catalog, storage: Storage, root: URL) async throws -> BackupAPI.Receipt {
        try Trash.requireRoot(root)
        let relative: String
        if let saved = try await catalog.backupPublicationPath(upload.id) {
            relative = saved
        } else {
            let folder = try await catalog.backupObjectDirectory(upload.object.manifest)
            relative = folder + "/"
                + upload.object.role.rawValue + "-" + Storage.sanitized(upload.object.filename)
        }
        guard let target = OriginalsStore.resolve(relative, in: root) else { throw HTTPError(.conflict) }
        try await catalog.prepareBackupPublication(upload, path: relative)
        if FileManager.default.fileExists(atPath: target.path) {
            let actual = try await detached { try Fingerprint.digests(of: target) }
            guard actual.sha256 == upload.object.sha256, actual.size == upload.object.size else {
                throw HTTPError(.conflict, message: "The publication destination collides; its journal was retained.")
            }
        } else {
            let input = partial(upload.id, storage: storage)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let staging = target.deletingLastPathComponent().appendingPathComponent(".v2-" + upload.id + ".partial")
            guard OriginalsStore.resolve(OriginalsStore.relative(staging, to: root), in: root) != nil else {
                throw HTTPError(.conflict)
            }
            defer { try? FileManager.default.removeItem(at: staging) }
            let existing = FileManager.default.fileExists(atPath: staging.path)
                ? try await detached { try Fingerprint.digests(of: staging) } : nil
            if existing?.sha256 != upload.object.sha256 || existing?.size != upload.object.size {
                let source = try await detached { try Fingerprint.digests(of: input) }
                guard source.sha256 == upload.object.sha256, source.size == upload.object.size else {
                    throw HTTPError(.conflict, message: "The staged bytes changed; publication was not committed.")
                }
                if FileManager.default.fileExists(atPath: staging.path) { try FileManager.default.removeItem(at: staging) }
                let copied = try await detached { try Fingerprint.copy(from: input, to: staging) }
                guard copied.sha256 == upload.object.sha256, copied.size == upload.object.size else {
                    throw HTTPError(.conflict, message: "The publication copy changed; its journal was retained.")
                }
            }
            try BackupDurability.publish(staging, root: root)
            try FileManager.default.moveItem(at: staging, to: target)
        }
        try BackupDurability.publish(target, root: root)
        let receipt = try await catalog.completeBackupUpload(upload, path: relative)
        try FileManager.default.setAttributes([.posixPermissions: 0o440], ofItemAtPath: target.path)
        try? FileManager.default.removeItem(at: partial(upload.id, storage: storage))
        return receipt
    }

    static func recover(catalog: Catalog, storage: Storage, originals: OriginalsStore) async throws {
        for upload in try await catalog.pendingBackupPublications() {
            _ = try await originals.place { root in
                try await finish(upload, catalog: catalog, storage: storage, root: root)
            }
        }
    }
}
