// SPDX-License-Identifier: Apache-2.0
import Foundation
import HomespunCore

struct BackupWorkspacePermit: Sendable {
    var reservation: BackupStore.Reservation
    var directory: URL
    var maximumBytes: Int
}

struct BackupInboxRecovery: Sendable {
    var recovered = Set<UUID>()
    var problems: [String] = []
}

/// Scheduling policy/transport live in the coordinator; capacity, reservations, file references
/// and durable inbox ownership remain the parent's canonical Store/Files/Inbox implementation.
struct BackupWorkspace: Sendable {
    let store: BackupStore
    let policy: BackupSpacePolicy
    var inbox: BackupInbox { .init(files: store.files) }

    func prepare(_ operation: BackupStore.Operation, bytes: Int) async throws -> BackupWorkspacePermit {
        guard bytes > 0 else { throw BackupAPI.ValidationError.invalidManifest }
        let reservation = BackupStore.Reservation(id: UUID(), operationID: operation.id, epoch: operation.epoch,
            stage: .preparation, futureBytes: Int64(bytes), systemCopyBytes: 0, taskSlots: 0)
        try await store.reserveSpace(reservation, policy: policy)
        return .init(reservation: reservation, directory: try store.files.prepareStaging(operationID: operation.id), maximumBytes: bytes)
    }

    func finalize(_ operation: BackupStore.Operation, bytes: Int) async throws -> BackupWorkspacePermit {
        guard bytes > 0 else { throw BackupAPI.ValidationError.invalidManifest }
        let reservation = BackupStore.Reservation(id: UUID(), operationID: operation.id, epoch: operation.epoch,
            stage: .finalization, futureBytes: Int64(bytes), systemCopyBytes: 0, taskSlots: 0)
        try await store.reserveSpace(reservation, policy: policy)
        return .init(reservation: reservation, directory: try store.files.prepareStaging(operationID: operation.id), maximumBytes: bytes)
    }

    func release(_ permit: BackupWorkspacePermit) async throws { try await store.releaseReservation(permit.reservation.id) }

    func consume(_ permit: BackupWorkspacePermit, bytes: Int) async throws -> BackupWorkspacePermit {
        var updated = permit
        updated.reservation.futureBytes = max(0, permit.reservation.futureBytes - Int64(bytes))
        try await store.reserveSpace(updated.reservation, policy: policy)
        return updated
    }

    func remaining(_ permit: BackupWorkspacePermit, bytes: Int) async throws -> BackupWorkspacePermit {
        var updated = permit
        updated.reservation.futureBytes = Int64(bytes)
        try await store.reserveSpace(updated.reservation, policy: policy)
        return updated
    }

    func reserveTransfer(_ transfer: BackupStore.Transfer, futureBytes: Int64) async throws -> UUID {
        let reservation = BackupStore.Reservation(id: transfer.id, operationID: transfer.operationID, epoch: transfer.epoch,
            stage: transfer.kind == .upload ? .upload : .finalization, futureBytes: futureBytes,
            systemCopyBytes: transfer.kind == .upload ? Int64(ServerClientV2.maximumBufferedChunk * 2) : 0,
            taskSlots: 1, transferID: transfer.id)
        try await store.reserveSpace(reservation, policy: policy)
        do {
            try await store.stageTransfer(transfer)
        } catch {
            try await store.releaseReservation(reservation.id)
            throw error
        }
        return reservation.id
    }

    func download(_ transfer: BackupStore.Transfer, resource: ServerAPI.CompactResource,
                  remote: any BackupRemote, preReserved: Bool = false) async throws -> BackupStore.Resource {
        guard let generation = transfer.generationID else { throw BackupStore.Failure.invalidReceipt }
        let reservation = try await reserveTransfer(transfer, futureBytes: preReserved ? 0 : Int64(resource.size))
        try await store.startTransfer(transfer.id)
        let fileID = UUID()
        let temporary = store.files.inbox.appendingPathComponent("\(transfer.id.uuidString).\(fileID.uuidString).download")
        let response: HTTPURLResponse
        do {
            response = try await remote.download(generation: generation, resource: resource, to: temporary)
        } catch {
            // This is only this process's exclusive, uncommitted stream attempt, not orphan cleanup.
            // A completed handoff/captured resource is never deleted by this path.
            try await store.finishTransfer(transfer.id, state: .failed)
            if try await store.transfers(operationID: transfer.operationID).first(where: { $0.id == transfer.id })?.capturedResourceID == nil,
               !FileManager.default.fileExists(atPath: temporary.deletingPathExtension().appendingPathExtension("json").path) {
                do { try FileManager.default.removeItem(at: temporary) }
                catch let missing as CocoaError where missing.code == .fileNoSuchFile || missing.code == .fileReadNoSuchFile {}
            }
            try await store.releaseReservation(reservation)
            throw error
        }
        let capture = try inbox.capture(temporary, transferID: transfer.id, sessionID: transfer.sessionID, response: response)
        let result = try await ingest(capture, transfer: transfer)
        try await store.releaseReservation(reservation)
        return result
    }

    func downloadOriginal(_ transfer: BackupStore.Transfer, requestID: UUID, remote: any BackupRemote,
                          preReserved: Bool = false) async throws -> BackupStore.Resource {
        guard transfer.kind == .originalDownload else { throw BackupStore.Failure.invalidReceipt }
        let reservation = try await reserveTransfer(transfer, futureBytes: preReserved ? 0 : Int64(transfer.expected.size))
        try await store.startTransfer(transfer.id)
        let fileID = UUID()
        let temporary = store.files.inbox.appendingPathComponent("\(transfer.id.uuidString).\(fileID.uuidString).download")
        let response: HTTPURLResponse
        do {
            response = try await remote.downloadOriginal(version: transfer.version, requestID: requestID,
                                                         resource: transfer.expected, to: temporary)
        } catch {
            try await store.finishTransfer(transfer.id, state: .failed)
            if !FileManager.default.fileExists(atPath: temporary.deletingPathExtension().appendingPathExtension("json").path) {
                do { try FileManager.default.removeItem(at: temporary) }
                catch let missing as CocoaError where missing.code == .fileNoSuchFile || missing.code == .fileReadNoSuchFile {}
            }
            try await store.releaseReservation(reservation)
            throw error
        }
        let capture = try inbox.capture(temporary, transferID: transfer.id, sessionID: transfer.sessionID, response: response)
        let result = try await ingest(capture, transfer: transfer)
        try await store.releaseReservation(reservation)
        return result
    }

    func reconcileInbox() async throws -> BackupInboxRecovery {
        try store.files.prepare()
        var result = BackupInboxRecovery()
        let handoffs = try await reconcilePhotoHandoffs()
        result.problems += handoffs.problems
        let transfers = try await store.transfers()
        let sessions = try await store.sessions()
        let captures = try inbox.captures()
        for capture in captures {
            guard let transfer = transfers.first(where: { $0.id == capture.transferID }),
                  let session = sessions.first(where: { $0.id == capture.sessionID }),
                  session.id == transfer.sessionID, !session.background else {
                result.problems.append("A working file has no matching foreground transfer intent. It has been preserved.")
                continue
            }
            do {
                _ = try await ingest(capture, transfer: transfer)
                result.recovered.insert(transfer.operationID)
            } catch {
                result.problems.append("A downloaded file needs reconciliation. No copy was imported or removed.")
            }
        }
        for orphan in try inbox.orphans() {
            if let transfer = transfers.first(where: { $0.id == orphan.transferID }),
               await MainActor.run(body: { BackupExecutionSessions.contains(transfer.sessionID) }) { continue }
            guard let transfer = transfers.first(where: { $0.id == orphan.transferID }),
                  transfer.kind != .upload, transfer.state != .running,
                  let session = sessions.first(where: { $0.id == transfer.sessionID }), !session.background,
                  let binding = try await store.binding(session.bindingID) else {
                result.problems.append("An unindexed working file has been preserved for review.")
                continue
            }
            let digest = try await Task.detached { try Fingerprint.digests(of: orphan.url) }.value
            guard digest.size == transfer.expected.size, digest.sha256 == transfer.expected.sha256.lowercased(),
                  transfer.capturedResourceID == nil else {
                result.problems.append("A sidecarless working file did not have a unique complete transfer proof.")
                continue
            }
            let response = HTTPURLResponse(url: binding.baseURL, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["ETag": "\"\(transfer.expected.sha256.lowercased())\""])!
            let capture = try inbox.capture(orphan.url, transferID: transfer.id, sessionID: session.id, response: response)
            _ = try await ingest(capture, transfer: transfer)
            result.recovered.insert(transfer.operationID)
        }
        return result
    }

    private func ingest(_ capture: BackupInbox.Capture, transfer: BackupStore.Transfer) async throws -> BackupStore.Resource {
        guard transfer.kind != .upload, capture.transferID == transfer.id, capture.sessionID == transfer.sessionID,
              capture.taskID == transfer.taskID, capture.status == 200, capture.contentRange == nil,
              capture.bytes == Int64(transfer.expected.size), capture.etag == "\"\(transfer.expected.sha256.lowercased())\"",
              let session = try await store.sessions().first(where: { $0.id == transfer.sessionID }),
              let binding = try await store.binding(session.bindingID),
              binding.origin == transfer.version.origin, capture.scheme == "https",
              capture.host == binding.baseURL.host, capture.port == (binding.baseURL.port ?? 443) else {
            throw BackupStore.Failure.invalidReceipt
        }
        if let oldID = transfer.capturedResourceID,
           let old = try await store.resources(transfer.operationID).first(where: { $0.fileID == oldID }),
           old.availability == .present {
            try inbox.removeSidecar(capture)
            return old
        }
        let destination = store.files.stagedFile(operationID: transfer.operationID, fileID: capture.id)
        _ = try store.files.prepareStaging(operationID: transfer.operationID)
        let source = FileManager.default.fileExists(atPath: destination.path) ? destination : inbox.file(capture)
        let digest = try await Task.detached { try Fingerprint.digests(of: source) }.value
        guard digest.size == transfer.expected.size, digest.sha256 == transfer.expected.sha256.lowercased() else {
            throw BackupStore.Failure.invalidImport
        }
        if source != destination { try FileManager.default.moveItem(at: source, to: destination) }
        try BackupFiles.protect(destination)
        let resource = BackupStore.Resource(fileID: capture.id, operationID: transfer.operationID,
                                            kind: transfer.kind == .originalDownload ? .restoredOriginal : .compact,
                                            descriptor: transfer.expected)
        try await store.captureDownload(transfer.id, resource: resource)
        try await store.finishTransfer(transfer.id, state: .completed)
        try inbox.removeSidecar(capture)
        return resource
    }

    func collectReleasedFiles() async throws {
        let handoffs = try await reconcilePhotoHandoffs()
        guard handoffs.problems.isEmpty else { throw PhotoResourceHandoff.Failure.unprovenAlias }
        for resource in try await store.claimCleanup(excludingOperations: handoffs.protected) {
            let file = store.files.stagedFile(operationID: resource.operationID, fileID: resource.fileID)
            do { try FileManager.default.removeItem(at: file) }
            catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {}
            try await store.cleanedResource(resource.fileID)
        }
    }

    private func reconcilePhotoHandoffs() async throws -> (problems: [String], protected: Set<UUID>) {
        var problems: [String] = []
        var protected = Set<UUID>()
        for orphan in try PhotoResourceHandoff.orphans(in: store.files.staging, includingActive: true) {
            if PhotoResourceHandoff.isActive(orphan.id) { protected.insert(orphan.operationID); continue }
            guard try await store.operation(orphan.operationID) != nil else {
                problems.append("An unknown Photos handoff was preserved. No original was removed or re-imported.")
                continue
            }
            // A crashed Photos transaction may still be reading the URL. Its journal must be reconciled first.
            if try await store.hasUnresolvedPhotosHandoff(orphan.operationID) {
                protected.insert(orphan.operationID)
                continue
            }
            do { try PhotoResourceHandoff.clean(orphan, in: store.files.staging) }
            catch { problems.append("An unproven Photos handoff was preserved for recovery.") }
        }
        return (problems, protected)
    }
}
