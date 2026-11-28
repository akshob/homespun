// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Blocking Photos and storage queries must not occupy Swift's cooperative pool.
enum PhotoKitReads {
    private static let queue = DispatchQueue(label: "photos.homespun.photo-reads", qos: .userInitiated)

    static func run<Result: Sendable>(_ read: @escaping @Sendable () -> Result) async -> Result {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: read()) }
        }
    }
}
