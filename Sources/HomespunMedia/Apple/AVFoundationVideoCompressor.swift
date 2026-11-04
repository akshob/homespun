// SPDX-License-Identifier: Apache-2.0
#if canImport(AVFoundation)
import AVFoundation
import CoreMedia
import Foundation
import HomespunCore
import VideoToolbox

/// Compresses ordinary videos on the device with the hardware HEVC encoder (on-phone mode).
///
/// Output fits the profile's video box with even dimensions, AAC audio, and the source
/// metadata. HLG (including iPhone Dolby Vision 8.4) becomes 10-bit HLG; PQ, Dolby Vision
/// without an HLG base layer, and video above 60 fps are held unchanged. Spatial audio (APAC)
/// is skipped in the derivative. The result is verified, then published atomically; a result
/// that is not smaller keeps the original. Live Photo motion must use `LivePhotoMotionCompressor`.
public struct AVFoundationVideoCompressor: Sendable {
    public var profile: CompressionProfile
    /// VideoToolbox constant quality, 0...1. PhotoRelay's VMAF test (14 clips): 0.50 gave 29%
    /// of the source size at VMAF 86.1, close to x265 CRF 28 (86.8) but larger.
    public var quality: Double

    public init(profile: CompressionProfile = .standard, quality: Double = 0.5) {
        self.profile = profile
        self.quality = quality
    }

    public func compress(input: URL, output: URL) async throws -> VideoCompressionResult {
        guard try MediaFiles.size(of: input) > 0 else { throw VideoCompressionError.emptyInput }
        let asset = AVURLAsset(url: input)
        let tracks = try await asset.load(.tracks)
        guard let video = tracks.first(where: { $0.mediaType == .video }) else {
            throw VideoCompressionError.noVideoStream
        }
        if try await AVSupport.contentIdentifier(of: asset) != nil {
            throw VideoCompressionError.unsupported("Live Photo motion needs LivePhotoMotionCompressor")
        }
        let (videoFormat, traits) = try await AVSupport.traits(of: video)
        let held = traits.holdReasons
        if !held.isEmpty {
            let copy = try MediaFiles.publishCopy(of: input, to: output)
            return VideoCompressionResult(mode: .originalKeptHeld, sha256: copy.sha256, size: copy.size,
                                          heldReasons: held)
        }

        let partial = MediaFiles.partialURL(for: output)
        try? FileManager.default.removeItem(at: partial)
        defer { try? FileManager.default.removeItem(at: partial) }
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: partial, fileType: AVSupport.fileType(for: output))
        writer.metadata = try await AVSupport.metadataForWriting(asset)
        writer.shouldOptimizeForNetworkUse = true

        let size = profile.videoSize(width: traits.encodedWidth, height: traits.encodedHeight)
        let videoSettings = try settings(width: size.width, height: size.height, format: videoFormat,
                                         traits: traits, writer: writer)
        let videoOutput = AVAssetReaderTrackOutput(track: video, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: traits.isHLG
                ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        videoOutput.alwaysCopiesSampleData = false
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.transform = try await video.load(.preferredTransform)
        videoInput.expectsMediaDataInRealTime = false
        var pairs: [(AVAssetReaderOutput, AVAssetWriterInput)] = [(videoOutput, videoInput)]

        for track in tracks where track.mediaType == .audio {
            guard let format = try await track.load(.formatDescriptions).first,
                  let settings = try AVSupport.aacSettings(for: format, bitrate: profile.audioBitrateKbps * 1000)
            else { continue }
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
            pairs.append((output, AVAssetWriterInput(mediaType: .audio, outputSettings: settings)))
        }
        for (output, input) in pairs {
            guard reader.canAdd(output), writer.canAdd(input) else {
                throw VideoCompressionError.encodingFailed("cannot add \(input.mediaType.rawValue) track")
            }
            reader.add(output)
            writer.add(input)
        }

        try await AVSupport.transfer(reader: reader, writer: writer, pairs: pairs)
        try await verify(partial, source: asset, sourceVideo: video, box: size, hlg: traits.isHLG,
                         audioTracks: pairs.count - 1)

        if try MediaFiles.size(of: partial) >= MediaFiles.size(of: input) {
            let copy = try MediaFiles.publishCopy(of: input, to: output)
            return VideoCompressionResult(mode: .originalKeptNotSmaller, sha256: copy.sha256, size: copy.size)
        }
        let digest = try Fingerprint.sha256(of: partial)
        let finalSize = try MediaFiles.size(of: partial)
        try MediaFiles.publish(partial, to: output)
        return VideoCompressionResult(mode: .transcoded, sha256: digest, size: finalSize)
    }

    private func settings(width: Int, height: Int, format: CMFormatDescription, traits: AVSupport.VideoTraits,
                          writer: AVAssetWriter) throws -> [String: Any] {
        var compression: [String: Any] = [
            AVVideoQualityKey: quality,
            AVVideoExpectedSourceFrameRateKey: max(1, Int(traits.frameRate.rounded())),
        ]
        var settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            // Output dimensions keep the aspect ratio to within even-pixel rounding.
            AVVideoScalingModeKey: AVVideoScalingModeResize,
        ]
        if traits.isHLG {
            compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel as String
            settings[AVVideoColorPropertiesKey] = [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
            ]
        } else if let color = AVSupport.colorProperties(format) {
            settings[AVVideoColorPropertiesKey] = color
        }
        let scale = Double(width) / Double(traits.encodedWidth)
        if let aperture = AVSupport.cleanAperture(format, scale: scale) {
            settings[AVVideoCleanApertureKey] = aperture
        }
        settings[AVVideoCompressionPropertiesKey] = compression
        if writer.canApply(outputSettings: settings, forMediaType: .video) { return settings }

        // Constant quality needs Apple silicon; fall back to about 0.08 bits per pixel.
        compression[AVVideoQualityKey] = nil
        let fps = Double(max(traits.frameRate, 24))
        compression[AVVideoAverageBitRateKey] = max(1_000_000, Int(Double(width * height) * fps * 0.08))
        settings[AVVideoCompressionPropertiesKey] = compression
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
            throw VideoCompressionError.encodingFailed("HEVC encoder rejected \(width)x\(height) settings")
        }
        return settings
    }

    private func verify(_ partial: URL, source: AVAsset, sourceVideo: AVAssetTrack,
                        box: (width: Int, height: Int), hlg: Bool, audioTracks: Int) async throws {
        let result = AVURLAsset(url: partial)
        let tracks = try await result.load(.tracks)
        guard let video = tracks.first(where: { $0.mediaType == .video }) else {
            throw VideoCompressionError.noVideoStream
        }
        let (_, traits) = try await AVSupport.traits(of: video)
        guard traits.encodedWidth <= box.width, traits.encodedHeight <= box.height else {
            throw VideoCompressionError.dimensionsExceedProfile(traits.encodedWidth, traits.encodedHeight)
        }
        if hlg {
            guard traits.isHLG,
                  let format = try await video.load(.formatDescriptions).first,
                  (CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_BitsPerComponent)
                    as? NSNumber)?.intValue == 10 else {
                throw VideoCompressionError.verificationFailed("HLG output is not 10-bit HLG")
            }
        }
        let audio = tracks.filter { $0.mediaType == .audio }.count
        guard audio == audioTracks else { throw VideoCompressionError.audioTrackCountChanged(audioTracks, audio) }
        let checks = [
            ("video", try await AVSupport.duration(of: sourceVideo), try await AVSupport.duration(of: video)),
            ("container", try await source.load(.duration).seconds, try await result.load(.duration).seconds),
        ]
        for (label, before, after) in checks where !VideoVerification.durationsMatch(before, after) {
            throw VideoCompressionError.durationMismatch("\(label) \(before)s vs \(after)s")
        }
        _ = try await AVSupport.decodeVideo(partial)
    }
}
#endif
