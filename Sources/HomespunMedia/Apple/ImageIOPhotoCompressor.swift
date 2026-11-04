// SPDX-License-Identifier: Apache-2.0
#if canImport(ImageIO)
import CoreGraphics
import Foundation
import HomespunCore
import ImageIO
import UniformTypeIdentifiers

/// Resizes and re-encodes photos with ImageIO, matching PhotoRelay's output: the long edge
/// fits `photoMaxEdge` (never upscaled), orientation is applied to the pixels and reset to 1,
/// transparency is flattened onto white, and EXIF, GPS, TIFF, IPTC, XMP, the ICC profile, and
/// Apple maker notes (including the Live Photo content identifier) are kept.
///
/// HDR gain maps and depth data are not carried over; the compact copy is SDR.
public struct ImageIOPhotoCompressor: Sendable {
    public enum Format: String, Sendable {
        case jpeg, heic
        var type: UTType { self == .jpeg ? .jpeg : .heic }
    }

    public var profile: CompressionProfile
    public var format: Format

    public init(profile: CompressionProfile = .standard, format: Format = .jpeg) {
        self.profile = profile
        self.format = format
    }

    /// Whether this device can write HEIC (all iPhones since the A10, Apple silicon Macs).
    public static var canEncodeHEIC: Bool {
        (CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []).contains(UTType.heic.identifier)
    }

    static let contentIdentifierKey = "17"

    public func compress(input: URL, output: URL) throws -> PhotoCompressionResult {
        let inputSize = try MediaFiles.size(of: input)
        guard inputSize > 0 else { throw PhotoCompressionError.emptyInput }
        let data = try Data(contentsOf: input, options: .mappedIfSafe)
        if JPEGIntegrity.isJPEG(data), !JPEGIntegrity.isComplete(data) {
            throw PhotoCompressionError.unreadable("truncated JPEG (no end-of-image marker)")
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetStatus(source) == .statusComplete, CGImageSourceGetCount(source) > 0 else {
            throw PhotoCompressionError.unreadable("not a readable image")
        }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        guard let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else {
            throw PhotoCompressionError.unreadable("image has no dimensions")
        }
        guard let resized = CGImageSourceCreateThumbnailAtIndex(source, index, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(profile.photoMaxEdge, max(width, height)),
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary) else {
            throw PhotoCompressionError.unreadable("could not decode the image")
        }
        let image = try flattened(resized)

        let metadata = CGImageSourceCopyMetadataAtIndex(source, index, nil).flatMap {
            CGImageMetadataCreateMutableCopy($0)
        }
        if let metadata {
            CGImageMetadataSetValueMatchingImageProperty(
                metadata, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation, 1 as CFNumber)
        }
        var options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: Double(profile.photoQuality) / 100,
            kCGImagePropertyOrientation: 1,
        ]
        // The metadata tree does not carry Apple maker notes; they hold the Live Photo pairing.
        if let maker = properties[kCGImagePropertyMakerAppleDictionary] {
            options[kCGImagePropertyMakerAppleDictionary] = maker
        }

        let partial = MediaFiles.partialURL(for: output)
        try? FileManager.default.removeItem(at: partial)
        defer { try? FileManager.default.removeItem(at: partial) }
        guard let destination = CGImageDestinationCreateWithURL(
            partial as CFURL, format.type.identifier as CFString, 1, nil) else {
            throw PhotoCompressionError.encodingFailed("cannot write \(format.rawValue)")
        }
        CGImageDestinationAddImageAndMetadata(destination, image, metadata, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw PhotoCompressionError.encodingFailed("\(format.rawValue) encoder failed")
        }
        try verify(partial, width: image.width, height: image.height, source: properties)

        if try MediaFiles.size(of: partial) >= inputSize {
            let kept = output.deletingPathExtension().appendingPathExtension(input.pathExtension)
            let copy = try MediaFiles.publishCopy(of: input, to: kept)
            let oriented = Self.isQuarterTurn(properties) ? (height, width) : (width, height)
            return PhotoCompressionResult(mode: .originalKeptNotSmaller, url: kept, sha256: copy.sha256,
                                          size: copy.size, width: oriented.0, height: oriented.1)
        }
        let digest = try Fingerprint.sha256(of: partial)
        let size = try MediaFiles.size(of: partial)
        try MediaFiles.publish(partial, to: output)
        return PhotoCompressionResult(mode: .compressed, url: output, sha256: digest, size: size,
                                      width: image.width, height: image.height)
    }

    /// Composites images with transparency onto white, as JPEG has no alpha.
    private func flattened(_ image: CGImage) throws -> CGImage {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return image
        default: break
        }
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw PhotoCompressionError.encodingFailed("cannot flatten transparency")
        }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(bounds)
        context.draw(image, in: bounds)
        guard let flat = context.makeImage() else {
            throw PhotoCompressionError.encodingFailed("cannot flatten transparency")
        }
        return flat
    }

    private func verify(_ url: URL, width: Int, height: Int, source: [CFString: Any]) throws {
        guard let result = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetStatus(result) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(result, 0, nil) as? [CFString: Any],
              CGImageSourceCreateImageAtIndex(result, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
                != nil else {
            throw PhotoCompressionError.verificationFailed("output does not decode")
        }
        let outWidth = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let outHeight = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard outWidth == width, outHeight == height, max(outWidth, outHeight) <= profile.photoMaxEdge else {
            throw PhotoCompressionError.verificationFailed("output is \(outWidth)x\(outHeight)")
        }
        guard (properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1 else {
            throw PhotoCompressionError.verificationFailed("orientation was not reset")
        }
        func exif(_ dictionary: [CFString: Any], _ key: CFString) -> String? {
            (dictionary[kCGImagePropertyExifDictionary] as? [CFString: Any])?[key] as? String
        }
        for key in [kCGImagePropertyExifDateTimeOriginal, kCGImagePropertyExifOffsetTimeOriginal]
            where exif(source, key) != nil && exif(source, key) != exif(properties, key) {
            throw PhotoCompressionError.verificationFailed("\(key) was not preserved")
        }
        func identifier(_ dictionary: [CFString: Any]) -> String? {
            (dictionary[kCGImagePropertyMakerAppleDictionary] as? [String: Any])?[Self.contentIdentifierKey] as? String
        }
        if let expected = identifier(source), identifier(properties) != expected {
            throw PhotoCompressionError.verificationFailed("Live Photo content identifier was not preserved")
        }
    }

    private static func isQuarterTurn(_ properties: [CFString: Any]) -> Bool {
        [5, 6, 7, 8].contains(properties[kCGImagePropertyOrientation] as? Int ?? 1)
    }
}
#endif
