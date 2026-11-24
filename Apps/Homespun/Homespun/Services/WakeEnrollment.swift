// SPDX-License-Identifier: Apache-2.0
import Foundation
import HomespunCore
import Observation

@MainActor @Observable
final class WakeEnrollment {
    struct Target {
        var bindingID: UUID
        var enroll: @MainActor @Sendable (WakeRelayAPI.Sender) async throws -> Void
        var reconcile: @MainActor @Sendable () async throws -> Bool
    }

    private struct HintWaiter {
        var continuation: CheckedContinuation<Void, Never>
        var timeout: Task<Void, Never>
    }

    private(set) var enabled: Bool?
    private(set) var busy = false
    private(set) var cleanupPending = false
    private(set) var problem: String?
    @ObservationIgnored private var state: WakeEnrollmentState?
    @ObservationIgnored private let storage: any WakeEnrollmentStoring
    @ObservationIgnored private let relayURL: URL?
    @ObservationIgnored private let environment: WakeRelayAPI.Environment
    @ObservationIgnored private let makeClient: @Sendable (URL) throws -> any WakeRelayServing
    @ObservationIgnored private let demo: Bool
    @ObservationIgnored private let allowed: @MainActor @Sendable () -> Bool
    @ObservationIgnored private var target: Target?
    @ObservationIgnored private var token: String?
    @ObservationIgnored private var runtimeEpoch = UUID()
    @ObservationIgnored private var paused = false
    @ObservationIgnored private var admissionBlocked = false
    @ObservationIgnored private var work: (id: UUID, task: Task<Void, any Error>)?
    @ObservationIgnored private var hintWaiters: [UUID: HintWaiter] = [:]

    init(relayURL: URL?, environment: WakeRelayAPI.Environment, storage: any WakeEnrollmentStoring,
         demo: Bool = false, allowed: @escaping @MainActor @Sendable () -> Bool = { !Telemetry.paused },
         makeClient: @escaping @Sendable (URL) throws -> any WakeRelayServing = { try WakeRelayClient(baseURL: $0) }) {
        self.relayURL = relayURL
        self.environment = environment
        self.storage = storage
        self.demo = demo
        self.allowed = allowed
        self.makeClient = makeClient
    }

    var available: Bool { relayURL != nil && !demo }
    var shouldRegisterForPush: Bool { enabled == true && target != nil && available && !paused && !admissionBlocked && allowed() }

    func load() throws {
        guard !demo else { throw WakeEnrollmentFailure.demo }
        _ = try loaded()
    }

    func setEnabled(_ value: Bool) async throws {
        guard !demo else { throw WakeEnrollmentFailure.demo }
        if value {
            guard relayURL != nil else { throw WakeEnrollmentFailure.unavailable }
            guard target != nil else { throw WakeEnrollmentFailure.noServer }
        } else {
            admissionBlocked = true
            runtimeEpoch = UUID()
            work?.task.cancel()
            finishHintWaiters()
        }
        var next = try loaded()
        next.enabled = value
        next.epoch = UUID()
        if !value { Self.retireActive(&next) }
        try save(next)
        if value { admissionBlocked = false }
        runtimeEpoch = UUID()
        await joinCurrent()
        try await reconcile()
    }

    func configure(_ next: Target?) async throws {
        guard !demo else { return }
        runtimeEpoch = UUID()
        await joinCurrent()
        target = next
        if next != nil { finishHintWaiters() }
        var current = try loaded()
        if let active = current.active, active.bindingID != next?.bindingID {
            Self.retireActive(&current)
            try save(current)
        }
        try await reconcile()
    }

    func receivedDeviceToken(_ bytes: Data) async throws {
        guard !demo else { return }
        guard !bytes.isEmpty else { throw WakeEnrollmentFailure.invalidResponse }
        token = bytes.map { String(format: "%02x", $0) }.joined()
        try await reconcile()
    }

    func pauseAndWait() async {
        paused = true
        runtimeEpoch = UUID()
        finishHintWaiters()
        await joinCurrent()
    }

    func resume() async throws {
        guard !demo else { return }
        paused = false
        try await reconcile()
    }

    func receiveHint() async throws -> Bool {
        guard !demo, !paused, !admissionBlocked, allowed() else { return false }
        guard try loaded().enabled else { return false }
        if target == nil { await waitForTarget() }
        guard !paused, !admissionBlocked, allowed(), let target else { return false }
        let current = try loaded()
        guard current.enabled, let active = current.active, active.linked,
              active.bindingID == target.bindingID else { return false }
        return try await target.reconcile()
    }

    func registrationFailed() {
        problem = "iOS could not register background wakeups. Existing backups remain queued."
    }

    func enrollmentFailed() {
        problem = "The private wake enrollment needs attention. Backups remain queued and cleanup will retry."
    }

    private func waitForTarget() async {
        guard target == nil else { return }
        let id = UUID()
        await withCheckedContinuation { continuation in
            let timeout = Task { @MainActor in
                do { try await Task.sleep(for: .seconds(3)) }
                catch { return }
                finishHintWaiter(id)
            }
            hintWaiters[id] = .init(continuation: continuation, timeout: timeout)
        }
    }

    private func finishHintWaiter(_ id: UUID) {
        guard let waiter = hintWaiters.removeValue(forKey: id) else { return }
        waiter.timeout.cancel()
        waiter.continuation.resume()
    }

    private func finishHintWaiters() {
        for id in Array(hintWaiters.keys) { finishHintWaiter(id) }
    }

    private func reconcile() async throws {
        guard !demo, !paused, allowed() else { return }
        if let work { try await work.task.value; return }
        let epoch = runtimeEpoch, id = UUID()
        let task = Task { @MainActor in try await self.drive(epoch: epoch, renewals: 1) }
        work = (id, task)
        busy = true
        defer {
            if work?.id == id { work = nil; busy = false }
        }
        do {
            try await task.value
        } catch {
            if runtimeEpoch == epoch, !(error is CancellationError) {
                problem = error is WakeEnrollmentFailure ? error.localizedDescription
                    : "The wake service could not be reached. Private cleanup will retry; backups remain queued."
            }
            throw error
        }
    }

    private func drive(epoch: UUID, renewals: Int) async throws {
        problem = nil
        for record in try loaded().retiring {
            try Task.checkCancellation()
            guard epoch == runtimeEpoch, !paused, allowed() else { return }
            do {
                try await makeClient(record.relayURL).erase(id: record.id, managementToken: record.managementToken)
                var latest = try loaded()
                latest.retiring.removeAll { $0.id == record.id }
                try save(latest)
            } catch is CancellationError { throw CancellationError() }
            catch { problem = "An earlier wake enrollment still needs private cleanup. It will be retried." }
        }
        try Task.checkCancellation()
        guard epoch == runtimeEpoch, !paused, !admissionBlocked, allowed(), try loaded().enabled,
              let relayURL, let target, let token else { return }
        var current = try loaded()
        if current.active == nil {
            current.active = WakeEnrollmentRecord(id: UUID(), relayURL: relayURL, bindingID: target.bindingID,
                managementToken: PairingCrypto.encode(PairingCrypto.nonce()),
                senderToken: PairingCrypto.encode(PairingCrypto.nonce()))
            try save(current)
        }
        guard var record = try loaded().active, record.bindingID == target.bindingID else { throw WakeEnrollmentFailure.noServer }
        let consentEpoch = try loaded().epoch
        let tokenHash = Fingerprint.sha256(of: Data(token.utf8))
        if record.linked, record.tokenHash == tokenHash, let refreshed = record.refreshedAt,
           Date().timeIntervalSince(refreshed) >= 0, Date().timeIntervalSince(refreshed) < 86_400 { return }
        let client = try makeClient(record.relayURL)
        if record.generationID == nil {
            let registration = try await client.begin(id: record.id, managementToken: record.managementToken)
            try check(record: record, consentEpoch: consentEpoch, runtime: epoch)
            record.generationID = registration.generationID
            try updateActive(record)
        }
        guard let generation = record.generationID else { throw WakeEnrollmentFailure.invalidResponse }
        try check(record: record, consentEpoch: consentEpoch, runtime: epoch)
        do {
            try await client.activate(id: record.id, managementToken: record.managementToken,
                body: .init(generationID: generation, deviceToken: token, environment: environment, senderToken: record.senderToken))
        } catch WakeEnrollmentFailure.expired {
            try check(record: record, consentEpoch: consentEpoch, runtime: epoch)
            guard renewals > 0 else { throw WakeEnrollmentFailure.expired }
            var latest = try loaded()
            Self.retireActive(&latest)
            try save(latest)
            try await drive(epoch: epoch, renewals: renewals - 1)
            return
        }
        try check(record: record, consentEpoch: consentEpoch, runtime: epoch)
        record.tokenHash = tokenHash
        record.refreshedAt = Date()
        try updateActive(record)
        try await target.enroll(.init(routeID: record.id, generationID: generation, token: record.senderToken))
        try check(record: record, consentEpoch: consentEpoch, runtime: epoch)
        record.linked = true
        try updateActive(record)
    }

    private func check(record: WakeEnrollmentRecord, consentEpoch: UUID, runtime: UUID) throws {
        try Task.checkCancellation()
        let current = try loaded()
        guard runtime == runtimeEpoch, !paused, !admissionBlocked, allowed(), current.enabled, current.epoch == consentEpoch,
              current.active?.id == record.id, target?.bindingID == record.bindingID else { throw CancellationError() }
    }

    private func updateActive(_ record: WakeEnrollmentRecord) throws {
        var latest = try loaded()
        guard latest.active?.id == record.id else { throw CancellationError() }
        latest.active = record
        try save(latest)
    }

    private func loaded() throws -> WakeEnrollmentState {
        if let state { return state }
        let state = try storage.load()
        let all = state.retiring + (state.active.map { [$0] } ?? [])
        guard Set(all.map(\.id)).count == all.count,
              all.allSatisfy({ PairingCrypto.decode($0.managementToken, count: 32) != nil
                  && PairingCrypto.decode($0.senderToken, count: 32) != nil && $0.relayURL.scheme == "https" }) else {
            throw WakeEnrollmentFailure.storage
        }
        self.state = state
        enabled = state.enabled
        cleanupPending = !state.retiring.isEmpty
        return state
    }

    private func save(_ next: WakeEnrollmentState) throws {
        try storage.save(next)
        state = next
        enabled = next.enabled
        cleanupPending = !next.retiring.isEmpty
    }

    private static func retireActive(_ state: inout WakeEnrollmentState) {
        if let active = state.active { state.retiring.append(active) }
        state.active = nil
    }

    private func joinCurrent() async {
        guard let pending = work else { return }
        pending.task.cancel()
        do { try await pending.task.value }
        catch is CancellationError {}
        catch { problem = "An interrupted wake request will be reconciled before another enrollment." }
        if work?.id == pending.id { work = nil; busy = false }
    }
}
