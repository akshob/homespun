// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import Homespun

@Test func downloadCaptureOwnsTheFileBeforeReturningAndCanRecoverAnOrphan() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let files = BackupFiles(root: root)
    try files.prepare()
    let temporary = root.appendingPathComponent("temporary-download")
    let bytes = Data("complete immutable derivative".utf8)
    try bytes.write(to: temporary)
    let response = try #require(HTTPURLResponse(url: URL(string: "https://server.invalid/api/v2/derivatives/id/resources/photo")!,
        statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["ETag": "\"immutable\""]))
    let inbox = BackupInbox(files: files)
    let capture = try inbox.capture(temporary, transferID: UUID(), sessionID: UUID(), taskID: 4, response: response)
    #expect(!FileManager.default.fileExists(atPath: temporary.path))
    #expect(try Data(contentsOf: inbox.file(capture)) == bytes)
    #expect(try inbox.captures() == [capture])
    try inbox.removeSidecar(capture)
    #expect(try inbox.orphans().map(\.transferID) == [capture.transferID])
    #expect(try Data(contentsOf: inbox.file(capture)) == bytes)
}

@Test func downloadCaptureDoesNotTreatAnErrorBodyAsAnImportedCopy() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let files = BackupFiles(root: root)
    try files.prepare()
    let temporary = root.appendingPathComponent("error-body")
    let bytes = Data("not a derivative".utf8)
    try bytes.write(to: temporary)
    let response = try #require(HTTPURLResponse(url: URL(string: "https://server.invalid/file")!,
        statusCode: 403, httpVersion: "HTTP/1.1", headerFields: nil))
    #expect(throws: BackupInbox.Failure.self) {
        try BackupInbox(files: files).capture(temporary, transferID: UUID(), sessionID: UUID(), response: response)
    }
    #expect(try Data(contentsOf: temporary) == bytes)
}
