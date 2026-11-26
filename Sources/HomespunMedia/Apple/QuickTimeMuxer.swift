// SPDX-License-Identifier: Apache-2.0
#if canImport(AVFoundation) && canImport(VideoToolbox) && canImport(CoreMedia)
import AVFoundation
import CoreMedia
import Foundation
import VideoToolbox

/// Internal, deliberately restricted MOV prototype. Neither shipping compressor calls it.
/// Sample descriptions come from CoreMedia, not a hand-built codec configuration.
enum QuickTimeMuxer {
    enum Failure: Error, Equatable {
        case unsupported(String)
        case corruptInput(String)
        case limitExceeded(String)
        case codec(String, OSStatus)
        case io(Int32)
        case cleanupFailed(primary: String, cleanup: String)
        case byteCountMismatch
    }

    struct Limits: Sendable {
        var inputBytes = 64 * 1024 * 1024
        var retainedBytes = 192 * 1024 * 1024
        var atomBytes = 8 * 1024 * 1024
        var metadataBytes = 1024 * 1024
        var descriptionBytes = 64 * 1024
        var sampleBytes = 16 * 1024 * 1024
        var samplesPerTrack = 7_200
        var atoms = 4_096
        var dimension = 4_096
        var pixels = 8_912_896

        func validate() throws {
            guard (1...(64 * 1024 * 1024)).contains(inputBytes),
                  (1...(192 * 1024 * 1024)).contains(retainedBytes),
                  (1...(8 * 1024 * 1024)).contains(atomBytes),
                  (1...(1024 * 1024)).contains(metadataBytes),
                  (16...(64 * 1024)).contains(descriptionBytes),
                  (1...(16 * 1024 * 1024)).contains(sampleBytes),
                  (1...7_200).contains(samplesPerTrack), (1...4_096).contains(atoms),
                  (1...4_096).contains(dimension), (1...8_912_896).contains(pixels) else {
                throw Failure.limitExceeded("prototype limits")
            }
        }
    }

    struct Sample {
        var bytes: Data
        var duration: UInt32
        /// Actual signed display offset, not the shifted unsigned value stored in ctts.
        var compositionOffset: Int32 = 0
        var sync = true
    }

    struct Edit {
        var duration: UInt32
        var mediaTime: Int32
    }

    struct Track {
        var id: UInt32
        var kind: String
        var timescale: UInt32
        var header: Data
        var mediaHeader: Data
        var handler: Data
        var mediaInfoHeader: Data
        var dataInfo: Data
        var references: Data?
        var aperture: Data? = nil
        var edits: [Edit]
        var description: Data
        var samples: [Sample] = []
    }

    struct Movie {
        var header: Data
        var timescale: UInt32
        var tracks: [Track]
        var metadata: [Data]
    }

    struct Serialization {
        /// Payload Data uses copy-on-write references, never a concatenated output copy.
        var chunks: [Data]
        var totalBytes: Int
    }

    struct CompositionSummary: Equatable {
        var shift: Int32
        var least: Int32
        var greatest: Int32
        var start: Int32
        var end: Int32

        var fields: [Int32] { [shift, least, greatest, start, end] }
    }

    private static func timingAdd(_ a: Int64, _ b: Int64) throws -> Int64 {
        let (value, overflow) = a.addingReportingOverflow(b)
        guard !overflow else { throw Failure.limitExceeded("composition timing addition") }
        return value
    }

    private static func timing32(_ value: Int64) throws -> Int32 {
        guard let result = Int32(exactly: value) else { throw Failure.limitExceeded("signed composition timing") }
        return result
    }

    /// QTFF v0: stored offset = display offset - shift; absent cslg implies zero shift.
    /// Bounds use decode order; the last displayed frame retains its decode duration.
    static func compositionSummary(durations: [UInt32], displayOffsets: [Int32]) throws -> CompositionSummary {
        guard !durations.isEmpty, durations.count == displayOffsets.count,
              durations.allSatisfy({ $0 > 0 }),
              let least = displayOffsets.min(), let greatest = displayOffsets.max() else {
            throw Failure.corruptInput("composition sample timing")
        }
        var decode: Int64 = 0, start = Int64.max, end = Int64.min
        for index in durations.indices {
            let displayed = try timingAdd(decode, Int64(displayOffsets[index]))
            start = min(start, displayed)
            end = max(end, try timingAdd(displayed, Int64(durations[index])))
            decode = try timingAdd(decode, Int64(durations[index]))
        }
        return CompositionSummary(shift: min(least, 0), least: least, greatest: greatest,
                                  start: try timing32(start), end: try timing32(end))
    }

    static func add(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        guard lhs >= 0, rhs >= 0, !overflow else { throw Failure.limitExceeded("integer addition") }
        return value
    }

    static func multiply(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        guard lhs >= 0, rhs >= 0, !overflow else { throw Failure.limitExceeded("integer multiplication") }
        return value
    }

    static func u32(_ value: Int) throws -> UInt32 {
        guard let result = UInt32(exactly: value) else { throw Failure.limitExceeded("32-bit MOV field") }
        return result
    }

    static func integer(_ value: UInt32) -> Data {
        var value = value.bigEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }

    static func atom(_ type: String, _ payload: Data) throws -> Data {
        guard type.utf8.count == 4 else { throw Failure.unsupported("non-fourcc atom") }
        var result = integer(try u32(add(8, payload.count)))
        result.append(contentsOf: type.utf8)
        result.append(payload)
        return result
    }

    static func fullAtom(_ type: String, _ payload: Data, flags: UInt32 = 0) throws -> Data {
        try atom(type, integer(flags) + payload)
    }

    static func read32(_ data: Data, _ offset: Int) throws -> UInt32 {
        guard offset >= 0, offset <= data.count - 4 else { throw Failure.corruptInput("short MOV field") }
        return data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | UInt32($1) }
    }

    static func replace32(_ data: inout Data, _ offset: Int, _ value: UInt32) throws {
        guard offset >= 0, offset <= data.count - 4 else { throw Failure.corruptInput("short mutable field") }
        data.replaceSubrange(offset..<(offset + 4), with: integer(value))
    }

    /// The only edit to a bridged sample entry is Apple's documented dataRefIndex fix.
    static func description(_ format: CMFormatDescription, limits: Limits) throws -> Data {
        var block: CMBlockBuffer?
        let status: OSStatus
        switch CMFormatDescriptionGetMediaType(format) {
        case kCMMediaType_Video:
            status = CMVideoFormatDescriptionCopyAsBigEndianImageDescriptionBlockBuffer(
                allocator: kCFAllocatorDefault, videoFormatDescription: format,
                stringEncoding: CFStringBuiltInEncodings.macRoman.rawValue, flavor: nil, blockBufferOut: &block)
        case kCMMediaType_Audio:
            status = CMAudioFormatDescriptionCopyAsBigEndianSoundDescriptionBlockBuffer(
                allocator: kCFAllocatorDefault, audioFormatDescription: format, flavor: nil, blockBufferOut: &block)
        case kCMMediaType_Metadata:
            status = CMMetadataFormatDescriptionCopyAsBigEndianMetadataDescriptionBlockBuffer(
                allocator: kCFAllocatorDefault, metadataFormatDescription: format, flavor: nil, blockBufferOut: &block)
        default:
            throw Failure.unsupported("sample description media type")
        }
        guard status == noErr, let block else { throw Failure.codec("sample description bridge", status) }
        let count = CMBlockBufferGetDataLength(block)
        guard count >= 16, count <= limits.descriptionBytes else {
            throw Failure.limitExceeded("sample description")
        }
        var bytes = Data(count: count)
        let copied = bytes.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count, destination: $0.baseAddress!)
        }
        guard copied == noErr else { throw Failure.codec("sample description copy", copied) }
        guard try read32(bytes, 0) == count, bytes[14] == 0xff, bytes[15] == 0xff else {
            throw Failure.unsupported("unexpected CoreMedia sample entry")
        }
        bytes[14] = 0
        bytes[15] = 1
        return bytes
    }

    private static func table(_ name: String, _ values: [UInt32]) throws -> Data {
        var bytes = Data()
        for value in values { bytes.append(integer(value)) }
        return try fullAtom(name, bytes)
    }

    private static func runs(_ values: [UInt32]) -> [UInt32] {
        var entries: [UInt32] = []
        for value in values {
            if entries.count >= 2, entries[entries.count - 1] == value {
                entries[entries.count - 2] += 1
            } else { entries.append(contentsOf: [1, value]) }
        }
        return [UInt32(entries.count / 2)] + entries
    }

    private static func track(_ track: Track, offsets: [UInt32]) throws -> Data {
        guard !track.samples.isEmpty, track.description.count >= 16,
              track.samples.count == offsets.count else { throw Failure.unsupported("incomplete track") }
        var tables = try fullAtom("stsd", integer(1) + track.description)
        tables.append(try table("stts", runs(track.samples.map(\.duration))))
        if track.samples.contains(where: { $0.compositionOffset != 0 }) {
            let summary = try compositionSummary(durations: track.samples.map(\.duration),
                                                 displayOffsets: track.samples.map(\.compositionOffset))
            let stored = try track.samples.map { sample -> UInt32 in
                let shifted = try timingAdd(Int64(sample.compositionOffset), -Int64(summary.shift))
                guard let value = UInt32(exactly: shifted) else { throw Failure.limitExceeded("stored composition offset") }
                return value
            }
            tables.append(try table("ctts", runs(stored)))
            tables.append(try fullAtom("cslg", summary.fields.reduce(into: Data()) {
                $0.append(integer(UInt32(bitPattern: $1)))
            }))
        }
        if track.samples.contains(where: { !$0.sync }) {
            let indices = track.samples.enumerated().filter { $0.element.sync }.map { UInt32($0.offset + 1) }
            tables.append(try table("stss", [UInt32(indices.count)] + indices))
        }
        tables.append(try table("stsc", [1, 1, 1, 1]))
        tables.append(try table("stsz", [0, UInt32(track.samples.count)] + track.samples.map {
            try u32($0.bytes.count)
        }))
        tables.append(try table("stco", [UInt32(offsets.count)] + offsets))
        let minf = try atom("minf", track.mediaInfoHeader + track.dataInfo + atom("stbl", tables))
        var mdhd = track.mediaHeader
        var duration = 0
        for sample in track.samples { duration = try add(duration, Int(sample.duration)) }
        try replace32(&mdhd, 24, u32(duration))
        let mdia = try atom("mdia", mdhd + track.handler + minf)
        var contents = track.header
        if let aperture = track.aperture { contents.append(aperture) }
        if !track.edits.isEmpty {
            var edits = integer(UInt32(track.edits.count))
            for edit in track.edits {
                edits.append(integer(edit.duration))
                edits.append(integer(UInt32(bitPattern: edit.mediaTime)))
                edits.append(integer(0x0001_0000))
            }
            contents.append(try atom("edts", fullAtom("elst", edits)))
        }
        if let references = track.references { contents.append(references) }
        contents.append(mdia)
        return try atom("trak", contents)
    }

    /// All offsets fit UInt32 under the prototype input/payload caps; otherwise fail closed.
    /// Two passes change offset values only, never the size or topology of the movie.
    static func serialize(_ movie: Movie, limits: Limits) throws -> Serialization {
        try limits.validate()
        guard !movie.tracks.isEmpty, movie.tracks.count <= 6 else { throw Failure.unsupported("track topology") }
        var payload = 0
        for track in movie.tracks {
            guard track.samples.count <= limits.samplesPerTrack else { throw Failure.limitExceeded("sample count") }
            for sample in track.samples {
                guard sample.duration > 0,
                      !sample.bytes.isEmpty, sample.bytes.count <= limits.sampleBytes else {
                    throw Failure.unsupported("sample size or timing")
                }
                payload = try add(payload, sample.bytes.count)
            }
        }
        func moov(_ offsets: [[UInt32]]) throws -> Data {
            var contents = movie.header
            for (index, model) in movie.tracks.enumerated() { contents.append(try track(model, offsets: offsets[index])) }
            for metadata in movie.metadata { contents.append(metadata) }
            guard contents.count <= limits.atomBytes else { throw Failure.limitExceeded("serialized movie") }
            return try atom("moov", contents)
        }
        let fileType = try atom("ftyp", Data("qt  ".utf8) + integer(0) + Data("qt  ".utf8))
        let wide = try atom("wide", Data())
        let offsetTemplate = try moov(movie.tracks.map { [UInt32](repeating: 0, count: $0.samples.count) })
        var offset = try add(add(fileType.count, wide.count), add(offsetTemplate.count, 8))
        var offsets: [[UInt32]] = []
        for track in movie.tracks {
            var values: [UInt32] = []
            for sample in track.samples {
                values.append(try u32(offset))
                offset = try add(offset, sample.bytes.count)
            }
            offsets.append(values)
        }
        let header = try moov(offsets)
        guard header.count == offsetTemplate.count else { throw Failure.byteCountMismatch }
        let mediaHeader = integer(try u32(add(payload, 8))) + Data("mdat".utf8)
        let chunks = [fileType, wide, header, mediaHeader] + movie.tracks.flatMap { $0.samples.map(\.bytes) }
        let exact = try chunks.reduce(0) { try add($0, $1.count) }
        guard exact == offset, exact > 0 else { throw Failure.byteCountMismatch }
        return Serialization(chunks: chunks, totalBytes: exact)
    }

    struct SourceTrack {
        var model: Track
        var sampleSizes: [UInt32]
        var durations: [UInt32]
        /// Actual signed display offsets after applying the validated cslg shift.
        var compositionOffsets: [Int32]
        var compositionOffsetAtom: Data?
        var compositionSummaryAtom: Data?
        var compositionSummary: CompositionSummary?
        var sampleOffsets: [Int]
    }

    struct Source {
        var movie: Movie
        var tracks: [SourceTrack]
        var size: Int
        var retainedBytes: Int
    }

    private struct Node {
        var type: String
        var range: Range<Int>
        var body: Range<Int> { (range.lowerBound + 8)..<range.upperBound }
    }

    /// Bounded read-only parsing. Rejects fragmented movies, external data references,
    /// unsupported edit rates/sample groups and out-of-file sample extents before decoding.
    static func source(_ url: URL, limits: Limits) throws -> Source {
        try limits.validate()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        guard length > 0, length <= UInt64(limits.inputBytes), let size = Int(exactly: length) else {
            throw Failure.limitExceeded("source bytes")
        }
        func read(_ offset: Int, _ count: Int) throws -> Data {
            guard offset >= 0, count >= 0, try add(offset, count) <= size else {
                throw Failure.corruptInput("file extent")
            }
            try handle.seek(toOffset: UInt64(offset))
            guard let bytes = try handle.read(upToCount: count), bytes.count == count else {
                throw Failure.corruptInput("short file read")
            }
            return bytes
        }
        var cursor = 0, movieData: Data?, mediaRanges: [Range<Int>] = [], atomCount = 0
        while cursor < size {
            atomCount += 1
            guard atomCount <= limits.atoms else { throw Failure.limitExceeded("top-level atoms") }
            let header = try read(cursor, 8)
            let short = try read32(header, 0)
            var count = Int(short), headerSize = 8
            if short == 1 {
                let extensionBytes = try read(cursor + 8, 8)
                let value = extensionBytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                guard let exact = Int(exactly: value) else { throw Failure.corruptInput("extended atom size") }
                count = exact
                headerSize = 16
            } else if short == 0 { count = size - cursor }
            guard count >= headerSize, count <= size - cursor else { throw Failure.corruptInput("atom extent") }
            let type = String(decoding: header[4..<8], as: UTF8.self)
            switch type {
            case "moov":
                guard movieData == nil, headerSize == 8 else { throw Failure.unsupported("duplicate/extended moov") }
                guard count <= limits.atomBytes else { throw Failure.limitExceeded("source movie model") }
                let modelBytes = try add(multiply(count, 2), multiply(multiply(limits.samplesPerTrack, 6), 64))
                guard modelBytes <= limits.retainedBytes else { throw Failure.limitExceeded("source parser memory") }
                movieData = try read(cursor, count)
            case "mdat": mediaRanges.append((cursor + headerSize)..<(cursor + count))
            case "ftyp", "wide", "free", "skip": break
            default: throw Failure.unsupported("top-level \(type)")
            }
            cursor += count
        }
        guard let data = movieData, !mediaRanges.isEmpty else { throw Failure.corruptInput("missing movie/media") }
        func children(_ range: Range<Int>) throws -> [Node] {
            var result: [Node] = [], offset = range.lowerBound
            while offset < range.upperBound {
                atomCount += 1
                guard atomCount <= limits.atoms else { throw Failure.limitExceeded("movie atom count") }
                let count = Int(try read32(data, offset))
                guard count >= 8, count <= range.upperBound - offset else {
                    throw Failure.corruptInput("nested atom extent")
                }
                result.append(Node(type: String(data: data.subdata(in: (offset + 4)..<(offset + 8)),
                                                encoding: .isoLatin1) ?? "",
                                   range: offset..<(offset + count)))
                offset += count
            }
            return result
        }
        func only(_ type: String, _ nodes: [Node]) throws -> Node {
            let matches = nodes.filter { $0.type == type }
            guard matches.count == 1, let node = matches.first else { throw Failure.corruptInput("missing/duplicate \(type)") }
            return node
        }
        func raw(_ node: Node) -> Data { data.subdata(in: node.range) }
        func whitelist(_ nodes: [Node], _ types: Set<String>) throws {
            for node in nodes where !types.contains(node.type) { throw Failure.unsupported("movie atom \(node.type)") }
        }
        func versionZero(_ node: Node) throws {
            guard try read32(data, node.body.lowerBound) >> 24 == 0 else {
                throw Failure.unsupported("versioned \(node.type)")
            }
        }
        let root = try children(8..<data.count)
        try whitelist(root, ["mvhd", "trak", "meta", "udta", "free"])
        let mvhd = try only("mvhd", root)
        try versionZero(mvhd)
        guard mvhd.range.count == 108 else { throw Failure.unsupported("movie header layout") }
        let movieScale = try read32(data, mvhd.range.lowerBound + 20)
        guard movieScale > 0, movieScale <= 1_000_000 else { throw Failure.limitExceeded("movie timescale") }
        var metadata: [Data] = []
        func validateMeta(_ node: Node) throws {
            let nested = try children(node.body)
            try whitelist(nested, ["hdlr", "keys", "ilst"])
            let handler = try only("hdlr", nested)
            guard handler.range.count >= 32,
                  try read32(data, handler.range.lowerBound + 16) == AVSupport.fourCC("mdta") else {
                throw Failure.unsupported("movie metadata handler")
            }
            let keys = try only("keys", nested)
            try versionZero(keys)
            let count = Int(try read32(data, keys.range.lowerBound + 12))
            guard count > 0, count <= limits.atoms else { throw Failure.limitExceeded("metadata keys") }
            let entries = try children((keys.range.lowerBound + 16)..<keys.range.upperBound)
            guard entries.count == count, entries.allSatisfy({ $0.type == "mdta" }) else {
                throw Failure.unsupported("metadata key namespace")
            }
            let items = try children(only("ilst", nested).body)
            var indices = Set<UInt32>()
            for item in items {
                let index = try read32(data, item.range.lowerBound + 4)
                guard index > 0, index <= count, indices.insert(index).inserted else {
                    throw Failure.corruptInput("metadata key index")
                }
                let values = try children(item.body)
                guard !values.isEmpty, values.allSatisfy({ $0.type == "data" && $0.range.count >= 16 }) else {
                    throw Failure.unsupported("track-referencing metadata")
                }
            }
        }
        for node in root where node.type == "meta" || node.type == "udta" {
            guard node.range.count <= limits.metadataBytes,
                  root.filter({ $0.type == node.type }).count == 1 else {
                throw Failure.limitExceeded("movie metadata")
            }
            // QuickTime meta has no full-box prefix; other variants are unsupported.
            if node.type == "meta" {
                try validateMeta(node)
            } else {
                let nested = try children(node.body)
                try whitelist(nested, ["meta", "©xyz", "©day"])
                guard Set(nested.map(\.type)).count == nested.count else {
                    throw Failure.corruptInput("duplicate user data")
                }
                for child in nested where child.type == "meta" { try validateMeta(child) }
            }
            metadata.append(raw(node))
        }
        var tracks: [SourceTrack] = []
        for node in root where node.type == "trak" {
            guard tracks.count < 6 else { throw Failure.limitExceeded("track count") }
            let parts = try children(node.body)
            try whitelist(parts, ["tkhd", "edts", "tref", "tapt", "mdia", "free"])
            let tkhd = try only("tkhd", parts)
            try versionZero(tkhd)
            guard tkhd.range.count == 92 else { throw Failure.unsupported("track header layout") }
            let id = try read32(data, tkhd.range.lowerBound + 20)
            guard id > 0, id <= Int32.max, !tracks.contains(where: { $0.model.id == id }) else {
                throw Failure.corruptInput("track identity")
            }
            var aperture: Data?
            if let tapt = parts.first(where: { $0.type == "tapt" }) {
                let dimensions = try children(tapt.body)
                try whitelist(dimensions, ["clef", "prof", "enof"])
                guard dimensions.count == 3, tapt.range.count == 68 else {
                    throw Failure.unsupported("track aperture layout")
                }
                for type in ["clef", "prof", "enof"] {
                    let dimension = try only(type, dimensions)
                    guard dimension.range.count == 20,
                          try read32(data, dimension.body.lowerBound) == 0 else {
                        throw Failure.unsupported("track aperture version/layout")
                    }
                    let width = try read32(data, dimension.range.lowerBound + 12)
                    let height = try read32(data, dimension.range.lowerBound + 16)
                    let maximum = UInt32(limits.dimension) << 16
                    guard width > 0, height > 0, width <= maximum, height <= maximum else {
                        throw Failure.limitExceeded("track aperture dimensions")
                    }
                }
                aperture = raw(tapt)
            }
            var edits: [Edit] = []
            if let edts = parts.first(where: { $0.type == "edts" }) {
                let entries = try children(edts.body)
                try whitelist(entries, ["elst"])
                let elst = try only("elst", entries)
                try versionZero(elst)
                let count = Int(try read32(data, elst.range.lowerBound + 12))
                guard count > 0, count <= 2, elst.range.count == 16 + count * 12 else {
                    throw Failure.unsupported("edit structure")
                }
                var nonempty = 0
                for index in 0..<count {
                    let offset = elst.range.lowerBound + 16 + index * 12
                    let duration = try read32(data, offset)
                    let time = Int32(bitPattern: try read32(data, offset + 4))
                    guard duration > 0, time >= -1, try read32(data, offset + 8) == 0x0001_0000 else {
                        throw Failure.unsupported("edit rate/time")
                    }
                    if time >= 0 { nonempty += 1 }
                    else if index != 0 { throw Failure.unsupported("nonleading empty edit") }
                    edits.append(Edit(duration: duration, mediaTime: time))
                }
                guard nonempty == 1, edits.last?.mediaTime != -1 else { throw Failure.unsupported("empty track") }
            }
            let mdia = try children(only("mdia", parts).body)
            try whitelist(mdia, ["mdhd", "hdlr", "minf"])
            let mdhd = try only("mdhd", mdia), hdlr = try only("hdlr", mdia)
            try versionZero(mdhd)
            guard mdhd.range.count == 32 else { throw Failure.unsupported("media header layout") }
            let scale = try read32(data, mdhd.range.lowerBound + 20)
            guard scale > 0, scale <= 1_000_000 else { throw Failure.limitExceeded("track timescale") }
            guard hdlr.range.count >= 32 else { throw Failure.corruptInput("handler") }
            guard hdlr.range.count <= limits.descriptionBytes,
                  parts.first(where: { $0.type == "tref" }).map({ $0.range.count <= limits.descriptionBytes }) != false else {
                throw Failure.limitExceeded("handler/track references")
            }
            let kind = String(decoding: data[(hdlr.range.lowerBound + 16)..<(hdlr.range.lowerBound + 20)],
                              as: UTF8.self)
            guard ["vide", "soun", "meta"].contains(kind) else { throw Failure.unsupported("track \(kind)") }
            guard kind == "vide" || aperture == nil else { throw Failure.unsupported("non-video track aperture") }
            let minf = try children(only("minf", mdia).body)
            try whitelist(minf, ["vmhd", "smhd", "nmhd", "gmhd", "hdlr", "dinf", "stbl"])
            let headers = minf.filter { ["vmhd", "smhd", "nmhd", "gmhd"].contains($0.type) }
            guard headers.count == 1, let header = headers.first else {
                throw Failure.unsupported("incompatible media information headers")
            }
            let infoType = kind == "vide" ? "vmhd" : kind == "soun" ? "smhd" : header.type
            guard kind != "meta" || ["gmhd", "nmhd"].contains(infoType) else {
                throw Failure.unsupported("metadata media information header")
            }
            let info = try only(infoType, minf)
            if info.type == "gmhd" {
                let generic = try children(info.body)
                // Optional text headers need a separate semantic validation; never drop one.
                try whitelist(generic, ["gmin"])
                let base = try only("gmin", generic)
                guard generic.count == 1, info.range.count == 32, base.range.count == 24,
                      try read32(data, base.body.lowerBound) == 0,
                      data[base.range.upperBound - 2] == 0, data[base.range.upperBound - 1] == 0 else {
                    throw Failure.unsupported("generic media information layout")
                }
            } else if info.type == "nmhd" {
                guard info.range.count == 12, try read32(data, info.body.lowerBound) == 0 else {
                    throw Failure.unsupported("null media information layout")
                }
            }
            guard info.range.count <= 32,
                  minf.first(where: { $0.type == "hdlr" }).map({ $0.range.count <= limits.descriptionBytes }) != false,
                  Set(minf.map(\.type)).count == minf.count, Set(mdia.map(\.type)).count == mdia.count else {
                throw Failure.unsupported("media header layout")
            }
            let dataInfo = try only("dinf", minf)
            let dinf = try children(dataInfo.body)
            try whitelist(dinf, ["dref"])
            let dref = try only("dref", dinf)
            guard dinf.count == 1, try read32(data, dref.body.lowerBound) == 0,
                  try read32(data, dref.range.lowerBound + 12) == 1 else {
                throw Failure.unsupported("external references")
            }
            let referenceEntries = try children((dref.range.lowerBound + 16)..<dref.range.upperBound)
            guard referenceEntries.count == 1, let reference = referenceEntries.first else {
                throw Failure.unsupported("data reference entries")
            }
            guard ["url ", "alis"].contains(reference.type), reference.range.count == 12,
                  try read32(data, reference.body.lowerBound) == 1 else {
                throw Failure.unsupported("non-self data reference")
            }
            let stbl = try children(only("stbl", minf).body)
            try whitelist(stbl, ["stsd", "stts", "ctts", "cslg", "stss", "stsc", "stsz", "stco", "co64", "sdtp"])
            guard Set(stbl.map(\.type)).count == stbl.count,
                  Set(parts.map(\.type)).count == parts.count else {
                throw Failure.corruptInput("duplicate track/table atoms")
            }
            let stsd = try only("stsd", stbl)
            guard try read32(data, stsd.range.lowerBound + 12) == 1 else {
                throw Failure.unsupported("multiple sample descriptions")
            }
            let descriptions = try children((stsd.range.lowerBound + 16)..<stsd.range.upperBound)
            guard descriptions.count == 1, let entry = descriptions.first,
                  entry.range.count >= 16, entry.range.count <= limits.descriptionBytes,
                  data[entry.range.lowerBound + 14] == 0, data[entry.range.lowerBound + 15] == 1 else {
                throw Failure.unsupported("sample description/data reference")
            }
            if kind == "meta", entry.type != "mebx" { throw Failure.unsupported("non-mebx metadata") }
            let stsz = try only("stsz", stbl)
            let count = Int(try read32(data, stsz.range.lowerBound + 16))
            guard count > 0, count <= limits.samplesPerTrack else { throw Failure.limitExceeded("declared sample count") }
            let commonSize = try read32(data, stsz.range.lowerBound + 12)
            guard stsz.range.count == 20 + (commonSize == 0 ? count * 4 : 0) else {
                throw Failure.corruptInput("sample size table")
            }
            let sizes = try (0..<count).map {
                commonSize == 0 ? try read32(data, stsz.range.lowerBound + 20 + $0 * 4) : commonSize
            }
            guard sizes.allSatisfy({ $0 > 0 && $0 <= limits.sampleBytes }) else {
                throw Failure.limitExceeded("declared sample size")
            }
            func expand(_ name: String, optional: Bool = false) throws -> [UInt32] {
                guard let node = stbl.first(where: { $0.type == name }) else {
                    if optional { return [UInt32](repeating: 0, count: count) }
                    throw Failure.corruptInput("missing \(name)")
                }
                let n = Int(try read32(data, node.range.lowerBound + 12))
                guard n > 0, n <= count, node.range.count == 16 + n * 8 else { throw Failure.corruptInput("run table") }
                var result: [UInt32] = []
                for i in 0..<n {
                    let run = Int(try read32(data, node.range.lowerBound + 16 + i * 8))
                    guard run > 0, run <= count - result.count else { throw Failure.corruptInput("sample run count") }
                    result.append(contentsOf: repeatElement(try read32(data, node.range.lowerBound + 20 + i * 8),
                                                          count: run))
                }
                guard result.count == count else { throw Failure.corruptInput("short run table") }
                return result
            }
            let durations = try expand("stts")
            guard durations.allSatisfy({ $0 > 0 }) else { throw Failure.corruptInput("zero-duration sample") }
            let mediaDuration = try durations.reduce(0) { try add($0, Int($1)) }
            guard try read32(data, mdhd.range.lowerBound + 24) == u32(mediaDuration) else {
                throw Failure.corruptInput("declared media duration")
            }
            if let sync = stbl.first(where: { $0.type == "stss" }) {
                let n = Int(try read32(data, sync.range.lowerBound + 12))
                guard n <= count, sync.range.count == 16 + n * 4 else { throw Failure.corruptInput("sync table") }
                var previous: UInt32 = 0
                for index in 0..<n {
                    let value = try read32(data, sync.range.lowerBound + 16 + index * 4)
                    guard value > previous, value <= count else { throw Failure.corruptInput("sync sample index") }
                    previous = value
                }
            }
            if let dependencies = stbl.first(where: { $0.type == "sdtp" }),
               dependencies.range.count != 12 + count { throw Failure.corruptInput("dependency table") }
            let ctts = stbl.first(where: { $0.type == "ctts" })
            let cslg = stbl.first(where: { $0.type == "cslg" })
            var summary: CompositionSummary?
            if let cslg {
                guard ctts != nil else { throw Failure.unsupported("composition summary without offsets") }
                guard cslg.range.count == 32, try read32(data, cslg.body.lowerBound) == 0 else {
                    throw Failure.unsupported("composition summary size/version/flags")
                }
                let fields = try (0..<5).map { Int32(bitPattern: try read32(data, cslg.range.lowerBound + 12 + $0 * 4)) }
                summary = CompositionSummary(shift: fields[0], least: fields[1], greatest: fields[2],
                                             start: fields[3], end: fields[4])
            }
            if let ctts, try read32(data, ctts.body.lowerBound) != 0 {
                throw Failure.unsupported("composition timing version/flags")
            }
            let shift = Int64(summary?.shift ?? 0)
            let composition = try expand("ctts", optional: true).enumerated().map { index, stored in
                let value = try timingAdd(Int64(stored), shift)
                guard let display = Int32(exactly: value) else {
                    throw Failure.limitExceeded(
                        "signed composition timing track=\(id) handler=\(kind) timescale=\(scale) sample=\(index) stored=0x\(String(stored, radix: 16)) shift=\(shift) value=\(value)")
                }
                return display
            }
            if let summary {
                let computed = try compositionSummary(durations: durations, displayOffsets: composition)
                guard summary == computed else {
                    throw Failure.corruptInput("composition summary parsed=\(summary.fields) computed=\(computed.fields)")
                }
            }
            let chunks = stbl.filter { $0.type == "stco" || $0.type == "co64" }
            guard chunks.count == 1, let chunkTable = chunks.first else { throw Failure.corruptInput("chunk table") }
            let chunkCount = Int(try read32(data, chunkTable.range.lowerBound + 12))
            let width = chunkTable.type == "stco" ? 4 : 8
            guard chunkCount > 0, chunkCount <= count, chunkTable.range.count == 16 + chunkCount * width else {
                throw Failure.corruptInput("chunk count")
            }
            let stsc = try only("stsc", stbl)
            let mapCount = Int(try read32(data, stsc.range.lowerBound + 12))
            guard mapCount > 0, mapCount <= chunkCount, stsc.range.count == 16 + mapCount * 12 else {
                throw Failure.corruptInput("sample-to-chunk table")
            }
            var maps: [(first: Int, samples: Int)] = []
            for i in 0..<mapCount {
                let p = stsc.range.lowerBound + 16 + i * 12
                let first = Int(try read32(data, p)), samples = Int(try read32(data, p + 4))
                guard first > (maps.last?.first ?? 0), first <= chunkCount,
                      samples > 0, samples <= count, try read32(data, p + 8) == 1 else {
                    throw Failure.unsupported("sample-to-chunk mapping")
                }
                maps.append((first, samples))
            }
            guard maps.first?.first == 1 else { throw Failure.corruptInput("first chunk mapping") }
            var sampleOffsets: [Int] = [], map = 0
            for chunk in 1...chunkCount {
                if map + 1 < maps.count, maps[map + 1].first == chunk { map += 1 }
                let p = chunkTable.range.lowerBound + 16 + (chunk - 1) * width
                let rawOffset = data[p..<(p + width)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                guard var offset = Int(exactly: rawOffset) else { throw Failure.corruptInput("chunk offset overflow") }
                for _ in 0..<maps[map].samples {
                    guard sampleOffsets.count < count else { throw Failure.corruptInput("excess chunk samples") }
                    let end = try add(offset, Int(sizes[sampleOffsets.count]))
                    guard mediaRanges.contains(where: { $0.lowerBound <= offset && end <= $0.upperBound }) else {
                        throw Failure.corruptInput("sample outside mdat")
                    }
                    sampleOffsets.append(offset)
                    offset = end
                }
            }
            guard sampleOffsets.count == count else { throw Failure.corruptInput("short chunk map") }
            tracks.append(SourceTrack(model: Track(
                id: id, kind: kind, timescale: scale, header: raw(tkhd), mediaHeader: raw(mdhd),
                handler: raw(hdlr), mediaInfoHeader: raw(info) + (minf.first(where: { $0.type == "hdlr" }).map(raw) ?? Data()),
                dataInfo: raw(dataInfo),
                references: parts.first(where: { $0.type == "tref" }).map(raw),
                aperture: aperture,
                edits: edits, description: raw(entry)), sampleSizes: sizes,
                durations: durations, compositionOffsets: composition,
                compositionOffsetAtom: ctts.map(raw), compositionSummaryAtom: cslg.map(raw),
                compositionSummary: summary, sampleOffsets: sampleOffsets))
        }
        guard tracks.filter({ $0.model.kind == "vide" }).count == 1,
              tracks.filter({ $0.model.kind == "soun" }).count <= 1,
              tracks.filter({ $0.model.kind == "meta" }).count <= 4 else {
            throw Failure.unsupported("track topology")
        }
        let ids = Set(tracks.map { $0.model.id })
        let extents = tracks.flatMap { track in
            zip(track.sampleOffsets, track.sampleSizes).map { ($0.0, $0.0 + Int($0.1)) }
        }.sorted { $0.0 < $1.0 }
        for index in 1..<extents.count where extents[index - 1].1 > extents[index].0 {
            throw Failure.unsupported("overlapping sample extents")
        }
        for track in tracks {
            guard let references = track.model.references else { continue }
            // tref child types are fourcc associations; every target must exist in this movie.
            var p = 8
            var associationTypes = Set<UInt32>()
            while p < references.count {
                let n = Int(try read32(references, p))
                guard n >= 12, n <= references.count - p, (n - 8) % 4 == 0,
                      (n - 8) / 4 <= ids.count,
                      references[(p + 4)..<(p + 8)].allSatisfy({ (0x20...0x7e).contains($0) }),
                      associationTypes.insert(try read32(references, p + 4)).inserted else {
                    throw Failure.corruptInput("track association")
                }
                var referents = Set<UInt32>()
                for q in stride(from: p + 8, to: p + n, by: 4) {
                    let referent = try read32(references, q)
                    guard ids.contains(referent), referents.insert(referent).inserted else {
                        throw Failure.unsupported("unmapped/repeated association")
                    }
                }
                p += n
            }
        }
        let retained = try add(multiply(data.count, 2),
                               multiply(tracks.reduce(0) { $0 + $1.sampleSizes.count }, 32))
        return Source(movie: Movie(header: raw(mvhd), timescale: movieScale,
                                   tracks: tracks.map(\.model), metadata: metadata),
                      tracks: tracks, size: size, retainedBytes: retained)
    }
}
#endif
