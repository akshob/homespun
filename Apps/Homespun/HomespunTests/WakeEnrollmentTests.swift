// SPDX-License-Identifier: Apache-2.0
import Foundation
import HomespunCore
import Testing
@testable import Homespun

@MainActor @Test func backgroundWakeupsAreHiddenWithoutAConfiguredRelay() {
    #expect(WakeSystem.relayURL(configured: "", pushEnvironment: "") == nil)
    #expect(WakeSystem.relayURL(configured: "https://wake.example.invalid", pushEnvironment: "") == nil)
    #expect(WakeSystem.relayURL(configured: "https://wake.example.invalid", pushEnvironment: "production") != nil)
    #expect(!WakeSystem.relayConfigured && !ServerTab.Route.wake.isAvailable)
}

@MainActor private final class WakeMemoryStore: WakeEnrollmentStoring {
    var value = WakeEnrollmentState()
    var failSave = false
    var reads = 0
    private var retiredWaiter: CheckedContinuation<Void, Never>?

    func load() -> WakeEnrollmentState { reads += 1; return value }
    func save(_ state: WakeEnrollmentState) throws {
        guard !failSave else { throw WakeEnrollmentFailure.storage }
        value = state
        if !state.enabled, !state.retiring.isEmpty {
            retiredWaiter?.resume()
            retiredWaiter = nil
        }
    }
    func untilRetired() async {
        if !value.enabled, !value.retiring.isEmpty { return }
        await withCheckedContinuation { retiredWaiter = $0 }
    }
}

private actor WakeRelayStandIn: WakeRelayServing {
    private var holdBegin = false
    private var failErase = false
    private var begun: [UUID] = []
    private var activated: [UUID] = []
    private var erased: [UUID] = []
    private var beginWaiters: [CheckedContinuation<Void, Never>] = []
    private var release: CheckedContinuation<Void, Never>?

    func suspendBegin() { holdBegin = true }
    func setEraseFailure(_ value: Bool) { failErase = value }
    func begin(id: UUID, managementToken: String) async -> WakeRelayAPI.Registration {
        begun.append(id)
        for waiter in beginWaiters { waiter.resume() }
        beginWaiters = []
        if holdBegin { await withCheckedContinuation { release = $0 } }
        return .init(generationID: UUID())
    }
    func activate(id: UUID, managementToken: String, body: WakeRelayAPI.Activation) {
        activated.append(id)
    }
    func erase(id: UUID, managementToken: String) throws {
        if failErase { throw WakeEnrollmentFailure.unavailable }
        erased.append(id)
    }
    func untilBegin() async {
        if !begun.isEmpty { return }
        await withCheckedContinuation { beginWaiters.append($0) }
    }
    func releaseBegin() { release?.resume(); release = nil; holdBegin = false }
    func activations() -> [UUID] { activated }
    func erasures() -> [UUID] { erased }
}

@MainActor private final class WakeHomeStandIn {
    var enrolled: [UUID] = []
    var reconciliations = 0
    let bindingID = UUID()
    var target: WakeEnrollment.Target {
        .init(bindingID: bindingID, enroll: { [self] sender in enrolled.append(sender.routeID) },
              reconcile: { [self] in reconciliations += 1; return true })
    }
}

@MainActor private func wakeService(_ storage: WakeMemoryStore, _ relay: WakeRelayStandIn,
                                    demo: Bool = false) -> WakeEnrollment {
    WakeEnrollment(relayURL: URL(string: "https://wake.invalid")!, environment: .sandbox,
                   storage: storage, demo: demo, allowed: { true }, makeClient: { _ in relay })
}

@MainActor @Test func revokingWakeConsentDuringBeginNeverActivatesAndErasesItsHandle() async throws {
    let storage = WakeMemoryStore(), relay = WakeRelayStandIn(), home = WakeHomeStandIn()
    let service = wakeService(storage, relay)
    try await service.configure(home.target)
    try await service.receivedDeviceToken(Data([1, 2, 3]))
    await relay.suspendBegin()
    let enabling = Task { try await service.setEnabled(true) }
    await relay.untilBegin()
    let disabling = Task { try await service.setEnabled(false) }
    await storage.untilRetired()
    let retiredID = try #require(storage.value.retiring.first?.id)
    await relay.releaseBegin()
    _ = await enabling.result
    try await disabling.value
    #expect(await relay.activations().isEmpty)
    #expect(await relay.erasures() == [retiredID])
    #expect(storage.value.active == nil && storage.value.retiring.isEmpty && !storage.value.enabled)
    #expect(home.enrolled.isEmpty)
}

@MainActor @Test func wakeErasureHandlesSurviveRelaunchAndNewEnrollment() async throws {
    let storage = WakeMemoryStore(), relay = WakeRelayStandIn(), home = WakeHomeStandIn()
    let first = wakeService(storage, relay)
    try await first.configure(home.target)
    try await first.receivedDeviceToken(Data([4, 5, 6]))
    try await first.setEnabled(true)
    let old = try #require(storage.value.active?.id)
    await relay.setEraseFailure(true)
    try await first.setEnabled(false)
    #expect(first.cleanupPending && storage.value.retiring.map(\.id) == [old])
    let returning = wakeService(storage, relay)
    try await returning.configure(home.target)
    try await returning.receivedDeviceToken(Data([4, 5, 6]))
    try await returning.setEnabled(true)
    let current = try #require(storage.value.active?.id)
    #expect(current != old && storage.value.retiring.map(\.id) == [old])
    await relay.setEraseFailure(false)
    try await returning.resume()
    #expect(storage.value.active?.id == current && storage.value.retiring.isEmpty)
    #expect(await relay.erasures().contains(old))
}

@MainActor @Test func failedWakePrivacyPersistenceStillBlocksNewHintsInMemory() async throws {
    let storage = WakeMemoryStore(), relay = WakeRelayStandIn(), home = WakeHomeStandIn()
    let service = wakeService(storage, relay)
    try await service.configure(home.target)
    try await service.receivedDeviceToken(Data([7, 8, 9]))
    try await service.setEnabled(true)
    storage.failSave = true
    await #expect(throws: WakeEnrollmentFailure.storage) { try await service.setEnabled(false) }
    #expect(!service.shouldRegisterForPush)
    #expect(try await service.receiveHint() == false)
    #expect(home.reconciliations == 0)
}

@MainActor @Test func demoWakeServiceNeverReadsCredentialsOrEnrolls() async throws {
    let storage = WakeMemoryStore(), relay = WakeRelayStandIn(), home = WakeHomeStandIn()
    let service = wakeService(storage, relay, demo: true)
    await #expect(throws: WakeEnrollmentFailure.demo) { try await service.setEnabled(true) }
    try await service.configure(home.target)
    try await service.receivedDeviceToken(Data([1]))
    #expect(try await service.receiveHint() == false)
    #expect(storage.reads == 0)
    #expect(await relay.activations().isEmpty && home.enrolled.isEmpty)
}

@MainActor @Test func aColdWakeWaitsBrieflyForItsAuthenticatedCompositionTarget() async throws {
    let storage = WakeMemoryStore(), relay = WakeRelayStandIn(), home = WakeHomeStandIn()
    let first = wakeService(storage, relay)
    try await first.configure(home.target)
    try await first.receivedDeviceToken(Data([1, 2, 3]))
    try await first.setEnabled(true)
    let returning = wakeService(storage, relay)
    let hint = Task { try await returning.receiveHint() }
    await Task.yield()
    try await returning.configure(home.target)
    #expect(try await hint.value)
    #expect(home.reconciliations == 1)
}
