// SPDX-License-Identifier: Apache-2.0
import Foundation

extension ServerAPI {
    public struct TLSInfo: Codable, Equatable, Sendable {
        public var fingerprint: ServerKeyFingerprint
        public var notAfter: Date
        public init(fingerprint: ServerKeyFingerprint, notAfter: Date) {
            self.fingerprint = fingerprint
            self.notAfter = notAfter
        }
    }

    public struct CodeChallengeRequest: Codable, Equatable, Sendable {
        public var nonce: String
        public init(nonce: String) { self.nonce = nonce }
    }

    public struct CodeProof: Codable, Equatable, Sendable {
        public var salt: String
        public var check: String
        public var proof: String
        public init(salt: String, check: String, proof: String) {
            self.salt = salt
            self.check = check
            self.proof = proof
        }
    }

    public struct CodeChallenge: Codable, Equatable, Sendable {
        public var id: String
        public var rounds: Int
        public var proofs: [CodeProof]
        public var expiresIn: Int
        public init(id: String, rounds: Int, proofs: [CodeProof], expiresIn: Int) {
            self.id = id
            self.rounds = rounds
            self.proofs = proofs
            self.expiresIn = expiresIn
        }
    }

    public struct ApprovalReveal: Codable, Equatable, Sendable {
        public var nonce: String
        public init(nonce: String) { self.nonce = nonce }
    }

    public struct IdentityRequest: Codable, Equatable, Sendable {
        public var keyID: String
        public var nonce: String
        public init(keyID: String, nonce: String) {
            self.keyID = keyID
            self.nonce = nonce
        }
        enum CodingKeys: String, CodingKey { case keyID = "keyId", nonce }
    }

    public struct IdentityProof: Codable, Equatable, Sendable {
        public var fingerprint: ServerKeyFingerprint
        public var proof: String
        public var notAfter: Date
        public init(fingerprint: ServerKeyFingerprint, proof: String, notAfter: Date) {
            self.fingerprint = fingerprint
            self.proof = proof
            self.notAfter = notAfter
        }
    }
}
