// SPDX-License-Identifier: Apache-2.0
#if canImport(AVFoundation) && canImport(VideoToolbox) && canImport(CoreMedia)
import AVFoundation
import CoreMedia
import Darwin
import Foundation
import HomespunCore
import os
import VideoToolbox

/// Package-test-only candidate. Bounds files written through its sink, not framework
/// scratch, allocator overhead, codec caches, Photos storage, or total process memory.
/// No app integration, shipping admission policy, or durable crash ownership is implied.
struct BoundedMotionEncoder: Sendable {
    typealias Failure = QuickTimeMuxer.Failure
    typealias Limits = QuickTimeMuxer.Limits

    enum Purpose: Sendable, Equatable { case encoded, originalCopy }
    enum DirectorySync: Sendable, Equatable { case publication, cleanup }

    struct FullRead: Sendable {
        var compressedSamples: [UInt32: Int]
        var videoFrames: Int
        var audioFrames: Int
        var metadataSamples: Int
    }

    struct Observer: Sendable {
        var didAppend: @Sendable (Int) -> Void = { _ in }
        var didInspectVideoOutput: @Sendable (Int) -> Void = { _ in }
        var didCopyVideoBytes: @Sendable () -> Void = {}
        var afterVideoFrame: @Sendable (Int, Bool) throws -> Void = { _, _ in }
        var didReachPayloadBound: @Sendable (Int, Int) -> Void = { _, _ in }
        var didFullRead: @Sendable (FullRead) -> Void = { _ in }
        var didJoin: @Sendable () -> Void = {}
        var didSerialize: @Sendable (Int) -> Void = { _ in }
        var didOpen: @Sendable (Purpose, URL) -> Void = { _, _ in }
        var didWrite: @Sendable (Purpose, Int) throws -> Void = { _, _ in }
        var didRename: @Sendable (Purpose, URL) throws -> Void = { _, _ in }
        var beforeDirectorySync: @Sendable (DirectorySync) throws -> Void = { _ in }
        var didDirectorySync: @Sendable (DirectorySync) -> Void = { _ in }
        var didCloseSink: @Sendable () -> Void = {}
        var didResidualResourceError: @Sendable () -> Void = {}
        var didPublish: @Sendable (Purpose, URL) -> Void = { _, _ in }
    }

    var bitrate = 2_000_000
    var audioBitrate = 96_000
    var limits = Limits()

    func compress(input: URL, output: URL, observer: Observer = .init()) async throws -> VideoCompressionResult {
        try Task.checkCancellation()
        try limits.validate()
        guard input.standardizedFileURL != output.standardizedFileURL, output.pathExtension.lowercased() == "mov",
              bitrate > 0, bitrate <= Int(Int32.max), audioBitrate > 0,
              limits.inputBytes > 0, limits.retainedBytes > 0, limits.atomBytes > 0,
              limits.metadataBytes > 0, limits.descriptionBytes >= 16,
              limits.sampleBytes > 0, limits.samplesPerTrack > 0,
              limits.samplesPerTrack <= 7_200, limits.dimension > 0, limits.pixels > 0 else {
            throw Failure.unsupported("prototype parameters/path")
        }
        let source = try QuickTimeMuxer.source(input, limits: limits)
        let identity = try Fingerprint.sha256(of: input)
        let asset = AVURLAsset(url: input)
        let assetTracks = try await asset.load(.tracks)
        guard assetTracks.count == source.tracks.count,
              Set(assetTracks.map { UInt32(bitPattern: $0.trackID) }) == Set(source.tracks.map { $0.model.id }),
              let identifier = try await AVSupport.contentIdentifier(of: asset), !identifier.isEmpty else {
            throw Failure.unsupported("track set/Live Photo identifier")
        }
        var formats: [UInt32: CMFormatDescription] = [:]
        var ranges: [UInt32: CMTimeRange] = [:]
        var decodeRanges: [UInt32: CMTimeRange] = [:]
        var videoTraits: AVSupport.VideoTraits?
        var metadataDescribesVideo = false
        for track in assetTracks {
            let id = UInt32(bitPattern: track.trackID)
            let descriptions = try await track.load(.formatDescriptions)
            guard descriptions.count == 1, let format = descriptions.first,
                  let model = source.tracks.first(where: { $0.model.id == id })?.model else {
                throw Failure.unsupported("fixed track description")
            }
            let kind = track.mediaType == .video ? "vide" : track.mediaType == .audio ? "soun" :
                track.mediaType == .metadata ? "meta" : ""
            guard kind == model.kind else { throw Failure.unsupported("undeclared media type") }
            formats[id] = format
            let range = try await track.load(.timeRange)
            guard range.isValid, !range.isEmpty, range.start.isNumeric, range.duration.isNumeric,
                  range.start >= .zero, range.duration > .zero else {
                throw Failure.unsupported("track time range")
            }
            ranges[id] = range
            // The raw parser validates the edit rate. The framework interpretation must
            // agree too; composite/repeated source segments are not reconstructed.
            let segments = try await track.load(.segments)
            let nonempty = segments.filter { !$0.isEmpty }
            guard nonempty.count == 1, let segment = nonempty.first,
                  segment.timeMapping.source.duration == segment.timeMapping.target.duration else {
                throw Failure.unsupported("composite/rate-changing edit")
            }
            decodeRanges[id] = segment.timeMapping.target
            if kind == "vide" {
                let traits = AVSupport.VideoTraits(format: format, frameRate: try await track.load(.nominalFrameRate))
                guard traits.encodedWidth > 0, traits.encodedHeight > 0,
                      traits.encodedWidth <= limits.dimension, traits.encodedHeight <= limits.dimension,
                      traits.encodedWidth % 2 == 0, traits.encodedHeight % 2 == 0,
                      try QuickTimeMuxer.multiply(traits.encodedWidth, traits.encodedHeight) <= limits.pixels,
                      traits.frameRate.isFinite, traits.frameRate > 0, traits.frameRate <= 60 else {
                    throw Failure.limitExceeded("video dimensions/frame rate")
                }
                // The existing motion policy holds all HDR. This narrower prototype
                // rejects it explicitly rather than inventing a held-success shortcut.
                guard !traits.isHLG, !traits.isPQ, !traits.isDolbyVisionCodec else {
                    throw Failure.unsupported("held HDR motion")
                }
                guard traits.codec == kCMVideoCodecType_H264 || traits.codec == kCMVideoCodecType_HEVC else {
                    throw Failure.unsupported("prototype source video codec")
                }
                videoTraits = traits
            } else if kind == "soun" {
                guard let basic = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
                      basic.mFormatID == kAudioFormatMPEG4AAC || basic.mFormatID == kAudioFormatLinearPCM,
                      (1...2).contains(basic.mChannelsPerFrame),
                      basic.mSampleRate.isFinite, basic.mSampleRate >= 8_000, basic.mSampleRate <= 48_000,
                      basic.mSampleRate.rounded() == basic.mSampleRate else {
                    throw Failure.unsupported("audio format/channels/sample rate")
                }
                guard let sourceTrack = source.tracks.first(where: { $0.model.id == id }),
                      model.timescale == UInt32(basic.mSampleRate),
                      basic.mFramesPerPacket == (basic.mFormatID == kAudioFormatMPEG4AAC ? 1024 : 1),
                      sourceTrack.durations.allSatisfy({ $0 <= basic.mFramesPerPacket }),
                      segment.timeMapping.target.duration.seconds * basic.mSampleRate <=
                        Double(sourceTrack.durations.reduce(UInt64(0)) { $0 + UInt64($1) }) + 1 else {
                    throw Failure.unsupported("audio packet/edit timeline")
                }
            } else {
                guard CMFormatDescriptionGetMediaSubType(format) == kCMMetadataFormatType_Boxed else {
                    throw Failure.unsupported("non-boxed metadata")
                }
                let referents = try await track.loadAssociatedTracks(ofType: .metadataReferent)
                if referents.contains(where: { $0.mediaType == .video }) { metadataDescribesVideo = true }
            }
        }
        guard let traits = videoTraits, metadataDescribesVideo else {
            throw Failure.unsupported("missing video/ContentDescribes association")
        }
        let run = Run(source: source, asset: asset, tracks: assetTracks, formats: formats, ranges: decodeRanges,
                      traits: traits, bitrate: bitrate, audioBitrate: audioBitrate, limits: limits, observer: observer)
        try await withTaskCancellationHandler {
            try run.encode()
        } onCancel: {
            run.cancel()
        }
        try Task.checkCancellation()
        guard try MediaFiles.size(of: input) == source.size, try Fingerprint.sha256(of: input) == identity else {
            throw Failure.corruptInput("source changed during full read")
        }
        let copyOriginal: Bool
        let serialization: QuickTimeMuxer.Serialization?
        if run.payloadBoundReached {
            copyOriginal = true
            serialization = nil
        } else {
            // Reserve nested atom construction and tables before serialization, not after.
            try run.checkMemory(extra: QuickTimeMuxer.multiply(limits.atomBytes, 12))
            let finished = try QuickTimeMuxer.serialize(run.movie, limits: limits)
            let serializationMemory = try QuickTimeMuxer.add(
                finished.chunks.prefix(4).reduce(0) { try QuickTimeMuxer.add($0, $1.count) },
                QuickTimeMuxer.multiply(finished.chunks.count, MemoryLayout<Data>.stride))
            try run.checkMemory(extra: serializationMemory)
            observer.didSerialize(finished.totalBytes)
            copyOriginal = finished.totalBytes >= source.size
            serialization = copyOriginal ? nil : finished
        }
        if copyOriginal {
            // Release every encoded payload before the single I-byte fallback file.
            run.discardPayload()
            let sink = try FileSink(output: output, expected: source.size, purpose: .originalCopy, observer: observer)
            do {
                try sink.copy(input)
                let digest = try Fingerprint.sha256(of: sink.partial)
                guard digest == identity, try MediaFiles.size(of: input) == source.size,
                      try Fingerprint.sha256(of: input) == identity else { throw Failure.corruptInput("fallback identity") }
                try sink.publish()
                return VideoCompressionResult(mode: .originalKeptNotSmaller, sha256: digest, size: source.size)
            } catch {
                try sink.abort(after: error)
                throw error
            }
        }
        guard let serialization, serialization.totalBytes > 0, serialization.totalBytes < source.size else {
            throw Failure.byteCountMismatch
        }
        let sink = try FileSink(output: output, expected: serialization.totalBytes, purpose: .encoded, observer: observer)
        do {
            try sink.write(serialization.chunks)
            try await verify(input: asset, inputURL: input, source: source, output: sink.partial, identifier: identifier, ranges: ranges)
            try Task.checkCancellation()
            guard try Fingerprint.sha256(of: input) == identity else { throw Failure.corruptInput("source changed before publish") }
            let digest = try Fingerprint.sha256(of: sink.partial)
            try sink.publish()
            return VideoCompressionResult(mode: .transcoded, sha256: digest, size: serialization.totalBytes)
        } catch {
            try sink.abort(after: error)
            throw error
        }
    }

    private func verify(input: AVAsset, inputURL: URL, source: QuickTimeMuxer.Source, output: URL,
                        identifier: String, ranges: [UInt32: CMTimeRange]) async throws {
        let asset = AVURLAsset(url: output)
        let tracks = try await asset.load(.tracks)
        guard tracks.count == source.tracks.count,
              Set(tracks.map { UInt32(bitPattern: $0.trackID) }) == Set(source.tracks.map { $0.model.id }),
              try await AVSupport.contentIdentifier(of: asset) == identifier else {
            throw Failure.corruptInput("output identity/topology")
        }
        let parsed = try QuickTimeMuxer.source(output, limits: limits)
        guard parsed.movie.metadata == source.movie.metadata else { throw Failure.corruptInput("movie metadata changed") }
        for model in source.tracks {
            let id = model.model.id
            guard let resultModel = parsed.tracks.first(where: { $0.model.id == id }),
                  resultModel.model.references == model.model.references,
                  resultModel.model.header == model.model.header,
                  resultModel.model.aperture == model.model.aperture,
                  resultModel.model.dataInfo == model.model.dataInfo,
                  let resultTrack = tracks.first(where: { UInt32(bitPattern: $0.trackID) == id }),
                  let before = ranges[id] else { throw Failure.corruptInput("track identity/association/header") }
            let after = try await resultTrack.load(.timeRange)
            guard abs(before.start.seconds - after.start.seconds) <= 0.001,
                  VideoVerification.durationsMatch(before.duration.seconds, after.duration.seconds, absolute: 0.1, relative: 0) else {
                throw Failure.corruptInput("output track duration")
            }
            guard let originalTrack = try await input.load(.tracks).first(where: {
                UInt32(bitPattern: $0.trackID) == id
            }) else { throw Failure.corruptInput("source association track") }
            let oldTypes = try await originalTrack.load(.availableTrackAssociationTypes)
            let newTypes = try await resultTrack.load(.availableTrackAssociationTypes)
            guard Set(oldTypes.map(\.rawValue)) == Set(newTypes.map(\.rawValue)) else {
                throw Failure.corruptInput("association types changed")
            }
            for type in oldTypes {
                let old = try await originalTrack.loadAssociatedTracks(ofType: type).map(\.trackID).sorted()
                let new = try await resultTrack.loadAssociatedTracks(ofType: type).map(\.trackID).sorted()
                guard old == new else { throw Failure.corruptInput("association referents changed") }
            }
            if model.model.kind == "meta" {
                guard resultModel.durations == model.durations,
                      resultModel.compositionOffsets == model.compositionOffsets,
                      resultModel.model.edits.map(\.mediaTime) == model.model.edits.map(\.mediaTime),
                      resultModel.model.edits.map(\.duration) == model.model.edits.map(\.duration) else {
                    throw Failure.corruptInput("timed metadata timing")
                }
                let a = try FileHandle(forReadingFrom: output)
                let b = try FileHandle(forReadingFrom: inputURL)
                defer { try? a.close(); try? b.close() }
                guard resultModel.sampleSizes == model.sampleSizes else { throw Failure.corruptInput("metadata sample sizes") }
                for index in model.sampleSizes.indices {
                    try a.seek(toOffset: UInt64(resultModel.sampleOffsets[index]))
                    try b.seek(toOffset: UInt64(model.sampleOffsets[index]))
                    guard try a.read(upToCount: Int(model.sampleSizes[index])) == b.read(upToCount: Int(model.sampleSizes[index])) else {
                        throw Failure.corruptInput("timed metadata payload")
                    }
                }
            }
            if model.model.kind == "vide" {
                guard let original = try await input.loadTracks(withMediaType: .video).first,
                      let first = try await original.load(.formatDescriptions).first,
                      let last = try await resultTrack.load(.formatDescriptions).first else {
                    throw Failure.corruptInput("output video format")
                }
                let a = CMVideoFormatDescriptionGetDimensions(first), b = CMVideoFormatDescriptionGetDimensions(last)
                guard a.width == b.width, a.height == b.height,
                      try await original.load(.preferredTransform) == resultTrack.load(.preferredTransform),
                      try await original.load(.naturalSize) == resultTrack.load(.naturalSize) else {
                    throw Failure.corruptInput("video framing/transform")
                }
                for key in [kCMFormatDescriptionExtension_CleanAperture, kCMFormatDescriptionExtension_PixelAspectRatio,
                            kCMFormatDescriptionExtension_ColorPrimaries, kCMFormatDescriptionExtension_TransferFunction,
                            kCMFormatDescriptionExtension_YCbCrMatrix] {
                    let a = CMFormatDescriptionGetExtension(first, extensionKey: key)
                    let b = CMFormatDescriptionGetExtension(last, extensionKey: key)
                    guard (a == nil && b == nil) || (a != nil && b != nil && CFEqual(a!, b!)) else {
                        throw Failure.corruptInput("video format extension \(key)")
                    }
                }
            }
        }
        let before = try await input.load(.duration).seconds
        let after = try await asset.load(.duration).seconds
        guard VideoVerification.durationsMatch(before, after, absolute: 0.1, relative: 0) else {
            throw Failure.corruptInput("output movie duration")
        }
        let frames = try await AVSupport.decodeVideo(output, cancellable: true)
        guard frames == source.tracks.first(where: { $0.model.kind == "vide" })?.sampleSizes.count else {
            throw Failure.corruptInput("short output video decode")
        }
        // Audio is also fully decoded; a readable video cannot conceal a broken AAC tail.
        for track in tracks where track.mediaType == .audio {
            guard let format = try await track.load(.formatDescriptions).first,
                  let basic = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else {
                throw Failure.corruptInput("output audio format")
            }
            let range = try await track.load(.timeRange)
            let check = try AudioDecode(asset: asset, track: track, expected: range.duration.seconds * basic.mSampleRate)
            try await withTaskCancellationHandler { try check.decode() } onCancel: { check.cancel() }
        }
    }

    private final class AudioDecode: @unchecked Sendable {
        let reader: AVAssetReader
        let output: AVAssetReaderTrackOutput
        let expected: Double
        private let lock = NSLock()
        private var cancelled = false

        init(asset: AVAsset, track: AVAssetTrack, expected: Double) throws {
            reader = try AVAssetReader(asset: asset)
            output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
            self.expected = expected
            guard reader.canAdd(output) else { throw Failure.unsupported("output audio reader") }
            reader.add(output)
        }

        func cancel() { lock.withLock { cancelled = true; reader.cancelReading() } }

        func decode() throws {
            defer { cancel() }
            let started = try lock.withLock {
                if cancelled { throw CancellationError() }
                return reader.startReading()
            }
            guard started else { throw Failure.corruptInput("output audio reader start") }
            var frames = 0
            while let sample = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                frames = try QuickTimeMuxer.add(frames, CMSampleBufferGetNumSamples(sample))
            }
            try Task.checkCancellation()
            guard reader.status == .completed, frames > 0, expected.isFinite,
                  abs(Double(frames) - expected) <= 1 else { throw Failure.corruptInput("output audio decode/length") }
        }
    }

    /// A single synchronous feeder with one completed VT submission at a time. Codec
    /// callbacks are joined by CompleteFrames before sample buffers are consumed/released.
    private final class Run: @unchecked Sendable {
        let source: QuickTimeMuxer.Source
        let asset: AVAsset
        let tracks: [AVAssetTrack]
        let formats: [UInt32: CMFormatDescription]
        let ranges: [UInt32: CMTimeRange]
        let traits: AVSupport.VideoTraits
        let bitrate: Int
        let audioBitrate: Int
        let limits: Limits
        let observer: Observer
        var movie: QuickTimeMuxer.Movie
        var payloadBoundReached = false
        private var payloadBytes = 0
        private var baseMemory = 0
        private let lock = NSLock()
        private var cancelled = false
        private var reader: AVAssetReader?
        private var videoFrames = 0
        private var audioFrames = 0
        private var metadataSamples = 0
        private var stillImageTimeFound = false
        private var compressedCounts: [UInt32: Int] = [:]

        init(source: QuickTimeMuxer.Source, asset: AVAsset, tracks: [AVAssetTrack],
             formats: [UInt32: CMFormatDescription], ranges: [UInt32: CMTimeRange], traits: AVSupport.VideoTraits,
             bitrate: Int, audioBitrate: Int, limits: Limits, observer: Observer) {
            self.source = source
            self.asset = asset
            self.tracks = tracks
            self.formats = formats
            self.ranges = ranges
            self.traits = traits
            self.bitrate = bitrate
            self.audioBitrate = audioBitrate
            self.limits = limits
            self.observer = observer
            movie = source.movie
        }

        func checkMemory(extra: Int = 0) throws {
            guard try QuickTimeMuxer.add(QuickTimeMuxer.add(baseMemory, payloadBytes), extra) <= limits.retainedBytes else {
                throw Failure.limitExceeded("accounted retained buffer/model bytes")
            }
        }

        func cancel() {
            lock.withLock {
                cancelled = true
                reader?.cancelReading()
            }
        }

        private func checkCancellation() throws {
            try Task.checkCancellation()
            if lock.withLock({ cancelled }) { throw CancellationError() }
        }

        private func startReader(_ track: AVAssetTrack, settings: [String: Any]?) throws
            -> (AVAssetReader, AVAssetReaderTrackOutput) {
            try checkCancellation()
            let value = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            output.alwaysCopiesSampleData = false
            guard value.canAdd(output) else { throw Failure.unsupported("source reader track") }
            value.add(output)
            let started = try lock.withLock {
                if cancelled { throw CancellationError() }
                reader = value
                return value.startReading()
            }
            guard started else { throw Failure.corruptInput("source reader start: \(String(describing: value.error))") }
            return (value, output)
        }

        private func finished(_ value: AVAssetReader) throws {
            try checkCancellation()
            guard value.status == .completed else {
                throw Failure.corruptInput("source reader incomplete: \(String(describing: value.error))")
            }
            lock.withLock { reader = nil }
        }

        func encode() throws {
            defer {
                // All VT callbacks/converter calls have returned before these observations.
                lock.withLock { reader?.cancelReading(); reader = nil }
                observer.didJoin()
            }
            let modelSlots = try QuickTimeMuxer.multiply(
                QuickTimeMuxer.multiply(limits.samplesPerTrack, 6),
                2 * (MemoryLayout<QuickTimeMuxer.Sample>.stride + 32))
            baseMemory = try QuickTimeMuxer.add(source.retainedBytes,
                QuickTimeMuxer.add(modelSlots, QuickTimeMuxer.multiply(limits.descriptionBytes, 12)))
            try checkMemory()
            // Compressed counts/sizes and fixed descriptions are checked independently
            // from decode. EOF alone never proves the declared source was read.
            try validateCompressedSource()
            guard let index = movie.tracks.firstIndex(where: { $0.kind == "vide" }) else {
                throw Failure.unsupported("missing video model")
            }
            try video(index)
            if let index = movie.tracks.firstIndex(where: { $0.kind == "soun" }) { try audio(index) }
            for index in movie.tracks.indices where movie.tracks[index].kind == "meta" { try metadata(index) }
            guard stillImageTimeFound else { throw Failure.unsupported("missing still-image-time metadata") }
            try checkCancellation()
            observer.didFullRead(FullRead(compressedSamples: compressedCounts, videoFrames: videoFrames,
                                          audioFrames: audioFrames, metadataSamples: metadataSamples))
        }

        private func validateCompressedSource() throws {
            for model in source.tracks {
                guard let track = tracks.first(where: { UInt32(bitPattern: $0.trackID) == model.model.id }),
                      let expectedFormat = formats[model.model.id] else { throw Failure.unsupported("source track mapping") }
                let (reader, output) = try startReader(track, settings: nil)
                var count = 0
                while let sample = output.copyNextSampleBuffer() {
                    try checkCancellation()
                    guard let format = CMSampleBufferGetFormatDescription(sample), CFEqual(format, expectedFormat) else {
                        throw Failure.unsupported("source format changed")
                    }
                    let n = CMSampleBufferGetNumSamples(sample)
                    guard n > 0, n <= model.sampleSizes.count - count else {
                        throw Failure.corruptInput("compressed sample count")
                    }
                    for i in 0..<n {
                        guard CMSampleBufferGetSampleSize(sample, at: i) == model.sampleSizes[count + i] else {
                            throw Failure.corruptInput("compressed sample size")
                        }
                    }
                    let retained = CMSampleBufferGetTotalSampleSize(sample)
                    guard retained <= limits.sampleBytes else { throw Failure.limitExceeded("compressed reader buffer") }
                    try checkMemory(extra: retained)
                    if model.model.kind == "vide" { try validateNALSample(sample, format: expectedFormat) }
                    count += n
                }
                try finished(reader)
                guard count == model.sampleSizes.count else { throw Failure.corruptInput("short compressed source") }
                compressedCounts[model.model.id] = count
            }
        }

        private func validateNALSample(_ sample: CMSampleBuffer, format: CMFormatDescription) throws {
            let codec = CMFormatDescriptionGetMediaSubType(format)
            var headerLength: Int32 = 0
            let status: OSStatus
            if codec == kCMVideoCodecType_H264 {
                status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: &headerLength)
            } else if codec == kCMVideoCodecType_HEVC {
                status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: &headerLength)
            } else { throw Failure.unsupported("source NAL codec") }
            guard status == noErr, [1, 2, 4].contains(headerLength) else {
                throw Failure.unsupported("source NAL framing")
            }
            let data = try sampleBytes(sample)
            var packetStart = 0
            for packet in 0..<CMSampleBufferGetNumSamples(sample) {
                let packetSize = CMSampleBufferGetSampleSize(sample, at: packet)
                let end = try QuickTimeMuxer.add(packetStart, packetSize)
                guard end <= data.count else { throw Failure.corruptInput("NAL sample extent") }
                var cursor = packetStart, units = 0, picture = false
                while cursor < end {
                    let width = Int(headerLength)
                    guard width <= end - cursor else { throw Failure.corruptInput("short NAL length") }
                    let count = data[cursor..<(cursor + width)].reduce(0) { ($0 << 8) | Int($1) }
                    cursor += width
                    let minimum = codec == kCMVideoCodecType_H264 ? 1 : 2
                    guard count >= minimum, count <= end - cursor, data[cursor] & 0x80 == 0 else {
                        throw Failure.corruptInput("NAL extent/header")
                    }
                    if codec == kCMVideoCodecType_H264 {
                        let type = data[cursor] & 0x1f
                        guard type > 0, type < 24 else { throw Failure.unsupported("H264 NAL type") }
                        picture = picture || (1...5).contains(type)
                    } else {
                        guard data[cursor + 1] & 7 != 0 else { throw Failure.corruptInput("HEVC temporal identifier") }
                        picture = picture || ((data[cursor] >> 1) & 0x3f) <= 31
                    }
                    cursor += count
                    units += 1
                    guard units <= limits.atoms else { throw Failure.limitExceeded("NAL units") }
                }
                guard picture else { throw Failure.corruptInput("video sample without picture") }
                packetStart = end
            }
            guard packetStart == data.count else { throw Failure.corruptInput("unaccounted NAL bytes") }
        }

        private func reachPayloadBound(_ size: Int) throws -> Bool {
            guard size > 0 else { throw Failure.corruptInput("empty encoded sample") }
            if payloadBoundReached { return true }
            let next = try QuickTimeMuxer.add(payloadBytes, size)
            guard next >= source.size else { return false }
            payloadBoundReached = true
            observer.didReachPayloadBound(next, source.size)
            discardPayload()
            return true
        }

        private func append(_ sample: QuickTimeMuxer.Sample, to index: Int) throws {
            guard !payloadBoundReached else { return }
            if try reachPayloadBound(sample.bytes.count) { return }
            guard sample.bytes.count <= limits.sampleBytes,
                  movie.tracks[index].samples.count < limits.samplesPerTrack else {
                throw Failure.limitExceeded("encoded sample size/count")
            }
            let next = try QuickTimeMuxer.add(payloadBytes, sample.bytes.count)
            try checkMemory(extra: sample.bytes.count)
            movie.tracks[index].samples.append(sample)
            payloadBytes = next
            observer.didAppend(movie.tracks[index].samples.count)
            try checkCancellation()
        }

        func discardPayload() {
            for index in movie.tracks.indices { movie.tracks[index].samples.removeAll(keepingCapacity: false) }
            payloadBytes = 0
        }

        private func sampleBytes(_ sample: CMSampleBuffer, additionalMemory: Int = 0) throws -> Data {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { throw Failure.corruptInput("missing sample bytes") }
            let size = CMBlockBufferGetDataLength(block)
            guard size > 0, size <= min(source.size, limits.sampleBytes) else { throw Failure.limitExceeded("sample buffer") }
            try checkMemory(extra: QuickTimeMuxer.add(QuickTimeMuxer.multiply(size, 2), additionalMemory))
            var bytes = Data(count: size)
            let status = bytes.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: size, destination: $0.baseAddress!)
            }
            guard status == noErr else { throw Failure.codec("sample bytes", status) }
            return bytes
        }

        private func edits(_ index: Int, mediaTime: Int32) throws {
            if movie.tracks[index].edits.isEmpty {
                let duration = try QuickTimeMuxer.read32(movie.tracks[index].header, 28)
                guard duration > 0 else { throw Failure.unsupported("empty presentation") }
                movie.tracks[index].edits = [.init(duration: duration, mediaTime: mediaTime)]
            } else {
                guard let last = movie.tracks[index].edits.indices.last,
                      movie.tracks[index].edits[last].mediaTime >= 0 else { throw Failure.unsupported("edit topology") }
                movie.tracks[index].edits[last].mediaTime = mediaTime
            }
        }

        private func video(_ index: Int) throws {
            let id = movie.tracks[index].id
            guard let track = tracks.first(where: { UInt32(bitPattern: $0.trackID) == id }),
                  let format = formats[id], let range = ranges[id],
                  let sourceTrack = source.tracks.first(where: { $0.model.id == id }) else {
                throw Failure.unsupported("video source")
            }
            guard sourceTrack.compositionOffsets.allSatisfy({ $0 == 0 }) ||
                    Set(sourceTrack.durations).count == 1 else {
                throw Failure.unsupported("reordered variable-frame timing")
            }
            let box = VideoCallback(didInspect: observer.didInspectVideoOutput)
            var session: VTCompressionSession?
            let status = VTCompressionSessionCreate(
                allocator: kCFAllocatorDefault, width: Int32(traits.encodedWidth), height: Int32(traits.encodedHeight),
                codecType: kCMVideoCodecType_HEVC, encoderSpecification: nil,
                imageBufferAttributes: nil, compressedDataAllocator: nil,
                outputCallback: { reference, _, status, flags, sample in
                    guard let reference else { return }
                    Unmanaged<VideoCallback>.fromOpaque(reference).takeUnretainedValue().receive(status, flags, sample)
                }, refcon: Unmanaged.passUnretained(box).toOpaque(), compressionSessionOut: &session)
            guard status == noErr, let session else { throw Failure.codec("VT session", status) }
            defer {
                _ = VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
                VTCompressionSessionInvalidate(session)
                box.fence()
            }
            func set(_ key: CFString, _ value: CFTypeRef) throws {
                let result = VTSessionSetProperty(session, key: key, value: value)
                guard result == noErr else { throw Failure.codec("VT property \(key)", result) }
            }
            try set(kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: bitrate))
            try set(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: traits.frameRate))
            try set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
            try set(kVTCompressionPropertyKey_MaxFrameDelayCount, NSNumber(value: 0))
            try set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main_AutoLevel)
            for (extensionKey, property) in [
                (kCMFormatDescriptionExtension_ColorPrimaries, kVTCompressionPropertyKey_ColorPrimaries),
                (kCMFormatDescriptionExtension_TransferFunction, kVTCompressionPropertyKey_TransferFunction),
                (kCMFormatDescriptionExtension_YCbCrMatrix, kVTCompressionPropertyKey_YCbCrMatrix),
                (kCMFormatDescriptionExtension_PixelAspectRatio, kVTCompressionPropertyKey_PixelAspectRatio),
            ] {
                if let value = CMFormatDescriptionGetExtension(format, extensionKey: extensionKey) { try set(property, value) }
            }
            if let aperture = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_CleanAperture) {
                guard CFGetTypeID(aperture) == CFDictionaryGetTypeID() else { throw Failure.unsupported("clean aperture dictionary") }
                try set(kVTCompressionPropertyKey_CleanAperture, aperture)
            }
            let prepared = VTCompressionSessionPrepareToEncodeFrames(session)
            guard prepared == noErr else { throw Failure.codec("VT prepare", prepared) }
            let (reader, output) = try startReader(track, settings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            ])
            var timestamp: Int64 = 0
            var decodedFormat: CMFormatDescription?
            var encodedDescription: Data?
            while let sample = output.copyNextSampleBuffer() {
                try checkCancellation()
                guard videoFrames < sourceTrack.sampleSizes.count,
                      CMSampleBufferGetNumSamples(sample) == 1,
                      let pixels = CMSampleBufferGetImageBuffer(sample),
                      let sampleFormat = CMSampleBufferGetFormatDescription(sample) else {
                    throw Failure.corruptInput("decoded video sample/count")
                }
                if let decodedFormat, !CFEqual(decodedFormat, sampleFormat) { throw Failure.unsupported("decoded video format changed") }
                decodedFormat = sampleFormat
                let scale = CMTimeScale(movie.tracks[index].timescale)
                let actual = CMTimeSubtract(CMSampleBufferGetPresentationTimeStamp(sample), range.start)
                let expected = CMTime(value: timestamp, timescale: scale)
                guard actual.isNumeric, abs(CMTimeSubtract(actual, expected).seconds) <= 1 / Double(scale) else {
                    throw Failure.unsupported("video presentation timeline")
                }
                let duration = sourceTrack.durations[videoFrames]
                videoFrames += 1
                // Charge real stride/plane backing extents, never w*h*1.5.
                let pixelBytes = try pixelAllocation(pixels)
                try checkMemory(extra: pixelBytes)
                if !payloadBoundReached {
                    let available = limits.retainedBytes - baseMemory - payloadBytes - pixelBytes
                    guard available > 0 else { throw Failure.limitExceeded("VT retained output capacity") }
                    box.reset(remainingPayloadBytes: source.size - payloadBytes,
                              sampleCapacity: min(limits.sampleBytes, available / 2))
                    let encoded = VTCompressionSessionEncodeFrame(
                        session, imageBuffer: pixels, presentationTimeStamp: expected,
                        duration: CMTime(value: Int64(duration), timescale: scale),
                        frameProperties: nil, sourceFrameRefcon: nil, infoFlagsOut: nil)
                    guard encoded == noErr else { throw Failure.codec("VT encode", encoded) }
                    let joined = VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
                    guard joined == noErr else { throw Failure.codec("VT complete", joined) }
                    switch try box.take() {
                    case .payloadBound(let size):
                        guard try reachPayloadBound(size) else { throw Failure.byteCountMismatch }
                    case .sample(let result):
                        let presentation = CMSampleBufferGetPresentationTimeStamp(result)
                        let decode = CMSampleBufferGetDecodeTimeStamp(result)
                        guard presentation.isNumeric, presentation == expected,
                              !decode.isNumeric || decode == presentation else {
                            throw Failure.unsupported("unexpected VT reordering/timing")
                        }
                        guard let format = CMSampleBufferGetFormatDescription(result) else { throw Failure.corruptInput("VT description") }
                        let description = try QuickTimeMuxer.description(format, limits: limits)
                        if let encodedDescription, encodedDescription != description { throw Failure.unsupported("VT description changed") }
                        encodedDescription = description
                        movie.tracks[index].description = description
                        let sync = try BoundedMotionEncoder.videoSampleIsSync(result)
                        guard videoFrames != 1 || sync else { throw Failure.corruptInput("first encoded video sample is not sync") }
                        let bytes = try sampleBytes(result, additionalMemory: pixelBytes)
                        observer.didCopyVideoBytes()
                        try append(.init(bytes: bytes, duration: duration, sync: sync), to: index)
                    }
                }
                timestamp += Int64(duration) // Source stts sum has already passed UInt32 validation.
                try observer.afterVideoFrame(videoFrames, payloadBoundReached)
                try checkCancellation()
            }
            try finished(reader)
            guard videoFrames == sourceTrack.sampleSizes.count else { throw Failure.corruptInput("short video decode") }
            try edits(index, mediaTime: 0)
        }

        private func pixelAllocation(_ buffer: CVPixelBuffer) throws -> Int {
            guard CVPixelBufferGetWidth(buffer) == traits.encodedWidth,
                  CVPixelBufferGetHeight(buffer) == traits.encodedHeight else { throw Failure.unsupported("decoded dimensions") }
            var planes = 0
            let n = CVPixelBufferGetPlaneCount(buffer)
            if n == 0 {
                planes = try QuickTimeMuxer.multiply(CVPixelBufferGetBytesPerRow(buffer), CVPixelBufferGetHeight(buffer))
            } else {
                guard n <= 3 else { throw Failure.unsupported("pixel planes") }
                for plane in 0..<n {
                    planes = try QuickTimeMuxer.add(planes, QuickTimeMuxer.multiply(
                        CVPixelBufferGetBytesPerRowOfPlane(buffer, plane), CVPixelBufferGetHeightOfPlane(buffer, plane)))
                }
            }
            return max(planes, CVPixelBufferGetDataSize(buffer))
        }

        private func audio(_ index: Int) throws {
            let id = movie.tracks[index].id
            guard let track = tracks.first(where: { UInt32(bitPattern: $0.trackID) == id }),
                  let sourceFormat = formats[id], let range = ranges[id],
                  let basic = CMAudioFormatDescriptionGetStreamBasicDescription(sourceFormat)?.pointee else {
                throw Failure.unsupported("audio source")
            }
            let rate = basic.mSampleRate, channels = basic.mChannelsPerFrame
            guard let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                          channels: channels, interleaved: true) else {
                throw Failure.unsupported("PCM configuration")
            }
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
            ]
            if payloadBoundReached {
                let (reader, output) = try startReader(track, settings: settings)
                let feeder = AudioFeeder(run: self, output: output, format: pcm, range: range, extraMemory: 0)
                try feeder.drain()
                try finished(reader)
                audioFrames = feeder.frames
                try verifyAudioFrames(audioFrames, range: range, rate: rate)
                return
            }
            guard let aac = AVAudioFormat(settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
                  ]), let converter = AVAudioConverter(from: pcm, to: aac),
                  let rates = converter.applicableEncodeBitRates?.map(\.intValue), !rates.isEmpty else {
                throw Failure.unsupported("AAC converter configuration")
            }
            defer { converter.reset() }
            let ceiling = min(audioBitrate, Int(rate * 6) * Int(channels))
            guard rates.allSatisfy({ $0 > 0 }),
                  let selected = rates.filter({ $0 <= ceiling }).max() ?? rates.min() else { throw Failure.unsupported("AAC bitrate") }
            converter.bitRate = selected
            converter.primeMethod = .normal
            let packetBytes = converter.maximumOutputPacketSize
            guard packetBytes > 0, packetBytes <= limits.sampleBytes else { throw Failure.limitExceeded("AAC packet capacity") }
            let requestedCapacity = try QuickTimeMuxer.multiply(packetBytes, 8)
            try checkMemory(extra: requestedCapacity)
            let compressed = AVAudioCompressedBuffer(format: aac, packetCapacity: 8, maximumPacketSize: packetBytes)
            let capacity = Int(compressed.byteCapacity)
            guard capacity >= requestedCapacity else { throw Failure.unsupported("AAC buffer capacity") }
            try checkMemory(extra: capacity)
            let (reader, output) = try startReader(track, settings: settings)
            let feeder = AudioFeeder(run: self, output: output, format: pcm, range: range, extraMemory: capacity)
            var description: Data?
            var descriptionCookie: Data?
            var done = false
            while !done, !payloadBoundReached {
                try checkCancellation()
                compressed.packetCount = 0
                var error: NSError?
                let status = converter.convert(to: compressed, error: &error) { requested, state in
                    feeder.next(requested, state)
                }
                if let error = feeder.error { throw error }
                guard status != .error, error == nil else { throw Failure.unsupported("AAC conversion: \(String(describing: error))") }
                let cookie = converter.magicCookie
                if compressed.packetCount > 0 {
                    guard let cookie, !cookie.isEmpty, cookie.count <= limits.descriptionBytes else {
                        throw Failure.unsupported("AAC magic cookie")
                    }
                    if let descriptionCookie, descriptionCookie != cookie { throw Failure.unsupported("AAC cookie changed") }
                    descriptionCookie = cookie
                    var outputBasic = converter.outputFormat.streamDescription.pointee
                    guard outputBasic.mFormatID == kAudioFormatMPEG4AAC,
                          outputBasic.mFramesPerPacket == 1024 else { throw Failure.unsupported("non-AAC-LC output") }
                    var format: CMAudioFormatDescription?
                    let created = cookie.withUnsafeBytes {
                        CMAudioFormatDescriptionCreate(
                            allocator: kCFAllocatorDefault, asbd: &outputBasic, layoutSize: 0, layout: nil,
                            magicCookieSize: cookie.count, magicCookie: $0.baseAddress, extensions: nil,
                            formatDescriptionOut: &format)
                    }
                    guard created == noErr, let format else { throw Failure.codec("AAC format", created) }
                    let entry = try QuickTimeMuxer.description(format, limits: limits)
                    if let description, description != entry { throw Failure.unsupported("AAC description changed") }
                    description = entry
                    movie.tracks[index].description = entry
                    guard let packets = compressed.packetDescriptions, compressed.packetCount <= 8,
                          compressed.byteLength <= capacity else { throw Failure.corruptInput("AAC packet descriptions") }
                    var packetEnd = 0
                    for packet in 0..<Int(compressed.packetCount) {
                        let p = packets[packet]
                        guard p.mStartOffset >= 0, let start = Int(exactly: p.mStartOffset),
                              p.mDataByteSize > 0, p.mVariableFramesInPacket == 0 || p.mVariableFramesInPacket == 1024,
                              start == packetEnd,
                              try QuickTimeMuxer.add(start, Int(p.mDataByteSize)) <= Int(compressed.byteLength) else {
                            throw Failure.corruptInput("AAC packet extent")
                        }
                        packetEnd = try QuickTimeMuxer.add(start, Int(p.mDataByteSize))
                        if try reachPayloadBound(Int(p.mDataByteSize)) { break }
                        try checkMemory(extra: QuickTimeMuxer.add(
                            QuickTimeMuxer.add(capacity, feeder.retainedBytes),
                            QuickTimeMuxer.multiply(Int(p.mDataByteSize), 2)))
                        let bytes = Data(bytes: compressed.data.advanced(by: start), count: Int(p.mDataByteSize))
                        try append(.init(bytes: bytes, duration: 1024), to: index)
                        if payloadBoundReached { break }
                    }
                    guard payloadBoundReached || packetEnd == Int(compressed.byteLength) else {
                        throw Failure.corruptInput("unaccounted AAC bytes")
                    }
                }
                switch status {
                case .endOfStream: done = true
                case .haveData:
                    guard compressed.packetCount > 0 else { throw Failure.corruptInput("AAC no progress") }
                case .inputRanDry:
                    throw Failure.corruptInput("unexpected AAC input starvation")
                case .error: throw Failure.unsupported("AAC converter error")
                @unknown default: throw Failure.unsupported("AAC converter status")
                }
            }
            // On an immutable-payload stop, do not feed the converter again. Its synchronous
            // call has joined. Decode every remaining PCM sample directly, including its tail.
            if payloadBoundReached {
                compressed.packetCount = 0
                compressed.byteLength = 0
                converter.reset()
                try feeder.drain()
            }
            try finished(reader)
            audioFrames = feeder.frames
            try verifyAudioFrames(audioFrames, range: range, rate: rate)
            if !payloadBoundReached {
                guard description != nil, let leading = Int32(exactly: converter.primeInfo.leadingFrames) else {
                    throw Failure.unsupported("AAC priming")
                }
                guard converter.magicCookie == descriptionCookie else { throw Failure.unsupported("final AAC cookie changed") }
                let mediaFrames = try QuickTimeMuxer.multiply(movie.tracks[index].samples.count, 1024)
                guard mediaFrames >= (try QuickTimeMuxer.add(Int(leading), audioFrames)) else {
                    throw Failure.corruptInput("AAC priming/presentation extent")
                }
                movie.tracks[index].timescale = UInt32(rate)
                try QuickTimeMuxer.replace32(&movie.tracks[index].mediaHeader, 20, UInt32(rate))
                try edits(index, mediaTime: leading)
            }
        }

        private func verifyAudioFrames(_ frames: Int, range: CMTimeRange, rate: Double) throws {
            let expected = range.duration.seconds * rate
            guard expected.isFinite, expected >= 1, expected <= Double(Int32.max),
                  abs(Double(frames) - expected) <= 1 else { throw Failure.corruptInput("short audio presentation") }
        }

        private func metadata(_ index: Int) throws {
            let id = movie.tracks[index].id
            guard let track = tracks.first(where: { UInt32(bitPattern: $0.trackID) == id }),
                  let model = source.tracks.first(where: { $0.model.id == id }), let format = formats[id] else {
                throw Failure.unsupported("metadata source")
            }
            movie.tracks[index].description = try QuickTimeMuxer.description(format, limits: limits)
            let (reader, output) = try startReader(track, settings: nil)
            var count = 0
            while let sample = output.copyNextSampleBuffer() {
                try checkCancellation()
                guard let current = CMSampleBufferGetFormatDescription(sample), CFEqual(current, format),
                      CMSampleBufferGetNumSamples(sample) == 1, count < model.sampleSizes.count else {
                    throw Failure.unsupported("metadata description/sample grouping")
                }
                let bytes = try sampleBytes(sample)
                guard bytes.count == model.sampleSizes[count], CMSampleBufferDataIsReady(sample),
                      let group = AVTimedMetadataGroup(sampleBuffer: sample),
                      group.timeRange.isValid, group.timeRange.start.isNumeric, group.timeRange.duration.isNumeric,
                      group.items.count <= limits.atoms else { throw Failure.corruptInput("timed metadata sample") }
                if group.items.contains(where: {
                    $0.identifier?.rawValue == "mdta/com.apple.quicktime.still-image-time" &&
                        $0.dataType == "com.apple.metadata.datatype.int8"
                }) { stillImageTimeFound = true }
                if !payloadBoundReached {
                    try append(.init(bytes: bytes, duration: model.durations[count],
                                     compositionOffset: model.compositionOffsets[count]), to: index)
                }
                count += 1
            }
            try finished(reader)
            guard count == model.sampleSizes.count else { throw Failure.corruptInput("short metadata source") }
            metadataSamples += count
        }

        private final class AudioFeeder: @unchecked Sendable {
            unowned let run: Run
            let output: AVAssetReaderTrackOutput
            let format: AVAudioFormat
            let range: CMTimeRange
            let extraMemory: Int
            var error: (any Error)?
            var frames = 0
            private var sample: CMSampleBuffer?
            private var offset = 0
            private var end = false
            private var currentPCM: AVAudioPCMBuffer?

            var retainedBytes: Int {
                let inputBytes = sample.flatMap { CMSampleBufferGetDataBuffer($0) }.map { CMBlockBufferGetDataLength($0) } ?? 0
                let pcmBytes = currentPCM.map {
                    UnsafeMutableAudioBufferListPointer($0.mutableAudioBufferList).reduce(0) { $0 + Int($1.mDataByteSize) }
                } ?? 0
                return inputBytes + pcmBytes
            }

            init(run: Run, output: AVAssetReaderTrackOutput, format: AVAudioFormat, range: CMTimeRange, extraMemory: Int) {
                self.run = run
                self.output = output
                self.format = format
                self.range = range
                self.extraMemory = extraMemory
            }

            private func read() throws -> Bool {
                try run.checkCancellation()
                guard let next = output.copyNextSampleBuffer() else { end = true; sample = nil; return false }
                let count = CMSampleBufferGetNumSamples(next)
                guard count > 0, let block = CMSampleBufferGetDataBuffer(next),
                      let description = CMSampleBufferGetFormatDescription(next),
                      let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
                      basic.mFormatID == kAudioFormatLinearPCM, basic.mBitsPerChannel == 32,
                      basic.mSampleRate == format.sampleRate, basic.mChannelsPerFrame == format.channelCount,
                      basic.mBytesPerFrame == 4 * format.channelCount,
                      basic.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                      basic.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0 else {
                    throw Failure.unsupported("decoded PCM format")
                }
                let bytes = CMBlockBufferGetDataLength(block)
                guard bytes <= run.limits.sampleBytes,
                      bytes == (try QuickTimeMuxer.multiply(count, Int(basic.mBytesPerFrame))) else {
                    throw Failure.limitExceeded("decoded audio buffer")
                }
                try run.checkMemory(extra: QuickTimeMuxer.add(bytes, extraMemory))
                let relative = CMTimeSubtract(CMSampleBufferGetPresentationTimeStamp(next), range.start).seconds
                guard relative.isFinite, abs(relative * format.sampleRate - Double(frames)) <= 1 else {
                    throw Failure.corruptInput("audio presentation gap")
                }
                frames = try QuickTimeMuxer.add(frames, count)
                guard Double(frames) <= range.duration.seconds * format.sampleRate + 1 else {
                    throw Failure.corruptInput("excess decoded audio presentation")
                }
                sample = next
                offset = 0
                return true
            }

            func next(_ requested: AVAudioPacketCount, _ state: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
                do {
                    try run.checkCancellation()
                    currentPCM = nil
                    if sample == nil || offset == CMSampleBufferGetNumSamples(sample!) {
                        sample = nil
                        if !end, !(try read()) { state.pointee = .endOfStream; return nil }
                    }
                    guard !end, let sample, let block = CMSampleBufferGetDataBuffer(sample), requested > 0 else {
                        state.pointee = .endOfStream
                        return nil
                    }
                    let count = min(Int(requested), min(4096, CMSampleBufferGetNumSamples(sample) - offset))
                    let bytes = try QuickTimeMuxer.multiply(count, Int(format.channelCount) * 4)
                    try run.checkMemory(extra: QuickTimeMuxer.add(
                        QuickTimeMuxer.add(CMBlockBufferGetDataLength(block), bytes), extraMemory))
                    guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else {
                        throw Failure.unsupported("PCM allocation")
                    }
                    pcm.frameLength = AVAudioFrameCount(count)
                    let buffers = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
                    guard buffers.count == 1, let destination = buffers[0].mData,
                          buffers[0].mDataByteSize >= bytes else { throw Failure.unsupported("interleaved PCM allocation") }
                    let copied = CMBlockBufferCopyDataBytes(
                        block, atOffset: offset * Int(format.channelCount) * 4, dataLength: bytes, destination: destination)
                    guard copied == noErr else { throw Failure.codec("PCM copy", copied) }
                    offset += count
                    currentPCM = pcm
                    state.pointee = .haveData
                    return pcm
                } catch {
                    self.error = error
                    state.pointee = .endOfStream
                    return nil
                }
            }

            func drain() throws {
                currentPCM = nil
                sample = nil
                // frames includes the whole already-decoded current sample, even when only
                // its prefix was supplied to the converter. It needs no second decode.
                while !end { _ = try read(); sample = nil }
            }
        }
    }

    static func videoSampleIsSync(_ sample: CMSampleBuffer) throws -> Bool {
        guard CMSampleBufferGetNumSamples(sample) == 1,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
              CFArrayGetCount(attachments) == 1,
              let dictionary = (attachments as NSArray).object(at: 0) as? NSDictionary else {
            throw Failure.corruptInput("video sample attachment shape")
        }
        guard let value = dictionary[kCMSampleAttachmentKey_NotSync as String] else { return true }
        guard CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID(), let boolean = value as? NSNumber else {
            throw Failure.corruptInput("video NotSync attachment type")
        }
        return !boolean.boolValue
    }

    final class VideoCallback: @unchecked Sendable {
        enum Output { case sample(CMSampleBuffer), payloadBound(Int) }
        private let lock = NSLock()
        private var sample: CMSampleBuffer?
        private var error: Failure?
        private var callbacks = 0
        private var capacity = 0
        private var remaining = 0
        private var boundSize: Int?
        private let didInspect: @Sendable (Int) -> Void

        init(didInspect: @escaping @Sendable (Int) -> Void = { _ in }) { self.didInspect = didInspect }

        func reset(remainingPayloadBytes: Int, sampleCapacity: Int) {
            lock.withLock {
                sample = nil; boundSize = nil; error = nil; callbacks = 0
                remaining = remainingPayloadBytes; capacity = sampleCapacity
            }
        }

        func receive(_ status: OSStatus, _ flags: VTEncodeInfoFlags, _ sample: CMSampleBuffer?) {
            lock.withLock {
                callbacks += 1
                if status != noErr { error = .codec("VT callback", status) }
                else if flags.contains(.frameDropped) { error = .corruptInput("VT dropped frame") }
                else if let sample {
                    guard let block = CMSampleBufferGetDataBuffer(sample) else {
                        error = .corruptInput("VT missing data buffer")
                        return
                    }
                    let size = CMBlockBufferGetDataLength(block)
                    guard CMSampleBufferGetNumSamples(sample) == 1,
                          CMSampleBufferGetTotalSampleSize(sample) == size, size > 0, remaining > 0 else {
                        error = .corruptInput("VT sample count/size")
                        return
                    }
                    didInspect(size)
                    // Inspect actual encoder bytes before retaining any output. A primitive
                    // proof survives; an over-I CMSampleBuffer never does.
                    if size >= remaining {
                        boundSize = size
                    } else if size > capacity {
                        error = .limitExceeded("VT retained output buffer")
                    } else { self.sample = sample }
                }
                else { error = .corruptInput("VT empty callback") }
            }
        }

        func take() throws -> Output {
            try lock.withLock {
                defer { sample = nil }
                if let error { throw error }
                guard callbacks == 1 else { throw Failure.corruptInput("VT callback count") }
                if let boundSize { return .payloadBound(boundSize) }
                guard let sample else { throw Failure.corruptInput("VT missing callback output") }
                return .sample(sample)
            }
        }

        func fence() { lock.withLock { sample = nil } }
    }

    /// Every new byte (including fallback) passes this one sink. No copyItem, writer,
    /// export session, alternate output, name sweep, or pre-existing-file replacement.
    private final class FileSink {
        let output: URL
        let partial: URL
        let expected: Int
        let purpose: Purpose
        let observer: Observer
        private var directory: Int32 = -1
        private var file: Int32 = -1
        private let partialName: String
        private let outputName: String
        private var directoryIdentity: stat?
        private var identity: stat?
        private var ownedName: String?
        private var announced = false
        private var written = 0
        private var synced = false
        private static let logger = Logger(subsystem: "photos.homespun.app", category: "BoundedMotionEncoder")

        init(output: URL, expected: Int, purpose: Purpose, observer: Observer) throws {
            try Task.checkCancellation()
            guard expected > 0, output.isFileURL, !["", ".", ".."].contains(output.lastPathComponent) else {
                throw Failure.unsupported("output sink path")
            }
            self.output = output
            self.expected = expected
            self.purpose = purpose
            self.observer = observer
            outputName = output.lastPathComponent
            partialName = ".owned-motion-\(UUID().uuidString).mov"
            partial = output.deletingLastPathComponent().appendingPathComponent(partialName)
            do {
                try ensureDirectory()
                var existing = stat()
                if fstatat(directory, outputName, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
                    throw Failure.unsupported("output already exists")
                }
                guard errno == ENOENT else { throw Failure.io(errno) }
                file = openat(directory, partialName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
                guard file >= 0 else { throw Failure.io(errno) }
                ownedName = partialName
                var created = stat()
                guard fstat(file, &created) == 0 else { throw Failure.io(errno) }
                identity = created
                #if os(iOS)
                try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                                     ofItemAtPath: partial.path)
                #endif
                announced = true
                observer.didOpen(purpose, partial)
            } catch {
                try abort(after: error)
                throw error
            }
        }

        deinit {
            // Normal paths explicitly publish/abort and check every close. A destructor
            // cannot throw or turn unresolved ownership into silently successful cleanup.
            var residual = ownedName != nil
            if file >= 0 {
                let value = file
                file = -1
                if Darwin.close(value) != 0 { residual = true }
                residual = true
            }
            if directory >= 0 {
                let value = directory
                directory = -1
                if Darwin.close(value) != 0 { residual = true }
                residual = true
            }
            if residual {
                Self.logger.error("Owned motion sink ended with unresolved resource state; no files swept.")
                observer.didResidualResourceError()
            }
        }

        private func ensureDirectory() throws {
            if directory < 0 {
                directory = Darwin.open(output.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                guard directory >= 0 else { throw Failure.io(errno) }
            }
            var actual = stat()
            guard fstat(directory, &actual) == 0 else { throw Failure.io(errno) }
            if let original = directoryIdentity {
                guard actual.st_dev == original.st_dev, actual.st_ino == original.st_ino else {
                    throw Failure.unsupported("owned directory changed; preserved")
                }
            } else { directoryIdentity = actual }
        }

        private func closeFile() throws {
            guard file >= 0 else { return }
            let value = file
            file = -1
            guard Darwin.close(value) == 0 else {
                let code = errno
                Self.logger.error("Owned motion file descriptor close failed.")
                observer.didResidualResourceError()
                throw Failure.io(code)
            }
        }

        private func closeDirectory() throws {
            guard directory >= 0 else { return }
            let value = directory
            directory = -1
            guard Darwin.close(value) == 0 else {
                let code = errno
                Self.logger.error("Owned motion directory descriptor close failed.")
                observer.didResidualResourceError()
                throw Failure.io(code)
            }
        }

        private func syncDirectory(_ phase: DirectorySync) throws {
            try observer.beforeDirectorySync(phase)
            guard fsync(directory) == 0 else { throw Failure.io(errno) }
            observer.didDirectorySync(phase)
        }

        private func writeBytes(_ bytes: UnsafeRawBufferPointer) throws {
            var offset = 0
            while offset < bytes.count {
                try Task.checkCancellation()
                let count = min(64 * 1024, bytes.count - offset)
                guard try QuickTimeMuxer.add(written, count) <= expected else { throw Failure.byteCountMismatch }
                let result = Darwin.write(file, bytes.baseAddress!.advanced(by: offset), count)
                if result < 0 {
                    if errno == EINTR { continue }
                    throw Failure.io(errno)
                }
                guard result > 0 else { throw Failure.io(EIO) }
                written = try QuickTimeMuxer.add(written, result)
                offset += result
                try observer.didWrite(purpose, written)
            }
        }

        func write(_ chunks: [Data]) throws {
            for chunk in chunks { try chunk.withUnsafeBytes { try writeBytes($0) } }
            try finish()
        }

        func copy(_ input: URL) throws {
            var source = Darwin.open(input.path, O_RDONLY | O_NOFOLLOW)
            guard source >= 0 else { throw Failure.io(errno) }
            func closeSource() throws {
                guard source >= 0 else { return }
                let value = source
                source = -1
                guard Darwin.close(value) == 0 else {
                    let code = errno
                    Self.logger.error("Owned motion source descriptor close failed.")
                    observer.didResidualResourceError()
                    throw Failure.io(code)
                }
            }
            do {
                var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                while true {
                    try Task.checkCancellation()
                    let count = buffer.withUnsafeMutableBytes { Darwin.read(source, $0.baseAddress!, $0.count) }
                    if count < 0 {
                        if errno == EINTR { continue }
                        throw Failure.io(errno)
                    }
                    if count == 0 { break }
                    try buffer.withUnsafeBytes { try writeBytes(UnsafeRawBufferPointer(rebasing: $0[..<count])) }
                }
                try closeSource()
                try finish()
            } catch {
                let primary = error
                do { try closeSource() }
                catch { throw Failure.cleanupFailed(primary: String(describing: primary), cleanup: String(describing: error)) }
                throw primary
            }
        }

        private func finish() throws {
            try Task.checkCancellation()
            var actual = stat()
            guard fstat(file, &actual) == 0 else { throw Failure.io(errno) }
            guard written == expected, actual.st_size == expected else { throw Failure.byteCountMismatch }
            guard fsync(file) == 0 else { throw Failure.io(errno) }
            try closeFile()
            synced = true
        }

        private func checkedOwned() throws -> stat {
            guard let name = ownedName, let identity else {
                throw Failure.unsupported("owned file identity unavailable; preserved")
            }
            try ensureDirectory()
            var actual = stat()
            guard fstatat(directory, name, &actual, AT_SYMLINK_NOFOLLOW) == 0 else { throw Failure.io(errno) }
            guard actual.st_dev == identity.st_dev, actual.st_ino == identity.st_ino else {
                throw Failure.unsupported("owned file replaced; unknown file preserved")
            }
            return actual
        }

        func publish() throws {
            try Task.checkCancellation()
            let actual = try checkedOwned()
            guard synced, actual.st_size == expected,
                  written == expected else { throw Failure.byteCountMismatch }
            // Public Darwin exclusive atomic rename preserves an unknown/pre-existing
            // destination even if one appears between construction and publication.
            guard renameatx_np(directory, partialName, directory, outputName, UInt32(RENAME_EXCL)) == 0 else {
                throw Failure.io(errno)
            }
            ownedName = outputName
            try observer.didRename(purpose, output)
            try Task.checkCancellation()
            try syncDirectory(.publication)
            try Task.checkCancellation()
            guard try checkedOwned().st_size == expected else { throw Failure.byteCountMismatch }
            try closeDirectory()
            try Task.checkCancellation()
            ownedName = nil
            observer.didCloseSink()
            observer.didPublish(purpose, output)
        }

        func abort(after primary: any Error) throws {
            var failures: [String] = []
            do { try closeFile() } catch { failures.append(String(describing: error)) }
            if let name = ownedName {
                do {
                    _ = try checkedOwned()
                    guard unlinkat(directory, name, 0) == 0 else { throw Failure.io(errno) }
                    try syncDirectory(.cleanup)
                    ownedName = nil
                } catch {
                    failures.append(String(describing: error))
                }
            }
            do { try closeDirectory() } catch { failures.append(String(describing: error)) }
            if ownedName == nil, announced { observer.didCloseSink() }
            if !failures.isEmpty {
                throw Failure.cleanupFailed(primary: String(describing: primary), cleanup: failures.joined(separator: "; "))
            }
        }
    }
}
#endif
