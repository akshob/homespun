// SPDX-License-Identifier: Apache-2.0
import Foundation
import os

struct BackupFiles: Sendable {
    let root: URL
    var database: URL { root.appendingPathComponent("backup.sqlite") }
    var staging: URL { root.appendingPathComponent("staging", isDirectory: true) }
    var inbox: URL { root.appendingPathComponent("inbox", isDirectory: true) }
    var resume: URL { root.appendingPathComponent("resume", isDirectory: true) }

    static var defaultRoot: URL {
        URL.applicationSupportDirectory.appendingPathComponent("Homespun/Backup", isDirectory: true)
    }

    enum Failure: Error, LocalizedError {
        case invalidFile
        var errorDescription: String? { "Homespun's backup workspace is not a protected regular file or folder." }
    }

    func prepare() throws {
        try Self.directory(root, excludedFromBackup: false)
        for folder in [staging, inbox, resume] { try Self.directory(folder, excludedFromBackup: true) }
    }

    func protectDatabase() throws {
        for suffix in ["", "-wal", "-shm"] {
            let url = URL(fileURLWithPath: database.path + suffix)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            try Self.protect(url)
        }
    }

    func stagedFile(operationID: UUID, fileID: UUID) -> URL {
        staging.appendingPathComponent(operationID.uuidString, isDirectory: true).appendingPathComponent(fileID.uuidString)
    }

    func prepareStaging(operationID: UUID) throws -> URL {
        let directory = staging.appendingPathComponent(operationID.uuidString, isDirectory: true)
        try Self.directory(directory, excludedFromBackup: true)
        return directory
    }

    func spaceObservation() throws -> BackupSpaceObservation {
        let capacity = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
        var total: Int64 = 0
        let enumerationError = OSAllocatedUnfairLock<(any Error)?>(initialState: nil)
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        for folder in [staging, inbox, resume] {
            guard let iterator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Array(keys),
                errorHandler: { _, error in enumerationError.withLock { $0 = error }; return false }) else {
                throw Failure.invalidFile
            }
            for case let url as URL in iterator {
                let values = try url.resourceValues(forKeys: keys)
                guard values.isSymbolicLink != true else { throw Failure.invalidFile }
                if values.isRegularFile == true {
                    guard let size = values.fileSize, size >= 0 else { throw Failure.invalidFile }
                    let (next, overflow) = total.addingReportingOverflow(Int64(size))
                    guard !overflow else { throw BackupSpaceFailure.workingSpaceRequired }
                    total = next
                }
            }
            if let error = enumerationError.withLock({ $0 }) { throw error }
        }
        return .init(availableBytes: capacity, transientBytes: total)
    }

    static func protect(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true || values.isDirectory == true else {
            throw Failure.invalidFile
        }
        try FileManager.default.setAttributes([
            .posixPermissions: values.isDirectory == true ? 0o700 : 0o600,
            .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
        ], ofItemAtPath: url.path)
    }

    private static func directory(_ url: URL, excludedFromBackup: Bool) throws {
        guard url.isFileURL else { throw Failure.invalidFile }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [
            .posixPermissions: 0o700,
            .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
        ])
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw Failure.invalidFile }
        try protect(url)
        var resource = URLResourceValues()
        resource.isExcludedFromBackup = excludedFromBackup
        var mutableURL = url
        try mutableURL.setResourceValues(resource)
    }
}
