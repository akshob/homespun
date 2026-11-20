// SPDX-License-Identifier: Apache-2.0
import CryptoKit
import Foundation
import HomespunCore
import os
import Security

enum ServerTrust: Hashable, Sendable {
    case pinned(Set<ServerKeyFingerprint>)
    case system
    case capture(expected: ServerKeyFingerprint?)
    case demo
    case blocked(String)
}

enum ServerKey {
    static func certificate(of trust: SecTrust) -> SecCertificate? {
        (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first
    }

    static func fingerprint(of trust: SecTrust) -> ServerKeyFingerprint? {
        guard let leaf = certificate(of: trust) else { return nil }
        return fingerprint(of: leaf)
    }

    static func fingerprint(of certificate: SecCertificate) -> ServerKeyFingerprint? {
        guard let key = SecCertificateCopyKey(certificate),
              let attributes = SecKeyCopyAttributes(key) as? [CFString: Any],
              attributes[kSecAttrKeyType] as? String == kSecAttrKeyTypeECSECPrimeRandom as String,
              attributes[kSecAttrKeySizeInBits] as? Int == 256,
              let bytes = SecKeyCopyExternalRepresentation(key, nil) as Data?,
              let publicKey = try? P256.Signing.PublicKey(x963Representation: bytes) else { return nil }
        return ServerKeyFingerprint(spki: publicKey.derRepresentation)
    }
}

actor SessionPinGate {
    private var verified = false
    private var pending: Task<Void, any Error>?

    func verify(_ probe: @escaping @Sendable () async throws -> Void) async throws {
        if verified { return }
        if let pending { try await pending.value; return }
        let task = Task { try await probe() }
        pending = task
        do {
            try await task.value
            verified = true
            pending = nil
        } catch {
            pending = nil
            throw error
        }
    }
}

final class ServerSessionLifetime: Sendable {
    private struct State {
        var active = 0
        var retired = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let invalidate: @Sendable (URLSession) -> Void

    init(invalidate: @escaping @Sendable (URLSession) -> Void = { $0.invalidateAndCancel() }) {
        self.invalidate = invalidate
    }

    func withOperation<Value>(session: URLSession, _ operation: () async throws -> Value) async throws -> Value {
        try state.withLock { state in
            guard !state.retired else { throw URLError(.cancelled) }
            state.active += 1
        }
        defer {
            let finished = state.withLock { state in
                state.active -= 1
                return state.retired && state.active == 0
            }
            if finished { invalidate(session) }
        }
        return try await operation()
    }

    func checkUsable() throws {
        try state.withLock { state in
            guard !state.retired else { throw URLError(.cancelled) }
        }
    }

    func retire(session: URLSession) {
        let finished = state.withLock { state in
            guard !state.retired else { return false }
            state.retired = true
            return state.active == 0
        }
        // URLSession traps when a task is created after invalidation. An admitted operation may
        // still be resuming from its pin probe, so invalidate only after all such operations exit.
        if finished { invalidate(session) }
    }
}

final class ServerTrustDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, Sendable {
    struct State: Sendable {
        var observed: ServerKeyFingerprint?
        var systemTrusted = false
        // A trusted proxy can use RSA; its certificate stays fixed for this capture, never as a pin.
        var systemCertificate: Data?
        var mismatchAt: Date?
        var refused: ServerKeyFingerprint?
        var version: UInt16?
    }
    let policy: ServerTrust
    let pinGate = SessionPinGate()
    let lifetime = ServerSessionLifetime()
    private let state = OSAllocatedUnfairLock(initialState: State())
    var observed: ServerKeyFingerprint? { state.withLock { $0.observed } }
    var systemTrusted: Bool { state.withLock { $0.systemTrusted } }
    var refused: ServerKeyFingerprint? { state.withLock { $0.refused } }
    var tlsVersion: String {
        state.withLock { $0.version == 0x0303 ? "TLS 1.2" : $0.version == 0x0304 ? "TLS 1.3" : "TLS" }
    }

    init(policy: ServerTrust) { self.policy = policy }

    static func accepts(policy: ServerTrust, seen: ServerKeyFingerprint?, observed: ServerKeyFingerprint?,
                        capturedCertificate: Data? = nil, trustedCertificate: Data? = nil) -> Bool {
        switch policy {
        case .pinned(let pins): return seen.map { pins.contains($0) } ?? false
        case .capture(let expected):
            if let seen {
                return capturedCertificate == nil && (expected == nil || expected == seen) && (observed == nil || observed == seen)
            }
            guard expected == nil, observed == nil, let trustedCertificate else { return false }
            return capturedCertificate == nil || capturedCertificate == trustedCertificate
        case .system: return true
        case .demo, .blocked: return false
        }
    }

    func mismatch(since: Date) -> Bool { state.withLock { ($0.mismatchAt ?? .distantPast) >= since } }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else { return (.performDefaultHandling, nil) }
        if policy == .system { return (.performDefaultHandling, nil) }
        guard evaluate(trust) else { return (.cancelAuthenticationChallenge, nil) }
        #if DEBUG
        AppLog.server.debug("ServerTrust challenge \(challenge.protectionSpace.host, privacy: .private):\(challenge.protectionSpace.port)")
        #endif
        return (.useCredential, URLCredential(trust: trust))
    }

    func evaluate(_ trust: SecTrust) -> Bool {
        let systemTrusted: Bool
        if case .capture = policy { systemTrusted = SecTrustEvaluateWithError(trust, nil) } else { systemTrusted = false }
        let fingerprint = ServerKey.fingerprint(of: trust)
        let certificate = systemTrusted && fingerprint == nil
            ? ServerKey.certificate(of: trust).map { SecCertificateCopyData($0) as Data } : nil
        let accepted = state.withLock { state in
            guard Self.accepts(policy: policy, seen: fingerprint, observed: state.observed,
                               capturedCertificate: state.systemCertificate, trustedCertificate: certificate) else {
                state.mismatchAt = Date()
                state.refused = fingerprint
                return false
            }
            state.observed = fingerprint
            state.systemCertificate = certificate
            state.systemTrusted = systemTrusted
            return true
        }
        return accepted
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        let version = metrics.transactionMetrics.last?.negotiatedTLSProtocolVersion?.rawValue
        state.withLock { $0.version = version }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        guard let original = task.originalRequest?.url, let url = request.url, url.scheme == "https",
              original.host == url.host, (original.port ?? 443) == (url.port ?? 443) else { return nil }
        return request
    }
}

final class ServerSessions: Sendable {
    static let shared = ServerSessions()
    private struct Key: Hashable { var url: URL; var trust: ServerTrust }
    private struct State {
        var sessions: [Key: (URLSession, ServerTrustDelegate)] = [:]
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func session(for url: URL, trust: ServerTrust) -> (URLSession, ServerTrustDelegate) {
        if case .capture = trust { return Self.make(trust) }
        return state.withLock { state in
            let key = Key(url: url, trust: trust)
            if let cached = state.sessions[key] { return cached }
            let pair = Self.make(trust)
            state.sessions[key] = pair
            return pair
        }
    }

    func captureSession(expected: ServerKeyFingerprint?) -> (URLSession, ServerTrustDelegate) {
        Self.make(.capture(expected: expected))
    }

    func freshSession(trust: ServerTrust) -> (URLSession, ServerTrustDelegate) { Self.make(trust) }

    private static func make(_ trust: ServerTrust) -> (URLSession, ServerTrustDelegate) {
        let delegate = ServerTrustDelegate(policy: trust)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        if trust == .demo { configuration.protocolClasses = [DemoURLProtocol.self] }
        return (URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil), delegate)
    }

    func markSuspect(_ url: URL) {
        reset(url)
    }

    func reset(_ url: URL? = nil) {
        state.withLock { state in
            for key in Array(state.sessions.keys) where url == nil || key.url == url {
                if let pair = state.sessions.removeValue(forKey: key) {
                    pair.1.lifetime.retire(session: pair.0)
                }
            }
        }
    }
}
