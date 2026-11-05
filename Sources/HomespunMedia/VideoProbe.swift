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

    public init(width: Int, height: Int, videoDuration: Double?, containerDuration: Double?, audioStreams: [Int],
                videoStreamIndex: Int = 0, colorTransfer: String? = nil, frameRate: Double = 0,
                hasDolbyVisionConfiguration: Bool = false, contentIdentifier: String? = nil) {
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
    }

    public var isHLG: Bool { colorTransfer == "arib-std-b67" }

    /// Reasons to keep the video unchanged, matching PhotoRelay: PQ HDR, Dolby Vision without
    /// an HLG base layer, and more than 60 frames per second.
    public var holdReasons: [String] {
        var reasons: [String] = []
        if colorTransfer == "smpte2084" { reasons.append("hdr") }
        if hasDolbyVisionConfiguration && !isHLG { reasons.append("dolby_vision") }
        if frameRate > 61 { reasons.append("high_frame_rate") }
        return reasons
    }

    #if os(Linux) || os(macOS)
    public static func read(_ url: URL) throws -> VideoProbe {
        let data = try ProcessRunner.run(["ffprobe", "-v", "error", "-show_streams", "-show_format",
                                          "-of", "json", url.path])
        return try parse(data)
    }
    #endif

    static func parse(_ data: Data) throws -> VideoProbe {
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
        let audio = output.streams.filter {
            $0.codec_type == "audio" && !["", "none", "unknown"].contains($0.codec_name ?? "")
        }.map(\.index)
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
                          contentIdentifier: tags["com.apple.quicktime.content.identifier"])
    }
}
