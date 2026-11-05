// SPDX-License-Identifier: Apache-2.0
#if os(Linux)
import CHomespunVips
import Foundation
import HomespunCore

/// Resizes and re-encodes photos with libvips on Linux, matching `ImageIOPhotoCompressor`:
/// the long edge fits `photoMaxEdge` (never upscaled), pixels are rotated upright, transparency
/// is flattened onto white, and the ICC profile, IPTC, and XMP are kept. The EXIF block is
/// copied byte for byte from the source with only Orientation and pixel size changed, because
/// libvips drops Apple maker notes, which carry the Live Photo content identifier.
public struct VipsPhotoCompressor: PhotoCompressor {
    public var profile: CompressionProfile

    public init(profile: CompressionProfile = .standard) { self.profile = profile }

    public func compress(input: URL, output: URL) throws -> PhotoCompressionResult {
        let inputSize = try MediaFiles.size(of: input)
        guard inputSize > 0 else { throw PhotoCompressionError.emptyInput }
        let data = try Data(contentsOf: input, options: .mappedIfSafe)
        if JPEGIntegrity.isJPEG(data), !JPEGIntegrity.isComplete(data) {
            throw PhotoCompressionError.unreadable("truncated JPEG (no end-of-image marker)")
        }

        let partial = MediaFiles.partialURL(for: output)
        let encoded = output.deletingLastPathComponent().appendingPathComponent(".encoded-\(output.lastPathComponent)")
        for url in [partial, encoded] { try? FileManager.default.removeItem(at: url) }
        defer { for url in [partial, encoded] { try? FileManager.default.removeItem(at: url) } }

        var sourceWidth: Int32 = 0, sourceHeight: Int32 = 0, width: Int32 = 0, height: Int32 = 0
        try Self.call { error in
            hs_vips_compact_jpeg(input.path, encoded.path, Int32(profile.photoMaxEdge), Int32(profile.photoQuality),
                                 &sourceWidth, &sourceHeight, &width, &height, &error)
        } failure: { PhotoCompressionError.unreadable($0) }

        let metadata = try Self.metadata(of: input)
        let exif = try metadata.exif.map {
            do { return try ExifEditor.uprighted($0, width: Int(width), height: Int(height)) }
            catch { throw PhotoCompressionError.encodingFailed("unusable EXIF block: \(error)") }
        }
        let xmp = metadata.xmp.map(JPEGSegments.uprightXMP)
        try JPEGSegments.inserting(exif: exif, xmp: xmp, into: Data(contentsOf: encoded)).write(to: partial)
        try verify(partial, width: Int(width), height: Int(height), exif: exif)

        if try MediaFiles.size(of: partial) >= inputSize {
            let kept = output.deletingPathExtension().appendingPathExtension(input.pathExtension)
            let copy = try MediaFiles.publishCopy(of: input, to: kept)
            return PhotoCompressionResult(mode: .originalKeptNotSmaller, url: kept, sha256: copy.sha256,
                                          size: copy.size, width: Int(sourceWidth), height: Int(sourceHeight))
        }
        let digest = try Fingerprint.sha256(of: partial)
        let size = try MediaFiles.size(of: partial)
        try MediaFiles.publish(partial, to: output)
        return PhotoCompressionResult(mode: .compressed, url: output, sha256: digest, size: size,
                                      width: Int(width), height: Int(height))
    }

    private func verify(_ url: URL, width: Int, height: Int, exif: Data?) throws {
        guard JPEGIntegrity.isComplete(try Data(contentsOf: url)) else {
            throw PhotoCompressionError.verificationFailed("output JPEG is incomplete")
        }
        var decodedWidth: Int32 = 0, decodedHeight: Int32 = 0
        try Self.call { hs_vips_decode(url.path, &decodedWidth, &decodedHeight, &$0) } failure: {
            PhotoCompressionError.verificationFailed("output does not decode: \($0)")
        }
        guard Int(decodedWidth) == width, Int(decodedHeight) == height,
              max(width, height) <= profile.photoMaxEdge else {
            throw PhotoCompressionError.verificationFailed("output is \(decodedWidth)x\(decodedHeight)")
        }
        let written = try Self.metadata(of: url).exif
        guard written.map(Self.stripHeader) == exif.map(Self.stripHeader) else {
            throw PhotoCompressionError.verificationFailed("EXIF block was not preserved")
        }
    }

    private static func stripHeader(_ block: Data) -> Data {
        block.starts(with: ExifEditor.header) ? block.dropFirst(ExifEditor.header.count) : block
    }

    static func metadata(of url: URL) throws -> (exif: Data?, xmp: Data?) {
        var exif: UnsafeMutablePointer<UInt8>?, xmp: UnsafeMutablePointer<UInt8>?
        var exifLength = 0, xmpLength = 0
        try call { hs_vips_metadata(url.path, &exif, &exifLength, &xmp, &xmpLength, &$0) } failure: {
            PhotoCompressionError.unreadable($0)
        }
        defer { hs_vips_free(exif); hs_vips_free(xmp) }
        return (exif.map { Data(bytes: $0, count: exifLength) }, xmp.map { Data(bytes: $0, count: xmpLength) })
    }

    private static func call(_ body: (inout UnsafeMutablePointer<CChar>?) -> Int32,
                             failure: (String) -> PhotoCompressionError) throws {
        var error: UnsafeMutablePointer<CChar>?
        let status = body(&error)
        defer { hs_vips_free(error) }
        guard status == 0 else { throw failure(error.map { String(cString: $0) } ?? "libvips failed") }
    }
}
#endif
