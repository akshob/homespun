// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import Homespun

/// Stands in for the network: records requests and answers with a status.
private final class FakeService: @unchecked Sendable {
    let lock = NSLock()
    var requests: [URLRequest] = []
    var status = 202
    var body = Data("{}".utf8)

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let (status, body) = lock.withLock {
            requests.append(request)
            return (self.status, self.body)
        }
        return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    var sent: [URLRequest] { lock.withLock { requests } }

    func events(_ index: Int) -> [[String: Any]] {
        let json = try? JSONSerialization.jsonObject(with: sent[index].httpBody ?? Data()) as? [String: Any]
        return json?["events"] as? [[String: Any]] ?? []
    }
}

@MainActor private func makeTelemetry(_ service: FakeService) -> (Telemetry, UserDefaults) {
    let suite = "telemetry-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let queue = FileManager.default.temporaryDirectory.appendingPathComponent("\(suite).json")
    defaults.set(queue.path, forKey: "test.queue")
    let telemetry = Telemetry(defaults: defaults, queueURL: queue, endpoint: URL(string: "https://telemetry.example")!,
                              send: service.send)
    return (telemetry, defaults)
}

@MainActor @Test func nothingLeavesBeforeOrWithoutConsent() async {
    let service = FakeService()
    let (telemetry, _) = makeTelemetry(service)
    #expect(telemetry.consent == .unasked && telemetry.installID == nil)
    telemetry.record(.setupStep("question"))
    telemetry.record(.featureUsed("compare"))     // not a setup event: dropped while undecided
    await telemetry.flush()
    #expect(service.sent.isEmpty && telemetry.queued.isEmpty)

    telemetry.setSharing(false)
    telemetry.record(.featureUsed("compare"))
    telemetry.record(.setupStep("photos"))
    await telemetry.flush()
    #expect(service.sent.isEmpty && telemetry.queued.isEmpty && telemetry.installID == nil)
}

@MainActor @Test func sharingSendsSetupStepsFromBeforeTheChoiceInBatches() async throws {
    let service = FakeService()
    let (telemetry, _) = makeTelemetry(service)
    telemetry.record(.setupStep("question"))
    telemetry.record(.setupChoice("have", "macDesktop"))
    telemetry.setSharing(true)
    let install = try #require(telemetry.installID)
    #expect(telemetry.queued.map(\.name) == ["setup.step", "setup.choice", "analytics.optin"])
    for _ in 0..<150 { telemetry.record(.featureUsed("compare")) }
    await telemetry.flush()
    // 153 events: batches of 100 and 53, each with the install, app and device.
    #expect(service.sent.count == 2)
    #expect(service.events(0).count == 100 && service.events(1).count == 53)
    let request = service.sent[0]
    #expect(request.url?.path == "/v1/events" && request.value(forHTTPHeaderField: "X-Homespun-Key") == Telemetry.appKey)
    let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
    #expect(body["install"] as? String == install.uuidString.lowercased())
    #expect((body["app"] as? [String: String])?["channel"] == "debug")
    #expect((body["device"] as? [String: String])?["family"] != nil)
    #expect(service.events(0).first?["props"] as? [String: String] == ["step": "question"])
    #expect(telemetry.queued.isEmpty && telemetry.hasSharedData)
}

@MainActor @Test func failedSendsWaitForNextTimeAndRejectedOnesDont() async {
    let service = FakeService()
    let (telemetry, _) = makeTelemetry(service)
    telemetry.setSharing(true)
    service.status = 503
    await telemetry.flush()
    #expect(telemetry.queued.count == 1)                 // kept: the service was away
    service.status = 400
    await telemetry.flush()
    #expect(telemetry.queued.isEmpty)                    // dropped: it will never be accepted
}

@MainActor @Test func stoppingAndStartingAgainUsesANewInstallAndDeletingForgetsIt() async throws {
    let service = FakeService()
    let (telemetry, defaults) = makeTelemetry(service)
    telemetry.setSharing(true)
    let first = try #require(telemetry.installID)
    await telemetry.flush()
    telemetry.setSharing(false)
    #expect(telemetry.installID == nil && telemetry.queued.isEmpty && telemetry.hasSharedData)
    telemetry.setSharing(true)
    let second = try #require(telemetry.installID)
    #expect(first != second)
    await telemetry.flush() // Both identities actually sent, not just the first.
    // The choice survives a relaunch.
    let relaunched = Telemetry(defaults: defaults, queueURL: URL(fileURLWithPath: defaults.string(forKey: "test.queue")!),
                               endpoint: URL(string: "https://telemetry.example")!, send: service.send)
    #expect(relaunched.consent == .sharing && relaunched.installID == second)
    #expect(relaunched.deletionHandles == [first, second])

    service.status = 204
    try await relaunched.deleteSharedData()
    let deletes = service.sent.filter { $0.httpMethod == "DELETE" }.compactMap { $0.url?.lastPathComponent }
    #expect(Set(deletes) == [first.uuidString.lowercased(), second.uuidString.lowercased()])
    #expect(!relaunched.hasSharedData && relaunched.installID != second && relaunched.isSharing)
}

@MainActor @Test func reportsGoWithoutAnInstallWhenNotSharing() async throws {
    let service = FakeService()
    let (telemetry, _) = makeTelemetry(service)
    telemetry.setSharing(false)
    service.status = 201
    service.body = Data(#"{"id":"HS-7K3QWX"}"#.utf8)
    let id = try await telemetry.sendReport(ProblemReport(message: "It stopped", email: "me@example.com",
                                                          diagnostics: ["library": ["items": 3]]))
    #expect(id == "HS-7K3QWX")
    let body = try #require(try JSONSerialization.jsonObject(with: service.sent[0].httpBody!) as? [String: Any])
    #expect(body["install"] is NSNull && body["message"] as? String == "It stopped" && body["email"] as? String == "me@example.com")
    service.status = 429
    await #expect(throws: TelemetryError.self) {
        _ = try await telemetry.sendReport(ProblemReport(message: "Again"))
    }
}

@MainActor @Test func aReplyAddressNeverLinksAReportToAnalytics() async throws {
    let service = FakeService()
    let (telemetry, _) = makeTelemetry(service)
    telemetry.setSharing(true)
    let install = try #require(telemetry.installID)
    service.status = 201
    service.body = Data(#"{"id":"HS-7K3QWX"}"#.utf8)

    _ = try await telemetry.sendReport(ProblemReport(message: "It stopped", email: "me@example.com"))
    let identified = try #require(try JSONSerialization.jsonObject(with: service.sent[0].httpBody!) as? [String: Any])
    #expect(identified["install"] is NSNull && identified["email"] as? String == "me@example.com")
    #expect(!telemetry.hasSharedData)
    #expect(telemetry.queued.contains { $0.name == "report.sent" })

    _ = try await telemetry.sendReport(ProblemReport(message: "No reply needed"))
    let anonymous = try #require(try JSONSerialization.jsonObject(with: service.sent[1].httpBody!) as? [String: Any])
    #expect(anonymous["install"] as? String == install.uuidString.lowercased())
    #expect(anonymous["email"] == nil && telemetry.hasSharedData)
}

@Test func numbersAreRounded() {
    #expect([0, 1, 2, 3, 4, 5, 9, 10, 49, 50, 99, 999, 1000, 12_345].map(Bucket.count)
            == [0, 1, 2, 2, 2, 5, 5, 10, 20, 50, 50, 500, 1000, 10_000])
    #expect(Bucket.megabytes(7_300_000) == 5 && Bucket.seconds(61.4) == 50)
}

@MainActor @Test func eventsCarryCodesNotNames() {
    let unsupported = PhotoLibrary.Failure.unsupported("IMG_1234.HEIC has no original")
    #expect(Telemetry.Event.code(unsupported) == "photos:unsupported")
    #expect(Telemetry.Event.code(ServerClient.Failure(status: 409, message: "IMG_9.MOV", code: "kept_original"))
            == "server:kept_original")
    #expect(Telemetry.Event.code(URLError(.timedOut)) == "url:-1001")
    let event = Telemetry.Event.featureUsed("my photo/IMG 1.HEIC")
    #expect(event.props["feature"] == .string("myphotoIMG1.HEIC"))
    let target = SetupFlow.PairTarget(url: URL(string: "http://192.168.1.20:8787")!, name: "akshob's Mac")
    #expect(SetupFlow.Page.pair(target).analyticsName == "pair")
    #expect(SetupFlow.Page.guide(.mac).analyticsName == "guide.mac")
    #expect(SetupFlow.Page.analytics.analyticsName == "analytics")
}

@MainActor @Test func aSessionThatEndedOnScreenIsNoticed() {
    let defaults = UserDefaults(suiteName: "session-\(UUID().uuidString)")!
    let (telemetry, _) = makeTelemetry(FakeService())
    #expect(!SessionMarker(defaults: defaults, telemetry: telemetry).endedUnexpectedly)
    SessionMarker(defaults: defaults, telemetry: telemetry).active() // on screen, then killed
    let next = SessionMarker(defaults: defaults, telemetry: telemetry)
    #expect(next.endedUnexpectedly && !next.offersReport)            // Debug builds ask only with -crashPrompt
    next.active()
    next.background()                                                // left normally
    #expect(!SessionMarker(defaults: defaults, telemetry: telemetry).endedUnexpectedly)
    defaults.set(true, forKey: "crashPrompt")
    SessionMarker(defaults: defaults, telemetry: telemetry).active()
    #expect(SessionMarker(defaults: defaults, telemetry: telemetry).offersReport)
}

private actor SuspendedTelemetryService {
    private(set) var requests: [URLRequest] = []
    private var completions: [Int: CheckedContinuation<(Data, URLResponse), any Error>] = [:]
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let index = requests.count
        requests.append(request)
        return try await withCheckedThrowingContinuation { continuation in
            completions[index] = continuation
            let ready = waiters.filter { requests.count >= $0.0 }
            waiters.removeAll { requests.count >= $0.0 }
            ready.forEach { $0.1.resume() }
        }
    }

    func waitForRequests(_ count: Int) async {
        if requests.count < count { await withCheckedContinuation { waiters.append((count, $0)) } }
    }

    func finish(_ index: Int, status: Int = 202, body: String = "{}") {
        completions.removeValue(forKey: index)!.resume(returning: (
            Data(body.utf8),
            HTTPURLResponse(url: requests[index].url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        ))
    }
}

@MainActor private func suspendedTelemetry(_ service: SuspendedTelemetryService) -> (Telemetry, UserDefaults, URL) {
    let suite = "suspended-telemetry-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(suite).json")
    return (Telemetry(defaults: defaults, queueURL: url, endpoint: URL(string: "https://telemetry.example")!,
                      send: service.send), defaults, url)
}

@MainActor @Test func suspendedFlushCannotConsumeOrSendTheNextConsentQueue() async throws {
    let service = SuspendedTelemetryService()
    let (telemetry, _, _) = suspendedTelemetry(service)
    telemetry.setSharing(true)
    let first = try #require(telemetry.installID)
    let old = Task { await telemetry.flush() }
    await service.waitForRequests(1)
    telemetry.setSharing(false)
    telemetry.setSharing(true)
    telemetry.record(.featureUsed("compare"))
    let secondQueue = telemetry.queued
    let second = try #require(telemetry.installID)
    await service.finish(0)
    await old.value
    #expect(telemetry.queued == secondQueue && telemetry.deletionHandles == [first])
    let firstRequests = await service.requests
    #expect(firstRequests.count == 1)

    let current = Task { await telemetry.flush() }
    await service.waitForRequests(2)
    let requests = await service.requests
    let body = try #require(try JSONSerialization.jsonObject(with: requests[1].httpBody!) as? [String: Any])
    #expect(body["install"] as? String == second.uuidString.lowercased())
    await service.finish(1)
    await current.value
    #expect(telemetry.queued.isEmpty && telemetry.deletionHandles == [first, second])
}

@MainActor @Test func erasureWaitsForLateSendButPreservesNewSharingAndItsHandle() async throws {
    let service = SuspendedTelemetryService()
    let (telemetry, defaults, url) = suspendedTelemetry(service)
    telemetry.setSharing(true)
    let first = try #require(telemetry.installID)
    let old = Task { await telemetry.flush() }
    await service.waitForRequests(1)
    let erasure = Task { try await telemetry.deleteSharedData() }
    for _ in 0..<1000 {
        if telemetry.installID != first { break }
        await Task.yield()
    }
    let second = try #require(telemetry.installID)
    try #require(second != first)
    telemetry.record(.featureUsed("compare"))
    let current = Task { await telemetry.flush() }
    await service.waitForRequests(2)
    let admittedRequests = await service.requests
    #expect(admittedRequests.allSatisfy { $0.httpMethod == "POST" })
    await service.finish(1)
    await current.value
    await service.finish(0)
    await old.value
    await service.waitForRequests(3)
    let requests = await service.requests
    #expect(requests[2].httpMethod == "DELETE" && requests[2].url?.lastPathComponent == first.uuidString.lowercased())
    await service.finish(2, status: 204)
    try await erasure.value
    #expect(telemetry.installID == second && telemetry.deletionHandles == [second])
    let relaunched = Telemetry(defaults: defaults, queueURL: url, endpoint: nil)
    #expect(relaunched.deletionHandles == [second] && relaunched.installID == second)
}

@MainActor @Test func metricAndReportAttemptsKeepTheirOriginalErasureHandle() async throws {
    for report in [false, true] {
        let service = SuspendedTelemetryService()
        let (telemetry, _, _) = suspendedTelemetry(service)
        telemetry.setSharing(true)
        let first = try #require(telemetry.installID)
        let sending = Task {
            if report { _ = try await telemetry.sendReport(ProblemReport(message: "Stopped")) }
            else {
                let at = Date()
                await telemetry.upload(payload: Data("{}".utf8), kind: "metrics", begin: at, end: at)
            }
        }
        await service.waitForRequests(1)
        telemetry.setSharing(false)
        telemetry.setSharing(true)
        let queue = telemetry.queued
        await service.finish(0, status: report ? 201 : 202, body: #"{"id":"HS-ABCDEF"}"#)
        try await sending.value
        #expect(telemetry.deletionHandles == [first] && telemetry.queued == queue)
    }
}

@MainActor @Test func legacySentHandleMigratesAndFailedErasureRemainsRetryable() async throws {
    let service = FakeService()
    let suite = "legacy-telemetry-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let old = UUID()
    defaults.set(old.uuidString, forKey: "telemetry.sentInstall")
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(suite).json")
    let telemetry = Telemetry(defaults: defaults, queueURL: url, endpoint: URL(string: "https://telemetry.example")!,
                              send: service.send)
    #expect(defaults.string(forKey: "telemetry.sentInstall") == nil)
    for status in [503, 404] {
        service.status = status
        await #expect(throws: TelemetryError.self) { try await telemetry.deleteSharedData() }
        #expect(telemetry.deletionHandles == [old])
    }
    let relaunched = Telemetry(defaults: defaults, queueURL: url, endpoint: URL(string: "https://telemetry.example")!,
                               send: service.send)
    #expect(relaunched.deletionHandles == [old])
    service.status = 204
    try await relaunched.deleteSharedData()
    #expect(!relaunched.hasSharedData)
}

@MainActor @Test func metricAggregatesCannotBridgeConsentPeriods() async throws {
    let service = FakeService()
    let suite = "metric-consent-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    var now = Date(timeIntervalSince1970: 100)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(suite).json")
    let telemetry = Telemetry(defaults: defaults, queueURL: url, endpoint: URL(string: "https://telemetry.example")!,
                              now: { now }, send: service.send)
    let payload = Data("{}".utf8)
    telemetry.setSharing(true)
    let first = try #require(telemetry.installID)
    now = Date(timeIntervalSince1970: 120)
    await telemetry.upload(payload: payload, kind: "metrics", begin: Date(timeIntervalSince1970: 110), end: now)
    now = Date(timeIntervalSince1970: 200)
    telemetry.setSharing(false)
    now = Date(timeIntervalSince1970: 300)
    telemetry.setSharing(true)
    let second = try #require(telemetry.installID)
    now = Date(timeIntervalSince1970: 400)
    for begin in [110.0, 250.0] {
        await telemetry.upload(payload: payload, kind: "metrics", begin: Date(timeIntervalSince1970: begin), end: now)
    }
    #expect(service.sent.count == 1 && telemetry.deletionHandles == [first])
    await telemetry.upload(payload: payload, kind: "metrics", begin: Date(timeIntervalSince1970: 310), end: now)
    #expect(service.sent.count == 2 && telemetry.deletionHandles == [first, second])
}

@MainActor @Test func failedQueueWriteCannotResurrectOldConsentOnRelaunch() async throws {
    let service = FakeService()
    let (telemetry, defaults) = makeTelemetry(service)
    let url = URL(fileURLWithPath: defaults.string(forKey: "test.queue")!)
    telemetry.setSharing(true)
    let first = try #require(telemetry.installID)
    await telemetry.flush()
    let oldState = try Data(contentsOf: url)
    try FileManager.default.removeItem(at: url)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    telemetry.setSharing(false) // The consent fence succeeds even though the file write cannot.
    #expect(telemetry.lastError != nil)
    try FileManager.default.removeItem(at: url)
    try oldState.write(to: url)
    let relaunched = Telemetry(defaults: defaults, queueURL: url, endpoint: nil)
    #expect(relaunched.consent == .notSharing && relaunched.installID == nil && relaunched.queued.isEmpty)
    #expect(relaunched.deletionHandles == [first])
}

@MainActor @Test func resumedDemoSuppressesColdCrashAndDelayedMixedDiagnostics() async throws {
    let service = FakeService()
    let suite = "demo-diagnostics-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    var now = Date(timeIntervalSince1970: 100)
    let policy = DiagnosticPolicy(defaults: defaults, now: { now })
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(suite).json")
    var telemetry = Telemetry(defaults: defaults, queueURL: url, endpoint: URL(string: "https://telemetry.example")!,
                              diagnosticPolicy: policy, now: { now }, send: service.send)
    telemetry.setSharing(true)
    let realQueue = telemetry.queued.map(\.name)
    now = Date(timeIntervalSince1970: 200)
    telemetry.paused = true
    now = Date(timeIntervalSince1970: 250)
    let resumedPolicy = DiagnosticPolicy(defaults: defaults, now: { now })
    telemetry = Telemetry(defaults: defaults, queueURL: url, endpoint: URL(string: "https://telemetry.example")!,
                          diagnosticPolicy: resumedPolicy, now: { now }, send: service.send)
    telemetry.paused = true
    telemetry.resolveDiagnosticNamespace()
    // Namespace resolution precedes both SessionMarker and the receiver on a resumed launch.
    defaults.set(true, forKey: "session.foreground")
    defaults.set(true, forKey: "crashPrompt")
    let marker = SessionMarker(defaults: defaults, telemetry: telemetry)
    #expect(!marker.endedUnexpectedly && !marker.offersReport)
    let store = DiagnosticsStore(folder: url.deletingPathExtension(), isPaused: { telemetry.paused })
    let receiver = MetricsReceiver(telemetry: telemetry, store: store)
    let data = Data(#"{"crashDiagnostics":[]}"#.utf8)
    await receiver.receive(data, begin: Date(timeIntervalSince1970: 110), end: now, kind: "diagnostics")
    await telemetry.flush()
    await telemetry.upload(payload: data, kind: "diagnostics", begin: now, end: now)
    #expect(store.latest() == nil && service.sent.isEmpty && telemetry.queued.map(\.name) == realQueue)
    now = Date(timeIntervalSince1970: 300)
    telemetry.paused = false
    let relaunchedPolicy = DiagnosticPolicy(defaults: defaults, now: { now })
    #expect(!relaunchedPolicy.allows(begin: Date(timeIntervalSince1970: 150), end: now))
    #expect(!relaunchedPolicy.allows(begin: Date(timeIntervalSince1970: 50), end: Date(timeIntervalSince1970: 60)))
    await receiver.receive(data, begin: Date(timeIntervalSince1970: 150), end: now, kind: "diagnostics")
    #expect(store.latest() == nil && service.sent.isEmpty)
    now = Date(timeIntervalSince1970: 400)
    await receiver.receive(data, begin: Date(timeIntervalSince1970: 310), end: now, kind: "diagnostics")
    #expect(store.latest() != nil && service.sent.count == 1)
    #expect(telemetry.consent == .sharing && telemetry.queued.map(\.name) == realQueue)
}

@MainActor @Test func legacyUnattributedDiagnosticCachesNeverEnterAProblemReport() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("diagnostic-cache-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data(#"{"crashDiagnostics":[{"legacy":"possibly demo"}]}"#.utf8)
        .write(to: folder.appendingPathComponent("1.json"))
    let store = DiagnosticsStore(folder: folder, isPaused: { false })
    #expect(store.latest() == nil)
}

/// The first task (10 items) asks iOS for background time: whatever iOS answers, or raises, the
/// app must carry on (0.1.0 ended here on a device when iOS raised at submit).
@MainActor @Test func askingForBackgroundTimeNeverEndsTheApp() {
    #expect(LongRun.shared.begin(items: 3, server: "test") == .notNeeded)
    let outcome = LongRun.shared.begin(items: LongRun.minimumItems, server: "test")
    print("LongRun on this simulator: \(outcome)")
    #expect(outcome != .notNeeded)
}

/// Sent reports are kept on this iPhone, newest first, so their numbers can be found later.
@MainActor @Test func sentReportsAreKeptNewestFirst() throws {
    let defaults = try #require(UserDefaults(suiteName: "sent-reports-\(UUID().uuidString)"))
    let reports = SentReports(defaults: defaults)
    reports.add(id: "HS-AAAAAA", message: "The grid was blank\nthen it crashed", at: Date(timeIntervalSince1970: 1))
    reports.add(id: "HS-BBBBBB", message: String(repeating: "x", count: 300), at: Date(timeIntervalSince1970: 2))
    #expect(reports.reports.map(\.id) == ["HS-BBBBBB", "HS-AAAAAA"])
    #expect(reports.reports[1].summary == "The grid was blank" && reports.reports[0].summary.count == 120)
    // Survives a relaunch; the oldest go past the limit; a number is listed once.
    #expect(SentReports(defaults: defaults).reports.map(\.id) == ["HS-BBBBBB", "HS-AAAAAA"])
    for index in 0..<SentReports.limit { reports.add(id: "HS-\(index)", message: "m") }
    reports.add(id: "HS-0", message: "again")
    #expect(reports.reports.count == SentReports.limit && reports.reports.first?.id == "HS-0")
    #expect(!reports.reports.contains { $0.id == "HS-AAAAAA" })
    #expect(reports.reports.filter { $0.id == "HS-0" }.count == 1)
}
