// SPDX-License-Identifier: Apache-2.0
import Photos
import UIKit

/// The grid's thumbnails, as in Apple's "Browsing and Modifying Photo Albums": each cell asks Photos'
/// caching image manager for its item at the cell's size in pixels (a quick low-quality picture
/// first when there is one, then the sharp one), and the manager keeps the next screens ready: a
/// window of items around what's on screen, reaching further in the direction of scrolling, whose
/// changes start and stop caching as it moves. High-quality caching stays off so fast scrolling
/// stays quick; thumbnails are never downloaded. A catalog (the demo's sample photos) makes its own
/// thumbnails: nothing is cached in Photos then.
@MainActor
final class GridThumbnails {
    let manager: PHCachingImageManager?
    private let source: () -> AssetSource
    private let catalog: (any ItemCatalog)?
    /// The thumbnails' side in pixels (a cell's side on screen).
    private(set) var pixels: CGFloat = 0
    /// The items being kept ready (positions in `order`).
    private(set) var window: Range<Int> = 0..<0
    /// Items the collection view asked to prefetch that the window didn't cover (yet).
    private(set) var prefetched = Set<String>()
    private var order: [String] = []

    init(manager: PHCachingImageManager?, source: @escaping () -> AssetSource, catalog: (any ItemCatalog)? = nil) {
        self.manager = manager
        self.source = source
        self.catalog = catalog
        manager?.allowsCachingHighQualityImages = false
    }

    private static let queue = DispatchQueue(label: "photos.homespun.preheat", qos: .userInitiated)

    nonisolated static func options() -> PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        return options
    }

    /// A thumbnail on its way (cancelled when its cell shows another item).
    enum Request {
        case photos(PHImageRequestID)
        case catalog(Task<Void, Never>)
    }

    /// Asks for an item's thumbnail; `handler` gets each picture on the main thread (the quick one
    /// may come before this returns), and whether it's the last. Nil: the item is gone.
    func request(_ id: String, pixels: CGFloat,
                 handler: @escaping @MainActor (UIImage, _ final: Bool) -> Void) -> Request? {
        if let catalog {
            return .catalog(Task {
                guard let image = await catalog.thumbnail(id, side: pixels), !Task.isCancelled else { return }
                let prepared = await image.byPreparingForDisplay() ?? image
                guard !Task.isCancelled else { return }
                handler(prepared, true)
            })
        }
        guard let manager, let asset = source().asset(id) else { return nil }
        let deliver = Delivery(handler: handler)
        return .photos(manager.requestImage(for: asset, targetSize: CGSize(width: pixels, height: pixels), contentMode: .aspectFill,
                                            options: Self.options()) { image, info in
            let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            guard let image else { return }
            deliver.send(image, final: !degraded)
        })
    }

    func cancel(_ request: Request) {
        switch request {
        case .photos(let id): manager?.cancelImageRequest(id)
        case .catalog(let task): task.cancel()
        }
    }

    /// Hands a picture to the main thread (Photos calls back on the main thread or its own).
    private struct Delivery: @unchecked Sendable {
        let handler: @MainActor (UIImage, Bool) -> Void

        func send(_ image: UIImage, final: Bool) {
            if Thread.isMainThread {
                MainActor.assumeIsolated { handler(image, final) }
            } else {
                let image = Unchecked(value: image)
                DispatchQueue.main.async { MainActor.assumeIsolated { handler(image.value, final) } }
            }
        }
    }

    /// New items or a new size: the window starts again.
    func reset(order: [String], pixels: CGFloat) {
        if let manager, pixels != self.pixels || !window.isEmpty || !prefetched.isEmpty {
            let manager = Unchecked(value: manager)
            Self.queue.async { manager.value.stopCachingImagesForAllAssets() }
        }
        self.order = order
        self.pixels = pixels
        window = 0..<0
        prefetched = []
    }

    /// Keeps the thumbnails of `wanted` (positions in the order) ready, and lets go of the rest.
    func keep(_ wanted: Range<Int>) {
        let wanted = wanted.clamped(to: 0..<order.count)
        guard wanted != window, pixels > 0, catalog == nil else { return }
        let (start, stop) = PreheatWindow.changes(from: window, to: wanted)
        window = wanted
        // Prefetched ahead of the window, they're cached already: the window takes them over (and
        // stops them when it moves on).
        let starting = start.flatMap { order[$0] }.filter { prefetched.remove($0) == nil }
        cache(start: starting, stop: stop.flatMap { order[$0] })
    }

    /// The collection view expects to show these soon (positions in the order).
    func prefetch(_ positions: [Int]) {
        let new = positions.filter { order.indices.contains($0) && !window.contains($0) }.map { order[$0] }
            .filter { !prefetched.contains($0) }
        guard !new.isEmpty, pixels > 0, catalog == nil else { return }
        prefetched.formUnion(new)
        cache(start: new, stop: [])
    }

    func cancelPrefetching(_ positions: [Int]) {
        let gone = positions.filter { order.indices.contains($0) && !window.contains($0) }.map { order[$0] }
            .filter { prefetched.contains($0) }
        guard !gone.isEmpty else { return }
        prefetched.subtract(gone)
        cache(start: [], stop: gone)
    }

    private func cache(start: [String], stop: [String]) {
        guard let manager, !start.isEmpty || !stop.isEmpty else { return }
        let size = CGSize(width: pixels, height: pixels), source = source(), managerBox = Unchecked(value: manager)
        // Reading assets faults them in from Photos' database: in the background, in order.
        Self.queue.async {
            if !stop.isEmpty {
                managerBox.value.stopCachingImages(for: source.assets(stop), targetSize: size, contentMode: .aspectFill,
                                                   options: Self.options())
            }
            if !start.isEmpty {
                managerBox.value.startCachingImages(for: source.assets(start), targetSize: size, contentMode: .aspectFill,
                                                    options: Self.options())
            }
        }
    }
}

/// Which part of the grid to keep thumbnails ready for, and what changes when it moves. Pure, so
/// it's tested without Photos.
enum PreheatWindow {
    /// What's visible (heights in the grid), with a screen more ahead in the direction of scrolling
    /// (positive: toward the end, the newest) and half a screen behind; still, most of a screen each way.
    static func band(visible: ClosedRange<CGFloat>, direction: CGFloat) -> ClosedRange<CGFloat> {
        let height = visible.upperBound - visible.lowerBound
        let (before, after): (CGFloat, CGFloat) = direction > 0 ? (0.5, 1) : direction < 0 ? (1, 0.5) : (0.75, 0.75)
        return (visible.lowerBound - height * before)...(visible.upperBound + height * after)
    }

    /// Whether the window should follow: once the visible part moved by a third of its height.
    static func moved(from old: ClosedRange<CGFloat>?, to new: ClosedRange<CGFloat>) -> Bool {
        guard let old else { return true }
        return abs((new.lowerBound + new.upperBound) - (old.lowerBound + old.upperBound)) / 2 > (new.upperBound - new.lowerBound) / 3
    }

    /// The items to start and stop caching when the window goes from `old` to `new`.
    static func changes(from old: Range<Int>, to new: Range<Int>) -> (start: [Range<Int>], stop: [Range<Int>]) {
        (subtract(old, from: new), subtract(new, from: old))
    }

    private static func subtract(_ other: Range<Int>, from range: Range<Int>) -> [Range<Int>] {
        guard !range.isEmpty else { return [] }
        guard !other.isEmpty, range.overlaps(other) else { return [range] }
        var parts: [Range<Int>] = []
        if range.lowerBound < other.lowerBound { parts.append(range.lowerBound..<other.lowerBound) }
        if range.upperBound > other.upperBound { parts.append(other.upperBound..<range.upperBound) }
        return parts
    }
}
