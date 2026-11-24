// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Captures file ownership synchronously; it does not authorize an origin or make a transport safe.
struct BackupInbox: Sendable {
    struct Capture: Codable, Equatable, Sendable {
        var id: UUID
        var transferID: UUID
        var sessionID: UUID
        var taskID: Int?
        var status: Int
        var scheme: String
        var host: String
        var port: Int
        var bytes: Int64
        var etag: String?
        var contentRange: String?
    }

    struct Orphan: Equatable, Sendable {
        var id: UUID
        var transferID: UUID
        var url: URL
    }

    enum Failure: Error, LocalizedError {
        case invalidResponse
        case invalidMetadata

        var errorDescription: String? { "The downloaded copy could not be captured safely. Its backup has not been changed." }
    }

    let files: BackupFiles

    func capture(_ temporary: URL, transferID: UUID, sessionID: UUID, taskID: Int? = nil,
                 response: HTTPURLResponse) throws -> Capture {
        guard [200, 206].contains(response.statusCode), let url = response.url, url.scheme == "https",
              let host = url.host, !host.isEmpty, (1...65_535).contains(url.port ?? 443) else {
            throw Failure.invalidResponse
        }
        let etag = response.value(forHTTPHeaderField: "ETag")
        let range = response.value(forHTTPHeaderField: "Content-Range")
        guard (etag?.utf8.count ?? 0) <= 512, (range?.utf8.count ?? 0) <= 512 else { throw Failure.invalidResponse }
        let attributes = try temporary.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
              let size = attributes.fileSize, size > 0 else { throw Failure.invalidResponse }
        try files.prepare()
        let capture = Capture(id: UUID(), transferID: transferID, sessionID: sessionID, taskID: taskID,
                              status: response.statusCode, scheme: "https", host: host, port: url.port ?? 443,
                              bytes: Int64(size), etag: etag, contentRange: range)
        let destination = file(capture)
        try FileManager.default.moveItem(at: temporary, to: destination)
        // A failure from here leaves an identifiable orphan for reconciliation, never deletes it.
        try BackupFiles.protect(destination)
        try Self.flush(destination)
        let metadata = sidecar(capture)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(capture).write(to: metadata, options: .atomic)
        try BackupFiles.protect(metadata)
        try Self.flush(metadata)
        return capture
    }

    func file(_ capture: Capture) -> URL {
        files.inbox.appendingPathComponent("\(capture.transferID.uuidString).\(capture.id.uuidString).download")
    }

    func sidecar(_ capture: Capture) -> URL { file(capture).deletingPathExtension().appendingPathExtension("json") }

    func captures() throws -> [Capture] {
        let entries = try FileManager.default.contentsOfDirectory(at: files.inbox,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return try entries.filter { $0.pathExtension == "json" }.map { url in
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw Failure.invalidMetadata }
            let capture = try JSONDecoder().decode(Capture.self, from: Data(contentsOf: url))
            guard sidecar(capture).lastPathComponent == url.lastPathComponent,
                  capture.bytes > 0, capture.scheme == "https", [200, 206].contains(capture.status),
                  !capture.host.isEmpty, (1...65_535).contains(capture.port) else { throw Failure.invalidMetadata }
            return capture
        }
    }

    func orphans() throws -> [Orphan] {
        let entries = try FileManager.default.contentsOfDirectory(at: files.inbox,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        var result: [Orphan] = []
        for url in entries where url.pathExtension == "download" {
            let components = url.deletingPathExtension().lastPathComponent.split(separator: ".")
            guard components.count == 2, let transfer = UUID(uuidString: String(components[0])),
                  let id = UUID(uuidString: String(components[1])) else { throw Failure.invalidMetadata }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw Failure.invalidMetadata }
            let metadata = url.deletingPathExtension().appendingPathExtension("json")
            do { _ = try metadata.resourceValues(forKeys: [.isRegularFileKey]) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                result.append(.init(id: id, transferID: transfer, url: url))
            }
        }
        return result
    }

    func removeSidecar(_ capture: Capture) throws {
        do { try FileManager.default.removeItem(at: sidecar(capture)) }
        catch let error as CocoaError where error.code == .fileNoSuchFile { return }
    }

    private static func flush(_ url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }
}
