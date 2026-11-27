// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@_spi(Testing) @testable import HomespunMedia

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
import HomespunCore
import HomespunTestSupport
import ImageIO
import UniformTypeIdentifiers

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

    private enum ReaderEvent: Equatable, Sendable { case lanesJoined, readerCancelled }

    private final class MotionBarrier: @unchecked Sendable {
        private let lock = NSLock()
        private let gate = DispatchSemaphore(value: 0)
        private let repeatedCallbacks = DispatchSemaphore(value: 0)
        private var arrival: CheckedContinuation<Bool, Never>?
        private var blocked = false
        private var returned = false
        private var completed = false
        private var joined: (AVAssetReader.Status, AVAssetWriter.Status)?
        private var readerEvents: [ReaderEvent] = []
        private var inFlight = 0
        private var inFlightAtCancelReader: [Int] = []
        private var lateCallbacks: [String: Int] = [:]
        private var lateAppends = 0
        private var prematureCompletion = false

        var snapshot: (returned: Bool, completed: Bool, joined: (AVAssetReader.Status, AVAssetWriter.Status)?,
                       readerEvents: [ReaderEvent], inFlight: Int, inFlightAtCancelReader: [Int],
                       lateCallbacks: [String: Int], lateAppends: Int, prematureCompletion: Bool) {
            lock.withLock {
                (returned, completed, joined, readerEvents, inFlight, inFlightAtCancelReader,
                 lateCallbacks, lateAppends, prematureCompletion)
            }
        }

        func willReadSample() { lock.withLock { inFlight += 1 } }
        func didReadSample() { lock.withLock { inFlight -= 1 } }

        func lateCallback(_ mediaType: AVMediaType) {
            let count = lock.withLock {
                lateCallbacks[mediaType.rawValue, default: 0] += 1
                return lateCallbacks[mediaType.rawValue]!
            }
            if count == 3 { repeatedCallbacks.signal() }
            // A regressed requester must fail the assertions, not starve the test executor.
            Thread.sleep(forTimeInterval: 0.001)
        }

        func observeRequestsBeforeReaderCancel() {
            _ = repeatedCallbacks.wait(timeout: .now() + .seconds(2))
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

        func record(_ event: ReaderEvent) {
            lock.withLock {
                guard blocked else { return }
                if !returned { prematureCompletion = true }
                if event == .readerCancelled { inFlightAtCancelReader.append(inFlight) }
                readerEvents.append(event)
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

    @Test func stoppedLanesStopBeingRequested() async throws {
        let directory = try Synthetic.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("in.mov"), output = directory.appendingPathComponent("out.mov")
        var spec = Self.motion
        spec.frames = 15
        try await Synthetic.video(at: input, spec)
        let barrier = MotionBarrier()
        let observer = AVSupport.MotionObserver(willReadSample: { mediaType in
            barrier.willReadSample()
            if mediaType == .video { barrier.pause() }
        }, didReadSample: { _ in barrier.didReadSample() },
           lateCallback: { barrier.lateCallback($0) },
           didJoinLanes: {
               barrier.record(.lanesJoined)
               // Hold cancelWriting off on the lifecycle queue so an unfinished input's
               // repeated requests are observable, even when joining no longer starves.
               barrier.observeRequestsBeforeReaderCancel()
           },
           didCancelReader: { barrier.record(.readerCancelled) },
           didJoin: { barrier.didJoin($0, $1) })
        let task = Task {
            defer { barrier.didFinish() }
            return try await LivePhotoMotionCompressor().compress(input: input, output: output, observer: observer)
        }
        defer { barrier.release() }
        guard await barrier.waitUntilBlockedOrFinished() else {
            _ = try await task.value
            Issue.record("Motion completed without reaching its first video sample read")
            return
        }
        task.cancel()
        barrier.release()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        let snapshot = barrier.snapshot
        #expect(snapshot.lateCallbacks.values.allSatisfy { $0 <= 1 }, "Late requester callbacks: \(snapshot.lateCallbacks)")
        #expect(snapshot.readerEvents == [.lanesJoined, .readerCancelled])
        #expect(snapshot.inFlightAtCancelReader == [0] && snapshot.inFlight == 0)
        #expect(!snapshot.prematureCompletion)
        let joined = try #require(snapshot.joined)
        #expect(joined.0 == .cancelled && joined.1 == .cancelled)
        #expect(try files(in: directory) == ["in.mov"])
    }

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

    @Test(arguments: CancellationPhase.allCases)
    func cancellationJoinsReadsBeforeCancellingReader(_ phase: CancellationPhase) async throws {
        let directory = try Synthetic.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("in.mov"), output = directory.appendingPathComponent("out.mov")
        var spec = Self.motion
        spec.frames = 15
        if phase == .heldDecode { spec.transfer = AVVideoTransferFunction_ITU_R_2100_HLG }
        try await Synthetic.video(at: input, spec)
        let barrier = MotionBarrier()
        let observer = AVSupport.MotionObserver(willReadSample: { mediaType in
            barrier.willReadSample()
            // Stop after the cancellation check, immediately before a real sample read.
            // Encoded verification starts only after the transfer's final join.
            if mediaType == .video, phase != .encodedDecode || barrier.snapshot.joined != nil {
                barrier.pause()
            }
        }, didReadSample: { _ in barrier.didReadSample() },
           didAppend: { barrier.appended($0, pause: false) },
           lateCallback: { barrier.lateCallback($0) },
           didJoinLanes: { barrier.record(.lanesJoined) },
           didCancelReader: { barrier.record(.readerCancelled) },
           didJoin: { barrier.didJoin($0, $1) })
        let task = Task {
            defer { barrier.didFinish() }
            return try await LivePhotoMotionCompressor().compress(input: input, output: output, observer: observer)
        }
        defer { barrier.release() }
        guard await barrier.waitUntilBlockedOrFinished() else {
            _ = try await task.value
            Issue.record("Motion completed without reaching the controlled sample-read barrier")
            return
        }
        // Stop is requested before the blocked read can return, fixing teardown order without sleeps.
        #expect(barrier.snapshot.inFlight > 0)
        task.cancel()
        #expect(!barrier.snapshot.completed && barrier.snapshot.readerEvents.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: output.path))
        barrier.release()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(barrier.snapshot.readerEvents == [.lanesJoined, .readerCancelled],
                "Reader teardown must follow the last sample read and every lane callback")
        #expect(barrier.snapshot.inFlightAtCancelReader == [0] && barrier.snapshot.inFlight == 0)
        #expect(barrier.snapshot.lateCallbacks.values.allSatisfy { $0 <= 1 },
                "Late requester callbacks: \(barrier.snapshot.lateCallbacks)")
        #expect(barrier.snapshot.returned && barrier.snapshot.completed && barrier.snapshot.lateAppends == 0)
        #expect(!barrier.snapshot.prematureCompletion)
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
}
#endif
