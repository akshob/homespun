// SPDX-License-Identifier: Apache-2.0
import Foundation
import HomespunCore

/// Durable intent is in BackupStore. These owners represent only permitted local execution;
/// neither a server encoder nor a discovery backoff holds isRunning, the screen, or LongRun.
@MainActor
final class BackupCoordinator {
    private struct PreparedCandidate: Codable, Sendable {
        var metadata: BackupPhotoMetadata
        var resources: [BackupStore.Resource]
    }
    private struct Work {
        var stage: BackupStore.Stage
        var task: Task<Void, Never>
    }
    private struct Discovery {
        var id: UUID
        var task: Task<Void, Never>
    }

    let store: BackupStore
    let photos: any PhotoSource
    let namespace: String
    private(set) var context: BackupBindingContext?
    private var workspace: BackupWorkspace?
    private var active: [UUID: Work] = [:]
    private var driver: Task<Void, Never>?
    private var discovery: Discovery?
    private var discoveryAgain = false
    private let discoverySleep: @Sendable (Duration) async throws -> Void
    private var resultSync: ResultSync
    private var driveAgain = false
    private var retired = false
    private var visible = false
    private var generation = 0
    private var uploadOrder: UUID?
    private var validatedOriginals = Set<UUID>()
    private var schedulingPaused = false
    private var backgroundOpportunities = 0
    private var opportunityIDs = Set<UUID>()
    private var suspended = false
    var currentWorkspace: BackupWorkspace? { workspace }
    var changed: @MainActor (Set<UUID>) async -> Void = { _ in }
    var progress: @MainActor (UUID, String) -> Void = { _, _ in }
    var localWork: @MainActor (Int) -> Void = { _ in }
    var failed: @MainActor (Error) -> Void = { _ in }
    var notifyReady: @MainActor (BackupBindingContext) async throws -> Bool = { _ in false }

    init(store: BackupStore, photos: any PhotoSource, namespace: String,
         discoverySleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.store = store
        self.photos = photos
        self.namespace = namespace
        self.discoverySleep = discoverySleep
        resultSync = ResultSync(store: store)
        configureSync()
    }

    private func configureSync() {
        resultSync.committed = { [weak self] context, ids in
            guard let self, self.context?.binding.id == context.binding.id, !self.retired else { return }
            do { try await self.releaseRetainedSpools(ids) } catch { self.failed(error) }
            await self.changed(ids)
            self.drive()
        }
        resultSync.readyNotification = { [weak self] context in
            guard let self, !self.retired, self.context?.binding.id == context.binding.id else { return false }
            return try await self.notifyReady(context)
        }
    }

    func activate(_ context: BackupBindingContext, policy: BackupSpacePolicy) async throws {
        guard !retired, !suspended else { throw CancellationError() }
        if self.context?.binding.id == context.binding.id {
            workspace = .init(store: store, policy: policy)
            try await reconcile()
            return
        }
        generation &+= 1
        let mine = generation, old = self.context
        self.context = nil
        discovery?.task.cancel()
        let previousDiscovery = discovery
        driver?.cancel()
        let previousDriver = driver
        driver = nil
        for work in active.values { work.task.cancel() }
        if let old { try await store.retireBinding(old.binding.id) }
        await resultSync.stopAndWait()
        await previousDriver?.value
        await previousDiscovery?.task.value
        let previous = active.values.map(\.task)
        for task in previous { await task.value }
        if let old { BackupExecutionSessions.release(old.session.id) }
        guard !retired, generation == mine else { throw CancellationError() }
        if let old, old.binding.origin == context.binding.origin,
           old.binding.consumerID?.isEmpty == false, old.binding.consumerID == context.binding.consumerID,
           old.binding.mode == context.binding.mode {
            try await store.reattach(from: old.binding.id, to: context.binding.id)
        } else {
            for binding in try await store.bindings() where binding.retired && binding.origin == context.binding.origin
                && binding.consumerID?.isEmpty == false && binding.consumerID == context.binding.consumerID
                && binding.mode == context.binding.mode {
                try await store.reattach(from: binding.id, to: context.binding.id)
            }
        }
        guard !retired, generation == mine else { throw CancellationError() }
        self.context = context
        BackupExecutionSessions.claim(context.session.id)
        workspace = .init(store: store, policy: policy)
        resultSync = ResultSync(store: store)
        configureSync()
        if let workspace {
            let recovery = try await workspace.reconcileInbox()
            if !recovery.problems.isEmpty { failed(BackupStageFailure.blocked(recovery.problems.joined(separator: "\n"))) }
            await changed(recovery.recovered)
        }
        try await drainForegroundAttempts()
        for transfer in try await store.transfers() where !BackupExecutionSessions.contains(transfer.sessionID) {
            try await store.releasePreviewTransfer(transfer.id)
        }
        if let workspace { try await workspace.collectReleasedFiles() }
        await changed([])
        try await reconcile()
    }

    func admit(_ ids: [String], compact: Bool, trigger: RunHistory.Trigger,
               authorized: @MainActor () -> Bool = { true }) async throws -> BackupStore.Batch {
        guard !retired, !suspended, let context, authorized() else { throw BackupStore.Failure.retiredBinding }
        let mine = generation, binding = context.binding
        guard binding.mode != .files || context.information.capabilities.uploadProtocols.contains(.foregroundOffset) else {
            throw BackupStageFailure.blocked("This server has no supported foreground upload protocol. Native transfers remain unavailable.")
        }
        if binding.mode == .immich,
           context.information.capabilities.externalVerification != .fullResourceScrub {
            throw BackupStageFailure.blocked("Update the Immich add-on for negotiated full-resource verification. No unverified external original is ready to free up.")
        }
        let projection = try await store.ledgerProjection(namespace: namespace)
        let present = photos.existing(projection.entries.values.map(\.compactIdentifier), includeHidden: true)
        for id in ids {
            if present.contains(id) {
                throw BackupStageFailure.blocked("This is an existing compact copy. Use Find Compact Copies to revalidate its original; it must not be uploaded as a new original.")
            }
            if let entry = projection.entries[id], present.contains(entry.compactIdentifier) {
                throw BackupStageFailure.blocked(entry.origin == nil
                    ? "This item already has a compact mapping with unknown historical origin. Recover that mapping before making another copy."
                    : "This item already has a compact copy. Reconnect its original server to review or restore it.")
            }
        }
        guard !retired, mine == generation, self.context?.binding.id == binding.id,
              authorized(), !Task.isCancelled else { throw CancellationError() }
        if trigger != .automatic {
            try await store.setKeptDecision(ids, namespace: namespace, kept: false)
            for old in try await store.currentOperations(ids, namespace: namespace)
                where old.bindingID == binding.id && old.delivery != .importedVerified {
                let intent = try await store.importIntent(old.id)
                if old.problem?.code == "source_changed", intent == nil {
                    try await store.setDesired(.cancelled, operationID: old.id)
                } else if old.attention || old.desired == .paused || old.backup == .blocked || old.backup == .failed {
                    try await store.retry(old.id)
                    if let receipt = old.receipt, receipt.compact == .failed || receipt.compact == .held {
                        _ = try await store.enqueueCommand(old.id, action: .retry)
                    }
                }
            }
        }
        guard authorized(), !retired, mine == generation else { throw CancellationError() }
        let batch = try await store.admit(ids, namespace: namespace, bindingID: binding.id,
                                         profile: context.information.capabilities.recipe.profile, compact: compact)
        try await store.rememberAdmission(batch, trigger: trigger)
        await changed(Set(batch.operationIDs))
        if !retired, mine == generation {
            if trigger != .automatic { schedulingPaused = false }
            drive()
            scheduleDiscovery()
        }
        return batch
    }

    func reconcile() async throws {
        guard !retired, !suspended, let context else { return }
        drive()
        try await resultSync.synchronize(context)
        drive()
        scheduleDiscovery()
    }

    func reconcileHint(bindingID: UUID) async throws -> Bool {
        guard !retired, !suspended, let context, context.binding.id == bindingID else { return false }
        let cursor = try await store.cursor(bindingID: bindingID)
        let sync = resultSync, store = store
        return try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                try await sync.synchronize(context)
                return try await store.cursor(bindingID: bindingID) != cursor
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                throw CancellationError()
            }
            defer { group.cancelAll() }
            return try await group.next() ?? false
        }
    }

    func setVisible(_ visible: Bool) {
        self.visible = visible
        if !visible { discovery?.task.cancel() }
        else { drive(); scheduleDiscovery() }
    }

    private func drive() {
        guard !retired, !suspended, !schedulingPaused, visible || backgroundOpportunities > 0,
              context != nil, workspace != nil else { return }
        guard driver == nil else { driveAgain = true; return }
        let mine = generation
        driver = Task {
            defer { driver = nil }
            do {
                repeat {
                    driveAgain = false
                    guard !retired, generation == mine, !Task.isCancelled, let context, let workspace else { return }
                    for (stage, limit) in [(BackupStore.Stage.preparation, 2), (.upload, 2), (.finalization, 1)] {
                        var slots = limit - active.values.count { $0.stage == stage }
                        guard slots > 0 else { continue }
                        var operations = try await store.deviceRunnable(stage, binding: context.binding,
                            namespace: namespace, limit: 200).filter { active[$0.id] == nil }
                        if stage == .upload, let last = uploadOrder, let position = operations.firstIndex(where: { $0.id == last }) {
                            operations = Array(operations.dropFirst(position + 1)) + Array(operations.prefix(position + 1))
                        }
                        for operation in operations {
                            guard slots > 0, !retired, !suspended, !schedulingPaused, generation == mine,
                                  visible || backgroundOpportunities > 0, !Task.isCancelled else { break }
                            guard let lease = try await store.claim(operation.id, stage: stage) else { continue }
                            guard !retired, !suspended, !schedulingPaused, generation == mine,
                                  visible || backgroundOpportunities > 0, self.context?.binding.id == context.binding.id else {
                                try await store.deferLease(lease)
                                continue
                            }
                            launch(operation, lease: lease, context: context, workspace: workspace, generation: mine)
                            slots -= 1
                        }
                    }
                } while driveAgain && !Task.isCancelled
            } catch {
                if !(error is CancellationError) { failed(error) }
            }
        }
    }

    private func launch(_ operation: BackupStore.Operation, lease: BackupStore.Lease,
                        context: BackupBindingContext, workspace: BackupWorkspace, generation mine: Int) {
        let task = Task {
            do {
                switch lease.stage {
                case .preparation:
                    try await prepare(operation, lease: lease, context: context, workspace: workspace)
                case .upload:
                    uploadOrder = operation.id
                    try await uploadQuantum(operation, lease: lease, context: context, workspace: workspace)
                case .finalization:
                    let finalizer = BackupFinalizer(store: store, photos: photos, workspace: workspace)
                    _ = try await finalizer.run(operation, lease: lease, context: context) { [weak self] message in
                        Task { @MainActor [weak self] in
                            guard let self, self.generation == mine else { return }
                            self.progress(operation.id, message)
                        }
                    }
                }
                try await store.release(lease)
            } catch {
                do {
                    if error is CancellationError || Task.isCancelled {
                        try await store.deferLease(lease)
                    } else if error is BackupSpaceFailure {
                        try await store.deferLease(lease, until: Date().addingTimeInterval(30))
                        failed(error)
                    } else if ServerClient.isConnectionFailure(error) {
                        try await store.deferLease(lease, until: Date().addingTimeInterval(30))
                        failed(error)
                    } else if error is BackupDatabase.Failure || error is BackupDatabase.RollbackFailure {
                        failed(error)
                        try await store.deferLease(lease, until: Date().addingTimeInterval(30))
                    } else {
                        let current = try await store.operation(operation.id)
                        if current?.lease == lease {
                            let code: String
                            if let failure = error as? BackupStageFailure, case .sourceChanged = failure { code = "source_changed" }
                            else { code = "stage_failed" }
                            try await store.fail(lease, code: code, message: error.localizedDescription)
                        }
                        failed(error)
                    }
                } catch {
                    // A retired epoch cannot overwrite a newer operation or a successful Photos fact.
                    if (error as? BackupStore.Failure) != .staleOperation { failed(error) }
                }
            }
            active[operation.id] = nil
            localWork(active.count)
            await changed([operation.id])
            if !retired, generation == mine {
                drive()
                scheduleDiscovery()
            }
        }
        active[operation.id] = .init(stage: lease.stage, task: task)
        localWork(active.count)
    }

    private func prepare(_ operation: BackupStore.Operation, lease: BackupStore.Lease,
                         context: BackupBindingContext, workspace: BackupWorkspace) async throws {
        let candidateKey = "prepared-candidate:" + operation.id.uuidString
        if let candidate = try await store.metadata(candidateKey, as: PreparedCandidate.self) {
            guard try photos.sourceGeneration(operation.itemID) == candidate.metadata.generation else {
                throw BackupStageFailure.sourceChanged("The previously staged original changed in Photos. Its working files are preserved; select the current item again.")
            }
            for resource in candidate.resources {
                let file = store.files.stagedFile(operationID: operation.id, fileID: resource.fileID)
                let digest = try await Task.detached { try Fingerprint.digests(of: file) }.value
                guard digest.size == resource.descriptor.size, digest.sha256 == resource.descriptor.sha256.lowercased() else {
                    throw BackupStageFailure.blocked("The earlier staged original needs recovery. It was not silently replaced or discarded.")
                }
            }
            try await store.prepared(lease, manifest: .init(kind: candidate.metadata.kind, resources: candidate.resources.map(\.descriptor)),
                resources: candidate.resources, captureDate: candidate.metadata.creationDate, metadata: BackupStore.encode(candidate.metadata))
            return
        }
        let bytes = try photos.preparationBytes(operation.itemID, mode: context.binding.mode)
        let permit = try await workspace.prepare(operation, bytes: bytes)
        do {
            let prepared = try await photos.prepareBackup(operation.itemID, mode: context.binding.mode,
                directory: permit.directory, maximumBytes: permit.maximumBytes) { [weak self] message in
                    Task { @MainActor [weak self] in self?.progress(operation.id, message) }
                }
            let resources = prepared.resources.map {
                BackupStore.Resource(fileID: $0.fileID, operationID: operation.id, kind: .original, descriptor: $0.descriptor)
            }
            try await store.saveMetadata(candidateKey, value: PreparedCandidate(metadata: prepared.metadata, resources: resources), immutable: true)
            try await store.prepared(lease, manifest: prepared.manifest, resources: resources,
                                     captureDate: prepared.metadata.creationDate, metadata: BackupStore.encode(prepared.metadata))
        } catch {
            try await workspace.release(permit)
            throw error
        }
    }

    /// One registration or a bounded number of chunks, then yield the slot fairly to other items.
    private func uploadQuantum(_ supplied: BackupStore.Operation, lease: BackupStore.Lease,
                               context: BackupBindingContext, workspace: BackupWorkspace) async throws {
        guard let operation = try await store.operation(supplied.id), operation.lease == lease,
              let request = operation.request, let manifest = operation.manifest else { throw BackupStore.Failure.staleOperation }
        if operation.receipt == nil {
            let matches = try await context.remote.lookup(operationID: operation.id)
            guard matches.count <= 1 else { throw BackupStore.Failure.conflictingReceipt }
            let receipt: BackupAPI.Receipt
            if let existing = matches.first { receipt = existing }
            else { receipt = try await context.remote.submit(request) }
            try await apply(receipt, operation: operation, lease: lease, context: context)
            return
        }
        guard let receipt = operation.receipt else { throw BackupStore.Failure.invalidReceipt }
        if receipt.backup == .retained {
            try await store.releaseOriginalSpools(operation.id)
            try await workspace.collectReleasedFiles()
            return
        }
        if context.binding.mode == .immich { return }
        let resources = try await store.resources(operation.id)
        let missing = manifest.resources.filter { expected in
            !receipt.originals.contains { $0.role == expected.role && $0.state == .verified
                && $0.size == expected.size && $0.sha256.lowercased() == expected.sha256.lowercased() }
        }
        guard let expected = missing.first else {
            let fresh = try await context.remote.status(receipt.requestID)
            try await apply(fresh, operation: operation, lease: lease, context: context)
            return
        }
        guard let resource = resources.first(where: { $0.kind == .original && $0.descriptor.role == expected.role && $0.availability == .present }) else {
            throw BackupStageFailure.blocked("The immutable staged original is missing. It has not been silently replaced or skipped.")
        }
        let file = store.files.stagedFile(operationID: operation.id, fileID: resource.fileID)
        try BackupFiles.protect(file)
        if !validatedOriginals.contains(resource.fileID) {
            let digest = try await Task.detached { try Fingerprint.digests(of: file) }.value
            guard digest.sha256 == expected.sha256.lowercased(), digest.size == expected.size else { throw BackupStore.Failure.invalidReceipt }
            validatedOriginals.insert(resource.fileID)
        }
        guard try PhotoLibrary.size(of: file) == expected.size else { throw BackupStore.Failure.invalidReceipt }
        let transfers = try await store.transfers(operationID: operation.id)
        let transfer: BackupStore.Transfer
        if let old = transfers.last(where: { $0.kind == .upload && $0.expected.role == expected.role
            && $0.version == receipt.version && $0.epoch == operation.epoch && $0.sessionID == context.session.id && !$0.state.terminal }) {
            transfer = old
        } else {
            var reusable: UUID?
            for old in transfers.reversed() where old.kind == .upload && old.version == receipt.version
                && old.expected.role == expected.role && old.uploadID != nil {
                if try await store.metadata("rejected-upload:" + old.uploadID!.uuidString, as: Bool.self) != true {
                    reusable = old.uploadID
                    break
                }
            }
            transfer = .init(id: UUID(), operationID: operation.id, epoch: operation.epoch, sessionID: context.session.id,
                             kind: .upload, version: receipt.version, expected: expected,
                             resourceID: resource.fileID, uploadID: reusable ?? UUID())
        }
        let reservation = try await workspace.reserveTransfer(transfer, futureBytes: 0)
        do {
            try await store.startTransfer(transfer.id)
            let admission = try await context.remote.admitUpload(.init(uploadID: transfer.uploadID!, requestID: receipt.requestID,
                                                                      version: receipt.version, role: expected.role))
            guard admission.size == Int64(expected.size), admission.uploadProtocol == .foregroundOffset else {
                throw BackupStore.Failure.invalidReceipt
            }
            var position = try await context.remote.uploadPosition(transfer.uploadID!)
            guard position.size == Int64(expected.size) else { throw BackupStore.Failure.invalidReceipt }
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            for _ in 0..<4 where position.offset < position.size {
                try Task.checkCancellation()
                guard try await store.operation(operation.id)?.lease == lease else { throw BackupStore.Failure.staleOperation }
                try handle.seek(toOffset: UInt64(position.offset))
                let count = min(Int64(ServerClientV2.maximumBufferedChunk), position.maximumChunkBytes, position.size - position.offset)
                guard count > 0, let data = try handle.read(upToCount: Int(count)), data.count == Int(count) else {
                    throw BackupStore.Failure.invalidReceipt
                }
                do {
                    position.offset = try await context.remote.append(data, uploadID: transfer.uploadID!, offset: position.offset)
                } catch let failure as ServerClient.Failure where failure.status == 409 {
                    position = try await context.remote.uploadPosition(transfer.uploadID!)
                    guard position.size == Int64(expected.size) else { throw BackupStore.Failure.invalidReceipt }
                }
                progress(operation.id, "Uploading \(Int(Double(position.offset) / Double(position.size) * 100))%")
            }
            if position.offset == position.size {
                do {
                    let completed = try await context.remote.completeUpload(transfer.uploadID!)
                    try await apply(completed, operation: operation, lease: lease, context: context)
                    try await store.finishTransfer(transfer.id, state: .completed)
                } catch let failure as ServerClient.Failure where failure.status == 422 {
                    try await store.saveMetadata("rejected-upload:" + transfer.uploadID!.uuidString, value: true)
                    validatedOriginals.remove(resource.fileID)
                    try await store.finishTransfer(transfer.id, state: .failed)
                    throw failure
                }
            } else {
                try await store.finishTransfer(transfer.id, state: .unknown)
            }
            try await store.releaseReservation(reservation)
        } catch {
            if let current = try await store.transfers(operationID: operation.id).first(where: { $0.id == transfer.id }),
               !current.state.terminal {
                try await store.finishTransfer(transfer.id, state: .unknown)
            }
            try await store.releaseReservation(reservation)
            throw error
        }
    }

    private func apply(_ receipt: BackupAPI.Receipt, operation: BackupStore.Operation,
                       lease: BackupStore.Lease, context: BackupBindingContext) async throws {
        guard receipt.operationID == operation.id, receipt.version.origin == context.binding.origin,
              receipt.retention != .external || context.binding.mode == .immich else { throw BackupStore.Failure.invalidReceipt }
        _ = try await store.apply(receipt, operationID: operation.id, epoch: lease.epoch)
        if receipt.backup == .retained {
            try await store.releaseOriginalSpools(operation.id)
            if let workspace { try await workspace.collectReleasedFiles() }
        }
    }

    private func scheduleDiscovery() {
        guard visible, !retired, !suspended, context != nil else { return }
        guard discovery == nil else { discoveryAgain = true; return }
        let mine = generation, id = UUID()
        discoveryAgain = false
        let task = Task {
            var restart = true
            defer {
                if discovery?.id == id {
                    discovery = nil
                    if restart, discoveryAgain, visible, !retired, !suspended, generation == mine { scheduleDiscovery() }
                }
            }
            let delays = [1, 2, 4, 8, 15, 30]
            var attempt = 0
            while !retired, visible, !suspended, generation == mine {
                do {
                    try Task.checkCancellation()
                    discoveryAgain = false
                    guard let context else { return }
                    let sync = resultSync
                    let pending = try await store.needsResultDiscovery(bindingID: context.binding.id, namespace: namespace)
                    if !pending {
                        if discoveryAgain { continue }
                        return
                    }
                    try await discoverySleep(.seconds(delays[min(attempt, delays.count - 1)]))
                    guard !retired, visible, !suspended, generation == mine,
                          self.context?.binding.id == context.binding.id else { return }
                    try await sync.synchronize(context)
                    drive()
                } catch {
                    if Task.isCancelled { return }
                    if error is CancellationError { continue }
                    failed(error)
                    if let failure = error as? ServerClient.Failure,
                       failure.code == BackupAPI.ErrorCode.historyChanged || failure.code == BackupAPI.ErrorCode.unsupportedPreview {
                        restart = false
                        return
                    }
                    if error is BackupDatabase.Failure || error is BackupDatabase.RollbackFailure
                        || (error as? BackupStore.Failure) == .storageClosed {
                        restart = false
                        return
                    }
                }
                attempt = min(attempt + 1, delays.count - 1)
            }
        }
        discovery = .init(id: id, task: task)
    }

    func pause(only ids: Set<String>? = nil) async throws {
        guard let context else { return }
        schedulingPaused = true
        driver?.cancel()
        for (id, work) in active {
            if let ids, let operation = try await store.operation(id), !ids.contains(operation.itemID) { continue }
            work.task.cancel()
        }
        var cursor: Int64 = 0
        repeat {
            let page = try await store.operationPage(namespace: namespace, after: cursor)
            cursor = page.cursor
            for operation in page.operations where operation.bindingID == context.binding.id && operation.desired == .active
                && operation.delivery != .importedVerified && (ids?.contains(operation.itemID) ?? true) {
                try await store.setDesired(.paused, operationID: operation.id)
            }
            if !page.hasMore { break }
        } while true
        for (id, work) in active {
            if let ids, let operation = try await store.operation(id), !ids.contains(operation.itemID) { continue }
            work.task.cancel()
        }
        await changed([])
        if ids != nil { schedulingPaused = false; drive() }
    }

    func resume() async throws {
        guard !retired, let context else { return }
        var cursor: Int64 = 0
        repeat {
            let page = try await store.operationPage(namespace: namespace, after: cursor)
            cursor = page.cursor
            for operation in page.operations where operation.bindingID == context.binding.id
                && operation.desired == .paused && operation.delivery != .importedVerified {
                if try await store.decision(operation.itemID, namespace: namespace) { continue }
                try await store.setDesired(.active, operationID: operation.id)
            }
            if !page.hasMore { break }
        } while true
        await changed([])
        schedulingPaused = false
        drive()
        scheduleDiscovery()
    }

    func retire() {
        retired = true
        schedulingPaused = true
        generation &+= 1
        driver?.cancel()
        discovery?.task.cancel()
        resultSync.retire()
        for work in active.values { work.task.cancel() }
    }

    func stopAndWait() async throws {
        retire()
        await driver?.value
        await discovery?.task.value
        await resultSync.stopAndWait()
        let tasks = active.values.map(\.task)
        for task in tasks { await task.value }
        if let context { BackupExecutionSessions.release(context.session.id) }
        try await drainForegroundAttempts()
    }

    func suspend() {
        suspended = true
        generation &+= 1
        driver?.cancel()
        discovery?.task.cancel()
        resultSync.retire()
        for work in active.values { work.task.cancel() }
    }

    func suspendAndWait() async throws {
        suspend()
        await driver?.value
        await discovery?.task.value
        await resultSync.stopAndWait()
        let tasks = active.values.map(\.task)
        for task in tasks { await task.value }
        driver = nil
        discovery = nil
        try await drainForegroundAttempts()
    }

    func resumeExecution(schedule: Bool = true) {
        guard !retired else { return }
        suspended = false
        resultSync = ResultSync(store: store)
        configureSync()
        if schedule {
            drive()
            scheduleDiscovery()
        }
    }

    func detach() async throws {
        try await suspendAndWait()
        if let context {
            try await store.retireBinding(context.binding.id)
            BackupExecutionSessions.release(context.session.id)
        }
        context = nil
        workspace = nil
        suspended = false
        resultSync = ResultSync(store: store)
        configureSync()
    }

    private func releaseRetainedSpools(_ ids: Set<UUID>) async throws {
        guard let context, let workspace else { return }
        if ids.isEmpty {
            var cursor: Int64 = 0
            repeat {
                let page = try await store.operationPage(namespace: namespace, after: cursor)
                cursor = page.cursor
                for operation in page.operations where operation.bindingID == context.binding.id && operation.backup == .retained {
                    try await store.releaseOriginalSpools(operation.id)
                }
                if !page.hasMore { break }
            } while !Task.isCancelled
        } else {
            for id in ids {
                if let operation = try await store.operation(id),
                   operation.bindingID == context.binding.id, operation.backup == .retained {
                    try await store.releaseOriginalSpools(id)
                }
            }
        }
        try await workspace.collectReleasedFiles()
    }

    private func drainForegroundAttempts() async throws {
        let sessions = try await store.sessions()
        let transfers = try await store.transfers()
        for transfer in transfers where !transfer.state.terminal && active[transfer.operationID] == nil
            && sessions.contains(where: { $0.id == transfer.sessionID && !$0.background })
            && !BackupExecutionSessions.contains(transfer.sessionID) {
            try await store.finishTransfer(transfer.id, state: .failed)
            try await store.releaseReservation(transfer.id)
        }
    }

    func runOpportunity() async throws {
        guard !retired, !suspended else { throw CancellationError() }
        let id = UUID()
        opportunityIDs.insert(id)
        backgroundOpportunities += 1
        defer {
            backgroundOpportunities -= 1
            opportunityIDs.remove(id)
            if visible, !suspended { drive() }
        }
        do {
            try await withTaskCancellationHandler {
                try await reconcile()
                repeat {
                    try Task.checkCancellation()
                    drive()
                    await driver?.value
                    let work = active.values.map(\.task)
                    if work.isEmpty { break }
                    for task in work { await task.value }
                } while !Task.isCancelled
            } onCancel: {
                Task { @MainActor [weak self] in
                    guard let self, self.opportunityIDs.contains(id) else { return }
                    self.suspend()
                }
            }
            try Task.checkCancellation()
        } catch {
            if Task.isCancelled {
                try await suspendAndWait()
                opportunityIDs.remove(id)
                resumeExecution(schedule: false)
            }
            throw error
        }
    }
}
