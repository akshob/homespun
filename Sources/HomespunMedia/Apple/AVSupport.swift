// SPDX-License-Identifier: Apache-2.0
#if canImport(AVFoundation)
import AVFoundation
import CoreMedia
import Foundation

/// AVFoundation helpers shared by the ordinary-video and Live Photo motion compressors.
enum AVSupport {
    static let contentIdentifierKey = "com.apple.quicktime.content.identifier"
    static let creationDateKey = "com.apple.quicktime.creationdate"
    /// Apple Positional Audio Codec ('apac'), the iPhone's spatial audio track.
    static let spatialAudioFormat: AudioFormatID = 0x6170_6163

    static func contentIdentifier(of asset: AVAsset) async throws -> String? {
        for item in try await asset.load(.metadata) where isQuickTimeKey(item, contentIdentifierKey) {
            return try await item.load(.stringValue)
        }
        return nil
    }

    static func isQuickTimeKey(_ item: AVMetadataItem, _ key: String) -> Bool {
        (item.key as? String) == key || item.identifier?.rawValue == "mdta/\(key)"
    }

    /// Source metadata, plus a QuickTime creation date taken from the movie header when the
    /// source has none (typical of MP4 files from Android and messaging apps). Apple Photos
    /// dates videos from this item, and AVAssetWriter otherwise stamps the encode time.
    static func metadataForWriting(_ asset: AVAsset) async throws -> [AVMetadataItem] {
        var items = try await asset.load(.metadata)
        guard !items.contains(where: { isQuickTimeKey($0, creationDateKey) }),
              let created = try await asset.load(.creationDate),
              let date = try await created.load(.dateValue),
              date > Date(timeIntervalSince1970: 86_400) else { return items }
        let item = AVMutableMetadataItem()
        item.identifier = .quickTimeMetadataCreationDate
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        item.value = ISO8601DateFormatter().string(from: date) as NSString
        items.append(item)
        return items
    }

    struct VideoTraits {
        var encodedWidth: Int
        var encodedHeight: Int
        var transferFunction: String?
        var codec: FourCharCode
        var frameRate: Float

        init(format: CMFormatDescription, frameRate: Float) {
            let dimensions = CMVideoFormatDescriptionGetDimensions(format)
            encodedWidth = Int(dimensions.width)
            encodedHeight = Int(dimensions.height)
            transferFunction = CMFormatDescriptionGetExtension(
                format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
            codec = CMFormatDescriptionGetMediaSubType(format)
            self.frameRate = frameRate
        }

        var isHLG: Bool { transferFunction == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String) }
        var isPQ: Bool { transferFunction == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String) }
        /// Dolby Vision sample entries. iPhone Dolby Vision (profile 8.4) is stored as `hvc1`
        /// with an HLG base layer and is handled as HLG.
        var isDolbyVisionCodec: Bool {
            ["dvh1", "dvhe", "dva1", "dvav"].map(fourCC).contains(codec)
        }

        /// Reasons to keep an ordinary video unchanged, matching PhotoRelay's rules.
        var holdReasons: [String] {
            var reasons: [String] = []
            if isPQ { reasons.append("hdr") }
            if isDolbyVisionCodec && !isHLG { reasons.append("dolby_vision") }
            if frameRate > 61 { reasons.append("high_frame_rate") }
            return reasons
        }
    }

    static func fourCC(_ code: String) -> FourCharCode {
        code.utf8.reduce(0) { $0 << 8 | FourCharCode($1) }
    }

    static func traits(of track: AVAssetTrack) async throws -> (CMFormatDescription, VideoTraits) {
        guard let format = try await track.load(.formatDescriptions).first else {
            throw VideoCompressionError.noVideoStream
        }
        return (format, VideoTraits(format: format, frameRate: try await track.load(.nominalFrameRate)))
    }

    static func colorProperties(_ format: CMFormatDescription) -> [String: Any]? {
        let primaries = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries)
        let transfer = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction)
        let matrix = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_YCbCrMatrix)
        guard let primaries, let transfer, let matrix else { return nil }
        return [
            AVVideoColorPrimariesKey: primaries,
            AVVideoTransferFunctionKey: transfer,
            AVVideoYCbCrMatrixKey: matrix,
        ]
    }

    /// The source clean aperture scaled to the output, or nil when the source has none.
    static func cleanAperture(_ format: CMFormatDescription, scale: Double) -> [String: Any]? {
        guard let clap = CMFormatDescriptionGetExtension(
            format, extensionKey: kCMFormatDescriptionExtension_CleanAperture) as? [String: Any] else { return nil }
        func value(_ key: CFString, _ rational: CFString) -> Double? {
            if let number = clap[key as String] as? NSNumber { return number.doubleValue }
            if let pair = clap[rational as String] as? [NSNumber], pair.count == 2, pair[1].doubleValue != 0 {
                return pair[0].doubleValue / pair[1].doubleValue
            }
            return nil
        }
        guard let width = value(kCMFormatDescriptionKey_CleanApertureWidth,
                                kCMFormatDescriptionKey_CleanApertureWidthRational),
              let height = value(kCMFormatDescriptionKey_CleanApertureHeight,
                                 kCMFormatDescriptionKey_CleanApertureHeightRational)
        else { return nil }
        let x = value(kCMFormatDescriptionKey_CleanApertureHorizontalOffset,
                      kCMFormatDescriptionKey_CleanApertureHorizontalOffsetRational) ?? 0
        let y = value(kCMFormatDescriptionKey_CleanApertureVerticalOffset,
                      kCMFormatDescriptionKey_CleanApertureVerticalOffsetRational) ?? 0
        func even(_ v: Double) -> Int { Int((v * scale / 2).rounded()) * 2 }
        return [
            AVVideoCleanApertureWidthKey: even(width),
            AVVideoCleanApertureHeightKey: even(height),
            AVVideoCleanApertureHorizontalOffsetKey: Int((x * scale).rounded()),
            AVVideoCleanApertureVerticalOffsetKey: Int((y * scale).rounded()),
        ]
    }

    /// AAC settings for a decoded audio track; nil if the track is spatial audio (APAC),
    /// which derivatives skip.
    static func aacSettings(for format: CMFormatDescription, bitrate: Int) throws -> [String: Any]? {
        guard let basic = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else {
            throw VideoCompressionError.unsupported("unreadable audio format")
        }
        if basic.mFormatID == spatialAudioFormat { return nil }
        let channels = Int(basic.mChannelsPerFrame)
        let sampleRate = min(basic.mSampleRate, 48_000)
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: channels,
            AVSampleRateKey: sampleRate,
            AVEncoderBitRateKey: aacBitrate(channels <= 2 ? bitrate : 48_000 * channels,
                                            sampleRate: sampleRate, channels: channels),
        ]
        if channels > 2 {
            var layoutSize = 0
            guard let layout = CMAudioFormatDescriptionGetChannelLayout(format, sizeOut: &layoutSize) else {
                throw VideoCompressionError.unsupported("\(channels)-channel audio without a channel layout")
            }
            settings[AVChannelLayoutKey] = Data(bytes: layout, count: layoutSize)
        }
        return settings
    }

    /// The highest bitrate at or below `target` that the AAC encoder accepts for this sample
    /// rate and channel count. Low-rate audio (8 kHz voice, old phones) cannot carry 96 kbps.
    static func aacBitrate(_ target: Int, sampleRate: Double, channels: Int) -> Int {
        // AAC-LC carries at most 6144 bits per channel per 1024-sample frame.
        let ceiling = min(target, Int(sampleRate * 6) * channels)
        guard let output = AVAudioFormat(settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                                                    AVSampleRateKey: sampleRate,
                                                    AVNumberOfChannelsKey: channels]),
              let input = AVAudioFormat(standardFormatWithSampleRate: sampleRate,
                                        channels: AVAudioChannelCount(channels)),
              let converter = AVAudioConverter(from: input, to: output),
              let rates = converter.applicableEncodeBitRates?.map(\.intValue), let lowest = rates.min()
        else { return ceiling }
        return rates.filter { $0 <= ceiling }.max() ?? lowest
    }

    /// Copies sample buffers from each reader output to its writer input until all finish.
    final class SamplePump: @unchecked Sendable {
        /// One reader output feeding one writer input. Its state is only touched on its own queue.
        private final class Lane: @unchecked Sendable {
            let output: AVAssetReaderOutput
            let input: AVAssetWriterInput
            let queue: DispatchQueue
            var finished = false

            init(_ output: AVAssetReaderOutput, _ input: AVAssetWriterInput, index: Int) {
                self.output = output
                self.input = input
                queue = DispatchQueue(label: "photos.homespun.pump.\(index)")
            }
        }

        private let lanes: [Lane]

        init(_ pairs: [(AVAssetReaderOutput, AVAssetWriterInput)]) {
            lanes = pairs.enumerated().map { Lane($1.0, $1.1, index: $0) }
        }

        func run() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let group = DispatchGroup()
                for lane in lanes {
                    group.enter()
                    lane.input.requestMediaDataWhenReady(on: lane.queue) {
                        while !lane.finished && lane.input.isReadyForMoreMediaData {
                            if let sample = lane.output.copyNextSampleBuffer(), lane.input.append(sample) { continue }
                            lane.finished = true
                            lane.input.markAsFinished()
                            group.leave()
                        }
                    }
                }
                group.notify(queue: .global()) { continuation.resume() }
            }
        }
    }

    /// Runs a configured reader/writer pair to completion.
    static func transfer(reader: AVAssetReader, writer: AVAssetWriter,
                         pairs: [(AVAssetReaderOutput, AVAssetWriterInput)]) async throws {
        guard reader.startReading() else {
            throw VideoCompressionError.encodingFailed("reader: \(String(describing: reader.error))")
        }
        guard writer.startWriting() else {
            throw VideoCompressionError.encodingFailed("writer: \(String(describing: writer.error))")
        }
        writer.startSession(atSourceTime: .zero)
        await SamplePump(pairs).run()
        if reader.status == .failed {
            writer.cancelWriting()
            throw VideoCompressionError.encodingFailed("reader: \(String(describing: reader.error))")
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw VideoCompressionError.encodingFailed("writer: \(String(describing: writer.error))")
        }
    }

    /// Decodes every frame of the first video track; returns the frame count.
    static func decodeVideo(_ url: URL) async throws -> Int {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoCompressionError.noVideoStream
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw VideoCompressionError.verificationFailed("decode: \(String(describing: reader.error))")
        }
        var frames = 0
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetImageBuffer(sample) != nil { frames += 1 }
        }
        guard reader.status == .completed, frames > 0 else {
            throw VideoCompressionError.verificationFailed("decode: \(String(describing: reader.error))")
        }
        return frames
    }

    static func duration(of track: AVAssetTrack) async throws -> Double {
        try await track.load(.timeRange).duration.seconds
    }

    static func fileType(for url: URL) -> AVFileType {
        switch url.pathExtension.lowercased() {
        case "mp4": .mp4
        case "m4v": .m4v
        default: .mov
        }
    }
}
#endif
