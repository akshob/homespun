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
#endif
