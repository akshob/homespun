// SPDX-License-Identifier: Apache-2.0
import Foundation
import HomespunCore
#if os(Linux)
import CHomespunVips
#endif

public enum PhotoCompressionError: Error, Equatable {
    case emptyInput
    /// The source cannot be decoded or is truncated. Flag it; never mark it complete.
    case unreadable(String)
    case encodingFailed(String)
    case verificationFailed(String)
}

public struct PhotoCompressionResult: Equatable, Sendable {
    public enum Mode: String, Sendable {
        case compressed
        /// The compact copy was not smaller, so the original bytes were published instead,
        /// under the original's file extension.
        case originalKeptNotSmaller
    }
    public var mode: Mode
    /// Where the result was published. Differs from the requested output only in its
    /// extension, when the original is kept.
    public var url: URL
    public var sha256: String
    public var size: Int
    public var width: Int
    public var height: Int
}

/// Structural JPEG check. Decoders such as ImageIO silently fill a truncated JPEG with grey,
/// so the primary image's marker segments and entropy-coded scans are walked to its EOI.
public enum JPEGIntegrity {
    public static func isJPEG(_ data: Data) -> Bool { data.starts(with: [0xFF, 0xD8, 0xFF]) }

    /// True when the first image in `data` ends with an EOI marker.
    public static func isComplete(_ data: Data) -> Bool {
        data.withUnsafeBytes { bytes in
            guard bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return false }
            var index = 2
            while index + 1 < bytes.count {
                guard bytes[index] == 0xFF else { return false }
                let marker = bytes[index + 1]
                index += 2
                switch marker {
                case 0xFF:
                    index -= 1  // fill byte
                case 0xD9:
                    return true
                case 0x01, 0xD0...0xD7:
                    continue
                default:
                    guard index + 1 < bytes.count else { return false }
                    let length = Int(bytes[index]) << 8 | Int(bytes[index + 1])
                    guard length >= 2, index + length <= bytes.count else { return false }
                    index += length
                    if marker == 0xDA {
                        // Entropy-coded data runs to the next marker other than a stuffed
                        // 0xFF00 or a restart marker.
                        while index + 1 < bytes.count {
                            if bytes[index] == 0xFF, bytes[index + 1] != 0x00,
                               !(0xD0...0xD7).contains(bytes[index + 1]) {
                                break
                            }
                            index += 1
                        }
                    }
                }
            }
            return false
        }
    }
}

/// A photo backend: ImageIO on Apple platforms, libvips on Linux.
public protocol PhotoCompressor: Sendable {
    /// Writes a compact JPEG to `output`, or publishes the original bytes (under the original's
    /// extension) when the compact copy would not be smaller. Throws for undecodable input.
    func compress(input: URL, output: URL) throws -> PhotoCompressionResult
}

public enum PlatformMedia {
    /// The photo backend's name, or nil if none works here.
    public static var photoBackend: String? {
        #if canImport(ImageIO)
        "Apple ImageIO"
        #elseif os(Linux)
        hs_vips_version().map { "libvips " + String(cString: $0) }
        #else
        nil
        #endif
    }

    /// The photo backend for this platform, or nil where none is available.
    public static func photoCompressor(profile: CompressionProfile) -> (any PhotoCompressor)? {
        #if canImport(ImageIO)
        ImageIOPhotoCompressor(profile: profile)
        #elseif os(Linux)
        VipsPhotoCompressor(profile: profile)
        #else
        nil
        #endif
    }
}
