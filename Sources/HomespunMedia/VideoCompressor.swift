// SPDX-License-Identifier: Apache-2.0
import Foundation
import HomespunCore

public enum VideoCompressionError: Error, Equatable {
    case noVideoStream
    case emptyInput
    case durationMismatch(String)
    case dimensionsExceedProfile(Int, Int)
    case audioTrackCountChanged(Int, Int)
    /// The input needs a different compressor (for example, Live Photo motion).
    case unsupported(String)
    case encodingFailed(String)
    case verificationFailed(String)
}

public struct VideoCompressionResult: Equatable, Sendable {
    public enum Mode: String, Sendable {
        case transcoded
        case originalKeptNotSmaller
        /// Kept byte-identical because no validated conversion exists yet; see `heldReasons`.
        case originalKeptHeld
    }
    public var mode: Mode
    public var sha256: String
    public var size: Int
    /// Why the original was held, using PhotoRelay's names: `hdr` (PQ), `dolby_vision`
    /// (no HLG base layer), `high_frame_rate` (above 60 fps), `multichannel_audio`, `spatial_audio`.
    public var heldReasons: [String] = []
}

public enum VideoVerification {
    /// Video stream and container lengths must each match within 0.5 s or 1%.
    public static func durationsMatch(_ source: Double?, _ output: Double?,
                                      absolute: Double = 0.5, relative: Double = 0.01) -> Bool {
        guard let source, let output else { return true }
        return abs(source - output) <= max(absolute, relative * source)
    }
}

/// Compresses ordinary (non-Live Photo, SDR) videos with x265 through the `ffmpeg` tool,
/// verifies the result, and publishes it atomically. If the transcode is not smaller,
/// the original is copied instead. Live Photo motion must be compressed with AVFoundation
/// on Apple platforms; FFmpeg breaks the still/motion pairing.
public struct FFmpegVideoCompressor: Sendable {
    public var profile: CompressionProfile

    public init(profile: CompressionProfile = .standard) { self.profile = profile }

    public func arguments(input: URL, output: URL, probe: VideoProbe) -> [String] {
        let size = profile.videoSize(width: probe.width, height: probe.height)
        var arguments = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-xerror",
                         "-threads", "2", "-filter_threads", "1", "-filter_complex_threads", "1",
                         "-max_alloc", "268435456", "-progress", "pipe:1", "-stats_period", "30", "-y", "-i", input.path,
                         "-map", "0:\(probe.videoStreamIndex)"]
        for index in probe.audioStreams { arguments += ["-map", "0:\(index)"] }
        // HLG (including iPhone Dolby Vision 8.4, whose base layer is HLG) stays 10-bit HLG;
        // the Dolby Vision metadata is dropped.
        let color = probe.isHLG
            ? ["-pix_fmt", "yuv420p10le", "-x265-params", "pools=2:frame-threads=1:colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc",
               "-color_primaries", "bt2020", "-color_trc", "arib-std-b67", "-colorspace", "bt2020nc"]
            : ["-pix_fmt", "yuv420p", "-x265-params", "pools=2:frame-threads=1"]
        arguments += ["-map_metadata", "0",
                      "-c:v", "libx265", "-preset", "medium", "-crf", String(profile.videoCRF)] + color + [
                      "-tag:v", "hvc1",
                      "-vf", "scale=\(size.width):\(size.height)",
                      "-c:a", "aac", "-b:a", "\(profile.audioBitrateKbps)k",
                      "-movflags", "+use_metadata_tags+faststart",
                      "-f", output.pathExtension.lowercased() == "mov" ? "mov" : "mp4", output.path]
        return arguments
    }

    /// Video stream and container lengths must each match within 0.5 s or 1%.
    public static func durationsMatch(_ source: Double?, _ output: Double?) -> Bool {
        VideoVerification.durationsMatch(source, output)
    }

    #if os(Linux) || os(macOS)
    public func compress(input: URL, output: URL) throws -> VideoCompressionResult {
        let sourceBytes = try MediaFiles.size(of: input)
        guard sourceBytes > 0 else { throw VideoCompressionError.emptyInput }
        let probe = try VideoProbe.read(input)
        if probe.contentIdentifier != nil {
            throw VideoCompressionError.unsupported("Live Photo motion must be compressed with AVFoundation")
        }
        if !probe.holdReasons.isEmpty {
            let copy = try MediaFiles.publishCopy(of: input, to: output)
            return VideoCompressionResult(mode: .originalKeptHeld, sha256: copy.sha256, size: copy.size,
                                          heldReasons: probe.holdReasons)
        }
        let partial = MediaFiles.partialURL(for: output)
        try? FileManager.default.removeItem(at: partial)
        defer { try? FileManager.default.removeItem(at: partial) }

        // An advancing multi-hour video is allowed to run. Only a stalled frame/media-time
        // counter is bounded; total duration is deliberately not a timeout.
        var encode = arguments(input: input, output: partial, probe: probe)
        let (outputLimit, overflow) = sourceBytes.multipliedReportingOverflow(by: 2)
        guard !overflow else { throw VideoCompressionError.encodingFailed("Input exceeds the supported working-space bound") }
        encode.insert(contentsOf: ["-fs", String(outputLimit)], at: encode.count - 1)
        try ProcessRunner.run(encode, progressTimeout: 30 * 60)
        if try MediaFiles.size(of: partial) >= sourceBytes {
            // The output-size bound may stop a non-beneficial transcode early. Validate all
            // source frames before keeping it; never mistake that stop for a complete encode.
            try ProcessRunner.run(["ffmpeg", "-v", "error", "-nostdin", "-xerror", "-threads", "2",
                "-max_alloc", "268435456", "-progress", "pipe:1", "-stats_period", "30",
                "-i", input.path, "-map", "0:v:0", "-f", "null", "-"], progressTimeout: 30 * 60)
            try FileManager.default.removeItem(at: partial)
            let copy = try MediaFiles.publishCopy(of: input, to: output)
            return .init(mode: .originalKeptNotSmaller, sha256: copy.sha256, size: copy.size)
        }
        let result = try VideoProbe.read(partial)
        let box = profile.videoSize(width: probe.width, height: probe.height)
        guard result.width <= box.width, result.height <= box.height else {
            throw VideoCompressionError.dimensionsExceedProfile(result.width, result.height)
        }
        if probe.isHLG, !result.isHLG || result.hasDolbyVisionConfiguration {
            throw VideoCompressionError.verificationFailed("HLG output is not plain HLG")
        }
        guard result.audioStreams.count == probe.audioStreams.count else {
            throw VideoCompressionError.audioTrackCountChanged(probe.audioStreams.count, result.audioStreams.count)
        }
        for (label, source, compressed) in [("video", probe.videoDuration, result.videoDuration),
                                            ("container", probe.containerDuration, result.containerDuration)]
            where !Self.durationsMatch(source, compressed) {
            throw VideoCompressionError.durationMismatch("\(label) \(source ?? 0)s vs \(compressed ?? 0)s")
        }
        try ProcessRunner.run(["ffmpeg", "-v", "error", "-nostdin", "-xerror", "-threads", "2",
                               "-filter_threads", "1", "-max_alloc", "268435456", "-progress", "pipe:1",
                               "-stats_period", "30", "-i", partial.path,
                               "-map", "0:v:0", "-f", "null", "-"], progressTimeout: 30 * 60)

        if try MediaFiles.size(of: partial) >= MediaFiles.size(of: input) {
            let copy = try MediaFiles.publishCopy(of: input, to: output)
            return VideoCompressionResult(mode: .originalKeptNotSmaller, sha256: copy.sha256, size: copy.size)
        }
        let digest = try Fingerprint.sha256(of: partial)
        let finalSize = try MediaFiles.size(of: partial)
        try MediaFiles.publish(partial, to: output)
        return VideoCompressionResult(mode: .transcoded, sha256: digest, size: finalSize)
    }
    #endif
}
