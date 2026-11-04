// SPDX-License-Identifier: Apache-2.0
#if canImport(AVFoundation)
import AVFoundation
import CoreMedia
import Foundation
import HomespunCore

/// Re-encodes Live Photo motion while keeping its pairing with the still.
///
/// FFmpeg cannot do this: it drops the links between Live Photo timed-metadata tracks and
/// the video, so iOS refuses the pair. AVFoundation passes those (`mebx`) tracks through and
/// re-creates their ContentDescribes links to the new video track. Motion keeps its encoded
/// size and clean aperture by default; changing them made iOS show the motion zoomed in
/// relative to the still. Validate the published pair with `LivePhotoValidator`.
///
/// Ported from PhotoRelay's `macos/livephoto_compress.swift`.
public struct LivePhotoMotionCompressor: Sendable {
    public var profile: CompressionProfile
    public var bitrate: Int
    /// Fit within the profile's video box instead of keeping the encoded size. Shrinks files
    /// further at a slight framing risk.
    public var downscale: Bool

    public init(profile: CompressionProfile = .standard, bitrate: Int = 2_000_000, downscale: Bool = false) {
        self.profile = profile
        self.bitrate = bitrate
        self.downscale = downscale
    }

    /// The Live Photo content identifier that pairs a motion file with its still, if any.
    public static func contentIdentifier(of url: URL) async throws -> String? {
        try await AVSupport.contentIdentifier(of: AVURLAsset(url: url))
    }

    public func compress(input: URL, output: URL) async throws -> VideoCompressionResult {
        guard try MediaFiles.size(of: input) > 0 else { throw VideoCompressionError.emptyInput }
        let asset = AVURLAsset(url: input)
        let tracks = try await asset.load(.tracks)
        guard let video = tracks.first(where: { $0.mediaType == .video }) else {
            throw VideoCompressionError.noVideoStream
        }
        guard let identifier = try await AVSupport.contentIdentifier(of: asset) else {
            throw VideoCompressionError.unsupported("not Live Photo motion (no content identifier)")
        }
        let (videoFormat, traits) = try await AVSupport.traits(of: video)

        var held: [String] = []
        // HDR motion stays unchanged until a re-encode is validated on a device.
        if traits.isHLG || traits.isPQ || traits.isDolbyVisionCodec { held.append("hdr") }
        var audioSettings: [(AVAssetTrack, [String: Any])] = []
        for track in tracks where track.mediaType == .audio {
            guard let format = try await track.load(.formatDescriptions).first,
                  let basic = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else {
                throw VideoCompressionError.unsupported("unreadable audio format")
            }
            if basic.mFormatID == AVSupport.spatialAudioFormat {
                held.append("spatial_audio")
            } else if basic.mChannelsPerFrame > 2 {
                held.append("multichannel_audio")
            } else if let settings = try AVSupport.aacSettings(
                for: format, bitrate: profile.audioBitrateKbps * 1000) {
                audioSettings.append((track, settings))
            }
        }
        if !held.isEmpty {
            let copy = try MediaFiles.publishCopy(of: input, to: output)
            return VideoCompressionResult(mode: .originalKeptHeld, sha256: copy.sha256, size: copy.size,
                                          heldReasons: Array(Set(held)).sorted())
        }

        let partial = MediaFiles.partialURL(for: output)
        try? FileManager.default.removeItem(at: partial)
        defer { try? FileManager.default.removeItem(at: partial) }
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: partial, fileType: AVSupport.fileType(for: output))
        writer.metadata = try await asset.load(.metadata)
        writer.shouldOptimizeForNetworkUse = true

        var pairs: [(AVAssetReaderOutput, AVAssetWriterInput)] = []
        var inputsByTrack: [CMPersistentTrackID: AVAssetWriterInput] = [:]

        // Live Photo motion is encoded larger than it is shown: the clean aperture crops a
        // stabilisation margin. Size from the encoded frame and carry the clean aperture over,
        // scaled, so the framing matches the original.
        let (width, height) = downscale
            ? profile.videoSize(width: traits.encodedWidth, height: traits.encodedHeight)
            : (traits.encodedWidth, traits.encodedHeight)
        let scale = Double(width) / Double(traits.encodedWidth)
        let sourceVisible = try await video.load(.naturalSize)
        var videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: Int(traits.frameRate.rounded()),
            ] as [String: Any],
        ]
        if let color = AVSupport.colorProperties(videoFormat) { videoSettings[AVVideoColorPropertiesKey] = color }
        if let aperture = AVSupport.cleanAperture(videoFormat, scale: scale) {
            videoSettings[AVVideoCleanApertureKey] = aperture
        }
        let videoOutput = AVAssetReaderTrackOutput(track: video, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        videoOutput.alwaysCopiesSampleData = false
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.transform = try await video.load(.preferredTransform)
        videoInput.expectsMediaDataInRealTime = false
        pairs.append((videoOutput, videoInput))
        inputsByTrack[video.trackID] = videoInput

        for (track, settings) in audioSettings {
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            pairs.append((output, input))
            inputsByTrack[track.trackID] = input
        }

        let sourceMetadataTracks = tracks.filter { $0.mediaType == .metadata }
        for track in sourceMetadataTracks {
            let format = try await track.load(.formatDescriptions).first
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            let input = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: format)
            pairs.append((output, input))
            inputsByTrack[track.trackID] = input
        }

        for (output, input) in pairs {
            guard reader.canAdd(output), writer.canAdd(input) else {
                throw VideoCompressionError.encodingFailed("cannot add \(input.mediaType.rawValue) track")
            }
            reader.add(output)
            writer.add(input)
        }
        // Re-create every source track association, including the metadata "content
        // describes" links that make iOS accept the Live Photo.
        var associationCount = 0
        for track in tracks {
            guard let input = inputsByTrack[track.trackID] else { continue }
            for type in try await track.load(.availableTrackAssociationTypes) {
                for referent in try await track.loadAssociatedTracks(ofType: type) {
                    guard let target = inputsByTrack[referent.trackID] else { continue }
                    guard input.canAddTrackAssociation(withTrackOf: target, type: type.rawValue) else {
                        throw VideoCompressionError.encodingFailed("cannot recreate \(type.rawValue) association")
                    }
                    input.addTrackAssociation(withTrackOf: target, type: type.rawValue)
                    associationCount += 1
                }
            }
        }

        try await AVSupport.transfer(reader: reader, writer: writer, pairs: pairs)

        let result = AVURLAsset(url: partial)
        let resultTracks = try await result.load(.tracks)
        guard try await AVSupport.contentIdentifier(of: result) == identifier else {
            throw VideoCompressionError.verificationFailed("content identifier was not preserved")
        }
        let resultMetadata = resultTracks.filter { $0.mediaType == .metadata }
        guard resultMetadata.count == sourceMetadataTracks.count else {
            throw VideoCompressionError.verificationFailed("metadata track count changed")
        }
        var resultAssociations = 0
        for track in resultTracks {
            for type in try await track.load(.availableTrackAssociationTypes) {
                resultAssociations += try await track.loadAssociatedTracks(ofType: type).count
            }
        }
        guard resultAssociations >= associationCount else {
            throw VideoCompressionError.verificationFailed("track associations were lost")
        }
        let resultAudio = resultTracks.filter { $0.mediaType == .audio }.count
        guard resultAudio == audioSettings.count else {
            throw VideoCompressionError.audioTrackCountChanged(audioSettings.count, resultAudio)
        }
        guard let resultVideo = resultTracks.first(where: { $0.mediaType == .video }) else {
            throw VideoCompressionError.noVideoStream
        }
        let visible = try await resultVideo.load(.naturalSize)
        let expectedWidth = abs(sourceVisible.width) * scale, expectedHeight = abs(sourceVisible.height) * scale
        guard abs(abs(visible.width) - expectedWidth) <= 2, abs(abs(visible.height) - expectedHeight) <= 2 else {
            throw VideoCompressionError.verificationFailed(
                "visible frame \(visible) does not match the source framing \(sourceVisible)")
        }
        // The pass-through metadata tracks span the whole movie, so the container length alone
        // would hide a short video track.
        let checks = [
            ("video", try await AVSupport.duration(of: video), try await AVSupport.duration(of: resultVideo)),
            ("container", try await asset.load(.duration).seconds, try await result.load(.duration).seconds),
        ]
        for (label, before, after) in checks
            where !VideoVerification.durationsMatch(before, after, absolute: 0.1, relative: 0) {
            throw VideoCompressionError.durationMismatch("\(label) \(before)s vs \(after)s")
        }
        _ = try await AVSupport.decodeVideo(partial)

        if try MediaFiles.size(of: partial) >= MediaFiles.size(of: input) {
            let copy = try MediaFiles.publishCopy(of: input, to: output)
            return VideoCompressionResult(mode: .originalKeptNotSmaller, sha256: copy.sha256, size: copy.size)
        }
        let digest = try Fingerprint.sha256(of: partial)
        let size = try MediaFiles.size(of: partial)
        try MediaFiles.publish(partial, to: output)
        return VideoCompressionResult(mode: .transcoded, sha256: digest, size: size)
    }
}
#endif
