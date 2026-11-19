// SPDX-License-Identifier: Apache-2.0
import Crypto
import Foundation

/// SHA-256 of a server key's DER SubjectPublicKeyInfo, not of its certificate.
public struct ServerKeyFingerprint: Hashable, Codable, Sendable {
    public let bytes: Data

    public init?(bytes: Data) {
        guard bytes.count == 32 else { return nil }
        self.bytes = bytes
    }

    public init?(base64url: String) {
        guard let bytes = PairingCrypto.decode(base64url, count: 32) else { return nil }
        self.bytes = bytes
    }

    public init(spki: Data) {
        self.bytes = Data(SHA256.hash(data: spki))
    }

    public var base64url: String { PairingCrypto.encode(bytes) }
    public var curlPin: String { "sha256//" + bytes.base64EncodedString() }
    public var display: String {
        stride(from: 0, to: 20, by: 4).map { offset in
            String(base64url.dropFirst(offset).prefix(4))
        }.joined(separator: " ")
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let fingerprint = Self(base64url: value) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid server key fingerprint")
        }
        self = fingerprint
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(base64url)
    }
}
