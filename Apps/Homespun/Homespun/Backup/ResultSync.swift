// SPDX-License-Identifier: Apache-2.0
import Foundation
import HomespunCore

struct BackupBindingContext: Sendable {
    var binding: BackupStore.Binding
    var information: BackupStore.BindingInformation
    var session: BackupStore.TransferSession
    var remote: any BackupRemote
}

@MainActor
enum BackupExecutionSessions {
    private static var owners = Set<UUID>()
    static func claim(_ id: UUID) { owners.insert(id) }
    static func release(_ id: UUID) { owners.remove(id) }
    static func contains(_ id: UUID) -> Bool { owners.contains(id) }
}

/// One bounded bulk-feed/snapshot owner per authenticated origin, never an item polling loop.
@MainActor
final class ResultSync {
    private struct Run {
        var id: UUID
        var task: Task<Void, Error>
    }
    private let store: BackupStore
    private var runs: [BackupAPI.Origin: Run] = [:]
    private var retired = false
    private var generation = 0
    var committed: @MainActor (BackupBindingContext, Set<UUID>) async -> Void = { _, _ in }
    var readyNotification: @MainActor (BackupBindingContext) async throws -> Bool = { _ in false }

    init(store: BackupStore) { self.store = store }

    func synchronize(_ context: BackupBindingContext) async throws {
        guard !retired else { throw CancellationError() }
        if let run = runs[context.binding.origin] {
            try await withTaskCancellationHandler { try await run.task.value } onCancel: { run.task.cancel() }
            return
        }
        let id = UUID(), mine = generation
        let task = Task {
            defer {
                if runs[context.binding.origin]?.id == id { runs[context.binding.origin] = nil }
            }
            try Task.checkCancellation()
            try await drainOutbox(context)
            if try await store.snapshotRun(bindingID: context.binding.id) != nil {
                try await recoverSnapshot(context)
            } else {
                do {
                    for _ in 0..<8 {
                        try Task.checkCancellation()
                        let cursor = try await store.cursor(bindingID: context.binding.id)
                        let page = try await context.remote.changes(after: cursor, epoch: context.binding.origin.historyEpoch)
                        guard page.origin == context.binding.origin else { throw BackupStore.Failure.invalidReceipt }
                        try Task.checkCancellation()
                        _ = try await store.applyChanges(page, bindingID: context.binding.id)
                        if !retired, mine == generation {
                            await committed(context, Set(page.changes.map(\.receipt.operationID)))
                        }
                        if !page.hasMore { break }
                    }
                } catch let failure as ServerClient.Failure where failure.code == BackupAPI.ErrorCode.snapshotRequired {
                    _ = try await store.beginSnapshot(bindingID: context.binding.id)
                    try await recoverSnapshot(context)
                }
            }
            try await drainOutbox(context)
        }
        runs[context.binding.origin] = .init(id: id, task: task)
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private func recoverSnapshot(_ context: BackupBindingContext) async throws {
        let id: UUID
        if let run = try await store.snapshotRun(bindingID: context.binding.id) { id = run.id }
        else { id = try await store.beginSnapshot(bindingID: context.binding.id) }
        for _ in 0..<8 {
            try Task.checkCancellation()
            guard let run = try await store.snapshotRun(bindingID: context.binding.id), run.id == id else {
                throw BackupStore.Failure.invalidReceipt
            }
            let page = try await context.remote.snapshot(continuation: run.continuation)
            guard page.origin == context.binding.origin else { throw BackupStore.Failure.invalidReceipt }
            try Task.checkCancellation()
            let progress = try await store.applySnapshot(page, runID: id, requestedContinuation: run.continuation)
            if progress.complete {
                await committed(context, [])
                return
            }
        }
    }

    private func drainOutbox(_ context: BackupBindingContext) async throws {
        let due = try await store.outbox(limit: 100, bindingID: context.binding.id)
        let notifications = due.filter { $0.kind == .readyNotification }
        for item in due where item.kind != .readyNotification {
            try Task.checkCancellation()
            do {
                switch item.kind {
                case .serverCommand:
                    let envelope = try BackupStore.decode(BackupStore.CommandEnvelope.self, item.payload)
                    guard envelope.command.version.origin == context.binding.origin,
                          let operation = try await store.operation(item.operationID),
                          operation.origin == context.binding.origin else { throw BackupStore.Failure.invalidReceipt }
                    let receipt = try await context.remote.command(requestID: envelope.requestID, envelope.command)
                    guard receipt.version == envelope.command.version, receipt.requestID == envelope.requestID,
                          receipt.operationID == operation.id else { throw BackupStore.Failure.invalidReceipt }
                    if let current = try await store.operation(operation.id), current.epoch == operation.epoch {
                        _ = try await store.apply(receipt, operationID: operation.id, epoch: operation.epoch)
                        await committed(context, [operation.id])
                    }
                case .deliveryAcknowledgement:
                    let acknowledgement = try ServerAPI.decoder.decode(BackupAPI.DeliveryAcknowledgement.self, from: item.payload)
                    guard acknowledgement.version.origin == context.binding.origin else { throw BackupStore.Failure.invalidReceipt }
                    try await context.remote.acknowledge(acknowledgement)
                case .readyNotification: continue
                }
                // The exact admitted command/ack is a completed fact even if Settings changed meanwhile.
                try await store.acknowledgeOutbox(item.id)
            } catch {
                if error is CancellationError { throw error }
                if error is BackupStore.Failure || error is BackupDatabase.Failure || error is BackupDatabase.RollbackFailure {
                    throw error
                }
                let delay = min(3600, 30 * pow(2, Double(min(item.attempts, 7))))
                try await store.retryOutbox(item.id, after: Date().addingTimeInterval(delay))
            }
        }
        if !notifications.isEmpty {
            let delivered = try await readyNotification(context)
            for item in notifications {
                if delivered { try await store.acknowledgeOutbox(item.id) }
                else { try await store.retryOutbox(item.id, after: Date().addingTimeInterval(3600)) }
            }
        }
    }

    func retire() {
        retired = true
        generation &+= 1
        for run in runs.values { run.task.cancel() }
    }

    func stopAndWait() async {
        retire()
        let tasks = runs.values.map(\.task)
        for task in tasks { _ = try? await task.value }
    }
}
