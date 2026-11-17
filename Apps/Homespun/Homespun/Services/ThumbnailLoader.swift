// SPDX-License-Identifier: Apache-2.0
import Photos
import UIKit

/// Small square thumbnails from Photos for UIKit collections of items (Free Up Space's compact
/// copies, a row of items in Needs Attention): through a caching manager, cached ahead for the
/// cells about to show (the collection view's prefetching), cancelled when a cell takes another item.
@MainActor
final class ThumbnailLoader {
    let manager: PHCachingImageManager
    /// The requested size, in pixels.
    let pixels: CGSize
    private var assets: [String: PHAsset] = [:]
    private var cached: [String: PHAsset] = [:]

    init(manager: PHCachingImageManager, side: CGFloat, scale: CGFloat) {
        self.manager = manager
        pixels = Self.pixels(side: side, scale: scale)
    }

    /// Enough pixels for the side on this screen.
    static func pixels(side: CGFloat, scale: CGFloat) -> CGSize {
        let pixels = (side * max(scale, 1)).rounded(.up)
        return CGSize(width: pixels, height: pixels)
    }

    private static func options() -> PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        return options
    }

    /// Starts loading an item's thumbnail: `deliver` gets a quick one, then the sharp one.
    func request(_ id: String, deliver: @escaping @MainActor @Sendable (UIImage) -> Void) -> PHImageRequestID? {
        guard let asset = asset(id) else { return nil }
        return manager.requestImage(for: asset, targetSize: pixels, contentMode: .aspectFill, options: Self.options()) { image, _ in
            guard let image else { return }
            if Thread.isMainThread {
                MainActor.assumeIsolated { deliver(image) }
            } else {
                Task { @MainActor in deliver(image) }
            }
        }
    }

    func cancel(_ request: PHImageRequestID) {
        manager.cancelImageRequest(request)
    }

    /// Caches the thumbnails of items about to show.
    func preheat(_ ids: [String]) {
        fetch(ids)
        let new = ids.compactMap { id in cached[id] == nil ? assets[id] : nil }
        guard !new.isEmpty else { return }
        for asset in new { cached[asset.localIdentifier] = asset }
        manager.startCachingImages(for: new, targetSize: pixels, contentMode: .aspectFill, options: Self.options())
    }

    /// Items no longer about to show.
    func stopPreheating(_ ids: [String]) {
        let gone = ids.compactMap { cached.removeValue(forKey: $0) }
        guard !gone.isEmpty else { return }
        manager.stopCachingImages(for: gone, targetSize: pixels, contentMode: .aspectFill, options: Self.options())
    }

    func stopPreheatingAll() {
        stopPreheating(Array(cached.keys))
    }

    private func asset(_ id: String) -> PHAsset? {
        if assets[id] == nil { fetch([id]) }
        return assets[id]
    }

    /// The assets of the items, fetched together (one fetch for a screenful).
    private func fetch(_ ids: [String]) {
        let missing = ids.filter { assets[$0] == nil }
        guard !missing.isEmpty else { return }
        PHAsset.fetchAssets(withLocalIdentifiers: missing, options: nil).enumerateObjects { asset, _, _ in
            self.assets[asset.localIdentifier] = asset
        }
    }
}
