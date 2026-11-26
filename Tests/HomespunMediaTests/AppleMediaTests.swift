// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import HomespunMedia

@Test func jpegIntegrityRequiresEndOfImage() {
    // SOI, APP0, SOS with entropy data containing a stuffed 0xFF00 and a restart marker, EOI.
    let complete: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x04, 0x4A, 0x46,
                             0xFF, 0xDA, 0x00, 0x04, 0x01, 0x02, 0x12, 0xFF, 0x00, 0x34, 0xFF, 0xD0, 0x56,
                             0xFF, 0xD9]
    #expect(JPEGIntegrity.isJPEG(Data(complete)))
    #expect(JPEGIntegrity.isComplete(Data(complete)))
    #expect(!JPEGIntegrity.isComplete(Data(complete.dropLast(2))))
    #expect(!JPEGIntegrity.isComplete(Data(complete.prefix(16))))
    #expect(!JPEGIntegrity.isComplete(Data([0x89, 0x50, 0x4E, 0x47])))
}

#if canImport(AVFoundation)
import AVFoundation
import CoreMedia
import Darwin
import HomespunCore
import HomespunTestSupport
import ImageIO
import UniformTypeIdentifiers
#if canImport(VideoToolbox)
import VideoToolbox
#endif

private func imageProperties(_ url: URL) -> [CFString: Any] {
    let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
    return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
}

private func dictionary(_ properties: [CFString: Any], _ key: CFString) -> [CFString: Any] {
    properties[key] as? [CFString: Any] ?? [:]
}

#if targetEnvironment(simulator)
private let isSimulator = true
#else
private let isSimulator = false
#endif

private func files(in directory: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
}

@Suite(.serialized) struct ImageIOPhotoTests {
    @Test func resizesUprightAndKeepsMetadata() throws {
        let directory = try Synthetic.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("IMG_0001.HEIC")
        try Synthetic.photo(at: input, .init(type: .heic, orientation: 6, contentIdentifier: "0D9C1F3A-6B2E-4C7D-9A51-2E8F4B6C1D70"))
        let output = directory.appendingPathComponent("IMG_0001.jpg")

        let result = try ImageIOPhotoCompressor().compress(input: input, output: output)

        #expect(result.mode == .compressed && result.url == output)
        #expect(result.width == 1536 && result.height == 2048)
        #expect(try result.sha256 == Fingerprint.sha256(of: output))
        #expect(try result.size < MediaFiles.size(of: input))
        let properties = imageProperties(output)
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 1536)
        #expect(properties[kCGImagePropertyOrientation] as? Int ?? 1 == 1)
        let exif = dictionary(properties, kCGImagePropertyExifDictionary)
        #expect(exif[kCGImagePropertyExifDateTimeOriginal] as? String == "2024:05:01 12:34:56")
        #expect(exif[kCGImagePropertyExifOffsetTimeOriginal] as? String == "-07:00")
        #expect(dictionary(properties, kCGImagePropertyGPSDictionary)[kCGImagePropertyGPSLatitude] as? Double == 37.33)
        #expect(dictionary(properties, kCGImagePropertyTIFFDictionary)[kCGImagePropertyTIFFModel] as? String
                == "iPhone 16 Pro")
        #expect((properties[kCGImagePropertyMakerAppleDictionary] as? [String: Any])?["17"] as? String == "0D9C1F3A-6B2E-4C7D-9A51-2E8F4B6C1D70")
        #expect(try files(in: directory) == ["IMG_0001.HEIC", "IMG_0001.jpg"])
    }

    @Test(.enabled(if: ImageIOPhotoCompressor.canEncodeHEIC))
    func writesHEIC() throws {
        let directory = try Synthetic.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("in.jpg")
        try Synthetic.photo(at: input, .init())
        let output = directory.appendingPathComponent("out.heic")
        let result = try ImageIOPhotoCompressor(format: .heic).compress(input: input, output: output)
        #expect(result.mode == .compressed && result.width == 2048 && result.height == 1536)
        let source = CGImageSourceCreateWithURL(output as CFURL, nil)!
        #expect(CGImageSourceGetType(source) as String? == UTType.heic.identifier)
    }

    @Test func flattensTransparencyOntoWhite() throws {
        let directory = try Synthetic.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("in.png")
        try Synthetic.photo(at: input, .init(type: .png, width: 3000, height: 2000, alpha: true))
        let output = directory.appendingPathComponent("out.jpg")
        let result = try ImageIOPhotoCompressor().compress(input: input, output: output)
        #expect(result.mode == .compressed && result.width == 2048)

        let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(output as CFURL, nil)!, 0, nil)!
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        #expect(pixel[0] > 245 && pixel[1] > 245 && pixel[2] > 245)
    }

    @Test func keepsOriginalWhenNotSmaller() throws {
        let directory = try Synthetic.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("flat.png")
        try Synthetic.photo(at: input, .init(type: .png, width: 800, height: 600, flat: true))
        let result = try ImageIOPhotoCompressor().compress(
            input: input, output: directory.appendingPathComponent("out.jpg"))
        #expect(result.mode == .originalKeptNotSmaller)
        #expect(result.url == directory.appendingPathComponent("out.png"))
        #expect(try Data(contentsOf: result.url) == Data(contentsOf: input))
        #expect(try files(in: directory) == ["flat.png", "out.png"])
    }

    @Test func flagsTruncatedAndEmptyInputs() throws {
        let directory = try Synthetic.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("in.jpg")
        try Synthetic.photo(at: input, .init(width: 1200, height: 900))
        let data = try Data(contentsOf: input)
        try data.prefix(data.count * 2 / 3).write(to: input)
        let output = directory.appendingPathComponent("out.jpg")
        #expect(throws: PhotoCompressionError.self) { try ImageIOPhotoCompressor().compress(input: input, output: output) }
        try Data().write(to: input)
        #expect(throws: PhotoCompressionError.emptyInput) {
            try ImageIOPhotoCompressor().compress(input: input, output: output)
        }
        #expect(try files(in: directory) == ["in.jpg"])
    }
}

@Suite(.serialized) struct AVFoundationVideoTests {
    @Test func compressesToProfileKeepingRotationAndAudio() async throws {
        let directory = try Synthetic.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("in.mov")
        let rotation = CGAffineTransform(rotationAngle: .pi / 2)
        try await Synthetic.video(at: input, .init(transform: rotation))
        let output = directory.appendingPathComponent("out.mov")

        let result = try await AVFoundationVideoCompressor().compress(input: input, output: output)

        #expect(result.mode == .transcoded)
        #expect(try result.sha256 == Fingerprint.sha256(of: output))
        let asset = AVURLAsset(url: output)
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let format = try #require(try await video.load(.formatDescriptions).first)
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        #expect(dimensions.width == 1280 && dimensions.height == 720)
        #expect(CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_HEVC)
        let sourceVideo = try #require(try await AVURLAsset(url: input).loadTracks(withMediaType: .video).first)
        #expect(try await video.load(.preferredTransform) == sourceVideo.load(.preferredTransform))
        #expect(try await abs(video.load(.preferredTransform).b - 1) < 0.001)
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
        #expect(try files(in: directory) == ["in.mov", "out.mov"])
    }

    @Test func encodesLowSampleRateAudio() async throws {
        let directory = try Synthetic.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("voice.mov")
        try await Synthetic.video(at: input, .init(frames: 30, audioChannels: 1, audioSampleRate: 8_000,
                                                   audioBitrate: 24_000))
        let output = directory.appendingPathComponent("out.mov")
        let result = try await AVFoundationVideoCompressor().compress(input: input, output: output)
        #expect(result.mode == .transcoded)
        #expect(try await AVURLAsset(url: output).loadTracks(withMediaType: .audio).count == 1)
    }

    @Test func hlgBecomesTenBitHLG() async throws {
        let directory = try Synthetic.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("hlg.mov")
        try await Synthetic.video(at: input, .init(transfer: AVVideoTransferFunction_ITU_R_2100_HLG))
        let output = directory.appendingPathComponent("out.mov")
        let result = try await AVFoundationVideoCompressor().compress(input: input, output: output)
        #expect(result.mode == .transcoded)
        let video = try #require(try await AVURLAsset(url: output).loadTracks(withMediaType: .video).first)
        let (format, traits) = try await AVSupport.traits(of: video)
        #expect(traits.isHLG)
        #expect((CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_BitsPerComponent)
                 as? NSNumber)?.intValue == 10)
    }

    @Test(arguments: [
        ("pq", AVVideoTransferFunction_SMPTE_ST_2084_PQ as String?, Int32(30), ["hdr"]),
        ("fps120", nil, Int32(120), ["high_frame_rate"]),
    ])
    func holdsUnvalidatedConversions(name: String, transfer: String?, fps: Int32, reasons: [String]) async throws {
        let directory = try Synthetic.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("\(name).mov")
        try await Synthetic.video(at: input, .init(fps: fps, frames: 30, transfer: transfer))
        let output = directory.appendingPathComponent("out.mov")
        let result = try await AVFoundationVideoCompressor().compress(input: input, output: output)
        #expect(result.mode == .originalKeptHeld && result.heldReasons == reasons)
        #expect(try Data(contentsOf: output) == Data(contentsOf: input))
    }

    @Test func refusesLivePhotoMotion() async throws {
        let directory = try Synthetic.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("live.mov")
        try await Synthetic.video(at: input, .init(frames: 15, liveIdentifier: "7A1B2C3D-4E5F-4061-8273-94A5B6C7D8E9"))
        await #expect(throws: VideoCompressionError.self) {
            try await AVFoundationVideoCompressor().compress(input: input, output: directory.appendingPathComponent("o.mov"))
        }
    }

    #if os(macOS)
    @Test(.enabled(if: ProcessRunner.available("ffmpeg")))
    func keepsMP4CreationDate() async throws {
        let directory = try Synthetic.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("whatsapp.mp4")
        try ProcessRunner.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=1920x1080:rate=30:duration=2",
                               "-f", "lavfi", "-i", "sine=frequency=440:duration=2", "-c:v", "libx264", "-b:v", "12M",
                               "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest",
                               "-metadata", "creation_time=2019-07-04T10:00:00Z", input.path])
        let output = directory.appendingPathComponent("whatsapp.mov")
        let result = try await AVFoundationVideoCompressor().compress(input: input, output: output)
        #expect(result.mode == .transcoded)
        let items = try await AVURLAsset(url: output).load(.metadata)
        let created = try #require(items.first { $0.identifier == .quickTimeMetadataCreationDate })
        #expect(try await created.load(.dateValue) == ISO8601DateFormatter().date(from: "2019-07-04T10:00:00Z"))
    }
    #endif
}

@Suite(.serialized) struct LivePhotoTests {
    static let motion = Synthetic.VideoSpec(width: 1440, height: 1080, frames: 60, bitrate: 12_000_000,
                                            audioChannels: 1, liveIdentifier: "5E4F1A2B-3C4D-4E5F-8A9B-0C1D2E3F4A5B",
                                            cleanAperture: (1360, 1020))

    private final class MotionBarrier: @unchecked Sendable {
        private let lock = NSLock()
        private let gate = DispatchSemaphore(value: 0)
        private var arrival: CheckedContinuation<Bool, Never>?
        private var blocked = false
        private var returned = false
        private var completed = false
        private var joined: (AVAssetReader.Status, AVAssetWriter.Status)?
        private var lateAppends = 0
        private var prematureCompletion = false

        var snapshot: (returned: Bool, completed: Bool, joined: (AVAssetReader.Status, AVAssetWriter.Status)?,
                       lateAppends: Int, prematureCompletion: Bool) {
            lock.withLock { (returned, completed, joined, lateAppends, prematureCompletion) }
        }

        func appended(_ mediaType: AVMediaType, pause: Bool) {
            lock.withLock { if joined != nil { lateAppends += 1 } }
            if pause, mediaType == .video { self.pause() }
        }

        func pause() {
            let first = lock.withLock {
                guard !blocked else { return false }
                blocked = true
                arrival?.resume(returning: true)
                arrival = nil
                return true
            }
            guard first else { return }
            gate.wait()
            lock.withLock { returned = true }
        }

        func waitUntilBlockedOrFinished() async -> Bool {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    if blocked { continuation.resume(returning: true) }
                    else if completed { continuation.resume(returning: false) }
                    else { arrival = continuation }
                }
            }
        }

        func didJoin(_ reader: AVAssetReader.Status, _ writer: AVAssetWriter.Status) {
            lock.withLock {
                if blocked && !returned { prematureCompletion = true }
                joined = (reader, writer)
            }
        }

        func didFinish() {
            lock.withLock {
                if blocked && !returned { prematureCompletion = true }
                completed = true
                arrival?.resume(returning: false)
                arrival = nil
            }
        }

        func release() { gate.signal() }
    }

    @Test func reencodesMotionKeepingPairingAndFraming() async throws {
        let directory = try Synthetic.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("IMG_0002.MOV")
        try await Synthetic.video(at: input, Self.motion)
        let output = directory.appendingPathComponent("out.mov")

        let result = try await LivePhotoMotionCompressor().compress(input: input, output: output)

        #expect(result.mode == .transcoded)
        #expect(try result.size < MediaFiles.size(of: input))
        #expect(try await LivePhotoMotionCompressor.contentIdentifier(of: output) == "5E4F1A2B-3C4D-4E5F-8A9B-0C1D2E3F4A5B")
        let source = AVURLAsset(url: input), asset = AVURLAsset(url: output)
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let sourceVideo = try #require(try await source.loadTracks(withMediaType: .video).first)
        #expect(try await video.load(.naturalSize) == sourceVideo.load(.naturalSize))
        let (_, traits) = try await AVSupport.traits(of: video)
        #expect(traits.encodedWidth == 1440 && traits.encodedHeight == 1080)
        let metadata = try #require(try await asset.loadTracks(withMediaType: .metadata).first)
        let described = try await metadata.loadAssociatedTracks(ofType: .metadataReferent)
        #expect(described.map(\.trackID) == [video.trackID])
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
    }

    @Test(.disabled(if: isSimulator, "Simulator encoders ignore the requested bitrate"))
    func keepsMotionThatDoesNotShrink() async throws {
        let directory = try Synthetic.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("small.mov")
        var spec = Self.motion
        spec.bitrate = 300_000
        try await Synthetic.video(at: input, spec)
        let output = directory.appendingPathComponent("out.mov")
        // Far above the source bitrate, so any encoder's output is larger.
        let result = try await LivePhotoMotionCompressor(bitrate: 50_000_000).compress(input: input, output: output)
        let inputSize = try MediaFiles.size(of: input)
        #expect(result.mode == .originalKeptNotSmaller, "source \(inputSize), output \(result.size)")
        #expect(try Data(contentsOf: output) == Data(contentsOf: input))
    }

    @Test func holdsHDRMotion() async throws {
        let directory = try Synthetic.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("hdr.mov")
        var spec = Self.motion
        spec.frames = 15
        spec.transfer = AVVideoTransferFunction_ITU_R_2100_HLG
        try await Synthetic.video(at: input, spec)
        let result = try await LivePhotoMotionCompressor().compress(
            input: input, output: directory.appendingPathComponent("out.mov"))
        #expect(result.mode == .originalKeptHeld && result.heldReasons == ["hdr"])
        let output = directory.appendingPathComponent("out.mov")
        #expect(try Data(contentsOf: output) == Data(contentsOf: input))
        #expect(try result.sha256 == Fingerprint.sha256(of: input))
        #expect(try result.size == MediaFiles.size(of: input))
        #expect(try await LivePhotoMotionCompressor.contentIdentifier(of: output) == spec.liveIdentifier)
        #expect(try files(in: directory) == ["hdr.mov", "out.mov"])
    }

    @Test func rejectsHeldMotionWithCorruptMediaButReadableHDRMetadata() async throws {
        let directory = try Synthetic.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("corrupt-hdr.mov")
        var spec = Self.motion
        spec.frames = 15
        spec.transfer = AVVideoTransferFunction_ITU_R_2100_HLG
        try await Synthetic.video(at: input, spec)
        var data = try Data(contentsOf: input)
        var offset = 0, corrupted = false
        while offset + 8 <= data.count {
            func integer(_ range: Range<Int>) -> UInt64 { data[range].reduce(0) { $0 << 8 | UInt64($1) } }
            var length = integer(offset..<(offset + 4))
            let type = String(decoding: data[(offset + 4)..<(offset + 8)], as: UTF8.self)
            var header = 8
            if length == 1 {
                try #require(offset + 16 <= data.count)
                length = integer((offset + 8)..<(offset + 16))
                header = 16
            } else if length == 0 { length = UInt64(data.count - offset) }
            try #require(length >= UInt64(header) && length <= UInt64(data.count - offset))
            let end = offset + Int(length)
            if type == "mdat" {
                // Keep moov/sample tables, the identifier and HLG descriptions intact.
                data.resetBytes(in: (offset + header)..<end)
                corrupted = true
            }
            offset = end
        }
        try #require(corrupted)
        try data.write(to: input)
        let asset = AVURLAsset(url: input)
        #expect(try await AVSupport.contentIdentifier(of: asset) == spec.liveIdentifier)
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let (_, traits) = try await AVSupport.traits(of: video)
        try #require(traits.isHLG, "The corrupt file must reach the held branch, not fail metadata loading")
        let output = directory.appendingPathComponent("out.mov")
        do {
            _ = try await LivePhotoMotionCompressor().compress(input: input, output: output)
            Issue.record("An undecodable held original must not be published")
        } catch let error as VideoCompressionError {
            guard case .verificationFailed = error else { throw error }
        }
        #expect(try files(in: directory) == ["corrupt-hdr.mov"])
    }

    enum CancellationPhase: CaseIterable, Sendable { case transfer, heldDecode, encodedDecode }

    @Test(arguments: CancellationPhase.allCases)
    func cancellationJoinsMotionBeforeRemovingItsPartial(_ phase: CancellationPhase) async throws {
        let directory = try Synthetic.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("in.mov"), output = directory.appendingPathComponent("out.mov")
        var spec = Self.motion
        spec.frames = 15
        if phase == .heldDecode { spec.transfer = AVVideoTransferFunction_ITU_R_2100_HLG }
        try await Synthetic.video(at: input, spec)
        let barrier = MotionBarrier()
        let observer = AVSupport.MotionObserver(didAppend: {
            barrier.appended($0, pause: phase == .transfer)
        }, didDecodeFrame: {
            if phase != .transfer { barrier.pause() }
        }, didJoin: { barrier.didJoin($0, $1) })
        let task = Task {
            defer { barrier.didFinish() }
            return try await LivePhotoMotionCompressor().compress(input: input, output: output, observer: observer)
        }
        defer { barrier.release() }
        guard await barrier.waitUntilBlockedOrFinished() else {
            _ = try await task.value
            Issue.record("Motion completed without reaching the controlled in-flight barrier")
            return
        }
        task.cancel()
        #expect(!barrier.snapshot.completed && !barrier.snapshot.returned,
                "Cancellation must join the callback, not return while it is suspended")
        #expect(!FileManager.default.fileExists(atPath: output.path))
        barrier.release()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(barrier.snapshot.returned && barrier.snapshot.completed && barrier.snapshot.lateAppends == 0)
        #expect(!barrier.snapshot.prematureCompletion)
        if phase == .transfer {
            let joined = try #require(barrier.snapshot.joined)
            #expect(joined.0 == .cancelled && joined.1 == .cancelled)
        }
        #expect(try files(in: directory) == ["in.mov"])
    }

    @Test func preCancelledMotionDoesNotStartOrPublish() async throws {
        let directory = try Synthetic.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await LivePhotoMotionCompressor().compress(
                input: directory.appendingPathComponent("not-opened.mov"),
                output: directory.appendingPathComponent("out.mov"))
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(try files(in: directory).isEmpty)
    }

    @Test func compressedPairIsStillALivePhoto() async throws {
        let directory = try Synthetic.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let still = directory.appendingPathComponent("IMG_0003.HEIC")
        let motion = directory.appendingPathComponent("IMG_0003.MOV")
        try Synthetic.photo(at: still, .init(type: .heic, contentIdentifier: "5E4F1A2B-3C4D-4E5F-8A9B-0C1D2E3F4A5B"))
        try await Synthetic.video(at: motion, Self.motion)
        #expect(await LivePhotoValidator.validate(photo: still, video: motion) == .valid)

        let compact = directory.appendingPathComponent("compact")
        try FileManager.default.createDirectory(at: compact, withIntermediateDirectories: true)
        let photo = try ImageIOPhotoCompressor().compress(
            input: still, output: compact.appendingPathComponent("IMG_0003.jpg"))
        let video = try await LivePhotoMotionCompressor().compress(
            input: motion, output: compact.appendingPathComponent("IMG_0003.mov"))
        #expect(photo.mode == .compressed && video.mode == .transcoded)
        #expect(await LivePhotoValidator.validate(photo: photo.url, video: compact.appendingPathComponent("IMG_0003.mov"))
                == .valid)

        let stranger = directory.appendingPathComponent("other.jpg")
        try Synthetic.photo(at: stranger, .init(width: 1200, height: 900, contentIdentifier: "FFFFFFFF-0000-4000-8000-000000000000"))
        #expect(await LivePhotoValidator.validate(photo: stranger, video: motion) != .valid)
    }

    #if canImport(VideoToolbox)
    private final class OwnedMotionProbe: @unchecked Sendable {
        struct Snapshot {
            var opened: [(BoundedMotionEncoder.Purpose, URL)] = []
            var writes: [(BoundedMotionEncoder.Purpose, Int)] = []
            var published: [(BoundedMotionEncoder.Purpose, URL)] = []
            var serialized: [Int] = []
            var fullRead: BoundedMotionEncoder.FullRead?
            var bound: (payload: Int, input: Int)?
            var joined = false
            var lateAppends = 0
            var inspectedVideoBytes: [Int] = []
            var copiedVideoSamples = 0
            var renamed: [URL] = []
            var directorySyncs: [BoundedMotionEncoder.DirectorySync] = []
            var closed = 0
            var residualErrors = 0
        }

        private let lock = NSLock()
        private var state = Snapshot()
        private var sawEarlyFrame = false
        var snapshot: Snapshot { lock.withLock { state } }

        var observer: BoundedMotionEncoder.Observer {
            .init(didAppend: { _ in self.lock.withLock { if self.state.joined { self.state.lateAppends += 1 } } },
                  didInspectVideoOutput: { size in self.lock.withLock { self.state.inspectedVideoBytes.append(size) } },
                  didCopyVideoBytes: { self.lock.withLock { self.state.copiedVideoSamples += 1 } },
                  didReachPayloadBound: { p, i in self.lock.withLock { self.state.bound = (p, i) } },
                  didFullRead: { value in self.lock.withLock { self.state.fullRead = value } },
                  didJoin: { self.lock.withLock { self.state.joined = true } },
                  didSerialize: { n in self.lock.withLock { self.state.serialized.append(n) } },
                  didOpen: { purpose, path in self.lock.withLock { self.state.opened.append((purpose, path)) } },
                  didWrite: { purpose, count in self.lock.withLock { self.state.writes.append((purpose, count)) } },
                  didRename: { _, path in self.lock.withLock { self.state.renamed.append(path) } },
                  didDirectorySync: { phase in self.lock.withLock { self.state.directorySyncs.append(phase) } },
                  didCloseSink: { self.lock.withLock { self.state.closed += 1 } },
                  didResidualResourceError: { self.lock.withLock { self.state.residualErrors += 1 } },
                  didPublish: { purpose, path in self.lock.withLock { self.state.published.append((purpose, path)) } })
        }

        func failInDecodedTail(_ early: Bool) throws {
            let fail = lock.withLock {
                guard early else { return false }
                if sawEarlyFrame { return true }
                sawEarlyFrame = true
                return false
            }
            if fail { throw QuickTimeMuxer.Failure.corruptInput("injected failure on decoded frame AFTER payload decision") }
        }
    }

    private static func ownedSpec(frames: Int = 60, audio: UInt32 = 1) -> Synthetic.VideoSpec {
        var spec = Self.motion
        spec.frames = frames
        spec.audioChannels = audio
        spec.taggedSDR = true
        spec.creationDate = "2024-05-01T12:34:56-07:00"
        spec.locationISO6709 = "+37.3300-122.0100/"
        return spec
    }

    private static func materialized(_ input: URL) throws -> QuickTimeMuxer.Movie {
        let source = try QuickTimeMuxer.source(input, limits: .init())
        var movie = source.movie
        let handle = try FileHandle(forReadingFrom: input)
        defer { try? handle.close() }
        for (index, track) in source.tracks.enumerated() {
            for sample in track.sampleSizes.indices {
                try handle.seek(toOffset: UInt64(track.sampleOffsets[sample]))
                let bytes = try #require(try handle.read(upToCount: Int(track.sampleSizes[sample])))
                movie.tracks[index].samples.append(.init(
                    bytes: bytes, duration: track.durations[sample],
                    compositionOffset: track.compositionOffsets[sample], sync: sample == 0 || track.model.kind != "vide"))
            }
        }
        return movie
    }

    private static func writeMovie(_ movie: QuickTimeMuxer.Movie, to url: URL) throws {
        let serialized = try QuickTimeMuxer.serialize(movie, limits: .init())
        try Data().write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        for chunk in serialized.chunks { try handle.write(contentsOf: chunk) }
    }

    private static func monoAudioWindow(_ input: URL, frames: Int = 1024) async throws -> [Float] {
        let asset = AVURLAsset(url: input)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false, AVNumberOfChannelsKey: 1,
        ])
        try #require(reader.canAdd(output))
        reader.add(output)
        defer { reader.cancelReading() }
        try #require(reader.startReading())
        var result: [Float] = []
        while result.count < frames, let sample = output.copyNextSampleBuffer() {
            let count = min(frames - result.count, CMSampleBufferGetNumSamples(sample))
            let block = try #require(CMSampleBufferGetDataBuffer(sample))
            var values = [Float](repeating: 0, count: count)
            let status = values.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
            }
            try #require(status == noErr)
            result.append(contentsOf: values)
        }
        try #require(result.count == frames)
        return result
    }

    private static func callbackSample(bytes: Int, format: CMFormatDescription, samples: Int = 1) throws -> CMSampleBuffer {
        var block: CMBlockBuffer?
        try #require(CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: bytes, flags: 0, blockBufferOut: &block) == noErr)
        let data = try #require(block)
        try #require(CMBlockBufferFillDataBytes(with: 0, blockBuffer: data, offsetIntoDestination: 0,
                                               dataLength: bytes) == noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                        presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var packetSize = bytes / samples
        var sample: CMSampleBuffer?
        try #require(CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: data, formatDescription: format,
            sampleCount: samples, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &packetSize, sampleBufferOut: &sample) == noErr)
        return try #require(sample)
    }

    @Test func ownedVideoCallbackOverActualIStoresOnlyAByteCount() async throws {
        let directory = try Synthetic.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("in.mov")
        try await Synthetic.video(at: input, Self.ownedSpec(frames: 15, audio: 0))
        let size = try MediaFiles.size(of: input)
        let track = try #require(try await AVURLAsset(url: input).loadTracks(withMediaType: .video).first)
        let format = try #require(try await track.load(.formatDescriptions).first)
        // Deterministic callback-sample injection, not an encoder quality experiment.
        // The backing block really exceeds this source's I; capacity is NOT substituted for I.
        let sample = try Self.callbackSample(bytes: size + 1, format: format)
        let callback = BoundedMotionEncoder.VideoCallback()
        callback.reset(remainingPayloadBytes: size, sampleCapacity: 1)
        callback.receive(noErr, [], sample)
        guard case .payloadBound(let actual) = try callback.take() else {
            Issue.record("Over-I output must yield a primitive proof, not a retained CMSampleBuffer")
            return
        }
        #expect(actual == CMSampleBufferGetTotalSampleSize(sample) && actual > size)
        callback.reset(remainingPayloadBytes: size, sampleCapacity: 0)
        callback.receive(noErr, [], try Self.callbackSample(bytes: 1, format: format))
        #expect(throws: QuickTimeMuxer.Failure.limitExceeded("VT retained output buffer")) { try callback.take() }
        #expect(try files(in: directory) == ["in.mov"])
    }

    @Test func ownedVideoSyncDefaultsAndMalformedAttachmentTypes() async throws {
        let directory = try Synthetic.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("in.mov")
        try await Synthetic.video(at: input, Self.ownedSpec(frames: 15, audio: 0))
        let track = try #require(try await AVURLAsset(url: input).loadTracks(withMediaType: .video).first)
        let format = try #require(try await track.load(.formatDescriptions).first)
        let sample = try Self.callbackSample(bytes: 4, format: format)
        #expect(try BoundedMotionEncoder.videoSampleIsSync(sample), "An absent NotSync key legitimately defaults to false")
        let attachments = try #require(CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true))
        let dictionary = try #require((attachments as NSArray).object(at: 0) as? NSMutableDictionary)
        dictionary[kCMSampleAttachmentKey_NotSync as String] = true
        #expect(try !BoundedMotionEncoder.videoSampleIsSync(sample))
        dictionary[kCMSampleAttachmentKey_NotSync as String] = false
        #expect(try BoundedMotionEncoder.videoSampleIsSync(sample))
        dictionary[kCMSampleAttachmentKey_NotSync as String] = "malformed"
        #expect(throws: QuickTimeMuxer.Failure.corruptInput("video NotSync attachment type")) {
            try BoundedMotionEncoder.videoSampleIsSync(sample)
        }
        let grouped = try Self.callbackSample(bytes: 4, format: format, samples: 2)
        #expect(throws: QuickTimeMuxer.Failure.corruptInput("video sample attachment shape")) {
            try BoundedMotionEncoder.videoSampleIsSync(grouped)
        }
    }

    @Test func ownedMuxerPreservesValidatedGenericHeaderApertureAndSelfAlias() async throws {
        let directory = try Synthetic.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("in.mov"), output = directory.appendingPathComponent("variant.mov")
        try await Synthetic.video(at: input, Self.ownedSpec(frames: 15, audio: 0))
        var movie = try Self.materialized(input)
        let metadata = try #require(movie.tracks.firstIndex(where: { $0.kind == "meta" }))
        let gmin = try QuickTimeMuxer.fullAtom("gmin", Data([0, 64, 128, 0, 128, 0, 128, 0, 0, 0, 0, 0]))
        let gmhd = try QuickTimeMuxer.atom("gmhd", gmin)
        let oldSize = Int(try QuickTimeMuxer.read32(movie.tracks[metadata].mediaInfoHeader, 0))
        movie.tracks[metadata].mediaInfoHeader = gmhd + movie.tracks[metadata].mediaInfoHeader.dropFirst(oldSize)
        let alias = try QuickTimeMuxer.atom("dinf", QuickTimeMuxer.fullAtom(
            "dref", QuickTimeMuxer.integer(1) + QuickTimeMuxer.fullAtom("alis", Data(), flags: 1)))
        for index in movie.tracks.indices { movie.tracks[index].dataInfo = alias }
        let video = try #require(movie.tracks.firstIndex(where: { $0.kind == "vide" }))
        var dimensions = Data()
        for (name, width, height) in [("clef", 1360, 1020), ("prof", 1360, 1020), ("enof", 1440, 1080)] {
            dimensions.append(try QuickTimeMuxer.fullAtom(name, QuickTimeMuxer.integer(UInt32(width) << 16) +
                                                         QuickTimeMuxer.integer(UInt32(height) << 16)))
        }
        let aperture = try QuickTimeMuxer.atom("tapt", dimensions)
        movie.tracks[video].aperture = aperture
        try Self.writeMovie(movie, to: output)
        let parsed = try QuickTimeMuxer.source(output, limits: .init())
        #expect(parsed.tracks[metadata].model.mediaInfoHeader == movie.tracks[metadata].mediaInfoHeader)
        #expect(parsed.tracks[video].model.aperture == aperture)
        #expect(parsed.tracks.allSatisfy { $0.model.dataInfo == alias })
        #expect(try await AVSupport.decodeVideo(output, cancellable: true) == 15)
        movie.tracks[metadata].mediaInfoHeader = gmhd + (try QuickTimeMuxer.fullAtom("nmhd", Data()))
        try Self.writeMovie(movie, to: output)
        #expect(throws: QuickTimeMuxer.Failure.self) { try QuickTimeMuxer.source(output, limits: .init()) }
        movie.tracks[metadata].mediaInfoHeader = gmhd
        movie.tracks[video].dataInfo = try QuickTimeMuxer.atom("dinf", QuickTimeMuxer.fullAtom(
            "dref", QuickTimeMuxer.integer(1) + QuickTimeMuxer.fullAtom("alis", Data([1]), flags: 1)))
        try Self.writeMovie(movie, to: output)
        #expect(throws: QuickTimeMuxer.Failure.self) { try QuickTimeMuxer.source(output, limits: .init()) }
    }

    @Test(arguments: [44_100, 48_000])
    func ownedAACPreservesNonperiodicChirpAndOnset(sampleRate: Int) async throws {
        let directory = try Synthetic.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("in.mov"), output = directory.appendingPathComponent("out.mov")
        var spec = Self.ownedSpec(frames: 60, audio: 1)
        spec.audioSampleRate = sampleRate
        spec.audioWaveform = .onsetChirp
        try await Synthetic.video(at: input, spec)
        let result = try await BoundedMotionEncoder().compress(input: input, output: output)
        if !isSimulator { #expect(result.mode == .transcoded) }
        let a = try await Self.monoAudioWindow(input, frames: sampleRate * 3 / 5)
        let b = try await Self.monoAudioWindow(output, frames: sampleRate * 3 / 5)
        let energyA = a.reduce(0.0) { $0 + Double($1) * Double($1) }
        let energyB = b.reduce(0.0) { $0 + Double($1) * Double($1) }
        let dot = zip(a, b).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
        try #require(energyA > 0 && energyB > 0)
        #expect(dot / sqrt(energyA * energyB) > 0.85)
        let threshold = (a.map { abs($0) }.max() ?? 0) * 0.1
        let onsetA = try #require(a.firstIndex { abs($0) > threshold })
        let onsetB = try #require(b.firstIndex { abs($0) > threshold })
        #expect(Double(abs(onsetA - onsetB)) / Double(sampleRate) <= 0.003)
    }

    @Test(.disabled(if: isSimulator, "Over-I encoder size witness requires bitrate-respecting encoders"))
    func ownedRealOverISingleVTOutputIsNeverCopied() async throws {
        let directory = try Synthetic.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("in.mov"), output = directory.appendingPathComponent("out.mov")
        var spec = Self.ownedSpec(frames: 1, audio: 0)
        spec.width = 512
        spec.height = 512
        spec.cleanAperture = nil
        spec.bitrate = 100_000
        try await Synthetic.video(at: input, spec)
        let size = try MediaFiles.size(of: input), identity = try Fingerprint.sha256(of: input)
        let probe = OwnedMotionProbe()
        let result = try await BoundedMotionEncoder(bitrate: 50_000_000).compress(
            input: input, output: output, observer: probe.observer)
        let state = probe.snapshot
        let inspected = try #require(state.inspectedVideoBytes.first)
        #expect(inspected > size, "Must witness one real VT output larger than actual I")
        #expect(state.copiedVideoSamples == 0 && state.serialized.isEmpty)
        #expect(state.fullRead?.videoFrames == 1 && (state.fullRead?.metadataSamples ?? 0) > 0)
        #expect(state.opened.count == 1 && state.opened.first?.0 == .originalCopy)
        #expect(result.mode == .originalKeptNotSmaller && result.size == size)
        #expect(try Fingerprint.sha256(of: input) == identity && Fingerprint.sha256(of: output) == identity)
        #expect(state.closed == 1 && state.residualErrors == 0)
        #expect(try files(in: directory) == ["in.mov", "out.mov"])
    }

    @Test func ownedPostRenameDirectorySyncFailureCleansOnlyKnownInode() async throws {
        let directory = try Synthetic.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("in.mov"), output = directory.appendingPathComponent("out.mov")
        let unknown = directory.appendingPathComponent(".owned-motion-unknown.mov")
        let marker = Data("unknown file".utf8)
        try marker.write(to: unknown)
        try await Synthetic.video(at: input, Self.ownedSpec(frames: 15, audio: 0))
        let probe = OwnedMotionProbe()
        var observer = probe.observer
        observer.beforeDirectorySync = { phase in
            if phase == .publication { throw QuickTimeMuxer.Failure.io(EIO) }
        }
        await #expect(throws: QuickTimeMuxer.Failure.io(EIO)) {
            _ = try await BoundedMotionEncoder().compress(input: input, output: output, observer: observer)
        }
        #expect(probe.snapshot.renamed == [output] && probe.snapshot.published.isEmpty)
        #expect(probe.snapshot.directorySyncs == [.cleanup])
        #expect(probe.snapshot.closed == 1 && probe.snapshot.residualErrors == 0)
        #expect(try Data(contentsOf: unknown) == marker)
        #expect(try files(in: directory) == [".owned-motion-unknown.mov", "in.mov"])
    }

    @Test func ownedPostRenameFailurePreservesUnknownReplacement() async throws {
        let directory = try Synthetic.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("in.mov"), output = directory.appendingPathComponent("out.mov")
        let moved = directory.appendingPathComponent("caller-moved.mov"), marker = Data("unknown replacement".utf8)
        try await Synthetic.video(at: input, Self.ownedSpec(frames: 15, audio: 0))
        let probe = OwnedMotionProbe()
        var observer = probe.observer
        let record = observer.didRename
        observer.didRename = { purpose, path in
            try record(purpose, path)
            try FileManager.default.moveItem(at: path, to: moved)
            try marker.write(to: path)
        }
        observer.beforeDirectorySync = { phase in
            if phase == .publication { throw QuickTimeMuxer.Failure.io(EIO) }
        }
        do {
            _ = try await BoundedMotionEncoder().compress(input: input, output: output, observer: observer)
            Issue.record("Unknown replacement cannot become a published success or be removed")
        } catch let error as QuickTimeMuxer.Failure {
            guard case .cleanupFailed = error else { throw error }
        }
        #expect(probe.snapshot.published.isEmpty && probe.snapshot.residualErrors > 0)
        #expect(try Data(contentsOf: output) == marker)
        #expect(try files(in: directory) == ["caller-moved.mov", "in.mov", "out.mov"])
    }

    @Test func ownedMuxerRoundTripsSampleExtentsAndRejectsIncompleteModel() async throws {
        let directory = try Synthetic.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("in.mov"), output = directory.appendingPathComponent("out.mov")
        try await Synthetic.video(at: input, Self.ownedSpec(frames: 15, audio: 0))
        let movie = try Self.materialized(input)
        let serialized = try QuickTimeMuxer.serialize(movie, limits: .init())
        try Self.writeMovie(movie, to: output)
        let parsed = try QuickTimeMuxer.source(output, limits: .init())
        #expect(try serialized.totalBytes == MediaFiles.size(of: output))
        #expect(parsed.movie.metadata == movie.metadata)
        let bytes = try FileHandle(forReadingFrom: output)
        defer { try? bytes.close() }
        for (index, track) in parsed.tracks.enumerated() {
            #expect(track.model.references == movie.tracks[index].references)
            #expect(track.model.header == movie.tracks[index].header)
            for sample in track.sampleSizes.indices {
                try bytes.seek(toOffset: UInt64(track.sampleOffsets[sample]))
                #expect(try bytes.read(upToCount: Int(track.sampleSizes[sample])) == movie.tracks[index].samples[sample].bytes)
                #expect(track.durations[sample] == movie.tracks[index].samples[sample].duration)
                #expect(track.compositionOffsets[sample] == movie.tracks[index].samples[sample].compositionOffset)
            }
        }
        #expect(try await AVSupport.decodeVideo(output, cancellable: true) == 15)
        var incomplete = movie
        incomplete.tracks[0].samples.removeAll()
        #expect(throws: QuickTimeMuxer.Failure.self) { try QuickTimeMuxer.serialize(incomplete, limits: .init()) }
    }

    @Test func ownedMuxedPairKeepsMetadataAssociationsAndFraming() async throws {
        let directory = try Synthetic.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("in.mov"), output = directory.appendingPathComponent("out.mov")
        let still = directory.appendingPathComponent("still.heic"), stranger = directory.appendingPathComponent("stranger.jpg")
        var spec = Self.ownedSpec()
        spec.transform = CGAffineTransform(rotationAngle: .pi / 2)
        spec.cleanApertureOffset = (4, 6)
        try await Synthetic.video(at: input, spec)
        try Synthetic.photo(at: still, .init(type: .heic, width: 1440, height: 1080,
                                            contentIdentifier: spec.liveIdentifier))
        try Synthetic.photo(at: stranger, .init(width: 1440, height: 1080,
                                               contentIdentifier: "FFFFFFFF-0000-4000-8000-000000000000"))
        #expect(await LivePhotoValidator.validate(photo: still, video: input) == .valid)
        let identity = try Fingerprint.sha256(of: input)
        let probe = OwnedMotionProbe()
        let result = try await BoundedMotionEncoder().compress(input: input, output: output, observer: probe.observer)
        if !isSimulator { #expect(result.mode == .transcoded) }
        #expect(await LivePhotoValidator.validate(photo: still, video: output) == .valid)
        #expect(await LivePhotoValidator.validate(photo: stranger, video: output) != .valid)
        #expect(try Fingerprint.sha256(of: input) == identity)
        let before = AVURLAsset(url: input), after = AVURLAsset(url: output)
        let a = try #require(try await before.loadTracks(withMediaType: .video).first)
        let b = try #require(try await after.loadTracks(withMediaType: .video).first)
        #expect(try await a.load(.naturalSize) == b.load(.naturalSize))
        #expect(try await a.load(.preferredTransform) == b.load(.preferredTransform))
        let first = try #require(try await a.load(.formatDescriptions).first)
        let last = try #require(try await b.load(.formatDescriptions).first)
        let d1 = CMVideoFormatDescriptionGetDimensions(first), d2 = CMVideoFormatDescriptionGetDimensions(last)
        #expect(d1.width == d2.width && d1.height == d2.height)
        for key in [kCMFormatDescriptionExtension_CleanAperture, kCMFormatDescriptionExtension_ColorPrimaries,
                    kCMFormatDescriptionExtension_TransferFunction, kCMFormatDescriptionExtension_YCbCrMatrix] {
            let x = try #require(CMFormatDescriptionGetExtension(first, extensionKey: key))
            let y = try #require(CMFormatDescriptionGetExtension(last, extensionKey: key))
            #expect(CFEqual(x, y))
        }
        let metadata = try #require(try await after.loadTracks(withMediaType: .metadata).first)
        #expect(try await metadata.loadAssociatedTracks(ofType: .metadataReferent).map(\.trackID) == [b.trackID])
        let old = try QuickTimeMuxer.source(input, limits: .init()), new = try QuickTimeMuxer.source(output, limits: .init())
        #expect(old.movie.metadata == new.movie.metadata)
        let items = try await after.load(.metadata)
        let date = try #require(items.first { AVSupport.isQuickTimeKey($0, AVSupport.creationDateKey) })
        let location = try #require(items.first { AVSupport.isQuickTimeKey($0, "com.apple.quicktime.location.ISO6709") })
        #expect(try await date.load(.stringValue) == spec.creationDate)
        #expect(try await location.load(.stringValue) == spec.locationISO6709)
        #expect(try await AVSupport.decodeVideo(output, cancellable: true) == spec.frames)
        #expect(try await abs(AVSupport.duration(of: a) - AVSupport.duration(of: b)) <= 0.1)
        #expect(try await abs(before.load(.duration).seconds - after.load(.duration).seconds) <= 0.1)
        let read = try #require(probe.snapshot.fullRead)
        #expect(read.videoFrames == spec.frames && read.audioFrames > 0 && read.metadataSamples > 0)
    }

    @Test(arguments: [(15, UInt32(0), 44_100), (60, UInt32(1), 44_100),
                      (90, UInt32(2), 48_000), (30, UInt32(1), 8_000)])
    func ownedMotionExactBytesAndSingleSink(frames: Int, audio: UInt32, sampleRate: Int) async throws {
        let directory = try Synthetic.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("in.mov"), output = directory.appendingPathComponent("out.mov")
        let unknown = directory.appendingPathComponent(".partial-out.mov")
        let marker = Data("unknown invocation: preserve".utf8)
        try marker.write(to: unknown)
        var spec = Self.ownedSpec(frames: frames, audio: audio)
        spec.audioSampleRate = sampleRate
        if sampleRate == 8_000 { spec.audioBitrate = 24_000 }
        if audio == 2 { spec.pixelAspect = (4, 3) }
        try await Synthetic.video(at: input, spec)
        let identity = try Fingerprint.sha256(of: input), inputSize = try MediaFiles.size(of: input)
        let probe = OwnedMotionProbe()
        let result = try await BoundedMotionEncoder().compress(input: input, output: output, observer: probe.observer)
        let state = probe.snapshot
        #expect(state.opened.count == 1 && state.published.count == 1)
        #expect(state.writes.last?.1 == result.size)
        #expect(try result.size == MediaFiles.size(of: output))
        #expect(try result.sha256 == Fingerprint.sha256(of: output))
        #expect(try Fingerprint.sha256(of: input) == identity)
        #expect(state.joined && state.lateAppends == 0)
        if result.mode == .transcoded {
            #expect(state.serialized == [result.size])
            #expect(result.size > 0 && result.size < inputSize)
            #expect(state.opened.first?.0 == .encoded)
        } else {
            #expect(result.mode == .originalKeptNotSmaller)
            #expect(state.opened.first?.0 == .originalCopy && result.size == inputSize)
            #expect(try Fingerprint.sha256(of: output) == identity)
        }
        if !isSimulator { #expect(result.mode == .transcoded) }
        #expect(try Data(contentsOf: unknown) == marker)
        #expect(try files(in: directory) == [".partial-out.mov", "in.mov", "out.mov"])
        let read = try #require(state.fullRead)
        #expect(read.videoFrames == frames)
        #expect(audio == 0 ? read.audioFrames == 0 : read.audioFrames > 0)
        if audio == 2 {
            let a = try #require(try await AVURLAsset(url: input).loadTracks(withMediaType: .video).first)
            let b = try #require(try await AVURLAsset(url: output).loadTracks(withMediaType: .video).first)
            let x = try #require(try await a.load(.formatDescriptions).first)
            let y = try #require(try await b.load(.formatDescriptions).first)
            #expect(CFEqual(try #require(CMFormatDescriptionGetExtension(x, extensionKey: kCMFormatDescriptionExtension_PixelAspectRatio)),
                            try #require(CMFormatDescriptionGetExtension(y, extensionKey: kCMFormatDescriptionExtension_PixelAspectRatio))))
        }
        if sampleRate == 8_000 {
            // AAC priming must preserve sound alignment, not just container duration.
            let a = try await Self.monoAudioWindow(input), b = try await Self.monoAudioWindow(output)
            let energyA = a.reduce(0.0) { $0 + Double($1) * Double($1) }
            let energyB = b.reduce(0.0) { $0 + Double($1) * Double($1) }
            let dot = zip(a, b).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
            #expect(energyA > 0 && energyB > 0)
            #expect(dot / sqrt(energyA * energyB) > 0.85)
        }
    }

    @Test(.disabled(if: isSimulator, "A real not-smaller witness requires bitrate-respecting encoders"))
    func ownedMotionActualPayloadBoundDrainsBeforeFallback() async throws {
        let directory = try Synthetic.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("in.mov"), output = directory.appendingPathComponent("out.mov")
        var spec = Self.ownedSpec(frames: 90)
        spec.bitrate = 300_000
        try await Synthetic.video(at: input, spec)
        let identity = try Fingerprint.sha256(of: input), size = try MediaFiles.size(of: input)
        let probe = OwnedMotionProbe()
        let result = try await BoundedMotionEncoder(bitrate: 50_000_000).compress(
            input: input, output: output, observer: probe.observer)
        let state = probe.snapshot
        let bound = try #require(state.bound, "Must witness an actual-I payload decision, not just final container overhead")
        #expect(bound.input == size && bound.payload >= size)
        #expect(result.mode == .originalKeptNotSmaller && result.size == size)
        #expect(state.opened.count == 1 && state.opened.first?.0 == .originalCopy)
        #expect(!state.writes.contains(where: { $0.0 == .encoded }) && state.serialized.isEmpty)
        #expect(state.writes.last?.1 == size)
        let read = try #require(state.fullRead)
        #expect(read.videoFrames == spec.frames && read.audioFrames == 132_300 && read.metadataSamples > 0)
        let video = try #require(try QuickTimeMuxer.source(input, limits: .init()).tracks.first(where: { $0.model.kind == "vide" }))
        #expect(read.compressedSamples[video.model.id] == spec.frames)
        #expect(try Fingerprint.sha256(of: input) == identity)
        #expect(try Fingerprint.sha256(of: output) == identity)
        #expect(try files(in: directory) == ["in.mov", "out.mov"])
    }

    @Test(.disabled(if: isSimulator, "The tail fault must follow a genuine actual-I payload decision"))
    func ownedMotionInjectedDecodedTailFailureCannotKeepAfterEarlyDecision() async throws {
        let directory = try Synthetic.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("in.mov"), output = directory.appendingPathComponent("out.mov")
        var spec = Self.ownedSpec(frames: 90)
        spec.bitrate = 300_000
        try await Synthetic.video(at: input, spec)
        let probe = OwnedMotionProbe()
        var observer = probe.observer
        observer.afterVideoFrame = { _, early in try probe.failInDecodedTail(early) }
        await #expect(throws: QuickTimeMuxer.Failure.corruptInput("injected failure on decoded frame AFTER payload decision")) {
            _ = try await BoundedMotionEncoder(bitrate: 50_000_000).compress(input: input, output: output, observer: observer)
        }
        #expect(probe.snapshot.bound != nil)
        #expect(probe.snapshot.fullRead == nil && probe.snapshot.joined)
        #expect(probe.snapshot.opened.isEmpty)
        #expect(try files(in: directory) == ["in.mov"])
    }

    @Test(.disabled(if: isSimulator, "Final not-smaller size is an encoder-dependent macOS witness"))
    func ownedMotionFinalActualContainerSizeCanRequireFallback() async throws {
        let directory = try Synthetic.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("in.mov"), output = directory.appendingPathComponent("out.mov")
        var spec = Self.ownedSpec(frames: 1, audio: 0)
        spec.width = 64
        spec.height = 64
        spec.cleanAperture = nil
        spec.bitrate = 300_000
        try await Synthetic.video(at: input, spec)
        let size = try MediaFiles.size(of: input), identity = try Fingerprint.sha256(of: input)
        let probe = OwnedMotionProbe()
        let result = try await BoundedMotionEncoder(bitrate: 50_000_000).compress(
            input: input, output: output, observer: probe.observer)
        let state = probe.snapshot
        #expect(state.bound == nil, "This witness must exercise final exact S, not the early payload rule")
        let exact = try #require(state.serialized.first)
        #expect(exact >= size)
        #expect(result.mode == .originalKeptNotSmaller && result.size == size)
        #expect(state.opened.count == 1 && state.opened.first?.0 == .originalCopy)
        #expect(state.fullRead?.videoFrames == 1 && state.joined)
        #expect(!state.writes.contains(where: { $0.0 == .encoded }))
        #expect(try Fingerprint.sha256(of: output) == identity)
        #expect(try files(in: directory) == ["in.mov", "out.mov"])
    }

    @Test func ownedMotionRealCorruptAndTruncatedTailsCannotPublish() async throws {
        let directory = try Synthetic.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("in.mov"), output = directory.appendingPathComponent("out.mov")
        var spec = Self.ownedSpec(frames: 60, audio: 0)
        spec.bitrate = 300_000
        try await Synthetic.video(at: input, spec)
        let source = try QuickTimeMuxer.source(input, limits: .init())
        let video = try #require(source.tracks.first(where: { $0.model.kind == "vide" }))
        let handle = try FileHandle(forWritingTo: input)
        for sample in (video.sampleSizes.count * 3 / 4)..<video.sampleSizes.count {
            try handle.seek(toOffset: UInt64(video.sampleOffsets[sample]))
            try handle.write(contentsOf: Data(count: Int(video.sampleSizes[sample])))
        }
        try handle.close()
        let probe = OwnedMotionProbe()
        await #expect(throws: (any Error).self) {
            _ = try await BoundedMotionEncoder(bitrate: 50_000_000).compress(input: input, output: output, observer: probe.observer)
        }
        #expect(probe.snapshot.opened.isEmpty && probe.snapshot.fullRead == nil)
        // This real corruption case need not reach the early decision: the separate
        // injected test proves that exact ordering deterministically.
        let short = try FileHandle(forWritingTo: input)
        try short.truncate(atOffset: UInt64(source.size * 3 / 5))
        try short.close()
        await #expect(throws: QuickTimeMuxer.Failure.self) {
            _ = try await BoundedMotionEncoder().compress(input: input, output: output)
        }
        #expect(try files(in: directory) == ["in.mov"])
    }

    @Test func ownedMotionMalformedTimedMetadataCannotBecomeKept() async throws {
        let directory = try Synthetic.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("in.mov"), output = directory.appendingPathComponent("out.mov")
        var spec = Self.ownedSpec(frames: 30, audio: 0)
        spec.bitrate = 300_000
        try await Synthetic.video(at: input, spec)
        let source = try QuickTimeMuxer.source(input, limits: .init())
        let metadata = try #require(source.tracks.first(where: { $0.model.kind == "meta" }))
        let handle = try FileHandle(forWritingTo: input)
        for index in metadata.sampleSizes.indices {
            try handle.seek(toOffset: UInt64(metadata.sampleOffsets[index]))
            try handle.write(contentsOf: Data(repeating: 0xff, count: Int(metadata.sampleSizes[index])))
        }
        try handle.close()
        let probe = OwnedMotionProbe()
        await #expect(throws: (any Error).self) {
            _ = try await BoundedMotionEncoder(bitrate: 50_000_000).compress(input: input, output: output, observer: probe.observer)
        }
        #expect(probe.snapshot.opened.isEmpty && probe.snapshot.fullRead == nil)
        #expect(try files(in: directory) == ["in.mov"])
    }

    enum OwnedLimit: CaseIterable, Sendable { case input, memory, samples, sampleBytes, dimensions }

    @Test(arguments: OwnedLimit.allCases)
    func ownedMotionInjectedCapsAreErrorsNeverNotSmaller(_ cap: OwnedLimit) async throws {
        let directory = try Synthetic.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("in.mov"), output = directory.appendingPathComponent("out.mov")
        try await Synthetic.video(at: input, Self.ownedSpec(frames: 15, audio: 0))
        var encoder = BoundedMotionEncoder()
        switch cap {
        case .input: encoder.limits.inputBytes = try MediaFiles.size(of: input) - 1
        case .memory: encoder.limits.retainedBytes = 1
        case .samples: encoder.limits.samplesPerTrack = 14
        case .sampleBytes: encoder.limits.sampleBytes = 1
        case .dimensions: encoder.limits.dimension = 100
        }
        let probe = OwnedMotionProbe()
        do {
            _ = try await encoder.compress(input: input, output: output, observer: probe.observer)
            Issue.record("Injected capacity is not an actual-I proof and must not return any success")
        } catch let error as QuickTimeMuxer.Failure {
            guard case .limitExceeded = error else { throw error }
        }
        #expect(probe.snapshot.opened.isEmpty && probe.snapshot.fullRead == nil)
        #expect(try files(in: directory) == ["in.mov"])
    }

    enum UnsupportedOwnedStructure: CaseIterable, Sendable { case secondVideo, repeatedEdit }

    @Test(arguments: UnsupportedOwnedStructure.allCases)
    func ownedMotionUnsupportedTracksAndEditsFailClosed(_ structure: UnsupportedOwnedStructure) async throws {
        let directory = try Synthetic.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("in.mov"), malformed = directory.appendingPathComponent("unsupported.mov")
        let output = directory.appendingPathComponent("out.mov")
        try await Synthetic.video(at: input, Self.ownedSpec(frames: 15, audio: 0))
        var movie = try Self.materialized(input)
        let index = try #require(movie.tracks.firstIndex(where: { $0.kind == "vide" }))
        switch structure {
        case .secondVideo:
            var clone = movie.tracks[index]
            clone.id = movie.tracks.map(\.id).max()! + 1
            try QuickTimeMuxer.replace32(&clone.header, 20, clone.id)
            clone.references = nil
            movie.tracks.append(clone)
        case .repeatedEdit:
            let duration = try QuickTimeMuxer.read32(movie.tracks[index].header, 28)
            movie.tracks[index].edits = [.init(duration: duration / 2, mediaTime: 0),
                                         .init(duration: duration - duration / 2, mediaTime: 0)]
        }
        try Self.writeMovie(movie, to: malformed)
        let probe = OwnedMotionProbe()
        do {
            _ = try await BoundedMotionEncoder().compress(input: malformed, output: output, observer: probe.observer)
            Issue.record("Unsupported source structure must fail before output")
        } catch let error as QuickTimeMuxer.Failure {
            guard case .unsupported = error else { throw error }
        }
        #expect(probe.snapshot.opened.isEmpty)
        #expect(try files(in: directory) == ["in.mov", "unsupported.mov"])
    }

    enum OwnedCancelPhase: CaseIterable, Sendable { case append, write, rename }

    @Test(arguments: OwnedCancelPhase.allCases)
    func ownedMotionCancellationJoinsAndPreservesUnknownFiles(_ phase: OwnedCancelPhase) async throws {
        let directory = try Synthetic.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("in.mov"), output = directory.appendingPathComponent("out.mov")
        let unknown = directory.appendingPathComponent(".partial-out.mov")
        let marker = Data("not owned by encoder".utf8)
        try marker.write(to: unknown)
        try await Synthetic.video(at: input, Self.ownedSpec(frames: 15, audio: 0))
        let barrier = MotionBarrier(), probe = OwnedMotionProbe()
        var observer = probe.observer
        if phase == .append {
            observer.didAppend = { _ in barrier.pause() }
        } else if phase == .write {
            let record = observer.didWrite
            observer.didWrite = { purpose, count in try record(purpose, count); barrier.pause() }
        } else {
            let record = observer.didRename
            observer.didRename = { purpose, path in try record(purpose, path); barrier.pause() }
        }
        let configuredObserver = observer
        let task = Task {
            defer { barrier.didFinish() }
            return try await BoundedMotionEncoder().compress(input: input, output: output, observer: configuredObserver)
        }
        defer { barrier.release() }
        guard await barrier.waitUntilBlockedOrFinished() else {
            _ = try await task.value
            Issue.record("Missing owned-encoder cancellation barrier")
            return
        }
        task.cancel()
        #expect(!barrier.snapshot.completed && !barrier.snapshot.returned)
        if phase == .rename {
            #expect(FileManager.default.fileExists(atPath: output.path) && probe.snapshot.published.isEmpty)
        } else {
            #expect(!FileManager.default.fileExists(atPath: output.path))
        }
        if phase == .append { #expect(!probe.snapshot.joined && probe.snapshot.opened.isEmpty) }
        barrier.release()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(barrier.snapshot.completed && barrier.snapshot.returned && !barrier.snapshot.prematureCompletion)
        #expect(probe.snapshot.joined && probe.snapshot.lateAppends == 0)
        #expect(probe.snapshot.published.isEmpty)
        if phase == .rename {
            #expect(probe.snapshot.directorySyncs == [.cleanup] && probe.snapshot.closed == 1)
        }
        #expect(try Data(contentsOf: unknown) == marker)
        #expect(try files(in: directory) == [".partial-out.mov", "in.mov"])
    }

    @Test(arguments: [ENOSPC, EIO])
    func ownedMotionWriteFailureRemovesOnlyItsOwnFile(_ code: Int32) async throws {
        // Injected sink faults, not filesystem pressure.
        let directory = try Synthetic.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("in.mov"), output = directory.appendingPathComponent("out.mov")
        let unknown = directory.appendingPathComponent(".owned-motion-unknown.mov")
        let marker = Data("pre-existing file".utf8)
        try marker.write(to: unknown)
        try await Synthetic.video(at: input, Self.ownedSpec(frames: 15, audio: 0))
        let probe = OwnedMotionProbe()
        var observer = probe.observer
        observer.didWrite = { _, _ in throw QuickTimeMuxer.Failure.io(code) }
        await #expect(throws: QuickTimeMuxer.Failure.io(code)) {
            _ = try await BoundedMotionEncoder().compress(input: input, output: output, observer: observer)
        }
        #expect(probe.snapshot.opened.count == 1 && probe.snapshot.joined)
        #expect(probe.snapshot.published.isEmpty)
        #expect(try Data(contentsOf: unknown) == marker)
        #expect(try files(in: directory) == [".owned-motion-unknown.mov", "in.mov"])
    }

    @Test func ownedMotionCannotReplacePreexistingDestination() async throws {
        let directory = try Synthetic.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("in.mov"), output = directory.appendingPathComponent("out.mov")
        let marker = Data("belongs to another invocation".utf8)
        try marker.write(to: output)
        try await Synthetic.video(at: input, Self.ownedSpec(frames: 15, audio: 0))
        let probe = OwnedMotionProbe()
        await #expect(throws: QuickTimeMuxer.Failure.unsupported("output already exists")) {
            _ = try await BoundedMotionEncoder().compress(input: input, output: output, observer: probe.observer)
        }
        #expect(probe.snapshot.opened.isEmpty)
        #expect(try Data(contentsOf: output) == marker)
        #expect(try files(in: directory) == ["in.mov", "out.mov"])
    }
    #endif
}
#endif
