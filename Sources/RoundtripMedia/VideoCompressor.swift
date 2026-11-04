// SPDX-License-Identifier: Apache-2.0
import Foundation
import RoundtripCore

public enum VideoCompressionError: Error, Equatable {
    case noVideoStream
    case durationMismatch(String)
    case dimensionsExceedProfile(Int, Int)
    case audioTrackCountChanged(Int, Int)
}

public struct VideoCompressionResult: Equatable, Sendable {
    public enum Mode: String, Sendable { case transcoded, originalKeptNotSmaller }
    public var mode: Mode
    public var sha256: String
    public var size: Int
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
        var arguments = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", input.path,
                         "-map", "0:v:0"]
        for index in probe.audioStreams { arguments += ["-map", "0:\(index)"] }
        arguments += ["-map_metadata", "0",
                      "-c:v", "libx265", "-preset", "medium", "-crf", String(profile.videoCRF),
                      "-pix_fmt", "yuv420p", "-tag:v", "hvc1",
                      "-vf", "scale=\(size.width):\(size.height)",
                      "-c:a", "aac", "-b:a", "\(profile.audioBitrateKbps)k",
                      "-movflags", "+use_metadata_tags+faststart",
                      "-f", output.pathExtension.lowercased() == "mov" ? "mov" : "mp4", output.path]
        return arguments
    }

    /// Video stream and container lengths must each match within 0.5 s or 1%.
    public static func durationsMatch(_ source: Double?, _ output: Double?) -> Bool {
        guard let source, let output else { return true }
        return abs(source - output) <= max(0.5, 0.01 * source)
    }

    #if os(Linux) || os(macOS)
    public func compress(input: URL, output: URL) throws -> VideoCompressionResult {
        let probe = try VideoProbe.read(input)
        let partial = output.deletingLastPathComponent()
            .appendingPathComponent(".partial-\(output.lastPathComponent)")
        try? FileManager.default.removeItem(at: partial)
        defer { try? FileManager.default.removeItem(at: partial) }

        try ProcessRunner.run(arguments(input: input, output: partial, probe: probe))
        let result = try VideoProbe.read(partial)
        let box = profile.videoSize(width: probe.width, height: probe.height)
        guard result.width <= box.width, result.height <= box.height else {
            throw VideoCompressionError.dimensionsExceedProfile(result.width, result.height)
        }
        guard result.audioStreams.count == probe.audioStreams.count else {
            throw VideoCompressionError.audioTrackCountChanged(probe.audioStreams.count, result.audioStreams.count)
        }
        for (label, source, compressed) in [("video", probe.videoDuration, result.videoDuration),
                                            ("container", probe.containerDuration, result.containerDuration)]
            where !Self.durationsMatch(source, compressed) {
            throw VideoCompressionError.durationMismatch("\(label) \(source ?? 0)s vs \(compressed ?? 0)s")
        }
        try ProcessRunner.run(["ffmpeg", "-v", "error", "-xerror", "-i", partial.path,
                               "-map", "0:v:0", "-f", "null", "-"])

        let sourceSize = try size(of: input)
        var mode = VideoCompressionResult.Mode.transcoded
        if try size(of: partial) >= sourceSize {
            try FileManager.default.removeItem(at: partial)
            try FileManager.default.copyItem(at: input, to: partial)
            mode = .originalKeptNotSmaller
        }
        let digest = try Fingerprint.sha256(of: partial)
        let finalSize = try size(of: partial)
        if FileManager.default.fileExists(atPath: output.path) {
            _ = try FileManager.default.replaceItemAt(output, withItemAt: partial)
        } else {
            try FileManager.default.moveItem(at: partial, to: output)
        }
        return VideoCompressionResult(mode: mode, sha256: digest, size: finalSize)
    }

    private func size(of url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
    }
    #endif
}
