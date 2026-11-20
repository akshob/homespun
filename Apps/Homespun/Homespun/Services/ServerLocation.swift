// SPDX-License-Identifier: Apache-2.0
import Foundation
import HomespunCore

enum ServerLocation {
    struct Candidate: Codable, Equatable, Sendable {
        var url: URL
        var serviceName: String
        var fingerprintHint: ServerKeyFingerprint?
    }

    struct Verified: Sendable {
        var candidate: Candidate
        var fingerprint: ServerKeyFingerprint
    }

    typealias Finder = @Sendable (String?, Set<ServerKeyFingerprint>, URL) async throws -> Verified?

    static func ordered(_ candidates: [Candidate], name: String?, pins: Set<ServerKeyFingerprint>) -> [Candidate] {
        candidates.sorted {
            let left = ($0.serviceName == name ? 2 : 0) + ($0.fingerprintHint.map(pins.contains) == true ? 1 : 0)
            let right = ($1.serviceName == name ? 2 : 0) + ($1.fingerprintHint.map(pins.contains) == true ? 1 : 0)
            return left == right ? $0.url.absoluteString < $1.url.absoluteString : left > right
        }
    }

    static func find(in candidates: [Candidate], name: String?, pins: Set<ServerKeyFingerprint>, excluding oldURL: URL,
                     probe: @Sendable (URL, Set<ServerKeyFingerprint>) async throws -> ServerKeyFingerprint?) async throws -> Verified? {
        guard !pins.isEmpty else { return nil }
        for candidate in ordered(candidates, name: name, pins: pins).prefix(16)
        where candidate.url != oldURL && candidate.url.scheme == "https" {
            try Task.checkCancellation()
            do {
                if let observed = try await probe(candidate.url, pins), pins.contains(observed) {
                    return Verified(candidate: candidate, fingerprint: observed)
                }
            } catch where AppSettings.isCancellation(error) {
                throw error
            } catch {
                continue
            }
        }
        return nil
    }

    static func locate(name: String?, pins: Set<ServerKeyFingerprint>, excluding oldURL: URL) async throws -> Verified? {
        let candidates = try await browse()
        return try await find(in: candidates, name: name, pins: pins, excluding: oldURL, probe: probe)
    }

    static func probe(_ url: URL, pins: Set<ServerKeyFingerprint>) async throws -> ServerKeyFingerprint? {
        for _ in 0..<2 {
            let (session, delegate) = ServerSessions.shared.freshSession(trust: .pinned(pins))
            defer { delegate.lifetime.retire(session: session) }
            var client = ServerClient(baseURL: url, trust: .pinned(pins), session: session, delegate: delegate)
            client.timeout = 4
            // This client has no token. A fresh, matching TLS observation is required before credentials move.
            _ = try await client.health()
            if let observed = delegate.observed, pins.contains(observed) { return observed }
        }
        return nil
    }

    @MainActor static func browse() async throws -> [Candidate] {
        #if DEBUG
        if let text = ProcessInfo.processInfo.environment["HOMESPUN_SERVER_CANDIDATES"],
           let data = text.data(using: .utf8) {
            return try JSONDecoder().decode([Candidate].self, from: data)
        }
        #endif
        let discovery = ServerDiscovery(describeOptions: false)
        discovery.start()
        defer { discovery.stop() }
        let start = Date()
        while Date().timeIntervalSince(start) < 6 {
            try await Task.sleep(for: .milliseconds(250))
            if discovery.blocked { break }
            if discovery.servers.contains(where: { $0.url != nil }), Date().timeIntervalSince(start) >= 2,
               Date().timeIntervalSince(discovery.lastChange) >= 0.75 { break }
        }
        return discovery.servers.compactMap { found in
            found.url.map { Candidate(url: $0, serviceName: found.name, fingerprintHint: found.fingerprintHint) }
        }
    }

    static func verifyLegacy(name: String?, token: String, excluding oldURL: URL) async throws -> ServerPairing.Verified? {
        for candidate in ordered(try await browse(), name: name, pins: []).prefix(8)
        where candidate.url != oldURL && candidate.url.scheme == "https" {
            do {
                var verified = try await ServerPairing.verify(url: candidate.url, token: token)
                verified.serviceName = candidate.serviceName
                return verified
            } catch where AppSettings.isCancellation(error) {
                throw error
            } catch {
                continue
            }
        }
        return nil
    }
}
