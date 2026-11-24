// SPDX-License-Identifier: Apache-2.0
import AVFoundation
import ImageIO
import Photos
import UIKit

/// Reads an item's media from PhotoKit and from downloaded files, for the viewer, Details and
/// Compare.
enum ItemMedia {
    /// The main resource (the photo, or the video) and the Live Photo motion, current versions.
    static func resources(_ asset: PHAsset) -> (main: PHAssetResource?, motion: PHAssetResource?) {
        let resources = PHAssetResource.assetResources(for: asset)
        let main = asset.mediaType == .video ? PhotoLibrary.current(resources, .fullSizeVideo, .video)
            : PhotoLibrary.current(resources, .fullSizePhoto, .photo)
        let motion = asset.mediaSubtypes.contains(.photoLive)
            ? PhotoLibrary.current(resources, .fullSizePairedVideo, .pairedVideo) : nil
        return (main, motion)
    }

    static func bytes(_ resource: PHAssetResource?) -> Int? {
        (resource?.value(forKey: "fileSize") as? NSNumber)?.intValue
    }

    /// Size, format and dimensions of the item, and the size of its Live Photo motion.
    static func facts(_ asset: PHAsset) -> (main: MediaFacts, motion: Int?) {
        let (main, motion) = resources(asset)
        return (MediaFacts(bytes: bytes(main), format: MediaFacts.format(uti: main?.uniformTypeIdentifier),
                           width: asset.pixelWidth, height: asset.pixelHeight), bytes(motion))
    }

    /// One image from PhotoKit (downloading from iCloud if needed). `size` nil: full size.
    @MainActor static func image(_ asset: PHAsset, size: CGSize?, fast: Bool = false) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = fast ? .fastFormat : .highQualityFormat
        options.resizeMode = fast ? .fast : .exact
        options.isNetworkAccessAllowed = !fast
        let target = size ?? PHImageManagerMaximumSize
        let manager = Unchecked(value: PHImageManager.default())
        let image = await PhotoRequest<Unchecked<UIImage?>>.value(cancelled: Unchecked(value: nil),
                                                                 cancel: { manager.value.cancelImageRequest($0) }) { finish in
            manager.value.requestImage(for: asset, targetSize: target, contentMode: .aspectFit,
                                 options: options) { image, info in
                if !fast, info?[PHImageResultIsDegradedKey] as? Bool == true { return }
                finish(Unchecked(value: image))
            }
        }.value
        guard !Task.isCancelled else { return nil }
        return await image?.byPreparingForDisplay() ?? image
    }

    @MainActor static func livePhoto(_ asset: PHAsset, size: CGSize) async -> PHLivePhoto? {
        let options = PHLivePhotoRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        let manager = Unchecked(value: PHImageManager.default())
        let box = await PhotoRequest<Unchecked<PHLivePhoto?>>.value(cancelled: Unchecked(value: nil),
                                                                   cancel: { manager.value.cancelImageRequest($0) }) { finish in
            manager.value.requestLivePhoto(for: asset, targetSize: size, contentMode: .aspectFit,
                                     options: options) { photo, info in
                if info?[PHImageResultIsDegradedKey] as? Bool == true { return }
                finish(Unchecked(value: photo))
            }
        }
        return box.value
    }

    @MainActor static func playerItem(_ asset: PHAsset) async -> Result<AVPlayerItem, Error> {
        let options = PHVideoRequestOptions()
        options.deliveryMode = .automatic
        options.isNetworkAccessAllowed = true
        let manager = Unchecked(value: PHImageManager.default())
        let box = await PhotoRequest<Unchecked<Result<AVPlayerItem, Error>>>.value(
            cancelled: Unchecked(value: .failure(CancellationError())), cancel: { manager.value.cancelImageRequest($0) }
        ) { finish in
            manager.value.requestPlayerItem(forVideo: asset, options: options) { item, info in
                let result: Result<AVPlayerItem, Error>
                if let item {
                    result = .success(item)
                } else {
                    result = .failure(info?[PHImageErrorKey] as? Error
                        ?? PhotoLibrary.Failure.unsupported("This video can't be played here."))
                }
                finish(Unchecked(value: result))
            }
        }
        return box.value
    }

    /// PhotoKit may call back before returning its request ID, or after cancellation.
    final class PhotoRequest<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Value, Never>?
        private var request: PHImageRequestID?
        private var finished = false
        private var cancelled = false
        private let cancelledValue: Value
        private let cancelRequest: @Sendable (PHImageRequestID) -> Void

        init(cancelled: Value, cancel: @escaping @Sendable (PHImageRequestID) -> Void) {
            cancelledValue = cancelled
            cancelRequest = cancel
        }

        @MainActor static func value(cancelled: Value, cancel: @escaping @Sendable (PHImageRequestID) -> Void,
                                     start: (@escaping @Sendable (Value) -> Void) -> PHImageRequestID) async -> Value {
            let pending = PhotoRequest(cancelled: cancelled, cancel: cancel)
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    guard pending.begin(continuation) else { return }
                    pending.install(start { pending.finish($0) })
                }
            } onCancel: { pending.cancel() }
        }

        func begin(_ continuation: CheckedContinuation<Value, Never>) -> Bool {
            lock.lock()
            let cancelled = cancelled
            if !cancelled { self.continuation = continuation }
            lock.unlock()
            if cancelled { continuation.resume(returning: cancelledValue) }
            return !cancelled
        }

        func install(_ request: PHImageRequestID) {
            lock.lock()
            let cancelled = cancelled
            if !finished { self.request = request }
            lock.unlock()
            if cancelled { cancelRequest(request) }
        }

        func finish(_ value: Value) {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true
            let continuation = continuation
            self.continuation = nil
            request = nil
            lock.unlock()
            continuation?.resume(returning: value)
        }

        func cancel() {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            cancelled = true
            finished = true
            let continuation = continuation, request = request
            self.continuation = nil
            self.request = nil
            lock.unlock()
            if let request { cancelRequest(request) }
            continuation?.resume(returning: cancelledValue)
        }
    }

    @MainActor static func player(_ asset: PHAsset) async -> AVPlayer? {
        (try? await playerItem(asset).get()).map(AVPlayer.init(playerItem:))
    }

    /// A downloaded photo, upright, with its facts.
    nonisolated static func image(at url: URL) -> (image: UIImage, facts: MediaFacts)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let upright = orientation >= 5
        let facts = MediaFacts(bytes: try? PhotoLibrary.size(of: url),
                               format: MediaFacts.format(uti: CGImageSourceGetType(source) as String?),
                               width: upright ? height : width, height: upright ? width : height)
        return (UIImage(cgImage: image), facts)
    }

    /// A downloaded video's facts: size, container and upright dimensions.
    nonisolated static func videoFacts(at url: URL) async -> MediaFacts {
        var facts = MediaFacts(bytes: try? PhotoLibrary.size(of: url))
        if let handle = try? FileHandle(forReadingFrom: url) {
            facts.format = MediaFacts.videoFormat(header: (try? handle.read(upToCount: 12)) ?? Data())
            try? handle.close()
        }
        if let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first,
           let loaded = try? await track.load(.naturalSize, .preferredTransform) {
            let upright = loaded.0.applying(loaded.1)
            facts.width = Int(abs(upright.width).rounded())
            facts.height = Int(abs(upright.height).rounded())
        }
        return facts
    }
}

extension MediaFacts {
    /// "MOV" or "MP4" from the start of an ISO media file (its `ftyp` brand).
    static func videoFormat(header: Data) -> String? {
        let bytes = [UInt8](header.prefix(12))
        guard bytes.count == 12, String(decoding: bytes[4..<8], as: UTF8.self) == "ftyp" else { return nil }
        return String(decoding: bytes[8..<12], as: UTF8.self) == "qt  " ? "MOV" : "MP4"
    }
}
