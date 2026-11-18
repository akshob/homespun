// SPDX-License-Identifier: Apache-2.0
// Makes only the demo's bundled videos and Live Photo, using the app's drawing code.
// Run on a Mac: Apps/Homespun/scripts/demo-media.sh [output-folder]
import AVFoundation
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

@main enum DemoMediaTool {
    static func main() async throws {
        let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Demo", isDirectory: true)
        let compact = output.appendingPathComponent("compact", isDirectory: true)
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.createDirectory(at: compact, withIntermediateDirectories: true)
        for recipe in DemoArt.recipes where recipe.bundled {
            let motion = recipe.name + ".MOV"
            if recipe.kind == .video {
                try await writeVideo(recipe.scene!, to: output.appendingPathComponent(motion), width: 1920, height: 1080,
                                     seconds: recipe.seconds, bitrate: 1_400_000, date: recipe.date)
                try await writeVideo(recipe.scene!, to: compact.appendingPathComponent(motion), width: 1280, height: 720,
                                     seconds: recipe.seconds, bitrate: 450_000, date: recipe.date)
            } else {
                let image = DemoArt.photo(recipe), still = recipe.name + ".HEIC", identifier = DemoArt.liveIdentifier
                try DemoArt.writeImage(image, to: output.appendingPathComponent(still), type: .heic,
                                       quality: DemoArt.heicQuality, date: recipe.date, contentIdentifier: identifier)
                try DemoArt.writeImage(DemoArt.scaled(image, maxEdge: 2048), to: compact.appendingPathComponent(still),
                                       type: .heic, quality: 0.5, date: recipe.date, contentIdentifier: identifier)
                try await writeVideo(recipe.scene!, to: output.appendingPathComponent(motion), width: 1440, height: 1080,
                                     seconds: recipe.seconds, bitrate: 1_600_000, date: recipe.date, liveIdentifier: identifier)
                try await writeVideo(recipe.scene!, to: compact.appendingPathComponent(motion), width: 960, height: 720,
                                     seconds: recipe.seconds, bitrate: 500_000, date: recipe.date, liveIdentifier: identifier)
            }
            print("drew \(recipe.name)")
        }
        try """
        # The demo's videos and Live Photo

        SPDX-License-Identifier: Apache-2.0

        Drawn by `Apps/Homespun/scripts/demo-media.sh` (`demo-media.swift` with the app's
        `Features/Demo/DemoArt.swift`; no photographs, no third-party media).

        The demo's photos, screenshot and grid pictures aren't here: the app draws them on the iPhone
        with the same `DemoArt.swift` when the demo starts (`DemoMedia.swift`), and writes `samples.json`
        then. `compact/` holds the compact copies the pretend server sends back for the videos and the
        Live Photo (it makes the photos' own by shrinking them). A unit test
        (`DemoMediaTests.bundledMediaFitsTheBudget`) keeps this folder at 5 MB or less.

        """.write(to: output.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    }

    /// HEVC with no sound, with the paired metadata track when making Live Photo motion.
    static func writeVideo(_ scene: DemoArt.Scene, to url: URL, width: Int, height: Int, seconds: Double, bitrate: Int,
                           date: String, liveIdentifier: String? = nil) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitrate, AVVideoExpectedSourceFrameRateKey: 30],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        var items: [AVMetadataItem] = []
        let creation = AVMutableMetadataItem()
        creation.keySpace = .quickTimeMetadata
        creation.key = "com.apple.quicktime.creationdate" as NSString
        creation.value = date as NSString
        creation.dataType = kCMMetadataBaseDataType_UTF8 as String
        items.append(creation)
        var metadataAdaptor: AVAssetWriterInputMetadataAdaptor?
        if let liveIdentifier {
            let item = AVMutableMetadataItem()
            item.key = "com.apple.quicktime.content.identifier" as NSString
            item.keySpace = .quickTimeMetadata
            item.value = liveIdentifier as NSString
            item.dataType = kCMMetadataBaseDataType_UTF8 as String
            items.append(item)
            var format: CMFormatDescription?
            CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
                allocator: kCFAllocatorDefault, metadataType: kCMMetadataFormatType_Boxed,
                metadataSpecifications: [[
                    kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String: "mdta/com.apple.quicktime.still-image-time",
                    kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String: "com.apple.metadata.datatype.int8",
                ]] as CFArray, formatDescriptionOut: &format)
            let metadataInput = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: format)
            writer.add(metadataInput)
            metadataInput.addTrackAssociation(withTrackOf: input, type: AVAssetTrack.AssociationType.metadataReferent.rawValue)
            metadataAdaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metadataInput)
        }
        writer.metadata = items
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        let frames = Int(seconds * 30)
        func ready(_ input: AVAssetWriterInput) async throws {
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { throw writer.error! }
                try await Task.sleep(nanoseconds: 2_000_000)
            }
        }
        if let metadataAdaptor {
            let item = AVMutableMetadataItem()
            item.identifier = AVMetadataIdentifier(rawValue: "mdta/com.apple.quicktime.still-image-time")
            item.dataType = "com.apple.metadata.datatype.int8"
            item.value = 0 as NSNumber
            try await ready(metadataAdaptor.assetWriterInput)
            metadataAdaptor.append(AVTimedMetadataGroup(items: [item], timeRange: CMTimeRange(
                start: CMTime(value: CMTimeValue(frames / 2), timescale: 30), duration: CMTime(value: 1, timescale: 30))))
            metadataAdaptor.assetWriterInput.markAsFinished()
        }
        for frame in 0..<frames {
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            let pixels = buffer!
            CVPixelBufferLockBaseAddress(pixels, [])
            let context = CGContext(data: CVPixelBufferGetBaseAddress(pixels), width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: CVPixelBufferGetBytesPerRow(pixels), space: DemoArt.sRGB,
                                    bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            context.translateBy(x: 0, y: Double(height))
            context.scaleBy(x: 1, y: -1)
            DemoArt.draw(scene, in: context, width: Double(width), height: Double(height),
                         t: Double(frame) / Double(max(frames - 1, 1)))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            try await ready(input)
            guard adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30)) else {
                throw writer.error!
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }
}
