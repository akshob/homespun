// SPDX-License-Identifier: Apache-2.0
import Foundation

/// The parts of `ffprobe` output the pipeline needs.
public struct VideoProbe: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var videoDuration: Double?
    public var containerDuration: Double?
    public var audioStreams: [Int]
    public var videoStreamIndex = 0
    public var colorTransfer: String?
    public var frameRate: Double = 0
    public var hasDolbyVisionConfiguration = false
    /// QuickTime Live Photo content identifier; set only for Live Photo motion.
    public var contentIdentifier: String?
    /// Audio tracks ffmpeg can't decode, left out of `audioStreams`: newer iPhones record Apple's
    /// spatial audio (APAC) next to an ordinary stereo track, which the compact copy keeps.
    public var undecodableAudio = 0

    public init(width: Int, height: Int, videoDuration: Double?, containerDuration: Double?, audioStreams: [Int],
                videoStreamIndex: Int = 0, colorTransfer: String? = nil, frameRate: Double = 0,
                hasDolbyVisionConfiguration: Bool = false, contentIdentifier: String? = nil, undecodableAudio: Int = 0) {
        self.width = width
        self.height = height
        self.videoDuration = videoDuration
        self.containerDuration = containerDuration
        self.audioStreams = audioStreams
        self.videoStreamIndex = videoStreamIndex
        self.colorTransfer = colorTransfer
        self.frameRate = frameRate
        self.hasDolbyVisionConfiguration = hasDolbyVisionConfiguration
        self.contentIdentifier = contentIdentifier
        self.undecodableAudio = undecodableAudio
    }

    public var isHLG: Bool { colorTransfer == "arib-std-b67" }

    /// Reasons to keep the video unchanged, matching PhotoRelay: PQ HDR, Dolby Vision without
    /// an HLG base layer, and more than 60 frames per second.
    public var holdReasons: [String] {
        var reasons: [String] = []
        if colorTransfer == "smpte2084" { reasons.append("hdr") }
        if hasDolbyVisionConfiguration && !isHLG { reasons.append("dolby_vision") }
        if frameRate > 61 { reasons.append("high_frame_rate") }
        // Its only sound is in tracks ffmpeg can't decode: a compact copy would be silent.
        if audioStreams.isEmpty && undecodableAudio > 0 { reasons.append("spatial_audio") }
        return reasons
    }

    #if os(Linux) || os(macOS)
    public static func read(_ url: URL) throws -> VideoProbe {
        let data = try ProcessRunner.run(["ffprobe", "-v", "error", "-show_streams", "-show_format",
                                          "-of", "json", url.path])
        return try parse(data, decodable: FFmpegCodecs.decodable)
    }
    #endif

    /// `decodable`: the codecs ffmpeg can decode (nil: don't check).
    static func parse(_ data: Data, decodable: Set<String>? = nil) throws -> VideoProbe {
        struct SideData: Decodable { let side_data_type: String? }
        struct Disposition: Decodable { let attached_pic: Int? }
        struct Stream: Decodable {
            let index: Int
            let codec_type: String?
            let codec_name: String?
            let width: Int?
            let height: Int?
            let duration: String?
            let color_transfer: String?
            let avg_frame_rate: String?
            let r_frame_rate: String?
            let side_data_list: [SideData]?
            let disposition: Disposition?
        }
        struct Format: Decodable { let duration: String?; let tags: [String: String]? }
        struct Output: Decodable { let streams: [Stream]; let format: Format? }
        let output = try JSONDecoder().decode(Output.self, from: data)
        guard let video = output.streams.first(where: { $0.codec_type == "video" && $0.disposition?.attached_pic != 1 }),
              let width = video.width, let height = video.height else {
            throw VideoCompressionError.noVideoStream
        }
        let named = output.streams.filter {
            $0.codec_type == "audio" && !["", "none", "unknown"].contains($0.codec_name ?? "")
        }
        let audio = named.filter { decodable?.contains($0.codec_name ?? "") ?? true }.map(\.index)
        func rate(_ text: String?) -> Double? {
            guard let parts = text?.split(separator: "/"), parts.count == 2,
                  let numerator = Double(parts[0]), let denominator = Double(parts[1]), denominator > 0 else { return nil }
            return numerator / denominator
        }
        let dolbyVision = video.side_data_list?.contains {
            ($0.side_data_type ?? "").lowercased().contains("dovi") || ($0.side_data_type ?? "").lowercased().contains("dolby vision")
        } ?? false
        let tags = output.format?.tags ?? [:]
        return VideoProbe(width: width, height: height, videoDuration: video.duration.flatMap(Double.init),
                          containerDuration: output.format?.duration.flatMap(Double.init), audioStreams: audio,
                          videoStreamIndex: video.index, colorTransfer: video.color_transfer,
                          frameRate: rate(video.avg_frame_rate) ?? rate(video.r_frame_rate) ?? 0,
                          hasDolbyVisionConfiguration: dolbyVision,
                          contentIdentifier: tags["com.apple.quicktime.content.identifier"],
                          undecodableAudio: named.count - audio.count)
    }
}

/// The codecs this ffmpeg can decode: `ffmpeg -codecs` lists them with "D" first.
public enum FFmpegCodecs {
    #if os(Linux) || os(macOS)
    private static let cache = Cache()
    public static var decodable: Set<String>? {
        cache.read { try ProcessRunner.run(["ffmpeg", "-hide_banner", "-codecs"]) }
    }

    /// A cancelled first job must not cache an unknown codec list for the server's lifetime.
    final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Set<String>?

        func read(_ load: () throws -> Data) -> Set<String>? {
            lock.lock()
            let cached = value
            lock.unlock()
            if let cached { return cached }
            guard let data = try? load() else { return nil }
            let found = FFmpegCodecs.parse(String(decoding: data, as: UTF8.self))
            guard !found.isEmpty else { return nil }
            lock.lock()
            value = found
            lock.unlock()
            return found
        }
    }
    #endif

    static func parse(_ listing: String) -> Set<String> {
        var found = Set<String>(), listed = false
        for line in listing.split(separator: "\n") {
            let parts = line.split(separator: " ")
            if parts.first?.hasPrefix("-------") == true {
                listed = true
                continue
            }
            guard listed, parts.count >= 2, parts[0].count == 6, parts[0].first == "D" else { continue }
            found.insert(String(parts[1]))
        }
        return found
    }
}
