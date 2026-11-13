// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Microsoft's QuickXorHash, which OneDrive reports for every file, so an upload can be
/// checked against the bytes the server sent. Port of Microsoft's reference implementation.
struct QuickXorHash {
    private static let widthInBits = 160
    private static let shift = 11
    private var data: [UInt64] = [0, 0, 0]
    private var shiftSoFar = 0
    private var lengthSoFar: UInt64 = 0

    mutating func update(_ bytes: UnsafeRawBufferPointer) {
        let count = bytes.count
        guard count > 0 else { return }
        let width = Self.widthInBits
        var vectorArrayIndex = shiftSoFar / 64
        var vectorOffset = shiftSoFar % 64
        for i in 0..<min(count, width) {
            let isLastCell = vectorArrayIndex == data.count - 1
            let bitsInVectorCell = isLastCell ? width % 64 : 64
            var xored: UInt8 = 0
            var j = i
            while j < count {
                xored ^= bytes[j]
                j += width
            }
            if vectorOffset <= bitsInVectorCell - 8 {
                data[vectorArrayIndex] ^= UInt64(xored) << UInt64(vectorOffset)
            } else {
                let next = isLastCell ? 0 : vectorArrayIndex + 1
                data[vectorArrayIndex] ^= UInt64(xored) << UInt64(vectorOffset)
                data[next] ^= UInt64(xored) >> UInt64(bitsInVectorCell - vectorOffset)
            }
            vectorOffset += Self.shift
            while vectorOffset >= bitsInVectorCell {
                vectorArrayIndex = isLastCell ? 0 : vectorArrayIndex + 1
                vectorOffset -= bitsInVectorCell
            }
        }
        shiftSoFar = (shiftSoFar + Self.shift * (count % width)) % width
        lengthSoFar += UInt64(count)
    }

    mutating func update(_ data: Data) { data.withUnsafeBytes { update($0) } }

    /// The 20-byte digest.
    func finalize() -> [UInt8] {
        var result = [UInt8](repeating: 0, count: (Self.widthInBits - 1) / 8 + 1)
        for cell in 0..<data.count {
            let bytes = Swift.withUnsafeBytes(of: data[cell].littleEndian, Array.init)
            for (offset, byte) in bytes.enumerated() where cell * 8 + offset < result.count {
                result[cell * 8 + offset] = byte
            }
        }
        let length = Swift.withUnsafeBytes(of: lengthSoFar.littleEndian, Array.init)
        for i in 0..<8 { result[Self.widthInBits / 8 - 8 + i] ^= length[i] }
        return result
    }

    /// Base64, as OneDrive reports it.
    var base64: String { Data(finalize()).base64EncodedString() }

    static func of(file url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = QuickXorHash()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hash.update(chunk) }
        return hash.base64
    }
}
