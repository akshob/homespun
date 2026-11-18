// SPDX-License-Identifier: Apache-2.0
import Photos
import SwiftUI
import UIKit

/// What the Library grid shows, from `LibraryView`.
struct GridInput {
    var data: GridData
    /// Bumped whenever `data` is replaced (comparing 35,000 cells on every update would cost too much).
    var dataVersion: Int
    /// The library state's version: badges changed.
    var stateVersion: Int
    var selecting: Bool
    var selectionVersion: Int
    var countsVersion: Int
    var filter: LibraryState.Filter
    var paired: Bool
    var serverName: String
    /// The person's grid size: 2, 4 or 6 columns on a phone.
    var density: Int
    /// Bumped to bring the newest items (the Library tab tapped again, Select mode's Newest).
    var newest: Int
    /// What's above the first month (the notice, or the empty state), and what it says, so it's
    /// measured again only when that changes.
    var notice: AnyView
    var noticeKey: String
}

/// What the grid does with taps, menus, drags and pinches.
struct GridActions {
    var tapped: (LibraryState.Cell) -> Void
    /// A cell's menu; the closure it gets goes before anything that opens the item (for the zoom).
    var menu: (LibraryState.Cell, _ opening: @escaping () -> Void) -> UIMenu?
    /// Drag-to-select reached this item (the first call is where the drag started).
    var dragSelect: (String) -> Void
    var dragEnded: () -> Void
    /// A pinch ended at this scale.
    var resize: (CGFloat) -> Void
}

/// The cell an item zooms out of when it opens and back into when it closes: the grid's cells are
/// UIKit, so a SwiftUI picture of the cell stands in for it as the zoom's source, over the cell.
@MainActor @Observable
final class GridZoom {
    struct Source: Equatable {
        var id: String
        /// In the grid's own coordinates (the whole screen).
        var frame: CGRect
        var image: UIImage?
    }

    var source: Source?
    /// The item the viewer shows (its `onShow`): the grid keeps its cell in view and zooms back into it.
    var shown: String?
    static let sourceID = "grid.zoom"
}

/// The zoom's stand-in, where the cell is.
struct GridZoomSource: View {
    let zoom: GridZoom
    let namespace: Namespace.ID

    var body: some View {
        if let source = zoom.source {
            Group {
                if let image = source.image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Theme.fill
                }
            }
            .frame(width: source.frame.width, height: source.frame.height)
            .clipped()
            .matchedTransitionSource(id: GridZoom.sourceID, in: namespace)
            .offset(x: source.frame.minX, y: source.frame.minY)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

/// The Library grid: a collection view with `GridLayout`, hosted in SwiftUI.
struct GridView: UIViewControllerRepresentable {
    let library: LibraryModel
    let selection: GridSelection
    let counts: SectionCounts
    let zoom: GridZoom
    var input: GridInput
    var actions: GridActions

    func makeUIViewController(context: Context) -> GridController {
        GridController(library: library, selection: selection, counts: counts, zoom: zoom, input: input, actions: actions)
    }

    func updateUIViewController(_ controller: GridController, context: Context) {
        controller.update(input, actions: actions)
    }
}

/// Runs the grid: data, cells, headers and the notice; opening at the newest; keeping the item in view
/// when the columns, the width or the items change; taps, menus, drag-to-select and pinching.
@MainActor
final class GridController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate,
    UICollectionViewDataSourcePrefetching, UIGestureRecognizerDelegate {
    private let library: LibraryModel
    private let selection: GridSelection
    private let counts: SectionCounts
    private let zoom: GridZoom
    private var input: GridInput
    private var actions: GridActions
    private var data = GridData()
    private var dataVersion = -1
    private let layout = GridLayout()
    private var collectionView: UICollectionView!
    private let thumbnails: GridThumbnails
    private let noticeHost = UIHostingController(rootView: AnyView(EmptyView()))
    private var noticeHeight: CGFloat = 0
    private var noticeMeasured: (key: String, width: CGFloat, category: UIContentSizeCategory)?
    /// The grid has been put at the newest items (or the top) once.
    private var placed = false
    /// At the newest end: stays there when the items, the width or the bars change.
    private var pinned = true
    /// Where a pinch ended, to keep the item under it in place when the columns change.
    private var pinchPoint: CGPoint?
    /// The place kept through a change of size: turning or unfolding brings a new width, then new
    /// insets, in steps; each step puts back the place from before the first, not from the step before.
    private var held: (place: Place, until: CFTimeInterval)?
    /// The place from before a turn, fold or unfold, kept until it has finished (its steps can take
    /// seconds on a busy device, and some leave a sliver of a screen between the bars).
    private var turning: Place?
    private var turns = 0
    /// The last place seen on a whole screen.
    private var lastPlace = Place.newest
    /// Where the grid was just put: for a moment, the scroll view moving by itself (a large title
    /// collapsing keeps a scroll view that was at the top there) is undone.
    private var placedAt: (y: CGFloat, until: CFTimeInterval)?
    private var lastPreheat: ClosedRange<CGFloat>?
    private var lastOffset: CGFloat = 0
    private var tracking = false

    init(library: LibraryModel, selection: GridSelection, counts: SectionCounts, zoom: GridZoom, input: GridInput,
         actions: GridActions) {
        self.library = library
        self.selection = selection
        self.counts = counts
        self.zoom = zoom
        self.input = input
        self.actions = actions
        thumbnails = GridThumbnails(manager: library.thumbnails, source: { [unowned library] in library.source },
                                    catalog: library.catalog)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = GridStyle.background
        // The safe area at the sides too: cells never go under a notch or iPhone Duo's tab strip.
        collectionView.contentInsetAdjustmentBehavior = .always
        collectionView.alwaysBounceVertical = true
        // The status bar's scroll to the top would bring the oldest items; the tab's second tap brings the newest.
        collectionView.scrollsToTop = false
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        collectionView.register(GridCell.self, forCellWithReuseIdentifier: GridCell.reuse)
        collectionView.register(MonthHeaderView.self, forSupplementaryViewOfKind: GridLayout.headerKind,
                                withReuseIdentifier: MonthHeaderView.reuse)
        collectionView.accessibilityIdentifier = "grid"
        self.collectionView = collectionView
        view = collectionView
        installGestures()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(noticeHost)
        noticeHost.didMove(toParent: self)
        noticeHost.view.backgroundColor = .clear
        // Inside the scroll view: the bars' safe area mustn't move it.
        noticeHost.safeAreaRegions = []
        noticeHost.rootView = input.notice
        // Always in the grid (not a reused view): its Set Up button stays reachable when it's scrolled away.
        collectionView.addSubview(noticeHost.view)
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self, UITraitDisplayScale.self]) { (self: GridController, _) in
            self.view.setNeedsLayout()
            self.refreshVisible()
            // The notice's text size reaches SwiftUI a moment later: measured again then.
            DispatchQueue.main.async {
                self.noticeMeasured = nil
                self.view.setNeedsLayout()
            }
        }
        apply(data: input.data, version: input.dataVersion)
        watchViewer()
        if PerfMonitor.shared.enabled {
            PerfMonitor.shared.blankProbe = { [weak self] in self?.blankCells() ?? (0, 0) }
        }
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        adoptAsContentScrollView()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        adoptAsContentScrollView()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isFront = false
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isFront = true
        lastInsets = collectionView.adjustedContentInset
        view.setNeedsLayout()
        // Back from an item: the zoom has landed, its stand-in goes.
        following?.cancel()
        let paged = viewerItem != nil
        viewerItem = nil
        if zoom.source != nil || zoom.shown != nil {
            zoom.source = nil
            zoom.shown = nil
        }
        // Back from an item: the bars may differ from when it opened (the newest end stays in view).
        if placed, pinned { setOffset(offsetRange.upperBound) }
        // The bars learn where the grid is when it scrolls: opened at the newest, the large title
        // has to collapse at once.
        let offset = collectionView.contentOffset
        collectionView.contentOffset = CGPoint(x: offset.x, y: offset.y - 1)
        collectionView.contentOffset = offset
        if paged { publishProbe() }
    }

    /// The navigation bar (its large title, its edge effect) and the tab bar (minimising on scroll,
    /// the second tap) follow the content's scroll view, which SwiftUI finds only among its own: the
    /// screens between this one and the navigation stack are told it's the grid.
    private func adoptAsContentScrollView() {
        guard isViewLoaded else { return }
        var controller: UIViewController? = self
        while let current = controller, !(current is UINavigationController), !(current is UITabBarController) {
            if current.contentScrollView(for: .top) !== collectionView { current.setContentScrollView(collectionView, for: .top) }
            if current.contentScrollView(for: .bottom) !== collectionView { current.setContentScrollView(collectionView, for: .bottom) }
            controller = current.parent
        }
    }

    // MARK: Updates from SwiftUI

    func update(_ new: GridInput, actions: GridActions) {
        let old = input
        input = new
        self.actions = actions
        if new.noticeKey != old.noticeKey {
            noticeHost.rootView = new.notice
            noticeMeasured = nil
            view.setNeedsLayout()
        }
        if new.dataVersion != dataVersion { apply(data: new.data, version: new.dataVersion) }
        if new.density != old.density {
            view.setNeedsLayout()
            view.layoutIfNeeded()
            PerfMonitor.shared.endAfterFrame("gridSize")
        }
        if new.stateVersion != old.stateVersion || new.selecting != old.selecting || new.selectionVersion != old.selectionVersion
            || new.countsVersion != old.countsVersion || new.filter != old.filter || new.paired != old.paired
            || new.serverName != old.serverName {
            refreshVisible()
        }
        selectPan.isEnabled = new.selecting
        holdDrag.isEnabled = new.selecting
        if new.newest != old.newest { showNewest() }
    }

    /// New items (a filter, the library changed): the item in view stays where it is on screen, or
    /// the newest end stays in view.
    private func apply(data new: GridData, version: Int) {
        let place = turning ?? currentPlace()
        held = nil
        let old = data
        data = new
        dataVersion = version
        layout.geometry = GridGeometry(metrics: layout.geometry.metrics, months: new.sections.map(\.range.count))
        collectionView.reloadData()
        thumbnails.reset(order: new.ids, pixels: pixels)
        lastPreheat = nil
        if let metrics = metrics() {
            layout.geometry = GridGeometry(metrics: metrics, months: new.sections.map(\.range.count))
            restore(place, old: old)
        }
        releaseInBackground(old)
        publishProbe()
    }

    // MARK: Geometry

    override func viewWillTransition(to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        let place = heldPlace() ?? currentPlace()
        turning = place
        turns += 1
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            guard let self else { return }
            self.turns -= 1
            guard self.turns == 0 else { return }
            self.turning = nil
            self.held = (place, CACurrentMediaTime() + 1)
            self.view.setNeedsLayout()
        }
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        relayout()
        let notice = CGRect(x: 0, y: 0, width: layout.geometry.metrics.width, height: noticeHeight)
        if noticeHost.view.frame != notice { noticeHost.view.frame = notice }
        noticeHost.view.isHidden = noticeHeight == 0
    }

    /// The thumbnails' side in pixels: a column's width on screen.
    private var pixels: CGFloat {
        let geometry = layout.geometry
        guard geometry.metrics.width > 0 else { return 0 }
        return (geometry.metrics.width / CGFloat(geometry.columns) * geometry.metrics.scale).rounded(.up)
    }

    private func metrics() -> GridGeometry.Metrics? {
        let insets = self.insets
        let width = collectionView.bounds.width - insets.left - insets.right
        guard width > 0, collectionView.bounds.height > 0 else { return nil }
        measureNotice(width: width)
        var metrics = GridGeometry.Metrics()
        metrics.width = width
        metrics.columns = GridColumns.count(width: width, density: input.density,
                                            accessibility: traitCollection.preferredContentSizeCategory.isAccessibilityCategory)
        metrics.header = MonthHeaderView.height(width: width, traits: traitCollection)
        metrics.top = noticeHeight > 0 ? noticeHeight + 12 : 0
        metrics.scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 3
        return metrics
    }

    /// A new width, column count, text size or notice: a new geometry, with the place kept.
    private func relayout() {
        guard let metrics = metrics(), metrics != layout.geometry.metrics || !placed && data.ids.count > 0 else { return }
        let place = heldPlace() ?? currentPlace(at: pinchPoint)
        held = (place, CACurrentMediaTime() + 1)
        pinchPoint = nil
        let before = pixels
        layout.geometry = GridGeometry(metrics: metrics, months: data.sections.map(\.range.count))
        if pixels != before {
            thumbnails.reset(order: data.ids, pixels: pixels)
            lastPreheat = nil
            // Sharper pictures for bigger cells (the old ones stay until they come).
            for case let cell as GridCell in collectionView.visibleCells { configure(cell, at: collectionView.indexPath(for: cell)) }
        }
        restore(place)
        // The viewer is open (folding or turning with an item open): its cell's new place, after this layout.
        if let viewer = viewerItem { DispatchQueue.main.async { [weak self] in self?.follow(viewer) } }
        publishProbe()
    }

    private func measureNotice(width: CGFloat) {
        let category = traitCollection.preferredContentSizeCategory
        if let measured = noticeMeasured, measured.key == input.noticeKey, measured.width == width, measured.category == category {
            return
        }
        noticeMeasured = (input.noticeKey, width, category)
        noticeHeight = input.noticeKey.isEmpty ? 0
            : noticeHost.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height.rounded(.up)
    }

    /// The bars' insets. While an item is open over the grid, the grid is out of the window and has
    /// none; it keeps the ones it had (and gets back), so following the viewer's item and the zoom's
    /// stand-in are where they'll be.
    private var insets: UIEdgeInsets {
        if collectionView.window != nil, isFront { lastInsets = collectionView.adjustedContentInset }
        return lastInsets
    }

    /// Whether the Library is the screen showing: from when it has appeared until it starts to go (an
    /// item opening over it hides the tab bar, which mustn't move the grid behind it). Folding and
    /// turning keep it showing.
    private var isFront = true

    private var lastInsets = UIEdgeInsets.zero

    /// What's visible, in the grid's coordinates: the scroll view less its bars.
    private var visibleRect: CGRect {
        let insets = self.insets, bounds = collectionView.bounds
        return CGRect(x: 0, y: bounds.minY + insets.top, width: layout.geometry.metrics.width,
                      height: max(1, bounds.height - insets.top - insets.bottom))
    }

    private var offsetRange: ClosedRange<CGFloat> {
        let insets = self.insets
        let top = -insets.top
        return top...max(top, layout.geometry.contentHeight + insets.bottom - collectionView.bounds.height)
    }

    private enum Place {
        case newest
        /// An item, where it was in the old order, and its middle's height on screen (a fraction).
        case item(String, position: Int, fraction: CGFloat)
    }

    private func heldPlace() -> Place? {
        if let turning { return turning }
        guard let held, CACurrentMediaTime() < held.until else { return nil }
        return held.place
    }

    /// Whether the bars leave a screen to see (mid-turn they can leave a sliver, or nothing).
    private var whole: Bool { collectionView.bounds.height > 0 && visibleRect.height >= 44 }

    private func currentPlace(at point: CGPoint? = nil) -> Place {
        guard placed, !pinned, layout.geometry.count > 0 else { return .newest }
        guard whole else { return lastPlace }
        guard let anchor = layout.geometry.anchor(in: visibleRect, at: point), anchor.item < data.ids.count else { return .newest }
        lastPlace = .item(data.ids[anchor.item], position: anchor.item, fraction: anchor.fraction)
        return lastPlace
    }

    private func restore(_ place: Place, old: GridData? = nil) {
        let range = offsetRange
        var y = range.upperBound
        if case .item(let id, let position, let fraction) = place, let now = self.position(of: id, was: position, in: old) {
            let top = layout.geometry.top(for: .init(item: now, fraction: fraction), visibleHeight: visibleRect.height)
            y = min(max(top - insets.top, range.lowerBound), range.upperBound)
        }
        setOffset(y)
        if layout.geometry.count > 0 { placed = true }
    }

    private func setOffset(_ y: CGFloat, animated: Bool = false) {
        let point = CGPoint(x: -insets.left, y: y)
        placedAt = animated ? nil : (y, CACurrentMediaTime() + 0.5)
        if animated { collectionView.setContentOffset(point, animated: true) } else { collectionView.contentOffset = point }
        // Mid-turn, the place from before it says whether it's at the newest end.
        if turning == nil, whole { pinned = y >= offsetRange.upperBound - 1 }
        updatePreheat()
    }

    /// Where an item is now; if it's gone (filtered out, deleted), the nearest of its old neighbours that's still here.
    private func position(of id: String, was position: Int, in old: GridData?) -> Int? {
        if let now = data.positions[id] { return now }
        guard let old else { return nil }
        for distance in 1...2_000 {
            for candidate in [position - distance, position + distance] where old.ids.indices.contains(candidate) {
                if let now = data.positions[old.ids[candidate]] { return now }
            }
            if position - distance < 0, position + distance >= old.ids.count { break }
        }
        return nil
    }

    /// The newest items at the bottom, like when the Library opens.
    private func showNewest() {
        let range = offsetRange
        let distance = range.upperBound - collectionView.contentOffset.y
        let animated = distance < collectionView.bounds.height * 2
        setOffset(range.upperBound, animated: animated)
        if !animated { publishProbe() }
    }

    // MARK: Data source

    func numberOfSections(in collectionView: UICollectionView) -> Int { max(1, data.sections.count) }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        section < data.sections.count ? data.sections[section].range.count : 0
    }

    private func position(_ indexPath: IndexPath) -> Int? {
        guard indexPath.section < data.sections.count else { return nil }
        let position = data.sections[indexPath.section].range.lowerBound + indexPath.item
        return position < data.cells.count ? position : nil
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: GridCell.reuse, for: indexPath)
        configure(cell as? GridCell, at: indexPath)
        return cell
    }

    private func configure(_ cell: GridCell?, at indexPath: IndexPath?) {
        guard let cell, let indexPath, let position = position(indexPath) else { return }
        let id = data.cells[position].id
        cell.show(id, info: library.info(id), loader: thumbnails, pixels: pixels)
        update(cell, position: position)
    }

    private func update(_ cell: GridCell, position: Int) {
        let initial = data.cells[position]
        let state = library.state.cell(initial.id) ?? initial
        cell.update(state: state, selecting: selection.active, selected: selection.active && selection.ids.contains(initial.id),
                    serverName: input.serverName)
    }

    func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String,
                        at indexPath: IndexPath) -> UICollectionReusableView {
        let view = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: MonthHeaderView.reuse, for: indexPath)
        if let header = view as? MonthHeaderView, indexPath.section < data.sections.count { configure(header, month: indexPath.section) }
        return view
    }

    private func configure(_ header: MonthHeaderView, month: Int) {
        let section = data.sections[month]
        let open = counts.open[section.id] ?? section.open
        let showsCount = input.filter == .notBackedUp || (input.filter == .all && open > 0 && input.paired)
        var button: String?
        if selection.active {
            let selectable = selectable(in: section)
            if !selectable.isEmpty { button = selectable.allSatisfy { selection.ids.contains($0) } ? "Deselect" : "Select All" }
        }
        header.show(.init(title: Self.title(section.month), count: showsCount ? "\(open) not backed up" : nil, button: button) {
            [weak self] in self?.selectMonth(section)
        })
    }

    private func selectable(in section: GridData.Section) -> [String] {
        guard section.range.upperBound <= data.cells.count else { return [] }
        return data.cells[section.range].lazy.map(\.id).filter { self.counts.selectable.contains($0) }
    }

    /// A header's Select All (or Deselect, when everything in the month is selected).
    private func selectMonth(_ section: GridData.Section) {
        let selectable = selectable(in: section)
        if selectable.allSatisfy({ selection.ids.contains($0) }) {
            selection.ids.subtract(selectable)
        } else {
            selection.ids.formUnion(selectable)
        }
    }

    private static var titles: [Int: String] = [:]
    private static let titleStyle = Date.FormatStyle.dateTime.month(.wide).year()

    static func title(_ month: Int) -> String {
        guard month > 0 else { return "Undated" }
        if let title = titles[month] { return title }
        let date = Calendar.current.date(from: DateComponents(year: month / 12, month: month % 12 + 1)) ?? .now
        let title = titleStyle.format(date)
        titles[month] = title
        return title
    }

    /// Badges, selection and month counts changed: only what's on screen is redrawn.
    private func refreshVisible() {
        guard isViewLoaded else { return }
        for case let cell as GridCell in collectionView.visibleCells {
            if let indexPath = collectionView.indexPath(for: cell), let position = position(indexPath) { update(cell, position: position) }
        }
        for indexPath in collectionView.indexPathsForVisibleSupplementaryElements(ofKind: GridLayout.headerKind)
            where indexPath.section < data.sections.count {
            if let header = collectionView.supplementaryView(forElementKind: GridLayout.headerKind, at: indexPath) as? MonthHeaderView {
                configure(header, month: indexPath.section)
            }
        }
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        // A cell made ahead of time may show an older badge or selection.
        if let cell = cell as? GridCell, let position = position(indexPath) { update(cell, position: position) }
    }

    // MARK: Prefetching

    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        thumbnails.prefetch(indexPaths.compactMap(position))
    }

    func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        thumbnails.cancelPrefetching(indexPaths.compactMap(position))
    }

    /// Keeps the thumbnails around what's visible ready, further ahead in the direction of scrolling.
    private func updatePreheat() {
        guard layout.geometry.count > 0, pixels > 0 else { return }
        let visible = visibleRect
        let range = visible.minY...visible.maxY
        guard PreheatWindow.moved(from: lastPreheat, to: range) else { return }
        let direction = lastPreheat.map { range.lowerBound - $0.lowerBound } ?? 0
        lastPreheat = range
        thumbnails.keep(layout.geometry.items(inBand: PreheatWindow.band(visible: range, direction: direction)))
    }

    // MARK: Taps and menus

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        guard let position = position(indexPath) else { return false }
        let cell = library.state.cell(data.cells[position].id) ?? data.cells[position]
        guard !selection.active else {
            actions.tapped(cell)
            return false
        }
        // The zoom's stand-in is drawn first, so the item zooms out of its cell when it opens.
        PerfMonitor.shared.begin("open")
        prepareZoom(position)
        DispatchQueue.main.async { [weak self] in self?.actions.tapped(cell) }
        return false
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
                        point: CGPoint) -> UIContextMenuConfiguration? {
        guard !selection.active, indexPaths.count == 1, let position = position(indexPaths[0]) else { return nil }
        let cell = library.state.cell(data.cells[position].id) ?? data.cells[position]
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            self?.actions.menu(cell) { [weak self] in self?.prepareZoom(position) }
        }
    }

    /// The zoom's stand-in goes over the item's cell.
    private func prepareZoom(_ position: Int) {
        guard position < data.cells.count else { return }
        let id = data.cells[position].id
        let frame = layout.geometry.frame(ofItem: position).offsetBy(dx: -collectionView.bounds.minX, dy: -collectionView.bounds.minY)
        let shown = (collectionView.cellForItem(at: indexPath(of: position)) as? GridCell).flatMap { $0.item == id ? $0.image : nil }
        zoom.source = GridZoom.Source(id: id, frame: frame, image: shown ?? (zoom.source?.id == id ? zoom.source?.image : nil))
        guard shown == nil else { return }
        _ = thumbnails.request(id, pixels: pixels) { [weak self] image, _ in
            guard let self, self.zoom.source?.id == id else { return }
            self.zoom.source?.image = image
        }
    }

    private func indexPath(of position: Int) -> IndexPath {
        let month = layout.geometry.month(ofItem: position)
        return IndexPath(item: position - layout.geometry.monthRange(month).lowerBound, section: month)
    }

    /// The item the viewer shows after paging (nil until then, and once the grid is back), followed
    /// here rather than through SwiftUI, so paging the viewer doesn't update the Library screen.
    private var viewerItem: String?
    private var following: DispatchWorkItem?

    private func watchViewer() {
        withObservationTracking { _ = zoom.shown } onChange: { [weak self] in
            // Called before the change: read it after.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.viewerChanged(self.zoom.shown)
                    self.watchViewer()
                }
            }
        }
    }

    /// The viewer showed another item. Its cell is put in view behind the viewer (like Photos) once
    /// paging pauses, so closing zooms into it; paging itself costs the grid nothing.
    private func viewerChanged(_ id: String?) {
        guard id != viewerItem else { return }
        viewerItem = id
        following?.cancel()
        guard let id, zoom.source?.id != id else { return }
        let work = DispatchWorkItem { [weak self] in self?.follow(id) }
        following = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func follow(_ id: String) {
        guard viewerItem == id, let position = data.positions[id] else { return }
        let frame = layout.geometry.frame(ofItem: position), visible = visibleRect
        if !visible.contains(frame), collectionView.bounds.height > 0 {
            let range = offsetRange
            setOffset(min(max(frame.midY - visible.height / 2 - insets.top, range.lowerBound),
                          range.upperBound))
        }
        prepareZoom(position)
        publishProbe()
    }

    // MARK: Scrolling

    func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool { false }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        held = nil
        placedAt = nil
        if !tracking {
            tracking = true
            PerfMonitor.shared.scrollBegan()
        }
        startJumpProbe()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { scrollEnded() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { scrollEnded() }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        pinned = collectionView.contentOffset.y >= offsetRange.upperBound - 1
        publishProbe()
    }

    private func scrollEnded() {
        if tracking {
            tracking = false
            PerfMonitor.shared.scrollEnded()
        }
        _ = currentPlace()
        publishProbe()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating {
            pinned = scrollView.contentOffset.y >= offsetRange.upperBound - 1
        } else if let placedAt, CACurrentMediaTime() < placedAt.until, abs(scrollView.contentOffset.y - placedAt.y) > 0.5 {
            // UIKit moved it, not the person: back to the newest end, or where it was put.
            let range = offsetRange
            setOffset(pinned ? range.upperBound : min(max(placedAt.y, range.lowerBound), range.upperBound))
        }
        updatePreheat()
        checkJump()
        lastOffset = scrollView.contentOffset.y
    }

    func scrollViewDidChangeAdjustedContentInset(_ scrollView: UIScrollView) {
        guard scrollView.window != nil, isFront else { return }
        // The bars changed (the tab bar minimised, the accessory came, the screen turned): the newest
        // end, or the item in view, stays in view.
        if placed, !scrollView.isTracking, !scrollView.isDecelerating {
            if let place = heldPlace() { restore(place) } else if pinned { setOffset(offsetRange.upperBound) }
        }
        view.setNeedsLayout()
        publishProbe()
    }

    // MARK: Drag to select, pinch

    /// Select mode: a sideways drag across cells selects (or deselects) the run, like Photos; so does
    /// touching and holding, then dragging. Near the top or bottom the grid scrolls along.
    private lazy var selectPan = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
    private lazy var holdDrag: UILongPressGestureRecognizer = {
        let recognizer = UILongPressGestureRecognizer(target: self, action: #selector(dragged(_:)))
        recognizer.minimumPressDuration = 0.25
        recognizer.allowableMovement = 10
        return recognizer
    }()
    private lazy var pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
    private var dragPoint: CGPoint?
    private var dragLink: CADisplayLink?
    private var lastDragged: Int?

    private func installGestures() {
        for recognizer in [selectPan, holdDrag, pinch] as [UIGestureRecognizer] {
            recognizer.delegate = self
            collectionView.addGestureRecognizer(recognizer)
        }
        selectPan.isEnabled = input.selecting
        holdDrag.isEnabled = input.selecting
        collectionView.panGestureRecognizer.require(toFail: selectPan)
    }

    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        // Only from a cell: a drag that starts on a header or a gap scrolls.
        if recognizer === selectPan {
            let velocity = selectPan.velocity(in: collectionView), translation = selectPan.translation(in: collectionView)
            let point = selectPan.location(in: collectionView)
            return selection.active && abs(velocity.x) > abs(velocity.y)
                && layout.geometry.item(at: CGPoint(x: point.x - translation.x, y: point.y - translation.y)) != nil
        }
        if recognizer === holdDrag { return selection.active && layout.geometry.item(at: holdDrag.location(in: collectionView)) != nil }
        return true
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        recognizer === pinch && other === collectionView.panGestureRecognizer
    }

    @objc private func dragged(_ recognizer: UIGestureRecognizer) {
        let point = recognizer.location(in: collectionView)
        switch recognizer.state {
        case .began:
            // The scroll view lets go of this touch: the grid stays put while the drag selects.
            collectionView.panGestureRecognizer.isEnabled = false
            collectionView.panGestureRecognizer.isEnabled = true
            let start = (recognizer as? UIPanGestureRecognizer).map { CGPoint(x: point.x - $0.translation(in: collectionView).x,
                                                                              y: point.y - $0.translation(in: collectionView).y) } ?? point
            lastDragged = nil
            if let item = layout.geometry.item(at: start) ?? layout.geometry.item(near: start) { select(to: item) }
            dragPoint = point
            selectAt(point)
            startDragScrolling()
        case .changed:
            dragPoint = point
            selectAt(point)
        default:
            stopDragScrolling()
            dragPoint = nil
            lastDragged = nil
            actions.dragEnded()
            publishProbe()
        }
    }

    private func selectAt(_ point: CGPoint) {
        guard let item = layout.geometry.item(near: point) else { return }
        select(to: item)
    }

    private func select(to item: Int) {
        guard item != lastDragged, item < data.cells.count else { return }
        lastDragged = item
        actions.dragSelect(data.cells[item].id)
    }

    private func startDragScrolling() {
        guard dragLink == nil else { return }
        let link = CADisplayLink(target: DragTicker(self), selector: #selector(DragTicker.tick(_:)))
        link.add(to: .main, forMode: .common)
        dragLink = link
    }

    private func stopDragScrolling() {
        dragLink?.invalidate()
        dragLink = nil
    }

    /// Near the top or bottom edge the grid scrolls, faster the closer the finger.
    fileprivate func dragTick(_ link: CADisplayLink) {
        guard var point = dragPoint else { return }
        let insets = self.insets, offset = collectionView.contentOffset.y
        let onScreen = point.y - offset, top = insets.top, bottom = collectionView.bounds.height - insets.bottom
        let edge: CGFloat = 70, fastest: CGFloat = 1_400
        var speed: CGFloat = 0
        if onScreen < top + edge { speed = -fastest * pow(min(1, (top + edge - onScreen) / edge), 2) }
        if onScreen > bottom - edge { speed = fastest * pow(min(1, (onScreen - bottom + edge) / edge), 2) }
        guard speed != 0 else { return }
        let range = offsetRange
        let new = min(max(offset + speed * CGFloat(link.targetTimestamp - link.timestamp), range.lowerBound), range.upperBound)
        guard new != offset else { return }
        setOffset(new)
        point.y += new - offset
        dragPoint = point
        selectAt(point)
    }

    @objc private func pinched(_ recognizer: UIPinchGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        pinchPoint = recognizer.location(in: collectionView)
        actions.resize(recognizer.scale)
        // No change of columns: nothing to keep.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.pinchPoint = nil }
    }

    // MARK: Performance probes (only with -perfMonitor)

    /// Cells on screen without a picture, and all cells on screen.
    private func blankCells() -> (blank: Int, shown: Int) {
        let visible = collectionView.bounds
        var blank = 0, shown = 0
        for case let cell as GridCell in collectionView.visibleCells where cell.frame.intersects(visible) {
            shown += 1
            if !cell.hasImage { blank += 1 }
        }
        return (blank, shown)
    }

    /// While a finger drags, the item that was in the middle must move with the finger: a frame
    /// where it moved otherwise is a jump (the old grid teleported a screen or a year at a drag's start).
    private var jumpProbe: (id: String, y: CGFloat, finger: CGFloat)?
    private var jumps = 0

    private func startJumpProbe() {
        guard PerfMonitor.shared.enabled, let anchor = layout.geometry.anchor(in: visibleRect), anchor.item < data.ids.count else { return }
        let finger = collectionView.panGestureRecognizer.translation(in: nil).y
        jumpProbe = (data.ids[anchor.item], layout.geometry.frame(ofItem: anchor.item).midY - collectionView.contentOffset.y, finger)
    }

    private func checkJump() {
        guard PerfMonitor.shared.enabled, collectionView.isTracking, let probe = jumpProbe, let position = data.positions[probe.id]
        else { return }
        let y = layout.geometry.frame(ofItem: position).midY - collectionView.contentOffset.y
        let finger = collectionView.panGestureRecognizer.translation(in: nil).y
        if abs((y - probe.y) - (finger - probe.finger)) > 40 { jumps += 1 }
        jumpProbe = (probe.id, y, finger)
    }

    /// Where the grid is, for the UI tests: its offset and its ends', the items in view, jumps, cells
    /// still without a picture a moment later, and the items the viewer shows and zooms back into.
    private func publishProbe() {
        guard PerfMonitor.shared.enabled, isViewLoaded else { return }
        for delay in [0, 0.8] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                let visible = self.visibleRect, geometry = self.layout.geometry, range = self.offsetRange
                let items = geometry.items(inBand: visible.minY...visible.maxY)
                PerfMonitor.shared.note([
                    "grid.offset": self.collectionView.contentOffset.y, "grid.top": range.lowerBound, "grid.bottom": range.upperBound,
                    "grid.jumps": Double(self.jumps), "grid.count": Double(geometry.count), "grid.columns": Double(geometry.columns),
                    "grid.width": geometry.metrics.width,
                    "grid.span": self.collectionView.bounds.width - self.insets.left - self.insets.right,
                    "grid.first": Double(items.lowerBound), "grid.last": Double(items.upperBound - 1),
                    "grid.anchor": Double(geometry.anchor(in: visible)?.item ?? -1), "grid.blank": Double(self.blankCells().blank),
                    "grid.shown": Double(self.viewerItem.flatMap { self.data.positions[$0] } ?? -1),
                    "grid.zoom": Double(self.zoom.source.flatMap { self.data.positions[$0.id] } ?? -1),
                ])
            }
        }
    }
}

/// The display link's target for drag-to-select's scrolling.
@MainActor private final class DragTicker: NSObject {
    weak var controller: GridController?
    init(_ controller: GridController) { self.controller = controller }
    @objc func tick(_ link: CADisplayLink) { controller?.dragTick(link) }
}
