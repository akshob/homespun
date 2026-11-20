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
        .workingFormat: CIFormat.RGBAf.rawValue,
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
           actual.decode == nil, reference.decode == nil,
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
        let maximumFilter = CIFilter.areaMaximum()
        maximumFilter.inputImage = image
        maximumFilter.extent = rect
        guard let maximumImage = maximumFilter.outputImage else { throw SnapshotFailure("Missing maximum ΔE") }
        let maximum = scalar(maximumImage)
        let gray = CIFilter.colorMatrix()
        // Lab ΔE carries its scalar in alpha too; color matrices unpremultiply inputs.
        gray.inputImage = image.premultiplyingAlpha()
        let red = CIVector(x: 0.01, y: 0, z: 0, w: 0)
        gray.rVector = red
        gray.gVector = red
        gray.bVector = red
        gray.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        gray.biasVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        let threshold = CIFilter.colorThreshold()
        threshold.inputImage = gray.outputImage
        threshold.threshold = tolerance.deltaE / 100
        guard let thresholdImage = threshold.outputImage else { throw SnapshotFailure("Missing ΔE threshold mask") }
        let mask = thresholdImage.cropped(to: rect)
        let average = CIFilter.areaAverage()
        average.inputImage = mask
        average.extent = rect
        guard let averageImage = average.outputImage else { throw SnapshotFailure("Missing changed-pixel fraction") }
        let fraction = Double(scalar(averageImage))
        guard maximum.isFinite, fraction.isFinite else { throw SnapshotFailure("Non-finite Lab ΔE in snapshot comparison") }
        let passed = fraction <= tolerance.fraction && maximum <= tolerance.maximum
        return Result(sizeMatches: true, changedFraction: fraction, maximumDeltaE: Double(maximum), passed: passed,
                      difference: passed ? nil : try heatmap(actual, mask: mask))
    }

    private static func scalar(_ image: CIImage) -> Float {
        var value: Float = 0
        withUnsafeMutableBytes(of: &value) { bytes in
            context.render(image, toBitmap: bytes.baseAddress!, rowBytes: MemoryLayout<Float>.size,
                           bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .Rf, colorSpace: nil)
        }
        return value
    }

    private static func heatmap(_ actual: CGImage, mask: CIImage) throws -> CGImage {
        let rect = CGRect(x: 0, y: 0, width: actual.width, height: actual.height)
        let dim = CIFilter.colorMatrix()
        dim.inputImage = CIImage(cgImage: actual)
        dim.rVector = CIVector(x: 0.25, y: 0, z: 0, w: 0)
        dim.gVector = CIVector(x: 0, y: 0.25, z: 0, w: 0)
        dim.bVector = CIVector(x: 0, y: 0, z: 0.25, w: 0)
        let blend = CIFilter.blendWithMask()
        blend.inputImage = CIImage(color: CIColor(red: 1, green: 0, blue: 1)).cropped(to: rect)
        blend.backgroundImage = dim.outputImage
        blend.maskImage = mask
        guard let output = blend.outputImage,
              let image = context.createCGImage(output, from: rect, format: .RGBA8, colorSpace: SnapshotImage.colorSpace) else {
            throw SnapshotFailure("Could not encode snapshot difference")
        }
        return image
    }
}
