// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import HomespunMedia

@Test func probeKeepsOnlyDecodableAudio() throws {
    let json = """
    {"streams":[{"index":0,"codec_type":"video","codec_name":"hevc","width":1920,"height":1080,"duration":"12.87"},
                {"index":1,"codec_type":"audio","codec_name":"aac"},
                {"index":2,"codec_type":"audio","codec_name":"unknown"},
                {"index":3,"codec_type":"data","codec_name":"unknown"}],
     "format":{"duration":"12.90"}}
    """
    let probe = try VideoProbe.parse(Data(json.utf8))
    #expect(probe == VideoProbe(width: 1920, height: 1080, videoDuration: 12.87, containerDuration: 12.90,
                                audioStreams: [1]))
}

@Test func ffmpegArgumentsUseX265AndProfileSize() {
    let probe = VideoProbe(width: 1920, height: 1080, videoDuration: 1, containerDuration: 1, audioStreams: [1])
    let args = FFmpegVideoCompressor().arguments(input: URL(fileURLWithPath: "/in.mov"),
                                                 output: URL(fileURLWithPath: "/out.mov"), probe: probe)
    #expect(args.contains("libx265") && args.contains("hvc1") && args.contains("scale=1280:720"))
    #expect(args[args.firstIndex(of: "-crf")! + 1] == "28")
    #expect(args.contains("0:1") && args.last == "/out.mov" && args.contains("mov"))
}

@Test func durationToleranceAllowsAudioTailButNotTruncation() {
    #expect(FFmpegVideoCompressor.durationsMatch(12.87, 12.6))
    #expect(FFmpegVideoCompressor.durationsMatch(57.19, 57.07))
    #expect(!FFmpegVideoCompressor.durationsMatch(11.5, 10.5))
    #expect(FFmpegVideoCompressor.durationsMatch(nil, 3))
}

#if os(Linux) || os(macOS)
@Test(.enabled(if: ProcessRunner.available("ffmpeg")))
func compressesSyntheticVideoEndToEnd() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let input = directory.appendingPathComponent("in.mp4")
    try ProcessRunner.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=1920x1080:rate=30:duration=3",
                           "-f", "lavfi", "-i", "sine=frequency=440:duration=3",
                           "-c:v", "mpeg4", "-q:v", "2", "-c:a", "aac", "-shortest", input.path])
    let output = directory.appendingPathComponent("out.mp4")
    let result = try FFmpegVideoCompressor().compress(input: input, output: output)
    #expect(result.mode == .transcoded)
    let probe = try VideoProbe.read(output)
    #expect(probe.width == 1280 && probe.height == 720 && probe.audioStreams.count == 1)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == ["in.mp4", "out.mp4"])
}

@Test(.enabled(if: ProcessRunner.available("ffmpeg")), arguments: [
    ("pq", "smpte2084", 30, ["hdr"]),
    ("fps120", "bt709", 120, ["high_frame_rate"]),
    ("hlg", "arib-std-b67", 30, []),
])
func ffmpegHoldsUnvalidatedVideoAndKeepsHLG(name: String, transfer: String, fps: Int, held: [String]) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let input = directory.appendingPathComponent("\(name).mp4")
    let tenBit = transfer != "bt709"
    let primaries = tenBit ? "bt2020" : "bt709", matrix = tenBit ? "bt2020nc" : "bt709"
    // FFmpeg 8+ takes colour tags from the frames, so set them with a filter as well.
    try ProcessRunner.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=1920x1080:rate=\(fps):duration=1",
                           "-vf", "setparams=color_trc=\(transfer):color_primaries=\(primaries):colorspace=\(matrix)",
                           "-c:v", "libx265", "-preset", "ultrafast", "-x265-params", "log-level=error", "-crf", "12",
                           "-pix_fmt", tenBit ? "yuv420p10le" : "yuv420p",
                           "-color_trc", transfer, "-color_primaries", tenBit ? "bt2020" : "bt709",
                           "-colorspace", tenBit ? "bt2020nc" : "bt709", "-tag:v", "hvc1", input.path])
    let output = directory.appendingPathComponent("out.mp4")
    let result = try FFmpegVideoCompressor().compress(input: input, output: output)
    #expect(result.heldReasons == held)
    if held.isEmpty {
        #expect(result.mode == .transcoded)
        let probe = try VideoProbe.read(output)
        #expect(probe.isHLG && probe.width == 1280 && probe.height == 720)
    } else {
        #expect(result.mode == .originalKeptHeld)
        #expect(try Data(contentsOf: output) == Data(contentsOf: input))
    }
}
#endif

@Test func jpegConverterAlwaysWritesAJPEGKeepingMetadata() throws {
    let source = try #require(Bundle.module.url(forResource: "orient6", withExtension: "heic", subdirectory: "Fixtures"))
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jpeg-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let converter = try #require(PlatformMedia.jpegConverter(quality: 95))
    let result = try converter.compress(input: source, output: directory.appendingPathComponent("still.jpg"))
    // Larger than the HEIC, but still a JPEG: full size, upright, same capture date and Live Photo identifier.
    #expect(result.mode == .compressed && result.url.pathExtension == "jpg")
    #expect(result.width == 600 && result.height == 900)
    let jpeg = try Data(contentsOf: result.url)
    let heic = try Data(contentsOf: source)
    #expect(JPEGIntegrity.isJPEG(jpeg) && jpeg.count > heic.count)
    #expect(jpeg.range(of: Data("2024:05:01 12:34:56".utf8)) != nil)
    #expect(jpeg.range(of: Data("8C1A3F52-7D44-4E1B-9B2A-5F6E7D8C9A01".utf8)) != nil)

    // XMP is replaced; EXIF stays.
    let xmp = Data(#"<x:xmpmeta xmlns:x="adobe:ns:meta/"><test/></x:xmpmeta>"#.utf8)
    let edited = try JPEGMetadata.replacingXMP(in: try JPEGMetadata.replacingXMP(in: jpeg, with: xmp), with: xmp)
    #expect(edited.ranges(of: Data("http://ns.adobe.com/xap/1.0/".utf8)).count == 1)
    #expect(edited.range(of: xmp) != nil && edited.range(of: Data("2024:05:01 12:34:56".utf8)) != nil)
    #expect(edited.range(of: Data("Exif\0\0".utf8))!.lowerBound < edited.range(of: xmp)!.lowerBound)
}
