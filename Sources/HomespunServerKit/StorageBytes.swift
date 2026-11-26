// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Hummingbird

enum StorageBytes {
    static func add(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard lhs >= 0, rhs >= 0, !overflow else {
            throw APIError(.serviceUnavailable, code: "storage_backpressure",
                           message: "Storage byte accounting exceeds supported bounds; no original was removed.")
        }
        return sum
    }

    static func sum<S: Sequence>(_ values: S) throws -> Int64 where S.Element == Int {
        try values.reduce(Int64(0)) { try add($0, Int64($1)) }
    }
}
