// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import Synchronization
import UniformTypeIdentifiers

/// PhotoKit requires a typed URL as well as a declared UTI. The verified UUID file remains authoritative.
struct PhotoResourceHandoff: Sendable {
    struct Identity: Hashable, Sendable {
        var device: dev_t
        var inode: ino_t
    }

    struct File: Sendable {
        var identity: Identity
        var bytes: Int64
    }

    struct Orphan: Sendable {
        var operationID: UUID
        var id: UUID
        var directory: URL
    }

    enum Failure: Error, LocalizedError, Equatable {
        case invalidResource, unprovenAlias, cleanup(String)
        var errorDescription: String? {
            switch self {
            case .invalidResource: "The verified Photos resource could not be linked safely. Its original working file was kept."
            case .unprovenAlias: "A Photos handoff has unproven ownership. Its files were kept for recovery."
            case .cleanup(let message): message
            }
        }
    }

    static let folderName = ".photos-handoffs"
    private static let active = Mutex<Set<UUID>>([])
    private var id: UUID?
    private var directory: URL?
    private var links: [(alias: URL, source: URL)] = []
    var resources: [PreparedPhotoResource]

    static func file(_ url: URL) throws -> File {
        guard url.isFileURL else { throw Failure.invalidResource }
        var value = stat()
        guard lstat(url.path, &value) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard value.st_mode & S_IFMT == S_IFREG, value.st_size >= 0 else { throw Failure.invalidResource }
        return .init(identity: .init(device: value.st_dev, inode: value.st_ino), bytes: value.st_size)
    }

    private static func prepare(_ files: [PreparedPhotoResource]) throws -> Self {
        var result = Self(resources: files)
        let opaque = files.filter { $0.url.pathExtension.isEmpty }
        guard let first = opaque.first else { return result }
        let parent = first.url.deletingLastPathComponent(), staging = parent.deletingLastPathComponent()
        guard staging.lastPathComponent == "staging", let operation = UUID(uuidString: parent.lastPathComponent),
              opaque.allSatisfy({ $0.url.deletingLastPathComponent() == parent
                  && $0.url.lastPathComponent == $0.fileID.uuidString }) else { throw Failure.invalidResource }
        try validateDirectory(staging)
        try validateDirectory(parent)
        let id = UUID()
        result.id = id
        active.withLock { $0.insert(id) }
        do {
            let root = staging.appendingPathComponent(folderName, isDirectory: true)
            try BackupFiles.prepareTransientDirectory(root)
            let directory = root.appendingPathComponent(operation.uuidString + "." + id.uuidString, isDirectory: true)
            result.directory = directory
            try BackupFiles.prepareTransientDirectory(directory)
            for index in files.indices where files[index].url.pathExtension.isEmpty {
                let resource = files[index]
                let declared = (resource.descriptor.filename as NSString).pathExtension
                guard let suffix = UTType(filenameExtension: declared)?.preferredFilenameExtension,
                      !suffix.isEmpty, resource.descriptor.size > 0 else { throw Failure.invalidResource }
                let original = try file(resource.url)
                guard original.bytes == Int64(resource.descriptor.size) else { throw Failure.invalidResource }
                let alias = directory.appendingPathComponent(resource.fileID.uuidString).appendingPathExtension(suffix)
                try FileManager.default.linkItem(at: resource.url, to: alias)
                result.links.append((alias, resource.url))
                guard try file(alias).identity == original.identity,
                      try file(resource.url).identity == original.identity else { throw Failure.invalidResource }
                try BackupFiles.protect(alias)
                result.resources[index].url = alias
            }
            return result
        } catch let failure {
            do { try result.finish() }
            catch { throw Failure.cleanup("\(failure.localizedDescription) \(error.localizedDescription)") }
            throw failure
        }
    }

    static func use(_ files: [PreparedPhotoResource],
                    _ operation: @Sendable ([PreparedPhotoResource]) async throws -> String) async throws -> String {
        let handoff = try prepare(files)
        let result: Result<String, any Error>
        do { result = .success(try await operation(handoff.resources)) }
        catch { result = .failure(error) }
        do { try handoff.finish() }
        catch let cleanup {
            let identifier: String?
            let problem: String
            switch result {
            case .success(let created): identifier = created; problem = cleanup.localizedDescription
            case .failure(let failure):
                if let created = failure as? PhotosCreationFailure { identifier = created.identifier }
                else if let original = failure as? PhotoLibrary.Failure,
                        case .restoreMetadata(let created, _) = original { identifier = created }
                else { identifier = nil }
                problem = "\(failure.localizedDescription) \(cleanup.localizedDescription)"
            }
            if let identifier { throw PhotosCreationFailure(identifier: identifier, message: problem) }
            throw Failure.cleanup(problem)
        }
        return try result.get()
    }

    private func finish() throws {
        defer { if let id { Self.active.withLock { $0.remove(id) } } }
        for link in links { try Self.removeAlias(link.alias, source: link.source) }
        if let directory { try Self.removeEmptyDirectory(directory) }
    }

    private static func removeAlias(_ alias: URL, source: URL) throws {
        guard FileManager.default.fileExists(atPath: alias.path) else { return }
        guard try file(alias).identity == file(source).identity else { throw Failure.unprovenAlias }
        try FileManager.default.removeItem(at: alias)
    }

    private static func removeEmptyDirectory(_ directory: URL) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try validateDirectory(directory)
        guard try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty else { throw Failure.unprovenAlias }
        try FileManager.default.removeItem(at: directory)
    }

    private static func validateDirectory(_ directory: URL) throws {
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw Failure.unprovenAlias }
    }

    static func isActive(_ id: UUID) -> Bool { active.withLock { $0.contains(id) } }

    static func orphans(in staging: URL, includingActive: Bool = false) throws -> [Orphan] {
        let root = staging.appendingPathComponent(folderName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        let values = try root.resourceValues(forKeys: keys)
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw Failure.unprovenAlias }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys)).compactMap { url in
            let values = try url.resourceValues(forKeys: keys)
            let parts = url.lastPathComponent.split(separator: ".")
            guard values.isDirectory == true, values.isSymbolicLink != true, parts.count == 2,
                  let operation = UUID(uuidString: String(parts[0])), let id = UUID(uuidString: String(parts[1])) else {
                throw Failure.unprovenAlias
            }
            guard includingActive || !isActive(id) else { return nil }
            return .init(operationID: operation, id: id, directory: url)
        }
    }

    static func clean(_ orphan: Orphan, in staging: URL) throws {
        guard !active.withLock({ $0.contains(orphan.id) }) else { return }
        guard FileManager.default.fileExists(atPath: orphan.directory.path) else { return }
        let parent = staging.appendingPathComponent(orphan.operationID.uuidString, isDirectory: true)
        try validateDirectory(staging)
        try validateDirectory(orphan.directory.deletingLastPathComponent())
        try validateDirectory(orphan.directory)
        try validateDirectory(parent)
        for alias in try FileManager.default.contentsOfDirectory(at: orphan.directory, includingPropertiesForKeys: nil) {
            guard let id = UUID(uuidString: alias.deletingPathExtension().lastPathComponent),
                  !alias.pathExtension.isEmpty else { throw Failure.unprovenAlias }
            let original = parent.appendingPathComponent(id.uuidString)
            try removeAlias(alias, source: original)
        }
        try removeEmptyDirectory(orphan.directory)
    }
}
