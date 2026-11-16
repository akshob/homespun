// SPDX-License-Identifier: Apache-2.0
import HomespunCore
import Photos
import SwiftUI

/// The Library tab (DESIGN 02): every photo and video with its badge, a Filter menu, Select mode
/// with Back Up, and Free Up Space. Tapping an item opens it.
struct LibraryView: View {
    let model: AppModel
    var freeUp: (Set<String>?) -> Void
    /// The right page's screen when the display is wide enough for a book (iPhone Duo open).
    @Binding var route: LibraryRoute
    @State private var filter = LibraryState.Filter.all
    @State private var media = LibraryModel.Media.all
    @State private var selection = GridSelection()
    /// The grid's structure for the current filter (built off the main thread); it changes only
    /// when items come, go or move, so badge changes don't rebuild the grid.
    @State private var data = GridData()
    @State private var counts = SectionCounts()
    @State private var dataReady = false
    @State private var builtKey: GridKey?
    @State private var anchor: Anchor?
    @State private var preheater: ThumbnailPreheater?
    /// What Back Up and Free Up Space would take from the selection (worked out off the main thread).
    @State private var selectionParts = SelectionParts()
    @Environment(\.displayScale) private var displayScale
    @State private var selectionBytes: (bytes: Int, exact: Bool)?
    @State private var sheet: Sheet?
    @State private var path: [String] = []
    @State private var pinch: CGFloat = 1
    /// The grid's density: 2 (large), 4 (medium) or 6 (small) columns on an iPhone.
    @AppStorage("gridColumns") private var columns = 4
    @SceneStorage("library.showsPage") private var showsPage = true
    @State private var gridSize = CGSize.zero
    @State private var gridFold: CGRect?
    /// Where the visible cells are, for drag-to-select (not observed: it changes as cells appear).
    @State private var frames = CellFrames()
    /// Drag-to-select: where the drag started, whether it selects or deselects, and the selection before it.
    @State private var dragAnchor: Int?
    @State private var dragSelects = true
    @State private var dragBase = Set<String>()
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.horizontalSizeClass) private var sizeClass

    enum Sheet: Identifiable {
        case backUp([String]), legend, setup
        var id: String {
            switch self {
            case .backUp: "backUp"
            case .legend: "legend"
            case .setup: "setup"
            }
        }
    }

    private var controller: LibraryController { model.library }

    private var selecting: Bool {
        get { selection.active }
        nonmutating set { selection.active = newValue }
    }

    private var selected: Set<String> {
        get { selection.ids }
        nonmutating set { selection.ids = newValue }
    }
    private var settings: AppSettings { model.settings }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if isBook {
                    Book(showsSecond: showsPage) {
                        content.safeAreaInset(edge: .top, spacing: 0) { paneHeader }
                    } second: {
                        LibraryRightPage(model: model, route: $route, selected: selected, ids: visibleIDs, backUp: backUp,
                                         showAll: { filter = $0 }, openItem: { path.append($0) })
                    }
                } else {
                    content
                }
            }
                .background(Theme.background)
                .navigationTitle(selecting ? selectionTitle : "Library")
                .navigationSubtitle(subtitle)
                .toolbarTitleDisplayMode(selecting ? .inline : .large)
                .toolbar { toolbar }
                .toolbar(selecting ? .hidden : .automatic, for: .tabBar)
                .navigationDestination(for: String.self) { id in
                    ItemViewer(model: model, ids: visibleIDs, start: id, freeUp: openFreeUp)
                }
                .sheet(item: $sheet) { sheet in
                    switch sheet {
                    case .backUp(let ids): BackUpSheet(controller: controller, identifiers: ids) { endSelecting() }
                    case .legend: BadgeLegendView(serverName: controller.serverName)
                    case .setup: OnboardingView(settings: model.settings, library: controller)
                    }
                }
                .task(id: selection.version) {
                    await measureSelection()
                }
                .task(id: gridKey) { await rebuildData() }
                .onChange(of: filter) { PerfMonitor.shared.begin("filter") }
                .onChange(of: media) { PerfMonitor.shared.begin("filter") }
                .onChange(of: selecting) { _, on in
                    controller.isSelecting = on
                    guard isBook else { return }
                    if on { route = .selection } else if route == .selection { route = .overview }
                }
        }
    }

    /// Two pages: the grid on the left, the next level on the right (DUO §8).
    private var isBook: Bool { sizeClass == .regular && controller.access.allowsReading }

    /// Free Up Space as the right page in a book, a sheet otherwise.
    private func openFreeUp(_ scope: Set<String>?) {
        if isBook, showsPage { route = .review(scope) } else { freeUp(scope) }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch controller.access {
        case .authorized, .limited:
            if controller.loaded, dataReady { grid } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        case .notDetermined:
            ContentUnavailableView {
                Label("See your photos here", systemImage: "photo.on.rectangle.angled")
            } description: {
                Text("Homespun needs Full Access to back up originals and free up space.")
            } actions: {
                Button("Allow Access to Photos") { Task { await controller.requestAccess() } }.primaryAction()
            }
        default:
            ContentUnavailableView {
                Label("Homespun can't see your photos", systemImage: "photo.badge.exclamationmark")
            } description: {
                Text("Allow Full Access in Settings to back up originals and free up space.")
            } actions: {
                Button("Open Settings") { openSettings() }.primaryAction()
            }
        }
    }

    private var visibleIDs: [String] { data.ids }

    private struct GridKey: Equatable {
        /// The grid shows once the library is loaded: data built before that doesn't count.
        var loaded: Bool
        var version: Int
        var filter: LibraryState.Filter
        var media: LibraryModel.Media
        var months: Int
    }

    private var gridKey: GridKey {
        GridKey(loaded: controller.loaded, version: controller.library.state.version, filter: filter, media: media,
                months: controller.library.monthsVersion)
    }

    /// Builds the grid's data for the current filter in the background; the grid itself is
    /// replaced only when its structure changed (otherwise just the month counts update).
    private func rebuildData() async {
        // The task runs again whenever the Library comes back on screen; nothing to do if nothing changed.
        let key = gridKey
        if dataReady, key == builtKey { return }
        let state = controller.library.state, filter = filter, months = controller.library.monthsSnapshot
        let ready = controller.loaded
        let kind = await controller.library.identifiers(media)
        let old = data
        let (new, same) = await Task.detached(priority: .userInitiated) { () -> (GridData, Bool) in
            let new = GridData(state: state, filter: filter, media: kind, months: months)
            let same = old.stateVersion >= 0 && new.ids == old.ids
                && new.sections.map(\.range) == old.sections.map(\.range) && new.sections.map(\.id) == old.sections.map(\.id)
            return (new, same)
        }.value
        guard !Task.isCancelled else { return }
        counts.update(new)
        if !same {
            let old = data
            data = new
            releaseInBackground(old)
        } else {
            releaseInBackground(new)
        }
        if ready {
            dataReady = true
            builtKey = key
        }
        PerfMonitor.shared.endAfterFrame("filter")
    }

    /// From the process's start to the grid with its items, once per launch (performance tests).
    private static var launchRecorded = false
    private static func recordLaunch() {
        guard !launchRecorded else { return }
        launchRecorded = true
        PerfMonitor.signposter.emitEvent("GridShown")
        PerfMonitor.shared.record("launch", milliseconds: PerfMonitor.sinceProcessStart)
        PerfMonitor.shared.record("launchFromMain", milliseconds: (CACurrentMediaTime() - PerfMonitor.mainStarted) * 1000)
        PerfMonitor.shared.startAutoscrollIfAsked()
    }

    /// The thumbnail's side in pixels, from the column width (the preheater caches the same size).
    private var thumbnailPixels: CGFloat {
        let width = gridSize.width > 0 ? gridSize.width : 402
        let columns = max(1, gridLayout.items.count)
        return (width / CGFloat(columns) * displayScale).rounded(.up)
    }

    /// Even columns; across both pages of an open iPhone Duo, the fold is the gutter between the
    /// two halves, never inside a cell (DUO §8, §11).
    private var gridLayout: (items: [GridItem], leading: CGFloat) {
        let accessibility = typeSize.isAccessibilitySize
        if sizeClass == .regular, let gridFold, gridSize.width > 0 {
            let split = BookSplit.make(size: gridSize, fold: gridFold)
            if split.axis == .horizontal, split.gutter.width > BookSplit.plainGutter {
                let perPage = GridColumns.count(width: split.second.width, density: columns, accessibility: accessibility)
                let cell = (split.second.width - CGFloat(perPage - 1) * 2) / CGFloat(perPage)
                let leading = split.first.width - (CGFloat(perPage) * cell + CGFloat(perPage - 1) * 2)
                if cell > 30, leading >= 0 {
                    let items = (0..<(perPage * 2)).map { index in
                        GridItem(.fixed(cell), spacing: index == perPage - 1 ? split.gutter.width : 2)
                    }
                    return (items, leading)
                }
            }
        }
        let count = GridColumns.count(width: gridSize.width > 0 ? gridSize.width : 402, density: columns,
                                      accessibility: accessibility)
        return (Array(repeating: GridItem(.flexible(), spacing: 2), count: count), 0)
    }

    private var grid: some View {
        let data = data
        let layout = gridLayout
        let pixels = thumbnailPixels
        let preheater = preheater
        let shape = GridShape(columns: layout.items.count, leading: layout.leading)
        return ScrollViewReader { proxy in ScrollView {
            VStack(spacing: 12) {
                notice
                LazyVGrid(columns: layout.items, spacing: 2) {
                    ForEach(data.sections, id: \.key) { section in
                        Section {
                            // Positions as identities: cheap to compare for 35,000 items; each cell
                            // follows the item at its position.
                            ForEach(section.range, id: \.self) { position in
                                let cell = data.cells[position]
                                GridCell(initial: cell, library: controller.library, selection: selection,
                                         serverName: controller.serverName, pixels: pixels)
                                    .onTapGesture { tapped(cell) }
                                    .contextMenu { if !selecting { menu(for: cell) } }
                                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("grid")) } action: {
                                        frames.rects[position] = $0
                                    }
                                    .onAppear { preheater?.appeared(position) }
                                    .onDisappear {
                                        frames.rects[position] = nil
                                        preheater?.disappeared(position)
                                    }
                            }
                        } header: {
                            MonthHeader(section: section, data: data, counts: counts, selection: selection, filter: filter,
                                        paired: settings.isPaired)
                        }
                    }
                }
                .coordinateSpace(.named("grid"))
                .gesture(HoldToDragSelect(enabled: selecting, changed: { dragSelect(to: $0, data) }, ended: endDragSelect))
                .padding(.leading, layout.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                if data.cells.isEmpty { empty }
            }
        }
        // A new grid when the columns change (the size menu, a pinch, unfolding iPhone Duo): a lazy
        // grid given new columns measures its rows again from the top of the library down to where
        // it is, which froze a 35,000-item library for seconds. A new one lays out only what's on
        // screen, like at launch; it then scrolls back to the item that was in view.
        .id(shape)
        .task(id: shape) {
            defer { PerfMonitor.shared.endAfterFrame("gridSize") }
            guard let anchor, anchor.shape != shape else { return }
            self.anchor = Anchor(item: anchor.item, shape: shape)
            if let position = data.positions[anchor.item] { proxy.scrollTo(position, anchor: .center) }
        }
        .onScrollPhaseChange { _, phase in
            if phase == .idle { anchor = currentAnchor(shape) }
        }
        .perfScrollTracking()
        .onAppear {
            Self.recordLaunch()
            if self.preheater == nil { self.preheater = ThumbnailPreheater(library: controller.library) }
            self.preheater?.configure(order: data.ids, side: pixels)
        }
        .onChange(of: data.stateVersion) { self.preheater?.configure(order: self.data.ids, side: thumbnailPixels) }
        .onChange(of: pixels) { self.preheater?.configure(order: self.data.ids, side: thumbnailPixels) }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { measure(proxy) }
                    .onChange(of: proxy.size) { _, _ in measure(proxy) }
            }
        }
        .modifier(OpensAtNewest())
        .simultaneousGesture(MagnifyGesture().onEnded { value in resize(value.magnification) })
        .accessibilityIdentifier("grid")
        }
    }

    /// The grid's columns: a change makes a new grid.
    private struct GridShape: Hashable {
        var columns: Int
        var leading: CGFloat
    }

    /// The item in the middle of the screen when scrolling last stopped, so a new grid (other
    /// columns) shows it too. None at the newest end: a new grid opens there anyway.
    private struct Anchor: Equatable {
        var item: String
        var shape: GridShape
    }

    private func currentAnchor(_ shape: GridShape) -> Anchor? {
        let shown = frames.rects.keys.sorted()
        guard let last = data.cells.indices.last, !shown.isEmpty, !shown.contains(last) else { return nil }
        let middle = shown[shown.count / 2]
        return middle < data.cells.count ? Anchor(item: data.cells[middle].id, shape: shape) : nil
    }

    /// Grid Size and pinching: timed from here to the new grid on screen.
    private func setColumns(_ new: Int) {
        guard new != columns else { return }
        PerfMonitor.shared.begin("gridSize")
        // What's in view now (the last stop of scrolling may be older).
        anchor = currentAnchor(GridShape(columns: gridLayout.items.count, leading: gridLayout.leading))
        columns = new
    }

    @ViewBuilder private var notice: some View {
        if controller.access == .limited {
            InlineNotice(tone: .warning, title: "Homespun sees only some photos",
                         message: "It can't back up or free up space for the rest. Allow Full Access in Settings.") {
                Button("Open Settings") { openSettings() }.font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal)
        } else if !settings.isPaired {
            InlineNotice(tone: .info, title: "Set up your home computer",
                         message: "Back up the originals there, then free up space on this iPhone.") {
                Button("Set Up") { sheet = .setup }.font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("connect.open")
            }
            .padding(.horizontal)
        }
    }

    @ViewBuilder private var empty: some View {
        if controller.library.count == 0 {
            ContentUnavailableView("No photos or videos", systemImage: "photo.on.rectangle",
                                   description: Text("Photos and videos you take appear here."))
        } else if filter == .notBackedUp, media == .all {
            ContentUnavailableView {
                Label("Everything's backed up", systemImage: "checkmark.circle.fill")
            } description: {
                Text("All your photos and videos have their originals on \(controller.serverName).")
            } actions: {
                Button("Show All Items") { filter = .all }
            }
        } else {
            ContentUnavailableView {
                Label("Nothing here", systemImage: filter.symbol)
            } actions: {
                Button("Show All Items") {
                    filter = .all
                    media = .all
                }
            }
        }
    }

    private var subtitle: String {
        if selecting {
            guard let selectionBytes, !selected.isEmpty else { return "" }
            return (selectionBytes.exact ? "" : "About ") + LibraryController.bytes(selectionBytes.bytes)
        }
        let state = controller.library.state
        if filter != .all || media != .all {
            let name = filter == .all ? media.title : filter.title
            return "\(name) · \(data.cells.count.formatted())"
        }
        guard settings.isPaired else { return "\(state.cells.count.formatted()) items · not connected" }
        if case .unreachable = settings.serverStatus { return "Can't reach \(controller.serverName)" }
        let open = state.count(.notBackedUp)
        return open == 0 ? "All backed up · \(controller.serverName)"
            : "\(open.formatted()) not backed up · \(controller.serverName)"
    }

    private var selectionTitle: String {
        selected.isEmpty ? "Select Items" : "\(selected.count) Selected"
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if selecting {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done", systemImage: "xmark") { endSelecting() }.accessibilityIdentifier("select.done")
            }
            ToolbarItem(placement: .primaryAction) {
                Button(allSelectableSelected ? "Deselect All" : "Select All") { toggleSelectAll() }
                    .accessibilityIdentifier("select.all")
            }
            ToolbarItemGroup(placement: .bottomBar) {
                Menu {
                    let freeable = freeableInSelection
                    if !freeable.isEmpty {
                        Button("Free Up Space (\(freeable.count))", systemImage: "trash") {
                            endSelecting()
                            openFreeUp(freeable)
                        }
                        .accessibilityIdentifier("selection.free")
                    }
                    Button("Badge Guide", systemImage: "info.circle") { openLegend() }
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
                Spacer()
                let ids = backUpCandidates
                Button {
                    backUp(ids)
                } label: {
                    Label(ids.isEmpty ? "Back Up" : "Back Up \(ids.count)", systemImage: "arrow.up.circle")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.glassProminent)
                .disabled(ids.isEmpty || controller.backUpBlockedReason != nil)
                .accessibilityIdentifier("compact.selected")
                .accessibilityHint(controller.backUpBlockedReason ?? "")
            }
        } else if controller.access.allowsReading {
            // In the book they're the left page's own controls (the pane header), so the strip
            // keeps room for what the right page opens.
            if !isBook {
                ToolbarItemGroup(placement: .primaryAction) {
                    selectButton
                    filterButton
                }
            }
            ToolbarItem(placement: .primaryAction) { moreMenu }
            if isBook {
                ToolbarItem(placement: .primaryAction) {
                    Button(showsPage ? "Hide Page" : "Show Page", systemImage: "sidebar.trailing") {
                        withAnimation { showsPage.toggle() }
                    }
                    .accessibilityIdentifier("library.togglePage")
                }
            }
        }
    }

    private var selectButton: some View {
        Button("Select", systemImage: "checkmark.circle") {
            selecting = true
            controller.journey.used(.select)
        }
        .accessibilityIdentifier("select.start")
        .popoverTip(SelectTip())
    }

    private var filterButton: some View {
        filterMenu
            .popoverTip(BadgeTip()) { action in
                if action.id == "guide" { openLegend() }
            }
    }

    /// The left page's header on the open iPhone Duo: Select and Filter in one glass capsule.
    @ViewBuilder private var paneHeader: some View {
        if isBook, !selecting, controller.access.allowsReading {
            HStack {
                Spacer()
                GlassEffectContainer {
                    HStack(spacing: 4) {
                        selectButton
                        filterButton
                    }
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .padding(.horizontal, 6)
                    .glassEffect(.regular.interactive(), in: .capsule)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
    }

    private var filterMenu: some View {
        Menu {
            Picker("Show", selection: $filter) {
                ForEach(LibraryState.Filter.allCases) { filter in
                    let count = controller.library.state.count(filter)
                    Label(filter == .all ? filter.title : "\(filter.title)  \(count.formatted())", systemImage: filter.symbol)
                        .tag(filter)
                        .accessibilityIdentifier("filter.\(filter.rawValue)")
                }
            }
            Picker("Kind", selection: $media) {
                ForEach(LibraryModel.Media.allCases) { media in
                    Label(media.title, systemImage: media.symbol).tag(media)
                }
            }
        } label: {
            Label("Filter", systemImage: filter == .all && media == .all ? "line.3.horizontal.decrease"
                  : "line.3.horizontal.decrease.circle.fill")
        }
        .accessibilityIdentifier("grid.filter")
    }

    private var moreMenu: some View {
        Menu {
            if settings.isPaired {
                Button("Select All Not Backed Up", systemImage: "checkmark.circle") {
                    PerfMonitor.shared.begin("selectAll")
                    selecting = true
                    selected = Set(controller.library.state.cells.lazy.filter(\.canCompact).map(\.id))
                }
                .accessibilityIdentifier("select.notBackedUp")
            }
            Picker("Grid Size", selection: Binding(get: { columns }, set: { setColumns($0) })) {
                Text("Large").tag(2)
                Text("Medium").tag(4)
                Text("Small").tag(6)
            }
            .pickerStyle(.menu)
            Button("Badge Guide", systemImage: "info.circle") { openLegend() }
                .accessibilityIdentifier("legend.open")
        } label: {
            Label("More", systemImage: "ellipsis")
        }
        .accessibilityIdentifier("grid.menu")
    }

    @ViewBuilder private func menu(for cell: LibraryState.Cell) -> some View {
        if cell.canFree, let original = cell.original {
            Button("Free Up Space", systemImage: "trash") { openFreeUp([original]) }
        }
        if cell.canCompact, settings.isPaired {
            Button("Back Up", systemImage: "arrow.up.circle") { backUp([cell.id]) }
                .disabled(controller.backUpBlockedReason != nil)
        }
        Button("Show Details", systemImage: "info.circle") {
            if isBook, showsPage { route = .item(cell.id) } else { path.append(cell.id) }
        }
        Text(cell.badge.label)
    }

    // MARK: Selecting

    private var allSelectableSelected: Bool {
        let selectable = counts.selectable
        return !selectable.isEmpty && selected.count >= selectable.count && selectable.isSubset(of: selected)
    }

    private var backUpCandidates: [String] { selectionParts.backUp }

    private var freeableInSelection: Set<String> { selectionParts.freeable }

    private func tapped(_ cell: LibraryState.Cell) {
        guard selecting else {
            PerfMonitor.shared.begin("open")
            if isBook, showsPage { route = .item(cell.id) } else { path.append(cell.id) }
            return
        }
        guard cell.canCompact || cell.canFree else { return }
        if selected.contains(cell.id) { selected.remove(cell.id) } else { selected.insert(cell.id) }
        Announce.say(selected.isEmpty ? "None selected" : "\(selected.count) selected")
    }

    /// Touch and hold, then drag across cells to select (or deselect) a run, like Photos.
    private func dragSelect(to location: CGPoint, _ data: GridData) {
        guard let index = frames.position(at: location), index < data.cells.count else { return }
        let id = data.cells[index].id
        if dragAnchor == nil {
            dragAnchor = index
            dragBase = selected
            dragSelects = !selected.contains(id)
        }
        guard let anchor = dragAnchor else { return }
        let run = data.cells[min(anchor, index)...max(anchor, index)].lazy.map(\.id).filter { counts.selectable.contains($0) }
        selected = dragSelects ? dragBase.union(run) : dragBase.subtracting(run)
    }

    private func endDragSelect() {
        if dragAnchor != nil { Announce.say("\(selected.count) selected") }
        dragAnchor = nil
    }

    private func toggleSelectAll() {
        PerfMonitor.shared.begin("selectAll")
        if allSelectableSelected {
            selected.removeAll()
        } else {
            selected = counts.selectable
        }
    }

    private func endSelecting() {
        selecting = false
        selected.removeAll()
    }

    /// Big runs get a sheet that sets expectations first (02·2.1); small ones just start.
    private func backUp(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        let bytes = selectionBytes?.bytes ?? 0
        if ids.count > 200 || bytes > 5_000_000_000 {
            sheet = .backUp(ids)
        } else {
            controller.backUp(ids)
            endSelecting()
        }
    }

    private func measureSelection() async {
        let ids = Array(selected)
        // What Back Up and Free Up Space would take, off the main thread (a selection can be the
        // whole library).
        let state = controller.library.state, chosen = selected
        selectionParts = await Task.detached(priority: .userInitiated) { SelectionParts(state: state, selected: chosen) }.value
        PerfMonitor.shared.endAfterFrame("selectAll")
        guard !ids.isEmpty else {
            selectionBytes = nil
            return
        }
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }
        let result = await Task.detached(priority: .userInitiated) { PhotoLibrary.estimatedBytes(ids) }.value
        if !Task.isCancelled { selectionBytes = result }
    }

    private func resize(_ magnification: CGFloat) {
        let sizes = [2, 4, 6]
        guard let index = sizes.firstIndex(of: columns) else { return columns = 4 }
        if magnification > 1.25, index > 0 { setColumns(sizes[index - 1]) }
        if magnification < 0.8, index < sizes.count - 1 { setColumns(sizes[index + 1]) }
    }

    private func openLegend() {
        controller.journey.used(.badgeGuide)
        sheet = .legend
    }

    private func measure(_ proxy: GeometryProxy) {
        gridSize = proxy.size
        gridFold = Book<EmptyView, EmptyView>.fold(in: proxy)
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
    }
}

/// The frames of the cells on screen by position, in the grid's coordinates; a plain store so
/// updating it doesn't redraw the grid.
final class CellFrames {
    var rects: [Int: CGRect] = [:]

    func position(at point: CGPoint) -> Int? {
        rects.first { $0.value.contains(point) }?.key
    }
}

/// Each month's count of items not backed up, and what Select All selects; kept apart from the
/// grid's structure so badge changes update the headers alone.
@MainActor @Observable
final class SectionCounts {
    private(set) var open: [Int: Int] = [:]
    @ObservationIgnored private(set) var selectable: Set<String> = []

    func update(_ data: GridData) {
        let new = Dictionary(data.sections.map { ($0.id, $0.open) }, uniquingKeysWith: { a, _ in a })
        if new != open { open = new }
        let old = selectable
        selectable = data.selectable
        releaseInBackground(old)
    }
}

/// What a selection holds for Back Up (items to back up, in library order) and for Free Up Space
/// (originals that can be removed).
struct SelectionParts: Sendable {
    var backUp: [String] = []
    var freeable: Set<String> = []

    init() {}

    init(state: LibraryState, selected: Set<String>) {
        var positioned: [(Int, String)] = []
        positioned.reserveCapacity(selected.count)
        for id in selected {
            guard let position = state.positions[id] else { continue }
            let cell = state.cells[position]
            if cell.canCompact { positioned.append((position, id)) }
            if cell.canFree, let original = cell.original { freeable.insert(original) }
        }
        backUp = positioned.sorted { $0.0 < $1.0 }.map(\.1)
    }
}

/// A month's header: its name, how many aren't backed up, and in Select mode its own Select All.
private struct MonthHeader: View {
    let section: GridData.Section
    let data: GridData
    let counts: SectionCounts
    let selection: GridSelection
    let filter: LibraryState.Filter
    let paired: Bool

    nonisolated(unsafe) private static let style = Date.FormatStyle.dateTime.month(.wide).year()

    var body: some View {
        let open = counts.open[section.id] ?? section.open
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.headline)
            if filter == .notBackedUp || (filter == .all && open > 0 && paired) {
                Text("\(open) not backed up").font(.subheadline).foregroundStyle(Theme.secondaryLabel)
            }
            Spacer()
            if selection.active {
                let selectable = data.cells[section.range].lazy.map(\.id).filter { counts.selectable.contains($0) }
                if !selectable.isEmpty {
                    let all = selectable.allSatisfy { selection.ids.contains($0) }
                    Button(all ? "Deselect" : "Select All") {
                        if all { selection.ids.subtract(selectable) } else { selection.ids.formUnion(selectable) }
                    }
                    .font(.subheadline.weight(.semibold))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .padding(.bottom, 6)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isHeader)
    }

    private var title: String {
        guard section.month > 0 else { return "Undated" }
        let date = Calendar.current.date(from: DateComponents(year: section.month / 12, month: section.month % 12 + 1)) ?? .now
        return Self.style.format(date)
    }
}

/// Select mode's touch and hold, then drag. A UIKit long press: a finger that moves before the
/// hold fails it at once, so the grid scrolls as usual; after the hold it has the touch, and the
/// scroll view stays put while the drag selects. (SwiftUI's long press sequenced before a drag
/// kept the touches from the scroll view: the grid couldn't scroll in Select mode.)
struct HoldToDragSelect: UIGestureRecognizerRepresentable {
    var enabled: Bool
    var changed: (CGPoint) -> Void
    var ended: () -> Void

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let recognizer = UILongPressGestureRecognizer()
        recognizer.minimumPressDuration = 0.25
        recognizer.allowableMovement = 10
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        recognizer.isEnabled = enabled
    }

    func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        switch recognizer.state {
        case .began, .changed: changed(context.converter.location(in: .named("grid")))
        case .ended, .cancelled, .failed: ended()
        default: break
        }
    }
}

/// Opens a long library at the newest items, like Photos, while a short one stays at the top.
struct OpensAtNewest: ViewModifier {
    func body(content: Content) -> some View {
        content
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.top, for: .alignment)
    }
}

/// Confirms a long run and sets expectations (DESIGN 02·2.1).
struct BackUpSheet: View {
    let controller: LibraryController
    let identifiers: [String]
    var started: () -> Void
    @State private var estimate: (bytes: Int, exact: Bool)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "arrow.up.circle").font(.system(size: 40)).foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
                Text("Back up \(identifiers.count.formatted()) items?").displayTitle()
                Text(sizeLine).foregroundStyle(Theme.secondaryLabel)
                promise("clock", time, "You can leave Homespun; the backup carries on while there's time.")
                promise("battery.100.bolt", "Best while charging", "And on your home Wi‑Fi.")
                Spacer(minLength: 0)
                Button {
                    controller.backUp(identifiers)
                    started()
                    dismiss()
                } label: {
                    Text("Back Up \(identifiers.count.formatted()) Items").frame(maxWidth: .infinity)
                }
                .primaryAction()
                .accessibilityIdentifier("backup.confirm")
            }
            .padding(24)
            .background(Theme.background)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", systemImage: "xmark") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .task {
            let ids = identifiers
            estimate = await Task.detached { PhotoLibrary.estimatedBytes(ids) }.value
        }
    }

    private var sizeLine: String {
        let size = estimate.map { "About \(LibraryController.bytes($0.bytes)) goes" } ?? "The originals go"
        return "\(size) to \(controller.serverName). Compact copies come back to Photos as each one finishes."
    }

    /// A rough time from the size: about 8 MB a second on home Wi‑Fi, including compacting.
    private var time: String {
        guard let estimate else { return "Working it out…" }
        let seconds = Double(estimate.bytes) / 8_000_000 + Double(identifiers.count) * 0.5
        let formatted = Duration.seconds(max(60, seconds)).formatted(.units(allowed: [.hours, .minutes], width: .wide,
                                                                            maximumUnitCount: 1))
        return "About \(formatted)"
    }

    private func promise(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.title3).foregroundStyle(Theme.accent).frame(width: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(Theme.secondaryLabel)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
