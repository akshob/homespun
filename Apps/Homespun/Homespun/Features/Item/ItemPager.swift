// SPDX-License-Identifier: Apache-2.0
import Photos
import SwiftUI
import UIKit

/// Where the item viewer's pages go: page `i` starts `i` strides from the left, a stride being a
/// page's width and the gap after it (like Photos). Plain arithmetic over the whole library, so no
/// page's size is ever estimated and the page shown stays put when the screen changes size.
struct PagerGeometry: Equatable {
    var page: CGSize
    var gap: CGFloat
    var count: Int

    var stride: CGFloat { page.width + gap }
    var contentSize: CGSize { CGSize(width: CGFloat(count) * stride, height: page.height) }

    func offset(of index: Int) -> CGFloat { CGFloat(min(max(index, 0), max(count - 1, 0))) * stride }

    func frame(of index: Int) -> CGRect { CGRect(origin: CGPoint(x: CGFloat(index) * stride, y: 0), size: page) }

    /// The page that most of the screen shows at this offset.
    func index(at offset: CGFloat) -> Int {
        guard count > 0, stride > 0 else { return 0 }
        return min(max(Int((offset / stride).rounded()), 0), count - 1)
    }

    /// The pages with any part between `minX` and `maxX`.
    func pages(from minX: CGFloat, to maxX: CGFloat) -> Range<Int> {
        guard count > 0, stride > 0, page.width > 0, maxX > minX else { return 0..<0 }
        let first = max(0, Int(((minX - page.width) / stride).rounded(.down)) + 1)
        let end = min(count, Int((maxX / stride).rounded(.up)))
        return first < end ? first..<end : 0..<0
    }
}

/// Lays out `PagerGeometry`: every page exactly the screen's size. The collection view is wider
/// than the screen by the gap, so paging moves one page and its gap at a time.
final class PagerLayout: UICollectionViewLayout {
    var gap: CGFloat = 0
    /// The page kept on screen when the size changes (rotating, folding, Details at the side).
    var anchor = 0
    private(set) var geometry = PagerGeometry(page: .zero, gap: 0, count: 0)

    override func prepare() {
        super.prepare()
        guard let view = collectionView else { return }
        let count = view.numberOfSections > 0 ? view.numberOfItems(inSection: 0) : 0
        geometry = PagerGeometry(page: CGSize(width: max(0, view.bounds.width - gap), height: view.bounds.height),
                                 gap: gap, count: count)
    }

    override var collectionViewContentSize: CGSize { geometry.contentSize }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        geometry.pages(from: rect.minX, to: rect.maxX).map { attributes(at: IndexPath(item: $0, section: 0)) }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        indexPath.item < geometry.count ? attributes(at: indexPath) : nil
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        newBounds.size != collectionView?.bounds.size
    }

    override func targetContentOffset(forProposedContentOffset proposedContentOffset: CGPoint) -> CGPoint {
        CGPoint(x: geometry.offset(of: anchor), y: 0)
    }

    private func attributes(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes {
        let attributes = UICollectionViewLayoutAttributes(forCellWith: indexPath)
        attributes.frame = geometry.frame(of: indexPath.item)
        return attributes
    }
}

/// The viewer's pages: a paging collection view over every item the viewer goes through (cells are
/// reused, so a library of tens of thousands costs no more than a few pages): `PhotoPageCell` for a
/// photo or Live Photo, `VideoPageCell` for a video.
struct ItemPager: UIViewControllerRepresentable {
    let ids: [String]
    let start: String
    @Binding var current: String?
    @Binding var zoomed: Bool
    let playback: VideoPlayback
    var item: (String) -> (any LibraryItem)?
    /// VoiceOver's label for a page.
    var label: (String) -> String
    /// Swipe down to close: the drag so far, then where and how fast it was let go.
    var dragged: (CGSize) -> Void
    var released: (_ translation: CGSize, _ velocity: CGSize) -> Void

    func makeUIViewController(context: Context) -> ItemPagerController {
        let controller = ItemPagerController(ids: ids, start: start)
        update(controller)
        return controller
    }

    func updateUIViewController(_ controller: ItemPagerController, context: Context) {
        update(controller)
    }

    private func update(_ controller: ItemPagerController) {
        controller.item = item
        controller.playback = playback
        controller.label = label
        let current = $current, zoomed = $zoomed
        controller.shown = { current.wrappedValue = $0 }
        controller.zoomChanged = { zoomed.wrappedValue = $0 }
        controller.swipeDown.changed = dragged
        controller.swipeDown.ended = released
        controller.zoomed = zoomed.wrappedValue
        controller.update(ids: ids)
        controller.refresh()
    }
}

@MainActor
final class ItemPagerController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate {
    /// Between pages, like Photos.
    static let gap: CGFloat = 20

    var item: (String) -> (any LibraryItem)? = { _ in nil }
    var label: (String) -> String = { _ in "" }
    var playback: VideoPlayback?
    /// The page shown changed (its identifier).
    var shown: (String) -> Void = { _ in }
    /// The page shown zoomed in or back out.
    var zoomChanged: (Bool) -> Void = { _ in }
    let swipeDown = SwipeDownToClose()
    var zoomed = false {
        didSet {
            collectionView.isScrollEnabled = !zoomed
            swipeDown.enabled = !zoomed
        }
    }

    private(set) var ids: [String]
    /// The page shown: the one a swipe ended on.
    private(set) var index: Int
    /// The page under the middle of the screen (another while a swipe is under way).
    private var middle: Int
    private let layout = PagerLayout()
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
    private let images = ItemImages()
    /// The size is changing: offsets in between don't say which page is shown.
    private var resizing = false
    /// Paging, for the performance monitor.
    private var moving = false
    private var front = false

    init(ids: [String], start: String) {
        self.ids = ids
        index = ids.firstIndex(of: start) ?? 0
        middle = index
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.clipsToBounds = true
        layout.gap = Self.gap
        layout.anchor = index
        collectionView.backgroundColor = .clear
        collectionView.isPagingEnabled = true
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.showsVerticalScrollIndicator = false
        collectionView.alwaysBounceVertical = false
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.insetsLayoutMarginsFromSafeArea = false
        collectionView.decelerationRate = .fast
        // Pages are paged through, never chosen.
        collectionView.allowsSelection = false
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(PhotoPageCell.self, forCellWithReuseIdentifier: PhotoPageCell.reuse)
        collectionView.register(VideoPageCell.self, forCellWithReuseIdentifier: VideoPageCell.reuse)
        collectionView.accessibilityIdentifier = "item.viewer"
        view.addSubview(collectionView)
        swipeDown.attach(to: collectionView)
        images.ready = { [weak self] id in self?.imageReady(id) }
        tellPosition()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let frame = CGRect(x: 0, y: 0, width: view.bounds.width + Self.gap, height: view.bounds.height)
        guard collectionView.frame != frame else { return }
        // Keep the page shown: a new width moves every page, and UIKit keeps the old offset.
        resizing = true
        layout.anchor = index
        middle = index
        collectionView.frame = frame
        layout.invalidateLayout()
        collectionView.contentOffset = CGPoint(x: CGFloat(index) * frame.width, y: 0)
        let scale = traitCollection.displayScale
        images.resize(CGSize(width: view.bounds.width * scale, height: view.bounds.height * scale))
        collectionView.layoutIfNeeded()
        resizing = false
        // The neighbours once the page shown is on screen (opening the viewer doesn't wait for them).
        Task { @MainActor [weak self] in self?.preload() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        front = true
        refresh()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        front = false
        playback?.pause()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        playback?.pause()
        settled()
        images.stopCaching()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        preload()
    }

    // MARK: Updates from SwiftUI

    /// The items changed (the library changed while the viewer is open): the same item stays shown,
    /// or the one now in its place if it's gone.
    func update(ids new: [String]) {
        guard new != ids else { return }
        let id = ids.indices.contains(index) ? ids[index] : nil
        ids = new
        index = id.flatMap { new.firstIndex(of: $0) } ?? min(index, max(new.count - 1, 0))
        middle = index
        guard isViewLoaded else { return }
        resizing = true
        layout.anchor = index
        collectionView.reloadData()
        collectionView.contentOffset = CGPoint(x: CGFloat(index) * collectionView.bounds.width, y: 0)
        collectionView.layoutIfNeeded()
        resizing = false
        preload()
        tellPosition()
        if new.indices.contains(index), new[index] != id {
            let id = new[index], report = shown
            // Not during SwiftUI's update.
            Task { @MainActor in report(id) }
        }
    }

    /// Redraws the pages on hand whose words or state changed.
    func refresh() {
        guard isViewLoaded else { return }
        for path in collectionView.indexPathsForVisibleItems {
            if let cell = collectionView.cellForItem(at: path) { configure(cell, at: path.item) }
        }
    }

    // MARK: Pages

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { ids.count }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let item = ids.indices.contains(indexPath.item) ? self.item(ids[indexPath.item]) : nil
        let kind = item?.itemKind == .video ? VideoPageCell.reuse : PhotoPageCell.reuse
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: kind, for: indexPath)
        configure(cell, at: indexPath.item, item: item)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell,
                        forItemAt indexPath: IndexPath) {
        (cell as? VideoPageCell)?.endDisplaying()
    }

    /// Full-size media loads only on the page shown; video playback waits until the viewer appears.
    private func configure(_ cell: UICollectionViewCell, at item: Int, item known: (any LibraryItem)? = nil) {
        guard ids.indices.contains(item) else { return }
        let id = ids[item], current = item == index, placeholder = images.image(id)
        if let cell = cell as? PhotoPageCell {
            cell.show(id: id, item: { known ?? self.item(id) }, current: current, label: label(id), placeholder: placeholder,
                      images: images) { [weak self] zoomed in self?.zoomed(id, zoomed) }
            return
        }
        guard let cell = cell as? VideoPageCell, let playback else { return }
        cell.show(id: id, item: { known ?? self.item(id) }, current: current && (front || playback.id == id), label: label(id),
                  placeholder: placeholder, images: images, playback: playback)
    }

    private func zoomed(_ id: String, _ zoomed: Bool) {
        guard ids.indices.contains(index), ids[index] == id else { return }
        zoomChanged(zoomed)
    }

    private func imageReady(_ id: String) {
        for path in collectionView.indexPathsForVisibleItems where ids.indices.contains(path.item) && ids[path.item] == id {
            if let cell = collectionView.cellForItem(at: path) { configure(cell, at: path.item) }
        }
    }

    /// Screen-size images of the neighbours, so a swipe never shows an empty page.
    private func preload() {
        images.keep(ids: ids, around: index, item: item)
    }

    // MARK: Scrolling

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !resizing, layout.geometry.stride > 0 else { return }
        let page = layout.geometry.index(at: scrollView.contentOffset.x)
        // Past half a page, its neighbours start loading.
        if page != middle, ids.indices.contains(page) {
            middle = page
            images.keep(ids: ids, around: page, item: item)
        }
        // Moved by VoiceOver or code rather than a finger: shown at once.
        if !scrollView.isTracking, !scrollView.isDecelerating { show(page) }
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { landed(scrollView) }

    /// The page a swipe ends on is the one shown: its full-size image loads (not while the pages
    /// move), and the title, toolbar and Details follow it.
    private func landed(_ scrollView: UIScrollView) {
        guard !resizing, layout.geometry.stride > 0 else { return }
        show(layout.geometry.index(at: scrollView.contentOffset.x))
    }

    private func show(_ page: Int) {
        guard page != index, ids.indices.contains(page) else { return }
        let old = index
        if ids.indices.contains(old) { playback?.unload(id: ids[old]) }
        index = page
        middle = page
        layout.anchor = page
        for item in [old, page] {
            if let cell = collectionView.cellForItem(at: IndexPath(item: item, section: 0)) { configure(cell, at: item) }
        }
        preload()
        tellPosition()
        shown(ids[page])
    }

    /// Which item of how many, for the UI tests (the pager isn't an element VoiceOver stops on).
    private func tellPosition() {
        collectionView.accessibilityValue = ids.isEmpty ? nil : "Item \(index + 1) of \(ids.count)"
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        guard !moving else { return }
        moving = true
        PerfMonitor.shared.scrollBegan()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard !decelerate else { return }
        landed(scrollView)
        settled()
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        landed(scrollView)
        settled()
    }

    private func settled() {
        guard moving else { return }
        moving = false
        PerfMonitor.shared.scrollEnded()
    }
}

/// Screen-size images for the viewer's pages: PhotoKit caches a few either side of the page shown,
/// and the nearest neighbours are decoded ahead, so a page appears with its photo already there.
@MainActor
final class ItemImages {
    /// Neighbours PhotoKit caches, and those decoded ahead, each side of the page shown.
    static let cacheReach = 3
    static let decodeReach = 1

    var ready: (String) -> Void = { _ in }
    /// One for every viewer opened (setting one up is slow enough to delay opening).
    private static let shared = PHCachingImageManager()
    private let manager = ItemImages.shared
    private var pixels = CGSize.zero
    private var decoded: [String: UIImage] = [:]
    private var loading: [String: Task<Void, Never>] = [:]
    /// What PhotoKit caches (a library with its own items, the demo's, caches nothing there).
    private var cached: [String: PHAsset] = [:]
    /// The items within reach of the page shown (`cached` has those from Photos).
    private var held: [String: any LibraryItem] = [:]

    private static let options: PHImageRequestOptions = {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = true
        return options
    }()

    func image(_ id: String) -> UIImage? { decoded[id] }

    /// The screen's size in pixels: a new one lets go of everything loaded at the old.
    func resize(_ pixels: CGSize) {
        guard pixels != self.pixels else { return }
        stopCaching()
        decoded = [:]
        loading.values.forEach { $0.cancel() }
        loading = [:]
        self.pixels = pixels
    }

    /// Keeps the images around `index`, and lets go of the rest.
    func keep(ids: [String], around index: Int, item lookup: (String) -> (any LibraryItem)?) {
        guard pixels.width > 0, pixels.height > 0, !ids.isEmpty, ids.indices.contains(index) else { return }
        func around(_ reach: Int) -> ArraySlice<String> {
            ids[max(0, index - reach)...min(ids.count - 1, index + reach)]
        }
        let far = Set(around(Self.cacheReach)), near = Set(around(Self.decodeReach))
        let gone = cached.filter { !far.contains($0.key) }
        if !gone.isEmpty {
            manager.stopCachingImages(for: Array(gone.values), targetSize: pixels, contentMode: .aspectFit, options: Self.options)
            for id in gone.keys { cached[id] = nil }
        }
        for id in held.keys where !far.contains(id) { held[id] = nil }
        var start: [PHAsset] = []
        for id in far where held[id] == nil {
            guard let item = lookup(id) else { continue }
            held[id] = item
            guard let asset = item as? PHAsset else { continue }
            cached[id] = asset
            start.append(asset)
        }
        if !start.isEmpty {
            manager.startCachingImages(for: start, targetSize: pixels, contentMode: .aspectFit, options: Self.options)
        }
        for id in decoded.keys where !near.contains(id) { decoded[id] = nil }
        for (id, task) in loading where !near.contains(id) {
            task.cancel()
            loading[id] = nil
        }
        for id in near where decoded[id] == nil && loading[id] == nil {
            guard let item = held[id] else { continue }
            loading[id] = Task { [weak self] in
                let image = await self?.load(item)
                guard let self, !Task.isCancelled else { return }
                self.loading[id] = nil
                guard let image else { return }
                self.decoded[id] = image
                self.ready(id)
            }
        }
    }

    /// Lets PhotoKit forget what this viewer cached (when it closes, or the size changes).
    func stopCaching() {
        held = [:]
        guard !cached.isEmpty else { return }
        manager.stopCachingImages(for: Array(cached.values), targetSize: pixels, contentMode: .aspectFit, options: Self.options)
        cached = [:]
    }

    /// The screen-size image, decoded: one loaded ahead, or from PhotoKit (its cache, usually).
    func load(_ item: any LibraryItem) async -> UIImage? {
        if let image = decoded[item.localIdentifier] { return image }
        guard pixels.width > 0 else { return nil }
        guard let asset = item as? PHAsset else {
            let image = await item.image(size: pixels, fast: false)
            return await image?.byPreparingForDisplay() ?? image
        }
        let manager = manager, pixels = pixels, options = Self.options
        let image: UIImage? = await withCheckedContinuation { continuation in
            manager.requestImage(for: asset, targetSize: pixels, contentMode: .aspectFit, options: options) { image, _ in
                continuation.resume(returning: image)
            }
        }
        return await image?.byPreparingForDisplay() ?? image
    }
}

/// Swipe down to close the item, like Photos: a vertical pan on the pager (it covers photos and
/// videos), which the paging and zooming scroll views wait for. A drag that starts sideways fails it
/// at once, so paging stays immediate; it's off while the item is zoomed in (the drag pans the photo
/// then).
@MainActor
final class SwipeDownToClose: NSObject, UIGestureRecognizerDelegate {
    var changed: (CGSize) -> Void = { _ in }
    var ended: (_ translation: CGSize, _ velocity: CGSize) -> Void = { _, _ in }
    var enabled = true {
        didSet { pan.isEnabled = enabled }
    }

    private lazy var pan: UIPanGestureRecognizer = {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.delegate = self
        pan.maximumNumberOfTouches = 1
        return pan
    }()

    func attach(to view: UIScrollView) {
        view.addGestureRecognizer(pan)
    }

    /// Starts only for a drag that's mostly downward.
    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard let pan = gesture as? UIPanGestureRecognizer else { return false }
        let velocity = pan.velocity(in: nil)
        return velocity.y > 0 && velocity.y > abs(velocity.x) * 1.2
    }

    /// The scroll views' pans wait for it.
    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        other is UIPanGestureRecognizer && other.view is UIScrollView
    }

    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        let translation = pan.translation(in: nil), velocity = pan.velocity(in: nil)
        switch pan.state {
        case .changed: changed(CGSize(width: translation.x, height: translation.y))
        case .ended: ended(CGSize(width: translation.x, height: translation.y), CGSize(width: velocity.x, height: velocity.y))
        case .cancelled, .failed: ended(.zero, .zero)
        default: break
        }
    }
}
