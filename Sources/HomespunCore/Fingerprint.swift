// SPDX-License-Identifier: Apache-2.0
import Crypto
import Foundation

/// SHA-256 identity of media files. An original's SHA-256 is its durable asset ID.
public enum Fingerprint {
    public static func sha256(of url: URL, chunkSize: Int = 4 << 20) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha1(of data: Data) -> String {
        Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// SHA-256 (identity), SHA-1 (how Immich finds files), and size in one pass over the file.
    public static func digests(of url: URL, chunkSize: Int = 4 << 20) throws -> (sha256: String, sha1: String, size: Int) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var sha256 = SHA256(), sha1 = Insecure.SHA1(), size = 0
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            sha256.update(data: chunk)
            sha1.update(data: chunk)
            size += chunk.count
        }
        return (sha256.finalize().map { String(format: "%02x", $0) }.joined(),
                sha1.finalize().map { String(format: "%02x", $0) }.joined(), size)
    }
}
