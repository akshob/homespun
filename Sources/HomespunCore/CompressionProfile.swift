// SPDX-License-Identifier: Apache-2.0
/// Target sizes for compact copies. Defaults match PhotoRelay's validated profile:
/// photos at most 2048 px on the long edge, videos within 1280x720 as HEVC CRF 28.
public struct CompressionProfile: Codable, Equatable, Sendable {
    public var photoMaxEdge: Int
    public var photoQuality: Int
    public var videoLongEdge: Int
    public var videoShortEdge: Int
    public var videoCRF: Int
    public var audioBitrateKbps: Int

    public init(photoMaxEdge: Int = 2048, photoQuality: Int = 80, videoLongEdge: Int = 1280,
                videoShortEdge: Int = 720, videoCRF: Int = 28, audioBitrateKbps: Int = 96) {
        self.photoMaxEdge = photoMaxEdge
        self.photoQuality = photoQuality
        self.videoLongEdge = videoLongEdge
        self.videoShortEdge = videoShortEdge
        self.videoCRF = videoCRF
        self.audioBitrateKbps = audioBitrateKbps
    }

    public static let standard = CompressionProfile()

    // `videoCrf` survives snake_case conversion both ways ("video_crf"); `videoCRF` would not.
    enum CodingKeys: String, CodingKey {
        case photoMaxEdge, photoQuality, videoLongEdge, videoShortEdge, audioBitrateKbps
        case videoCRF = "videoCrf"
    }

    /// Photo output size: fit the long edge within `photoMaxEdge`, keep aspect, never upscale.
    public func photoSize(width: Int, height: Int) -> (width: Int, height: Int) {
        let longEdge = max(width, height)
        guard longEdge > photoMaxEdge, longEdge > 0 else { return (width, height) }
        let scale = Double(photoMaxEdge) / Double(longEdge)
        return (max(1, Int((Double(width) * scale).rounded())), max(1, Int((Double(height) * scale).rounded())))
    }

    /// Video output size: fit within the long/short box for its orientation, keep aspect,
    /// never upscale, and round down to even dimensions as HEVC requires.
    public func videoSize(width: Int, height: Int) -> (width: Int, height: Int) {
        let landscape = width >= height
        let boxWidth = landscape ? videoLongEdge : videoShortEdge
        let boxHeight = landscape ? videoShortEdge : videoLongEdge
        let scale = min(1.0, Double(boxWidth) / Double(width), Double(boxHeight) / Double(height))
        func even(_ value: Double) -> Int { max(2, Int(value) & ~1) }
        return (even(Double(width) * scale), even(Double(height) * scale))
    }
}
