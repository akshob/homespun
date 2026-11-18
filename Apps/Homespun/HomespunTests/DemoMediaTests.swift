// SPDX-License-Identifier: Apache-2.0
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import Homespun

@Suite(.serialized) struct DemoMediaTests {
    // Checked against the old bundled pictures before removing them from the bundle.
    static let golden: [String: UInt64] = [
        "IMG_0102": 0x107170B53572B8B0, "IMG_0105": 0xBB3B30272F000000, "IMG_0109": 0xC3C3E28912000081,
        "IMG_0215": 0x0838383858B88C00, "IMG_0219": 0xCEB83001091CBC00, "IMG_0224": 0xE3C5E4606068E600,
        "IMG_0231": 0xE3F5E110B2F0F200, "IMG_0238": 0xE6E6E6E666E2E500, "IMG_0301": 0x18383842F5000000,
        "IMG_0305": 0xD8583A5CD9B00000, "IMG_0309": 0x7AFA785830000000, "IMG_0352": 0x6CEB8DE8E0F00000,
        "IMG_0358": 0x70F0949541818191, "IMG_0361": 0x6061A37102959495, "IMG_0420": 0xC0C0C0CBCA000000,
        "IMG_0428": 0xE863660000000000, "IMG_0510": 0xB02DE4070F000000, "IMG_0514": 0x40C0C0E0C9820000,
        "IMG_0517": 0x4080C0CF0CD5B39C, "IMG_0519": 0xE4CD1C0E0DA6C9A4, "IMG_0640": 0x307070B38D71B2B9,
        "IMG_0644": 0x9933314C50B8B1F0, "IMG_0651": 0x7878380F1CB6266A, "IMG_0655": 0x000070D4CC700000,
        "IMG_0941": 0x0C1C1C1C00F1E000, "IMG_0944": 0x707070303802F000, "IMG_0950": 0x1C981C086CBC9C00,
        "IMG_0958": 0x507A861C3C1C0C00, "IMG_0973": 0x46C6C0F302B2C9AD, "IMG_0978": 0xF0C1C33634001000,
    ]

    @Test func bundledThumbnailsMatchTheGoldenTable() throws {
        let bundle = Bundle.main.bundleURL.appendingPathComponent("Demo")
        for (name, golden) in Self.golden {
            let actual = try Self.dHash(bundle.appendingPathComponent("thumbs/\(name).JPG"))
            print("\(name): \(String(actual, radix: 16)), \((actual ^ golden).nonzeroBitCount) bits from golden")
            #expect((actual ^ golden).nonzeroBitCount <= 4, "\(name): \(String(actual, radix: 16))")
        }
    }

    static func dHash(_ url: URL) throws -> UInt64 {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let width = image.width, height = image.height
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                            bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        var sums = [Int](repeating: 0, count: 72), counts = sums
        for y in 0..<height {
            for x in 0..<width {
                let cell = (y * 8 / height) * 9 + x * 9 / width
                sums[cell] += Int(pixels[y * width + x])
                counts[cell] += 1
            }
        }
        let cells = zip(sums, counts).map { Double($0) / Double($1) }
        var hash: UInt64 = 0
        for y in 0..<8 {
            for x in 0..<8 { hash = (hash << 1) | (cells[y * 9 + x] < cells[y * 9 + x + 1] ? 1 : 0) }
        }
        return hash
    }
}
