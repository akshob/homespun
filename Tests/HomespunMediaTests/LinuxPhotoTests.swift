// SPDX-License-Identifier: Apache-2.0
import Foundation
import HomespunCore
import Testing
@testable import HomespunMedia

/// A big-endian EXIF block like an iPhone's: Orientation 6 in IFD0, pixel size in the EXIF IFD,
/// an Apple-style maker note, and a link to an IFD1 thumbnail.
private func sampleExif() -> Data {
    var tiff: [UInt8] = [0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x08]
    func u16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    func u32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    func entry(_ tag: Int, _ type: Int, _ count: Int, _ value: [UInt8]) -> [UInt8] {
        u16(tag) + u16(type) + u32(count) + value + [UInt8](repeating: 0, count: 4 - value.count)
    }
    let exifIFD = 8 + 2 + 2 * 12 + 4
    let makerNote = exifIFD + 2 + 3 * 12 + 4
    let note = Array("Apple iOS\0LIVE-8C1A3F52".utf8)
    tiff += u16(2) + entry(0x0112, 3, 1, u16(6)) + entry(0x8769, 4, 1, u32(exifIFD)) + u32(999)
    tiff += u16(3) + entry(0xA002, 3, 1, u16(900)) + entry(0xA003, 3, 1, u16(600))
        + entry(0x927C, 7, note.count, u32(makerNote)) + u32(0)
    tiff += note
    return Data(Array("Exif".utf8) + [0, 0] + tiff)
}

@Test func exifEditorUprightsAndKeepsEverythingElse() throws {
    let source = sampleExif()
    let edited = try ExifEditor.uprighted(source, width: 70_000, height: 200)
    #expect(edited.count == source.count)
    #expect(try ExifEditor.integer(0x0112, in: edited) == 1)
    #expect(try ExifEditor.integer(0xA002, in: edited, exifIFD: true) == 70_000)
    #expect(try ExifEditor.integer(0xA003, in: edited, exifIFD: true) == 200)
    #expect(edited.range(of: Data("Apple iOS\0LIVE-8C1A3F52".utf8)) != nil)
    // Only the orientation, the two sizes (one promoted to LONG), and the IFD1 link changed.
    let changed = zip(source, edited).enumerated().filter { $0.element.0 != $0.element.1 }.map(\.offset)
    #expect(changed.count <= 2 + 2 + 2 + 4 + 2 + 4)
    #expect(throws: ExifEditor.Failure.self) { try ExifEditor.uprighted(Data("Exif\0\0junk".utf8), width: 1, height: 1) }
}

@Test func xmpOrientationIsReset() {
    let xmp = Data(#"<rdf:Description tiff:Orientation="6"/><tiff:Orientation>8</tiff:Orientation>"#.utf8)
    let text = String(decoding: JPEGSegments.uprightXMP(xmp), as: UTF8.self)
    #expect(text == #"<rdf:Description tiff:Orientation="1"/><tiff:Orientation>1</tiff:Orientation>"#)
}

#if os(Linux)
@Suite(.serialized) struct VipsPhotoTests {
    static let identifier = "8C1A3F52-7D44-4E1B-9B2A-5F6E7D8C9A01"
    let profile = CompressionProfile(photoMaxEdge: 300)

    private func workspace(_ fixture: String) throws -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("homespun-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = try #require(Bundle.module.url(forResource: fixture, withExtension: nil, subdirectory: "Fixtures"))
        let input = directory.appendingPathComponent(fixture)
        try FileManager.default.copyItem(at: source, to: input)
        return (directory, input)
    }

    @Test(arguments: ["orient6.heic", "orient6.jpg"])
    func uprightCopyKeepsLivePhotoIdentifierAndDates(fixture: String) throws {
        let (directory, input) = try workspace(fixture)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("out.jpg")

        let result = try VipsPhotoCompressor(profile: profile).compress(input: input, output: output)

        #expect(result.mode == .compressed && result.width == 200 && result.height == 300)
        #expect(try result.sha256 == Fingerprint.sha256(of: output))
        let exif = try #require(try VipsPhotoCompressor.metadata(of: output).exif)
        #expect(try ExifEditor.integer(0x0112, in: exif) == 1)
        // Pixel-size tags are updated when the source has them (ImageIO's HEIC EXIF does not).
        let sized = fixture.hasSuffix(".jpg")
        #expect(try ExifEditor.integer(0xA002, in: exif, exifIFD: true) == (sized ? 200 : nil))
        #expect(try ExifEditor.integer(0xA003, in: exif, exifIFD: true) == (sized ? 300 : nil))
        #expect(exif.range(of: Data(Self.identifier.utf8)) != nil)
        #expect(exif.range(of: Data("2024:05:01 12:34:56".utf8)) != nil)
        #expect(exif.range(of: Data("-07:00".utf8)) != nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == [fixture, "out.jpg"].sorted())
    }

    @Test(.enabled(if: ProcessRunner.available("vips")))
    func flattensTransparencyOntoWhite() throws {
        let (directory, input) = try workspace("alpha.png")
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("out.jpg")
        let result = try VipsPhotoCompressor(profile: profile).compress(input: input, output: output)
        #expect(result.mode == .compressed && result.width == 300 && result.height == 200)
        let pixel = String(decoding: try ProcessRunner.run(["vips", "getpoint", output.path, "2", "2"]), as: UTF8.self)
        let values = pixel.split(whereSeparator: \.isWhitespace).compactMap { Double($0) }
        #expect(values.count == 3 && values.allSatisfy { $0 > 245 }, "corner pixel \(pixel)")
    }

    @Test(.enabled(if: ProcessRunner.available("vips")))
    func keepsOriginalWhenNotSmaller() throws {
        let (directory, fixture) = try workspace("orient6.jpg")
        defer { try? FileManager.default.removeItem(at: directory) }
        // Already small and heavily compressed, so a quality-80 copy is larger.
        let input = directory.appendingPathComponent("low.jpg")
        try ProcessRunner.run(["vips", "thumbnail", fixture.path, input.path + "[Q=5,keep=none]", "250"])
        let result = try VipsPhotoCompressor(profile: profile).compress(
            input: input, output: directory.appendingPathComponent("out.jpeg"))
        #expect(result.mode == .originalKeptNotSmaller && result.url.lastPathComponent == "out.jpg")
        #expect(try Data(contentsOf: result.url) == Data(contentsOf: input))
        #expect(result.width == 167 && result.height == 250)
    }

    @Test(arguments: ["orient6.heic", "orient6.jpg"])
    func flagsTruncatedInput(fixture: String) throws {
        let (directory, input) = try workspace(fixture)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = try Data(contentsOf: input)
        try data.prefix(data.count / 2).write(to: input)
        #expect(throws: PhotoCompressionError.self) {
            try VipsPhotoCompressor(profile: profile).compress(input: input, output: directory.appendingPathComponent("out.jpg"))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [fixture])
    }
}
#endif
