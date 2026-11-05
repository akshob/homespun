// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Edits a raw EXIF block ("Exif\0\0" followed by a TIFF structure) in place, so every other
/// tag, including Apple maker notes with the Live Photo content identifier, stays byte-identical.
public enum ExifEditor {
    public enum Failure: Error, Equatable {
        case malformed(String)
    }

    static let header: [UInt8] = Array("Exif".utf8) + [0, 0]

    /// The block for an upright, resized copy: Orientation set to 1 and pixel dimensions updated.
    /// The embedded thumbnail (IFD1) is unlinked, because it still shows the old orientation.
    public static func uprighted(_ block: Data, width: Int, height: Int) throws -> Data {
        var tiff = try TIFF(block)
        let ifd0 = try tiff.ifdOffset()
        for (tag, entry) in try tiff.entries(in: ifd0) {
            switch tag {
            case 0x0112: try tiff.setInteger(at: entry, to: 1)
            case 0x0100: try tiff.setInteger(at: entry, to: width)
            case 0x0101: try tiff.setInteger(at: entry, to: height)
            default: break
            }
        }
        if let exif = try tiff.pointer(tag: 0x8769, in: ifd0) {
            for (tag, entry) in try tiff.entries(in: exif) {
                switch tag {
                case 0xA002: try tiff.setInteger(at: entry, to: width)
                case 0xA003: try tiff.setInteger(at: entry, to: height)
                default: break
                }
            }
        }
        try tiff.setNextIFD(after: ifd0, to: 0)
        return Data(header + tiff.bytes)
    }

    /// An integer tag from IFD0 (or the EXIF IFD when `exifIFD` is true), for verification.
    public static func integer(_ tag: UInt16, in block: Data, exifIFD: Bool = false) throws -> Int? {
        let tiff = try TIFF(block)
        var ifd = try tiff.ifdOffset()
        if exifIFD {
            guard let exif = try tiff.pointer(tag: 0x8769, in: ifd) else { return nil }
            ifd = exif
        }
        guard let entry = try tiff.entries(in: ifd).first(where: { $0.tag == tag }) else { return nil }
        return try tiff.integer(at: entry.offset)
    }

    private struct TIFF {
        var bytes: [UInt8]
        let bigEndian: Bool

        init(_ block: Data) throws {
            var bytes = [UInt8](block)
            if bytes.starts(with: ExifEditor.header) { bytes.removeFirst(ExifEditor.header.count) }
            guard bytes.count >= 8 else { throw Failure.malformed("too short") }
            switch (bytes[0], bytes[1]) {
            case (0x4D, 0x4D): bigEndian = true
            case (0x49, 0x49): bigEndian = false
            default: throw Failure.malformed("no TIFF byte order")
            }
            self.bytes = bytes
            guard try read16(2) == 42 else { throw Failure.malformed("no TIFF marker") }
        }

        func check(_ offset: Int, _ length: Int) throws {
            guard offset >= 0, length >= 0, offset + length <= bytes.count else {
                throw Failure.malformed("offset \(offset) out of range")
            }
        }

        func read16(_ offset: Int) throws -> Int {
            try check(offset, 2)
            let a = Int(bytes[offset]), b = Int(bytes[offset + 1])
            return bigEndian ? a << 8 | b : b << 8 | a
        }

        func read32(_ offset: Int) throws -> Int {
            try check(offset, 4)
            let parts = (0..<4).map { Int(bytes[offset + $0]) }
            return bigEndian ? parts.reduce(0) { $0 << 8 | $1 } : parts.reversed().reduce(0) { $0 << 8 | $1 }
        }

        mutating func write16(_ offset: Int, _ value: Int) throws {
            try check(offset, 2)
            let pair = [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
            bytes[offset] = bigEndian ? pair[0] : pair[1]
            bytes[offset + 1] = bigEndian ? pair[1] : pair[0]
        }

        mutating func write32(_ offset: Int, _ value: Int) throws {
            try check(offset, 4)
            let quad = (0..<4).map { UInt8(value >> (24 - 8 * $0) & 0xFF) }
            for index in 0..<4 { bytes[offset + index] = bigEndian ? quad[index] : quad[3 - index] }
        }

        func ifdOffset() throws -> Int { try read32(4) }

        /// Each entry's tag and the offset of its 12-byte record.
        func entries(in ifd: Int) throws -> [(tag: UInt16, offset: Int)] {
            let count = try read16(ifd)
            try check(ifd + 2, count * 12 + 4)
            return try (0..<count).map { index in
                let entry = ifd + 2 + index * 12
                return (UInt16(try read16(entry)), entry)
            }
        }

        func pointer(tag: UInt16, in ifd: Int) throws -> Int? {
            guard let entry = try entries(in: ifd).first(where: { $0.tag == tag }) else { return nil }
            return try read32(entry.offset + 8)
        }

        /// SHORT or LONG, count 1, stored inline in the value field.
        func integer(at entry: Int) throws -> Int {
            let type = try read16(entry + 2), count = try read32(entry + 4)
            guard count == 1 else { throw Failure.malformed("tag with \(count) values") }
            switch type {
            case 3: return try read16(entry + 8)
            case 4: return try read32(entry + 8)
            default: throw Failure.malformed("integer tag of type \(type)")
            }
        }

        mutating func setInteger(at entry: Int, to value: Int) throws {
            let type = try read16(entry + 2), count = try read32(entry + 4)
            guard count == 1 else { throw Failure.malformed("tag with \(count) values") }
            switch type {
            case 3 where value <= 0xFFFF: try write16(entry + 8, value)
            case 3:
                // Promote to LONG; the value field is 4 bytes either way.
                try write16(entry + 2, 4)
                try write32(entry + 8, value)
            case 4: try write32(entry + 8, value)
            default: throw Failure.malformed("integer tag of type \(type)")
            }
        }

        mutating func setNextIFD(after ifd: Int, to value: Int) throws {
            try write32(ifd + 2 + (try read16(ifd)) * 12, value)
        }
    }
}

/// Places EXIF and XMP segments into a JPEG that has none.
enum JPEGSegments {
    static let xmpHeader: [UInt8] = Array("http://ns.adobe.com/xap/1.0/".utf8) + [0]
    static let maximumPayload = 65_533

    /// `jpeg` with any APP1 segments removed and the given EXIF and XMP inserted after SOI
    /// (and after a JFIF APP0 segment, if present).
    static func inserting(exif: Data?, xmp: Data?, into jpeg: Data) throws -> Data {
        var bytes = [UInt8](jpeg)
        guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else {
            throw PhotoCompressionError.encodingFailed("encoder output is not a JPEG")
        }
        var index = 2
        var insertAt = 2
        while index + 4 <= bytes.count, bytes[index] == 0xFF, (0xE0...0xEF).contains(bytes[index + 1]) || bytes[index + 1] == 0xFE {
            let length = Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
            guard length >= 2, index + 2 + length <= bytes.count else {
                throw PhotoCompressionError.encodingFailed("encoder output has a damaged segment")
            }
            if bytes[index + 1] == 0xE1 {
                bytes.removeSubrange(index..<(index + 2 + length))
                continue
            }
            if bytes[index + 1] == 0xE0, index == 2 { insertAt = index + 2 + length }
            index += 2 + length
        }
        var segments: [UInt8] = []
        if let exif {
            var payload = [UInt8](exif)
            if !payload.starts(with: ExifEditor.header) { payload = ExifEditor.header + payload }
            guard payload.count <= maximumPayload else {
                throw PhotoCompressionError.encodingFailed("EXIF block larger than 64 KB")
            }
            segments += segment(payload)
        }
        // XMP beyond one segment needs Extended XMP; such files keep EXIF only.
        if let xmp, xmpHeader.count + xmp.count <= maximumPayload {
            segments += segment(xmpHeader + [UInt8](xmp))
        }
        bytes.insert(contentsOf: segments, at: insertAt)
        return Data(bytes)
    }

    private static func segment(_ payload: [UInt8]) -> [UInt8] {
        let length = payload.count + 2
        return [0xFF, 0xE1, UInt8(length >> 8), UInt8(length & 0xFF)] + payload
    }

    /// XMP with any `tiff:Orientation` set to 1, matching the upright pixels.
    static func uprightXMP(_ xmp: Data) -> Data {
        String(decoding: xmp, as: UTF8.self)
            .replacingOccurrences(of: #"tiff:Orientation="\d""#, with: #"tiff:Orientation="1""#,
                                  options: .regularExpression)
            .replacingOccurrences(of: #"<tiff:Orientation>\d</tiff:Orientation>"#,
                                  with: "<tiff:Orientation>1</tiff:Orientation>", options: .regularExpression)
            .data(using: .utf8)!
    }
}
