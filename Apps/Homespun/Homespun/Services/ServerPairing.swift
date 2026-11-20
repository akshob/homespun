// SPDX-License-Identifier: Apache-2.0
import Foundation
import HomespunCore

struct ServerPairing {
    struct Paired {
        var url: URL
        var response: ServerAPI.PairResponse
        var pins: ServerPins
    }
    struct Verified {
        var url: URL
        var fingerprint: ServerKeyFingerprint
        var systemTrusted = false
        var serviceName: String?
    }
    struct IdentityFailure: LocalizedError {
        var observed: ServerKeyFingerprint?
        var errorDescription: String? { "Can't confirm this is your server. Nothing else was sent. Check the server's key or pair again." }
    }
    struct ApprovalFailure: Error { var state: ServerAPI.ApprovalState }
    struct UnrecognisedIdentity: LocalizedError {
        var observed: ServerKeyFingerprint?
        var errorDescription: String? { "This address couldn't confirm the pairing." }
    }

    private static func capture(url: URL, expected: ServerKeyFingerprint? = nil) -> ServerClient {
        if url.host == DemoServer.host { return ServerClient(baseURL: url, trust: .demo) }
        let pair = ServerSessions.shared.captureSession(expected: expected)
        return ServerClient(baseURL: url, trust: .capture(expected: expected), session: pair.0, delegate: pair.1)
    }

    private static func observed(_ client: ServerClient) throws -> ServerKeyFingerprint {
        if client.trust == .demo { return DemoServer.fingerprint }
        guard let fingerprint = client.delegate?.observed else { throw IdentityFailure() }
        return fingerprint
    }

    static func pair(link: PairingLink, deviceName: String, installID: String) async throws -> Paired {
        let url = try secureURL(link.serverURL)
        for attempt in 0..<2 {
            let client = capture(url: url, expected: link.fingerprint)
            defer { client.retireSession() }
            do {
                let nonce = PairingCrypto.nonce()
                let challenge = try await client.pairingChallenge(nonce: PairingCrypto.encode(nonce))
                let fingerprint = client.trust == .demo ? DemoServer.fingerprint : client.delegate?.observed
                let system = link.fingerprint == nil && client.delegate?.systemTrusted == true && client.trust != .demo
                guard system || fingerprint != nil else { throw IdentityFailure() }
                guard link.fingerprint == nil || link.fingerprint == fingerprint else { throw IdentityFailure() }
                guard (300_000...2_000_000).contains(challenge.rounds), challenge.proofs.count <= 4,
                      UUID(uuidString: challenge.id) != nil else { throw IdentityFailure() }
                let hash = PairingCrypto.codeHash(link.code)
                let match = try await Task.detached(priority: .userInitiated) { () -> ServerAPI.CodeProof? in
                    for entry in challenge.proofs {
                        guard let salt = PairingCrypto.decode(entry.salt, count: 16),
                              let check = PairingCrypto.decode(entry.check, count: 32) else { throw IdentityFailure() }
                        let key = try PairingCrypto.codeKey(codeHash: hash, salt: salt, rounds: challenge.rounds)
                        guard PairingCrypto.equal(check, PairingCrypto.codeCheck(key: key, nonce: nonce, salt: salt, id: challenge.id)) else {
                            continue
                        }
                        if link.fingerprint == nil && !system {
                            guard let fingerprint, let proof = PairingCrypto.decode(entry.proof, count: 32),
                                  PairingCrypto.equal(proof, PairingCrypto.codeProof(key: key, fingerprint: fingerprint,
                                                                                   nonce: nonce, salt: salt, id: challenge.id)) else {
                                throw IdentityFailure()
                            }
                        }
                        return entry
                    }
                    return nil
                }.value
                guard match != nil else { throw ServerClient.Failure(status: 403, message: PairingErrors.wrongCode) }
                let response = try await client.pair(code: link.code, deviceName: deviceName, challenge: challenge.id, installID: installID)
                return Paired(url: url, response: response,
                              pins: ServerPins(pins: system ? [] : fingerprint.map { [$0] } ?? [],
                                               source: link.fingerprint == nil ? "code" : "link"))
            } catch is IdentityFailure where attempt == 0 && client.delegate?.observed == nil && client.delegate?.systemTrusted != true {
                continue
            } catch {
                if error is IdentityFailure || error is ServerClient.IdentityMismatch { ServerSessions.shared.markSuspect(url) }
                throw error
            }
        }
        ServerSessions.shared.markSuspect(url)
        throw IdentityFailure()
    }

    @MainActor static func approve(url: URL, deviceName: String, installID: String,
                                   onNumber: (String, Date) -> Void,
                                   confirmNumber: (String) async -> Bool) async throws -> Paired {
        let url = try secureURL(url)
        var client = capture(url: url)
        client.timeout = 6
        defer { client.retireSession() }
        let nonce = PairingCrypto.nonce()
        let ticket = try await client.requestApproval(deviceName: deviceName,
            commitment: PairingCrypto.encode(PairingCrypto.commitment(nonce: nonce)))
        let fingerprint = try observed(client)
        guard let text = ticket.serverNonce, let serverNonce = PairingCrypto.decode(text, count: 32) else { throw IdentityFailure() }
        var poller = client
        poller.token = ticket.secret
        do {
            try await poller.revealApproval(ticket.id, nonce: PairingCrypto.encode(nonce))
            let number = PairingCrypto.sas(fingerprint: fingerprint, appNonce: nonce, serverNonce: serverNonce)
            let deadline = Date().addingTimeInterval(TimeInterval(ticket.expiresIn))
            onNumber(number, deadline)
            while Date() < deadline {
                try await Task.sleep(for: .seconds(1))
                let status: ServerAPI.ApprovalStatus
                do {
                    status = try await poller.approvalStatus(ticket.id)
                } catch let failure as ServerClient.Failure where failure.status == 404 {
                    throw ApprovalFailure(state: .expired)
                } catch let error as URLError where error.code != .cancelled {
                    continue
                }
                if status.state == .waiting { continue }
                guard status.state == .approved else { throw ApprovalFailure(state: status.state) }
                let confirmed = await confirmNumber(number)
                try Task.checkCancellation()
                guard confirmed else { throw IdentityFailure(observed: fingerprint) }
                let trust: ServerTrust = client.trust == .demo ? .demo : .pinned([fingerprint])
                let (session, delegate) = ServerSessions.shared.freshSession(trust: trust)
                defer { delegate.lifetime.retire(session: session) }
                let verified = ServerClient(baseURL: url, token: ticket.secret, trust: trust, session: session, delegate: delegate)
                let response = try await verified.completeApproval(ticket.id, installID: installID)
                return Paired(url: url, response: response, pins: ServerPins(pins: [fingerprint], source: "approval"))
            }
            throw ApprovalFailure(state: .expired)
        } catch {
            let authenticated = poller
            await Task.detached { await authenticated.cancelApproval(ticket.id) }.value
            throw error
        }
    }

    static func validIdentityProof(_ proof: ServerAPI.IdentityProof, observed: ServerKeyFingerprint?,
                                   tokenHash: Data, nonce: Data, systemTrusted: Bool = false) -> Bool {
        guard let fingerprint = (systemTrusted ? proof.fingerprint : observed),
              systemTrusted || proof.fingerprint == fingerprint, let received = PairingCrypto.decode(proof.proof, count: 32) else {
            return false
        }
        return PairingCrypto.equal(received, PairingCrypto.verifyProof(tokenHash: tokenHash, nonce: nonce, fingerprint: fingerprint))
    }

    static func verify(url: URL, token: String, allowSystemTrust: Bool = false) async throws -> Verified {
        let url = try secureURL(url)
        for attempt in 0..<2 {
            let client = capture(url: url)
            defer { client.retireSession() }
            let nonce = PairingCrypto.nonce(), hash = PairingCrypto.tokenHash(token)
            do {
                let proof = try await client.verifyIdentity(keyID: PairingCrypto.keyID(tokenHash: hash),
                                                            nonce: PairingCrypto.encode(nonce))
                let fingerprint = client.trust == .demo ? DemoServer.fingerprint : client.delegate?.observed
                // A trusted HTTPS proxy authenticates its own TLS key, while the paired backend proves its token.
                let system = allowSystemTrust && client.delegate?.systemTrusted == true
                guard system || fingerprint != nil else { throw IdentityFailure() }
                guard validIdentityProof(proof, observed: fingerprint, tokenHash: hash, nonce: nonce, systemTrusted: system) else {
                    throw IdentityFailure(observed: fingerprint)
                }
                return Verified(url: url, fingerprint: system ? proof.fingerprint : fingerprint ?? proof.fingerprint, systemTrusted: system)
            } catch let failure as ServerClient.Failure where failure.status == 404 {
                throw UnrecognisedIdentity(observed: client.delegate?.observed)
            } catch is IdentityFailure where attempt == 0 && client.delegate?.observed == nil && client.delegate?.systemTrusted != true {
                continue
            } catch {
                if error is IdentityFailure { ServerSessions.shared.markSuspect(url) }
                throw error
            }
        }
        ServerSessions.shared.markSuspect(url)
        throw IdentityFailure()
    }

    static func secureURL(_ url: URL) throws -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false), let scheme = components.scheme,
              ["http", "https"].contains(scheme), components.host != nil else { throw IdentityFailure() }
        components.scheme = "https"
        guard let url = components.url else { throw IdentityFailure() }
        return url
    }
}
