// SPDX-License-Identifier: Apache-2.0
// Small synthetic photos taken over many past months (EXIF dates), for UI tests that need a
// library spread over months (month headers, scrolling across them):
//   swift ci/dated-photos.swift <folder> <count> [per month, 12]
// The oldest is first; each month gets `per month` photos, one a day, ending last month.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count >= 3, let count = Int(arguments[2]) else {
    print("usage: swift dated-photos.swift <folder> <count> [per month]")
    exit(2)
}
let folder = URL(fileURLWithPath: arguments[1])
let perMonth = arguments.count > 3 ? Int(arguments[3]) ?? 12 : 12
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
let calendar = Calendar(identifier: .gregorian)
let formatter = DateFormatter()
formatter.locale = Locale(identifier: "en_US_POSIX")
formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
let thisMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: Date()))!
let months = (count + perMonth - 1) / perMonth

for index in 0..<count {
    let month = calendar.date(byAdding: .month, value: index / perMonth - months, to: thisMonth)!
    let date = calendar.date(byAdding: DateComponents(day: index % perMonth, hour: 12), to: month)!
    let width = 320, height = 240
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { exit(1) }
    // A colour per photo and a band per month, so screenshots tell them apart.
    let hue = Double(index % perMonth) / Double(perMonth)
    context.setFillColor(CGColor(red: 0.3 + 0.6 * hue, green: 0.5, blue: 0.9 - 0.6 * hue, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(gray: Double((index / perMonth) % 5) / 5, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: 40))
    let url = folder.appendingPathComponent(String(format: "DATED_%05d.JPG", index))
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { exit(1) }
    let stamp = formatter.string(from: date)
    let properties: [CFString: Any] = [
        kCGImageDestinationLossyCompressionQuality: 0.7,
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: stamp, kCGImagePropertyExifDateTimeDigitized: stamp],
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFDateTime: stamp],
    ]
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { exit(1) }
}
print("\(count) photos over \(months) months in \(folder.path)")
