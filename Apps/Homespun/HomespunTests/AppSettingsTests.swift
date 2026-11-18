// SPDX-License-Identifier: Apache-2.0
import Foundation
import HomespunCore
import Testing
@testable import Homespun

@MainActor @Suite(.serialized) struct AppSettingsTests {
    @Test func retryKeepsTheLastServerStatusUntilItConcludes() async throws {
        let name = "server-check-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ServerCheckProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let settings = AppSettings(defaults: defaults, tokens: DemoTokens(defaults: defaults), session: session)
        try settings.finishPairing(serverURL: URL(string: "https://server.invalid")!,
                                   response: .init(deviceID: "test-device", token: "test-token", server: DemoServer.info))
        let first = Task { await settings.refreshServerInfo() }
        try await pendingRequest()
        #expect(settings.serverStatus == .reachable)
        ServerCheckProtocol.fail()
        await first.value
        guard case .unreachable = settings.serverStatus else {
            Issue.record("the failed check wasn't reported")
            return
        }
        let unreachable = settings.serverStatus
        let checkedAt = settings.serverCheckedAt
        let retry = Task { await settings.refreshServerInfo() }
        try await pendingRequest()
        #expect(settings.serverStatus == unreachable, "retrying must not blink the accessory off")
        #expect(settings.serverCheckedAt == checkedAt)
        ServerCheckProtocol.fail()
        await retry.value
        #expect(settings.serverStatus == unreachable)
    }

    private func pendingRequest() async throws {
        for _ in 0..<500 {
            if !ServerCheckProtocol.pending.isEmpty { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw RequestDidNotStart()
    }

    private struct RequestDidNotStart: Error {}
}

private final class ServerCheckProtocol: URLProtocol, @unchecked Sendable {
    static let pending = Requests()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.pending.append(self) }
    override func stopLoading() { Self.pending.remove(self) }

    static func fail() {
        let request = pending.take()
        if let request { request.client?.urlProtocol(request, didFailWithError: URLError(.cannotConnectToHost)) }
    }

    final class Requests: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [ServerCheckProtocol] = []
        var isEmpty: Bool { lock.withLock { requests.isEmpty } }

        func append(_ request: ServerCheckProtocol) { lock.withLock { requests.append(request) } }
        func remove(_ request: ServerCheckProtocol) { lock.withLock { requests.removeAll { $0 === request } } }
        func take() -> ServerCheckProtocol? { lock.withLock { requests.isEmpty ? nil : requests.removeFirst() } }
    }
}
