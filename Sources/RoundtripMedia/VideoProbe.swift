import Foundation

/// The parts of `ffprobe` output the pipeline needs.
public struct VideoProbe: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var videoDuration: Double?
    public var containerDuration: Double?
    public var audioStreams: [Int]

    public static func read(_ url: URL) throws -> VideoProbe {
        let data = try ProcessRunner.run(["ffprobe", "-v", "error", "-show_streams", "-show_format",
                                          "-of", "json", url.path])
        return try parse(data)
    }

    static func parse(_ data: Data) throws -> VideoProbe {
        struct Stream: Decodable {
            let index: Int
            let codec_type: String?
            let codec_name: String?
            let width: Int?
            let height: Int?
            let duration: String?
        }
        struct Format: Decodable { let duration: String? }
        struct Output: Decodable { let streams: [Stream]; let format: Format? }
        let output = try JSONDecoder().decode(Output.self, from: data)
        guard let video = output.streams.first(where: { $0.codec_type == "video" }),
              let width = video.width, let height = video.height else {
            throw VideoCompressionError.noVideoStream
        }
        let audio = output.streams.filter {
            $0.codec_type == "audio" && !["", "none", "unknown"].contains($0.codec_name ?? "")
        }.map(\.index)
        return VideoProbe(width: width, height: height, videoDuration: video.duration.flatMap(Double.init),
                          containerDuration: output.format?.duration.flatMap(Double.init), audioStreams: audio)
    }
}
