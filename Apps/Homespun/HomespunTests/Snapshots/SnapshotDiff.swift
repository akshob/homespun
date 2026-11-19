// SPDX-License-Identifier: Apache-2.0
import CoreGraphics
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO

struct SnapshotFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

enum SnapshotImage {
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    static let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue

    static func context(width: Int, height: Int) throws -> CGContext {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: colorSpace, bitmapInfo: bitmapInfo) else {
            throw SnapshotFailure("Could not allocate a snapshot bitmap")
        }
        return context
    }

    static func sRGB(_ image: CGImage) throws -> CGImage {
        let context = try context(width: image.width, height: image.height)
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        guard let image = context.makeImage() else { throw SnapshotFailure("Could not normalize snapshot color space") }
        return image
    }

    static func solid(width: Int, height: Int, color: CGColor) throws -> CGImage {
        let context = try context(width: width, height: height)
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { throw SnapshotFailure("Could not make a snapshot placeholder") }
        return image
    }

    static func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            throw SnapshotFailure("Could not create snapshot PNG")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw SnapshotFailure("Could not encode snapshot PNG") }
        return data as Data
    }

    static func read(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            throw SnapshotFailure("Could not decode reference \(url.lastPathComponent)")
        }
        return image
    }
}

@MainActor
enum SnapshotDiff {
    struct Tolerance {
        var deltaE: Float = 2.3
        var fraction: Double = 0.0005
        var maximum: Float = 15
    }

    struct Result {
        let sizeMatches: Bool
        let changedFraction: Double?
        let maximumDeltaE: Double?
        let passed: Bool
        let difference: CGImage?
    }

    private static let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        .cacheIntermediates: false,
    ])

    static func compare(_ actual: CGImage, to reference: CGImage, tolerance: Tolerance = Tolerance()) throws -> Result {
        guard actual.width == reference.width, actual.height == reference.height else {
            return Result(sizeMatches: false, changedFraction: nil, maximumDeltaE: nil, passed: false,
                          difference: try SnapshotImage.solid(width: actual.width, height: actual.height,
                                                              color: CGColor(red: 1, green: 0, blue: 1, alpha: 1)))
        }
        if tolerance.deltaE >= 0, tolerance.fraction >= 0, tolerance.maximum >= 0,
           actual.bitsPerComponent == reference.bitsPerComponent, actual.bitsPerPixel == reference.bitsPerPixel,
           actual.bytesPerRow == reference.bytesPerRow, actual.bitmapInfo == reference.bitmapInfo,
           let actualSpace = actual.colorSpace, let referenceSpace = reference.colorSpace,
           CFEqual(actualSpace, referenceSpace),
           let actualBytes = actual.dataProvider?.data, let referenceBytes = reference.dataProvider?.data,
           CFEqual(actualBytes, referenceBytes) {
            return Result(sizeMatches: true, changedFraction: 0, maximumDeltaE: 0, passed: true, difference: nil)
        }
        let width = actual.width, height = actual.height
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        let filter = CIFilter.labDeltaE()
        filter.inputImage = CIImage(cgImage: actual)
        filter.image2 = CIImage(cgImage: reference)
        guard let image = filter.outputImage else { throw SnapshotFailure("Lab ΔE filter is unavailable") }
        var values = [Float](repeating: 0, count: width * height)
        values.withUnsafeMutableBytes { bytes in
            context.render(image, toBitmap: bytes.baseAddress!, rowBytes: width * MemoryLayout<Float>.size,
                           bounds: rect, format: .Rf, colorSpace: nil)
        }
        var changed = 0, maximum: Float = 0
        for value in values {
            guard value.isFinite else { throw SnapshotFailure("Non-finite Lab ΔE in snapshot comparison") }
            if value > tolerance.deltaE { changed += 1 }
            maximum = max(maximum, value)
        }
        let fraction = Double(changed) / Double(values.count)
        let passed = fraction <= tolerance.fraction && maximum <= tolerance.maximum
        return Result(sizeMatches: true, changedFraction: fraction, maximumDeltaE: Double(maximum), passed: passed,
                      difference: passed ? nil : try heatmap(actual, values: values, threshold: tolerance.deltaE))
    }

    private static func heatmap(_ actual: CGImage, values: [Float], threshold: Float) throws -> CGImage {
        let context = try SnapshotImage.context(width: actual.width, height: actual.height)
        context.draw(actual, in: CGRect(x: 0, y: 0, width: actual.width, height: actual.height))
        guard let data = context.data else { throw SnapshotFailure("Could not draw snapshot difference") }
        let pixels = data.bindMemory(to: UInt8.self, capacity: values.count * 4)
        for (index, value) in values.enumerated() {
            let offset = index * 4
            if value > threshold {
                pixels[offset] = 255
                pixels[offset + 1] = 0
                pixels[offset + 2] = 255
            } else {
                pixels[offset] /= 4
                pixels[offset + 1] /= 4
                pixels[offset + 2] /= 4
            }
            pixels[offset + 3] = 255
        }
        guard let image = context.makeImage() else { throw SnapshotFailure("Could not encode snapshot difference") }
        return image
    }
}
