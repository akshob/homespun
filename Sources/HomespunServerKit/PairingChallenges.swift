// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import HomespunCore
import NIOPosix

actor CodeChallenges {
    enum Failure: Error { case rateLimited }
    private struct Code {
        var salt: Data
        var key: Data
        var issued: Int
        var expires: Date
    }
    private struct Challenge {
        var hashes: Set<String>
        var expires: Date
    }
    let catalog: Catalog
    let rounds: Int
    let minimumInterval: TimeInterval
    private var codes: [String: Code] = [:]
    private var challenges: [String: Challenge] = [:]
    private var lastIssued = Date.distantPast
    private var issuing = false

    init(catalog: Catalog, rounds: Int = PairingCrypto.codeRounds, minimumInterval: TimeInterval = 1) {
        self.catalog = catalog
        self.rounds = rounds
        self.minimumInterval = minimumInterval
    }

    func challenge(nonce: Data, fingerprint: ServerKeyFingerprint, now: Date = Date()) async throws -> ServerAPI.CodeChallenge {
        guard !issuing, now.timeIntervalSince(lastIssued) >= minimumInterval else {
            throw Failure.rateLimited
        }
        issuing = true
        defer { issuing = false }
        lastIssued = now
        challenges = challenges.filter { $0.value.expires > now }
        let hashes = try await catalog.openPairingCodes(now: now)
        codes = codes.filter { $0.value.expires > now }
        let id = UUID().uuidString
        var proofs: [ServerAPI.CodeProof] = []
        var included: Set<String> = []
        for hash in hashes {
            var code: Code
            if let cached = codes[hash] {
                code = cached
            } else {
                let salt = PairingCrypto.nonce(count: 16), rounds = rounds
                try await catalog.shortenPairingCode(hash: hash, until: now.addingTimeInterval(120))
                let key = try await NIOThreadPool.singleton.runIfActive {
                    try PairingCrypto.codeKey(codeHash: hash, salt: salt, rounds: rounds)
                }
                code = Code(salt: salt, key: key, issued: 0, expires: now.addingTimeInterval(120))
            }
            guard code.issued < 3 else { continue }
            code.issued += 1
            codes[hash] = code
            included.insert(hash)
            proofs.append(.init(salt: PairingCrypto.encode(code.salt),
                                check: PairingCrypto.encode(PairingCrypto.codeCheck(key: code.key, nonce: nonce, salt: code.salt, id: id)),
                                proof: PairingCrypto.encode(PairingCrypto.codeProof(key: code.key, fingerprint: fingerprint,
                                                                                  nonce: nonce, salt: code.salt, id: id))))
        }
        challenges[id] = Challenge(hashes: included, expires: now.addingTimeInterval(60))
        return .init(id: id, rounds: rounds, proofs: proofs, expiresIn: 60)
    }

    func redeemable(id: String, codeHash: String, now: Date = Date()) -> Bool {
        guard let challenge = challenges.removeValue(forKey: id), challenge.expires > now else { return false }
        return challenge.hashes.contains(codeHash)
    }
}

actor IdentityProofLimit {
    private var window = Date.distantPast
    private var count = 0
    func allow(now: Date = Date()) -> Bool {
        if now.timeIntervalSince(window) >= 60 { window = now; count = 0 }
        count += 1
        return count <= 30
    }
}
