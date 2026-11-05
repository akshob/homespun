// SPDX-License-Identifier: Apache-2.0
#if canImport(AVFoundation)
import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ImageIO
import UniformTypeIdentifiers
import VideoToolbox

/// Synthetic photos and videos for tests of the Apple backend and the app. Tests never use
/// a real photo library.
public enum Synthetic {
    public static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("homespun-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Deterministic textured image: a gradient with many small rectangles, so encoders have
    /// real detail to work with.
    public static func texture(width: Int, height: Int, alpha: Bool = false, seed: UInt64 = 1) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.displayP3)!
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: space, bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast
                                                                 : CGImageAlphaInfo.noneSkipLast).rawValue)!
        var state = seed
        func random() -> CGFloat {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat(state >> 33) / CGFloat(1 << 31)
        }
        // With alpha, a transparent margin surrounds the content.
        let inset = alpha ? CGFloat(min(width, height)) / 4 : 0
        let area = CGRect(x: 0, y: 0, width: width, height: height).insetBy(dx: inset, dy: inset)
        let gradient = CGGradient(colorsSpace: space, colors: [CGColor(red: 0.1, green: 0.3, blue: 0.7, alpha: 1),
                                                               CGColor(red: 0.9, green: 0.7, blue: 0.2, alpha: 1)] as CFArray,
                                  locations: nil)!
        context.saveGState()
        context.clip(to: area)
        context.drawLinearGradient(gradient, start: area.origin, end: CGPoint(x: area.maxX, y: area.maxY), options: [])
        context.restoreGState()
        for _ in 0..<(width * height / 2000) {
            context.setFillColor(CGColor(red: random(), green: random(), blue: random(), alpha: 1))
            let size = 4 + random() * 40
            context.fill(CGRect(x: area.minX + random() * (area.width - size), y: area.minY + random() * (area.height - size),
                                width: size, height: size))
        }
        return context.makeImage()!
    }

    public struct PhotoSpec: Sendable {
        public var type: UTType
        public var width: Int
        public var height: Int
        public var orientation: Int
        public var alpha: Bool
        public var flat: Bool
        public var quality: Double
        /// Live Photo content identifier (Apple maker note 17). Use a UUID string: ImageIO pads
        /// shorter values to 36 bytes.
        public var contentIdentifier: String?

        public init(type: UTType = .jpeg, width: Int = 4032, height: Int = 3024, orientation: Int = 1,
                    alpha: Bool = false, flat: Bool = false, quality: Double = 0.95, contentIdentifier: String? = nil) {
            self.type = type
            self.width = width
            self.height = height
            self.orientation = orientation
            self.alpha = alpha
            self.flat = flat
            self.quality = quality
            self.contentIdentifier = contentIdentifier
        }
    }

    public static func photo(at url: URL, _ spec: PhotoSpec) throws {
        let image: CGImage
        if spec.flat {
            let context = CGContext(data: nil, width: spec.width, height: spec.height, bitsPerComponent: 8,
                                    bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: spec.width, height: spec.height))
            image = context.makeImage()!
        } else {
            image = texture(width: spec.width, height: spec.height, alpha: spec.alpha)
        }
        var properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: spec.quality,
            kCGImagePropertyOrientation: spec.orientation,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Apple",
                                             kCGImagePropertyTIFFModel: "iPhone 16 Pro"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2024:05:01 12:34:56",
                                             kCGImagePropertyExifOffsetTimeOriginal: "-07:00"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 37.33, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 122.01, kCGImagePropertyGPSLongitudeRef: "W"],
        ]
        if let identifier = spec.contentIdentifier {
            properties[kCGImagePropertyMakerAppleDictionary] = ["17": identifier]
        }
        let destination = CGImageDestinationCreateWithURL(url as CFURL, spec.type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    public struct VideoSpec: Sendable {
        public var width: Int
        public var height: Int
        public var fps: Int32
        public var frames: Int
        public var bitrate: Int
        public var audioChannels: UInt32
        public var audioSampleRate: Int
        public var audioBitrate: Int
        /// HLG or PQ transfer function; writes 10-bit HEVC tagged BT.2020.
        public var transfer: String?
        public var transform: CGAffineTransform
        /// Writes Live Photo motion: content identifier, still-image-time track, and its link.
        public var liveIdentifier: String?
        public var cleanAperture: (width: Int, height: Int)?

        public init(width: Int = 1920, height: Int = 1080, fps: Int32 = 30, frames: Int = 60,
                    bitrate: Int = 20_000_000, audioChannels: UInt32 = 2, audioSampleRate: Int = 44_100,
                    audioBitrate: Int = 128_000, transfer: String? = nil, transform: CGAffineTransform = .identity,
                    liveIdentifier: String? = nil, cleanAperture: (width: Int, height: Int)? = nil) {
            self.width = width
            self.height = height
            self.fps = fps
            self.frames = frames
            self.bitrate = bitrate
            self.audioChannels = audioChannels
            self.audioSampleRate = audioSampleRate
            self.audioBitrate = audioBitrate
            self.transfer = transfer
            self.transform = transform
            self.liveIdentifier = liveIdentifier
            self.cleanAperture = cleanAperture
        }
    }

    public static func video(at url: URL, _ spec: VideoSpec) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: url.pathExtension == "mp4" ? .mp4 : .mov)
        var compression: [String: Any] = [AVVideoAverageBitRateKey: spec.bitrate]
        var settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: spec.width,
                                       AVVideoHeightKey: spec.height]
        if let transfer = spec.transfer {
            settings[AVVideoCodecKey] = AVVideoCodecType.hevc
            compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel as String
            settings[AVVideoColorPropertiesKey] = [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                                                   AVVideoTransferFunctionKey: transfer,
                                                   AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020]
        }
        if let clap = spec.cleanAperture {
            settings[AVVideoCleanApertureKey] = [AVVideoCleanApertureWidthKey: clap.width,
                                                 AVVideoCleanApertureHeightKey: clap.height,
                                                 AVVideoCleanApertureHorizontalOffsetKey: 0,
                                                 AVVideoCleanApertureVerticalOffsetKey: 0]
        }
        settings[AVVideoCompressionPropertiesKey] = compression
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        videoInput.transform = spec.transform
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: spec.width, kCVPixelBufferHeightKey as String: spec.height,
        ])
        writer.add(videoInput)

        let sampleRate = spec.audioSampleRate
        var audioInput: AVAssetWriterInput?
        var audioFormat: CMAudioFormatDescription?
        if spec.audioChannels > 0 {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: spec.audioChannels,
                AVSampleRateKey: sampleRate, AVEncoderBitRateKey: spec.audioBitrate,
            ])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioInput = input
            var description = AudioStreamBasicDescription(
                mSampleRate: Double(sampleRate), mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                mBytesPerPacket: 2 * spec.audioChannels, mFramesPerPacket: 1, mBytesPerFrame: 2 * spec.audioChannels,
                mChannelsPerFrame: spec.audioChannels, mBitsPerChannel: 16, mReserved: 0)
            CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0,
                                           layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                           formatDescriptionOut: &audioFormat)
        }

        var metadataAdaptor: AVAssetWriterInputMetadataAdaptor?
        if let identifier = spec.liveIdentifier {
            let item = AVMutableMetadataItem()
            item.key = "com.apple.quicktime.content.identifier" as NSString
            item.keySpace = .quickTimeMetadata
            item.value = identifier as NSString
            item.dataType = kCMMetadataBaseDataType_UTF8 as String
            writer.metadata = [item]
            var format: CMFormatDescription?
            CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
                allocator: kCFAllocatorDefault, metadataType: kCMMetadataFormatType_Boxed,
                metadataSpecifications: [[
                    kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String:
                        "mdta/com.apple.quicktime.still-image-time",
                    kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String:
                        "com.apple.metadata.datatype.int8",
                ]] as CFArray, formatDescriptionOut: &format)
            let input = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: format)
            writer.add(input)
            input.addTrackAssociation(withTrackOf: videoInput, type: AVAssetTrack.AssociationType.metadataReferent.rawValue)
            metadataAdaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: input)
        }

        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        let background = texture(width: spec.width + spec.frames * 4, height: spec.height)
        func ready(_ input: AVAssetWriterInput) async throws {
            var waits = 0
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { throw writer.error! }
                waits += 1
                guard waits < 20_000 else { throw CocoaError(.fileWriteUnknown) }
                try await Task.sleep(nanoseconds: 500_000)
            }
        }
        var audioFrame = 0
        for frame in 0..<spec.frames {
            let time = CMTime(value: CMTimeValue(frame), timescale: spec.fps)
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            let pixels = buffer!
            CVPixelBufferLockBaseAddress(pixels, [])
            let context = CGContext(data: CVPixelBufferGetBaseAddress(pixels), width: spec.width, height: spec.height,
                                    bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixels),
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                        | CGBitmapInfo.byteOrder32Little.rawValue)!
            context.draw(background, in: CGRect(x: -frame * 4, y: 0, width: background.width, height: background.height))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            if let transfer = spec.transfer {
                // Tagging the frames avoids a colour conversion VideoToolbox rejects for HLG.
                CVBufferSetAttachment(pixels, kCVImageBufferColorPrimariesKey,
                                      kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
                CVBufferSetAttachment(pixels, kCVImageBufferTransferFunctionKey, transfer as CFString, .shouldPropagate)
                CVBufferSetAttachment(pixels, kCVImageBufferYCbCrMatrixKey,
                                      kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
            }
            try await ready(videoInput)
            guard adaptor.append(pixels, withPresentationTime: time) else { throw writer.error! }

            if let metadataAdaptor, frame == spec.frames / 2 {
                let item = AVMutableMetadataItem()
                item.identifier = AVMetadataIdentifier(rawValue: "mdta/com.apple.quicktime.still-image-time")
                item.dataType = "com.apple.metadata.datatype.int8"
                item.value = 0 as NSNumber
                try await ready(metadataAdaptor.assetWriterInput)
                metadataAdaptor.append(AVTimedMetadataGroup(
                    items: [item], timeRange: CMTimeRange(start: time, duration: CMTime(value: 1, timescale: spec.fps))))
            }

            if let audioInput, let audioFormat {
                let end = (frame + 1) * sampleRate / Int(spec.fps)
                let count = end - audioFrame
                let channels = Int(spec.audioChannels)
                var samples = [Int16](repeating: 0, count: count * channels)
                for index in 0..<count {
                    let value = Int16(8000 * sin(2 * Double.pi * 440 * Double(audioFrame + index) / Double(sampleRate)))
                    for channel in 0..<channels { samples[index * channels + channel] = value }
                }
                var block: CMBlockBuffer?
                let bytes = samples.count * 2
                CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes,
                                                   blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                                                   offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block)
                samples.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(
                    with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: bytes) }
                var sample: CMSampleBuffer?
                CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                    allocator: kCFAllocatorDefault, dataBuffer: block!, formatDescription: audioFormat,
                    sampleCount: count, presentationTimeStamp: CMTime(value: CMTimeValue(audioFrame),
                                                                      timescale: CMTimeScale(sampleRate)),
                    packetDescriptions: nil, sampleBufferOut: &sample)
                try await ready(audioInput)
                guard audioInput.append(sample!) else { throw writer.error! }
                audioFrame = end
            }
        }
        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        metadataAdaptor?.assetWriterInput.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }
}
#endif
