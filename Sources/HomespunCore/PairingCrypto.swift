// SPDX-License-Identifier: Apache-2.0
import Crypto
import Foundation
#if os(Linux)
import _CryptoExtras
#else
import CommonCrypto
#endif

/// Versioned, domain-separated proofs shared by the app and server.
public enum PairingCrypto {
    public static let codeRounds = 600_000
    public enum Failure: Error { case invalidInput, derivationFailed }

    public static func nonce(count: Int = 32) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    public static func encode(_ bytes: Data) -> String {
        bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ text: String, count: Int) -> Data? {
        guard text.utf8.count == (count * 8 + 5) / 6,
              text.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0)
                  || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
        let standard = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard let bytes = Data(base64Encoded: standard + String(repeating: "=", count: (4 - standard.count % 4) % 4)),
              bytes.count == count, encode(bytes) == text else { return nil }
        return bytes
    }

    public static func equal(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    public static func tokenHash(_ token: String) -> Data { Data(SHA256.hash(data: Data(token.utf8))) }

    public static func tokenHash(hex: String) throws -> Data {
        guard hex.utf8.count == 64 else { throw Failure.invalidInput }
        var bytes = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let end = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<end], radix: 16) else { throw Failure.invalidInput }
            bytes.append(byte)
            index = end
        }
        return bytes
    }

    public static func keyID(tokenHash: Data) -> String {
        encode(Data(SHA256.hash(data: message("homespun key id v1", [tokenHash])).prefix(16)))
    }

    public static func verifyProof(tokenHash: Data, nonce: Data, fingerprint: ServerKeyFingerprint) -> Data {
        mac(tokenHash, "homespun verify v1", [nonce, fingerprint.bytes])
    }

    public static func commitment(nonce: Data) -> Data {
        Data(SHA256.hash(data: message("homespun pair commit v1", [nonce])))
    }

    public static func sas(fingerprint: ServerKeyFingerprint, appNonce: Data, serverNonce: Data) -> String {
        let hash = SHA256.hash(data: message("homespun pair sas v1", [fingerprint.bytes, appNonce, serverNonce]))
        let value = hash.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } % 1_000_000
        return String(format: "%06u", value)
    }

    public static func normalizedCode(_ code: String) -> String {
        code.uppercased().filter { "23456789ABCDEFGHJKMNPQRSTVWXYZ".contains($0) }
    }

    public static func codeHash(_ code: String) -> String {
        Fingerprint.sha256(of: Data(normalizedCode(code).utf8))
    }

    public static func codeKey(codeHash: String, salt: Data, rounds: Int = codeRounds) throws -> Data {
        guard codeHash.count == 64, salt.count == 16 else { throw Failure.invalidInput }
        return try pbkdf2(password: Data(codeHash.utf8), salt: salt, rounds: rounds, count: 32)
    }

    public static func codeCheck(key: Data, nonce: Data, salt: Data, id: String) -> Data {
        mac(key, "homespun code check v1", [nonce, salt, Data(id.utf8)])
    }

    public static func codeProof(key: Data, fingerprint: ServerKeyFingerprint, nonce: Data, salt: Data, id: String) -> Data {
        mac(key, "homespun code proof v1", [fingerprint.bytes, nonce, salt, Data(id.utf8)])
    }

    static func pbkdf2(password: Data, salt: Data, rounds: Int, count: Int) throws -> Data {
        guard rounds > 0, rounds <= Int(UInt32.max), count > 0 else { throw Failure.invalidInput }
        #if os(Linux)
        let key = try KDF.Insecure.PBKDF2.deriveKey(
            from: password, salt: salt, using: .sha256, outputByteCount: count, unsafeUncheckedRounds: rounds)
        return key.withUnsafeBytes { Data($0) }
        #else
        var output = Data(count: count)
        let status = output.withUnsafeMutableBytes { destination in
            password.withUnsafeBytes { password in
                salt.withUnsafeBytes { salt in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                        password.bindMemory(to: Int8.self).baseAddress, password.count,
                        salt.bindMemory(to: UInt8.self).baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(rounds),
                        destination.bindMemory(to: UInt8.self).baseAddress, count)
                }
            }
        }
        guard status == kCCSuccess else { throw Failure.derivationFailed }
        return output
        #endif
    }

    private static func message(_ label: String, _ inputs: [Data]) -> Data {
        inputs.reduce(Data((label + "\0").utf8), +)
    }

    private static func mac(_ key: Data, _ label: String, _ inputs: [Data]) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: message(label, inputs), using: SymmetricKey(data: key)))
    }
}
