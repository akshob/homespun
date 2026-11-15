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
    // The choice survives a relaunch.
    let relaunched = Telemetry(defaults: defaults, queueURL: FileManager.default.temporaryDirectory.appendingPathComponent("x.json"),
                               endpoint: URL(string: "https://telemetry.example")!, send: service.send)
    #expect(relaunched.consent == .sharing && relaunched.installID == second)

    service.status = 204
    try await telemetry.deleteSharedData()
    let deletes = service.sent.filter { $0.httpMethod == "DELETE" }.compactMap { $0.url?.lastPathComponent }
    #expect(Set(deletes) == [first.uuidString.lowercased(), second.uuidString.lowercased()])
    #expect(!telemetry.hasSharedData && telemetry.installID != second && telemetry.isSharing)
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
    #expect(!SessionMarker(defaults: defaults).endedUnexpectedly)
    SessionMarker(defaults: defaults).active()                       // on screen, then killed
    let next = SessionMarker(defaults: defaults)
    #expect(next.endedUnexpectedly && !next.offersReport)            // Debug builds ask only with -crashPrompt
    next.active()
    next.background()                                                // left normally
    #expect(!SessionMarker(defaults: defaults).endedUnexpectedly)
    defaults.set(true, forKey: "crashPrompt")
    SessionMarker(defaults: defaults).active()
    #expect(SessionMarker(defaults: defaults).offersReport)
}
