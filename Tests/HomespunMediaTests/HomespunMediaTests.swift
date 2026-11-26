// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import HomespunMedia
#if os(Linux)
import Glibc
#elseif os(macOS)
import Darwin
#endif

@Test func cancelledVerifiedCopyDoesNotPublishOrReplaceAnExistingOutput() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let input = directory.appendingPathComponent("in.mov"), output = directory.appendingPathComponent("out.mov")
    let original = Data("synthetic original".utf8), existing = Data("existing verified output".utf8)
    try original.write(to: input)
    try existing.write(to: output)
    #expect(throws: CancellationError.self) {
        try MediaFiles.publishCopy(of: input, to: output, beforePublish: { throw CancellationError() })
    }
    #expect(try Data(contentsOf: input) == original)
    #expect(try Data(contentsOf: output) == existing)
    #expect(!FileManager.default.fileExists(atPath: MediaFiles.partialURL(for: output).path))
}

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
    let selected = VideoProbe(width: 1280, height: 720, videoDuration: 1, containerDuration: 1,
                              audioStreams: [2, 5], videoStreamIndex: 3)
    let decode = FFmpegVideoCompressor.decodeArguments(URL(fileURLWithPath: "/input.mov"), probe: selected)
    #expect(decode.contains("0:3") && decode.contains("0:2") && decode.contains("0:5") && !decode.contains("0:v:0"))
}

@Test func durationToleranceAllowsAudioTailButNotTruncation() {
    #expect(FFmpegVideoCompressor.durationsMatch(12.87, 12.6))
    #expect(FFmpegVideoCompressor.durationsMatch(57.19, 57.07))
    #expect(!FFmpegVideoCompressor.durationsMatch(11.5, 10.5))
    #expect(FFmpegVideoCompressor.durationsMatch(nil, 3))
}

#if os(Linux) || os(macOS)
@Test func cancelledCodecDiscoveryDoesNotPoisonLaterProbes() {
    let cache = FFmpegCodecs.Cache()
    #expect(cache.read { throw CancellationError() } == nil)
    let listing = Data("Codecs:\n -------\n DEV.L. hevc HEVC\n DEA.L. aac AAC\n".utf8)
    #expect(cache.read { listing } == ["hevc", "aac"])
    #expect(cache.read { throw CancellationError() } == ["hevc", "aac"])
}

@Test(.timeLimit(.minutes(1))) func processRunnerDrainsBothPipesAndBoundsDiagnostics() throws {
    let output = try ProcessRunner.run(["sh", "-c", "head -c 1048576 /dev/zero >&2; printf complete"])
    #expect(String(decoding: output, as: UTF8.self) == "complete")
    do {
        try ProcessRunner.run(["sh", "-c", "head -c 1048576 /dev/zero >&2; printf diagnostic-tail >&2; exit 7"])
        Issue.record("Expected a nonzero process exit")
    } catch let failure as ProcessFailure {
        #expect(failure.status == 7)
        #expect(failure.stderr.utf8.count <= ProcessRunner.maximumDiagnosticBytes)
        #expect(failure.stderr.hasSuffix("diagnostic-tail"))
    }
    #expect(throws: ProcessFailure.self) {
        try ProcessRunner.run(["sh", "-c", "head -c 4096 /dev/zero"], outputLimit: 1024)
    }
}

@Test(.timeLimit(.minutes(1))) func processPipeDrainsProgressWhenCooperativeWorkersAreOccupied() async throws {
    let workers = min(8, max(4, ProcessInfo.processInfo.activeProcessorCount))
    try await withThrowingTaskGroup(of: Data.self) { group in
        for _ in 0..<workers {
            group.addTask {
                try ProcessRunner.run(["sh", "-c", "printf drained; printf diagnostic >&2"])
            }
        }
        for try await output in group {
            #expect(String(decoding: output, as: UTF8.self) == "drained")
        }
    }
}

@Test(.timeLimit(.minutes(1))) func processCancellationTerminatesAndReapsOnlyItsOwnedChild() async throws {
    let cancellation = MediaProcessCancellation()
    defer { cancellation.cancel() }
    try await withThrowingTaskGroup(of: Int32?.self) { group in
        group.addTask {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(with: Result {
                        _ = try cancellation.run {
                            try ProcessRunner.run(["sh", "-c", "trap '' TERM; exec sleep 60"])
                        }
                        return ()
                    })
                }
            }
            return nil
        }
        group.addTask {
            while cancellation.processID == nil { try await Task.sleep(for: .milliseconds(10)) }
            return cancellation.processID
        }
        defer {
            cancellation.cancel()
            group.cancelAll()
        }
        // A failed launch or unexpectedly early exit finishes the first child instead of
        // leaving an unstructured task and polling for a PID that will never appear.
        let first = try await group.next()
        let pid = try #require(first ?? nil)
        cancellation.cancel()
        do {
            _ = try await group.next()
            Issue.record("Cancellation must not succeed")
        } catch is CancellationError {}
        var status: Int32 = 0
        #expect(waitpid(pid, &status, WNOHANG) == -1 && errno == ECHILD)
    }
    #expect(cancellation.processID == nil)
    #expect(throws: CancellationError.self) {
        try cancellation.run { try ProcessRunner.run(["sh", "-c", "exit 0"]) }
    }
}

@Test(.timeLimit(.minutes(1))) func stalledProcessProgressFailsWithoutATotalRuntimeLimit() throws {
    let advancing = try ProcessRunner.run(["sh", "-c",
        "for i in 1 2 3 4 5 6; do printf 'frame=%s\\nout_time_us=%s\\n' \"$i\" \"$i\"; sleep 0.1; done"], progressTimeout: 0.4)
    #expect(String(decoding: advancing, as: UTF8.self).contains("frame=6"))
    do {
        try ProcessRunner.run(["sh", "-c", "printf 'frame=1\\nout_time_us=1\\n'; exec sleep 60"], progressTimeout: 0.1)
        Issue.record("A stalled progress counter must fail")
    } catch let failure as ProcessFailure {
        #expect(failure.stderr.contains("Encoding stalled"))
    }
}

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

/// iPhone videos with spatial audio (APAC, which ffmpeg can't decode) keep their stereo track in
/// the compact copy; a video whose only sound is APAC is kept as it is rather than made silent.
@Test func spatialAudioIsLeftOutAndAloneIsHeld() throws {
    let listing = """
    Codecs:
     D..... = Decoding supported
     -------
     DEV.L. hevc                 H.265 / HEVC (High Efficiency Video Coding)
     DEA.L. aac                  AAC (Advanced Audio Coding) (decoders: aac aac_fixed)
     ..A.L. apple_apac           Apple Positional Audio Codec
    """
    let decodable = FFmpegCodecs.parse(listing)
    #expect(decodable == ["hevc", "aac"])
    let both = """
    {"streams":[{"index":0,"codec_type":"video","codec_name":"hevc","width":1920,"height":1080},
                {"index":1,"codec_type":"audio","codec_name":"aac"},
                {"index":2,"codec_type":"audio","codec_name":"apple_apac"},
                {"index":3,"codec_type":"data","codec_name":"unknown"}]}
    """
    let probe = try VideoProbe.parse(Data(both.utf8), decodable: decodable)
    #expect(probe.audioStreams == [1] && probe.undecodableAudio == 1 && probe.holdReasons.isEmpty)
    let args = FFmpegVideoCompressor().arguments(input: URL(fileURLWithPath: "/in.mov"),
                                                 output: URL(fileURLWithPath: "/out.mov"), probe: probe)
    #expect(!args.contains("0:2"))
    let only = """
    {"streams":[{"index":0,"codec_type":"video","codec_name":"hevc","width":1920,"height":1080},
                {"index":1,"codec_type":"audio","codec_name":"apple_apac"}]}
    """
    #expect(try VideoProbe.parse(Data(only.utf8), decodable: decodable).holdReasons == ["spatial_audio"])
}
