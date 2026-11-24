// SPDX-License-Identifier: Apache-2.0
import Foundation
import HomespunCore

struct BackupPreview: Sendable {
    let context: BackupBindingContext
    let workspace: BackupWorkspace
    let entry: CompactLedger.Entry

    struct File: Sendable {
        var url: URL
        var transferID: UUID
        var sessionID: UUID
    }

    @MainActor func fetch(video: Bool) async throws -> File {
        let store = workspace.store
        guard entry.origin == context.binding.origin, let version = entry.version, let requestID = entry.requestID,
              let operationID = entry.operationID, let operation = try await store.operation(operationID),
              let manifest = operation.manifest else { throw BackupStore.Failure.invalidReceipt }
        let preferred: ServerAPI.ResourceRole = video ? .fullSizeVideo : .fullSizePhoto
        let fallback: ServerAPI.ResourceRole = video ? .video : .photo
        guard let expected = manifest.resources.first(where: { $0.role == preferred })
            ?? manifest.resources.first(where: { $0.role == fallback }) else { throw BackupStore.Failure.invalidReceipt }
        let session = BackupStore.TransferSession(id: UUID(), bindingID: context.binding.id,
            identifier: "foreground.preview." + UUID().uuidString, installationID: context.session.installationID)
        try await store.registerSession(session)
        BackupExecutionSessions.claim(session.id)
        let transfer = BackupStore.Transfer(id: UUID(), operationID: operationID, epoch: operation.epoch,
            sessionID: session.id, kind: .originalDownload, version: version, expected: expected)
        do {
            try await store.saveMetadata("preview-transfer:" + transfer.id.uuidString, value: true)
            let resource = try await workspace.downloadOriginal(transfer, requestID: requestID, remote: context.remote)
            return .init(url: store.files.stagedFile(operationID: operationID, fileID: resource.fileID),
                         transferID: transfer.id, sessionID: session.id)
        } catch {
            BackupExecutionSessions.release(session.id)
            try await store.releasePreviewTransfer(transfer.id)
            try await workspace.collectReleasedFiles()
            throw error
        }
    }

    @MainActor func release(_ file: File) async throws {
        BackupExecutionSessions.release(file.sessionID)
        try await workspace.store.releasePreviewTransfer(file.transferID)
        try await workspace.collectReleasedFiles()
    }
}
