// SPDX-License-Identifier: Apache-2.0
import Foundation
import HomespunCore

/// Temporary names and atomic publishing shared by every media backend.
enum MediaFiles {
    /// Hidden sibling of `output` that keeps its extension, so encoders pick the right container.
    static func partialURL(for output: URL) -> URL {
        output.deletingLastPathComponent().appendingPathComponent(".partial-\(output.lastPathComponent)")
    }

    static func size(of url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
    }

    /// Moves a verified `partial` over `output` in one step.
    static func publish(_ partial: URL, to output: URL) throws {
        if FileManager.default.fileExists(atPath: output.path) {
            _ = try FileManager.default.replaceItemAt(output, withItemAt: partial)
        } else {
            try FileManager.default.moveItem(at: partial, to: output)
        }
    }

    /// Copies `input` byte-for-byte to `output` through a temporary name, checks size and
    /// SHA-256, then publishes it. Returns the digest and size.
    static func publishCopy(of input: URL, to output: URL,
                            beforePublish: () throws -> Void = {}) throws -> (sha256: String, size: Int) {
        let partial = partialURL(for: output)
        try? FileManager.default.removeItem(at: partial)
        defer { try? FileManager.default.removeItem(at: partial) }
        try FileManager.default.copyItem(at: input, to: partial)
        let digest = try Fingerprint.sha256(of: partial)
        let size = try size(of: partial)
        guard size == (try self.size(of: input)), digest == (try Fingerprint.sha256(of: input)) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: output.path])
        }
        try beforePublish()
        try publish(partial, to: output)
        return (digest, size)
    }
}
