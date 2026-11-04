// SPDX-License-Identifier: Apache-2.0
#if canImport(Photos)
import Foundation
import Photos

/// Asks PhotoKit whether a still and a motion file form a Live Photo, without touching the
/// photo library. Run it on every compressed pair before it is imported.
public enum LivePhotoValidator {
    public enum Outcome: Equatable, Sendable {
        case valid
        case invalid(String)
    }

    public static func validate(photo: URL, video: URL, timeout: Duration = .seconds(30)) async -> Outcome {
        await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
            let once = Once(continuation)
            let request = PHLivePhoto.request(
                withResourceFileURLs: [photo, video], placeholderImage: nil, targetSize: .zero,
                contentMode: .aspectFit
            ) { livePhoto, info in
                if let error = info[PHLivePhotoInfoErrorKey] as? Error {
                    once.finish(.invalid(error.localizedDescription))
                } else if info[PHLivePhotoInfoCancelledKey] as? Bool == true {
                    once.finish(.invalid("cancelled"))
                } else if info[PHLivePhotoInfoIsDegradedKey] as? Bool == true {
                    return
                } else if livePhoto != nil {
                    once.finish(.valid)
                } else {
                    once.finish(.invalid("not recognised as a Live Photo"))
                }
            }
            let nanoseconds = timeout.components.seconds * 1_000_000_000 + timeout.components.attoseconds / 1_000_000_000
            DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(Int(nanoseconds))) {
                if once.finish(.invalid("timed out")) { PHLivePhoto.cancelRequest(withRequestID: request) }
            }
        }
    }

    /// Resumes the continuation exactly once; PhotoKit may call back several times.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Outcome, Never>?

        init(_ continuation: CheckedContinuation<Outcome, Never>) { self.continuation = continuation }

        @discardableResult
        func finish(_ outcome: Outcome) -> Bool {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: outcome)
            return pending != nil
        }
    }
}
#endif
