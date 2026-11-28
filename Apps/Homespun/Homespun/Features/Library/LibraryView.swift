// SPDX-License-Identifier: Apache-2.0
import HomespunCore
import Photos
import SwiftUI

/// The Library tab (DESIGN 02): every photo and video with its badge, a Filter menu, Select mode
/// with Back Up, and Free Up Space. Tapping an item opens it.
struct LibraryView: View, Equatable {
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.model === rhs.model }
    let model: AppModel
    var freeUp: (Set<String>?) -> Void
    @State private var filter = LibraryState.Filter.all
    @State private var media = LibraryModel.Media.all
    @State private var selection = GridSelection()
    /// The grid's structure for the current filter (built off the main thread); it changes only
    /// when items come, go or move, so badge changes don't rebuild the grid.
    @State private var store = GridStore()
    @State private var counts = SectionCounts()
    @State private var dataReady = false
    @State private var build = GridBuild()
    /// Select mode's Newest (the tab bar, whose second tap does this, is hidden then).
    @State private var newestTaps = 0
    /// What Back Up and Free Up Space would take from the selection (worked out off the main thread).
    @State private var selectionParts = SelectionParts()
    @State private var selectionBytes: (bytes: Int, exact: Bool)?
    @State private var sheet: Sheet?
    /// The grid's density: 2 (large), 4 (medium) or 6 (small) columns on an iPhone.
    @AppStorage("gridColumns") private var columns = 4
    /// Drag-to-select: where the drag started, whether it selects or deselects, and the selection before it.
    @State private var dragAnchor: String?
    @State private var dragSelects = true
    @State private var dragBase = Set<String>()
    @Environment(\.openURL) private var openURL
    @Environment(\.showsTips) private var showsTips

    enum Sheet: Identifiable {
        case backUp([String]), legend, setup, identity, restore([String])
        var id: String {
            switch self {
            case .backUp: "backUp"
            case .restore: "restore"
            case .legend: "legend"
            case .setup: "setup"
            case .identity: "identity"
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
    private var data: GridData { store.data }

    var body: some View {
        let _ = RenderProbe.count("render.library")
        NavigationStack {
            content
                .background(Theme.background)
                .navigationTitle(selecting ? selectionTitle : "Library")
                .modifier(LibrarySubtitle(text: { subtitle }))
                .toolbarTitleDisplayMode(selecting ? .inline : .large)
                .toolbar { toolbar }
                .toolbar(selecting ? .hidden : .automatic, for: .tabBar)
                .sheet(item: $sheet) { sheet in
                    switch sheet {
                    case .backUp(let ids): BackUpSheet(controller: controller, identifiers: ids) { endSelecting() }
                    case .legend: BadgeLegendView(serverName: controller.serverName)
                    case .setup: OnboardingView(settings: model.settings, library: controller)
                    case .identity: IdentityProblemView(settings: settings) { self.sheet = .setup }
                    case .restore(let ids): RestoreOriginalSheet(controller: controller, compacts: ids) { if $0 { endSelecting() } }
                    }
                }
                .task(id: selection.version) {
                    await measureSelection()
                }
                .modifier(GridDataTrigger(key: { gridKey }, rebuild: { await rebuildData() }))
                // Get Started: pick what to try, from what isn't backed up.
                .onChange(of: controller.choosePending, initial: true) { _, pending in
                    guard pending else { return }
                    ItemViewerPresence.shared.close(animated: false) {
                        controller.choosePending = false
                        filter = .notBackedUp
                        selecting = true
                        controller.journey.used(.select)
                    }
                }
                .onChange(of: filter) { PerfMonitor.shared.begin("filter") }
                .onChange(of: media) { PerfMonitor.shared.begin("filter") }
                .onChange(of: selecting) { _, on in controller.isSelecting = on }
        }
    }

    private func openFreeUp(_ scope: Set<String>?) { freeUp(scope) }

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

    fileprivate struct GridKey: Equatable {
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
        if dataReady, key == build.key { return }
        let state = controller.library.state, filter = filter, months = controller.library.monthsSnapshot
        let ready = controller.loaded
        let kind = await controller.library.identifiers(media)
        let old = data
        let (new, change) = await Task.detached(priority: .userInitiated) { () -> (GridData, GridChange) in
            let new = GridData(state: state, filter: filter, media: kind, months: months)
            return (new, GridChange.between(old, new))
        }.value
        guard !Task.isCancelled else { return }
        counts.update(new)
        store.apply(new, change: change)
        if ready {
            dataReady = true
            build.key = key
        }
        PerfMonitor.shared.endAfterFrame("filter")
    }

    /// From the process's start to the grid with its items, once per launch (performance tests).
    private static var launchRecorded = false
    private static func recordLaunch() {
        guard !launchRecorded else { return }
        launchRecorded = true
        PerfMonitor.signposter.emitEvent("GridShown")
        let milliseconds = Int((CACurrentMediaTime() - PerfMonitor.mainStarted) * 1000)
        AppLog.app.info("launch GridShown: \(milliseconds, privacy: .public) ms from main")
        PerfMonitor.shared.record("launch", milliseconds: PerfMonitor.sinceProcessStart)
        PerfMonitor.shared.record("launchFromMain", milliseconds: (CACurrentMediaTime() - PerfMonitor.mainStarted) * 1000)
        PerfMonitor.shared.startAutoscrollIfAsked()
    }

    /// The grid's UIKit cells are also the viewer's zoom sources.
    private var grid: some View {
        LibraryAggregate {
            GridView(library: controller.library, selection: selection, counts: counts, store: store, input: gridInput,
                     actions: gridActions)
        }
            .ignoresSafeArea()
            .onAppear {
                Self.recordLaunch()
                controller.gridDidAppear()
            }
    }

    private var gridInput: GridInput {
        GridInput(selecting: selecting,
                  selectionVersion: selection.version, filter: filter, paired: settings.isPaired,
                  serverName: controller.serverName, density: columns, newest: controller.newestRequests &+ newestTaps,
                  notice: AnyView(top), noticeKey: topKey)
    }

    private var gridActions: GridActions {
        GridActions(tapped: { tapped($0) }, viewer: { start, ids, details in
            ItemViewerController(model: model, state: ItemViewerState(ids: ids, start: start, details: details), showsTips: showsTips)
        }, menu: { menu(for: $0, opening: $1) }, dragSelect: { dragSelect(to: $0) },
                    dragEnded: { endDragSelect() }, resize: { resize($0) })
    }

    /// Above the first month: the notice, and the empty state when nothing is shown (at their own
    /// height: the grid measures them).
    private var top: some View {
        VStack(spacing: 12) {
            notice
            if store.isEmpty { empty }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// What `top` says, so the grid draws and measures it again only when that changes.
    private var topKey: String {
        let notice = Self.noticeKey(problem: settings.connectionProblem, limited: controller.access == .limited,
                                    paired: settings.isPaired)
        let empty = !store.isEmpty ? "" : controller.library.count == 0 ? "none"
            : filter == .notBackedUp && media == .all
                ? "done.\(controller.serverName).\(controller.library.state.count(.needsAttention))" : "nothing.\(filter.rawValue)"
        return [notice, empty, controller.job.queueProblem ?? "",
                settings.needsBackupUpdate && !settings.updateNoticeDismissed ? controller.updateMessage : "",
                controller.showsRemoteNotice ? "remote" : "", controller.legacyNotice ?? ""]
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func noticeKey(problem: String?, limited: Bool, paired: Bool) -> String {
        problem.map { "connection.\($0)" } ?? (limited ? "limited" : !paired ? "setup" : "")
    }

    /// Grid Size and pinching: timed from here to the new grid on screen.
    private func setColumns(_ new: Int) {
        guard new != columns else { return }
        PerfMonitor.shared.begin("gridSize")
        columns = new
    }

    @ViewBuilder private var notice: some View {
        ServerUpdateNotice(controller: controller).padding(.horizontal)
        if let message = controller.legacyNotice {
            HStack(alignment: .top) {
                Text(message).font(.footnote).foregroundStyle(Theme.secondaryLabel)
                Button("Dismiss", systemImage: "xmark", action: controller.dismissLegacyNotice)
                    .labelStyle(.iconOnly)
            }
            .padding(.horizontal)
            .accessibilityIdentifier("library.legacy")
        }
        if let problem = controller.job.queueProblem, !settings.needsBackupUpdate {
            InlineNotice(tone: .warning, title: "Backup queue needs attention", message: problem) {
                Button("Try Again") { Task { await controller.job.refreshQueue(); await controller.refreshGrid() } }
                    .accessibilityIdentifier("queue.retry")
            }
            .padding(.horizontal)
        }
        if controller.showsRemoteNotice {
            InlineNotice(tone: .info, title: "Compact copies are processing on your server",
                         message: "Their originals are already backed up. Server work continues without keeping this screen awake. "
                            + "Open Homespun later to discover and save ready copies.")
                .padding(.horizontal)
                .accessibilityIdentifier("queue.remote")
        }
        if let problem = settings.connectionProblem {
            InlineNotice(tone: .error, title: "Connection needs attention", message: problem) {
                Button("Check Server") { sheet = .identity }.font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal)
        } else if controller.access == .limited {
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
            if controller.library.state.count(.needsAttention) > 0 {
                ContentUnavailableView {
                    Label("Some backups need attention", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("Earlier mappings aren't current-server verification. Review them before removing any originals.")
                } actions: {
                    Button("Show Needs Attention") { filter = .needsAttention }
                }
            } else {
                ContentUnavailableView {
                    Label("Everything's backed up", systemImage: "checkmark.circle.fill")
                } description: {
                    Text("All your photos and videos have their originals on \(controller.serverName).")
                } actions: {
                    Button("Show All Items") { filter = .all }
                }
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
        // Normal states always have a subtitle, so connection changes don't resize the title.
        let demo = settings.isDemo ? "Demo · " : ""
        let state = controller.library.state
        if filter != .all || media != .all {
            let name = filter == .all ? media.title : filter.title
            return demo + "\(name) · \(data.cells.count.formatted())"
        }
        guard settings.isPaired else { return demo + "\(state.cells.count.formatted()) items · not connected" }
        if case .unreachable = settings.serverStatus { return demo + "Can't reach \(controller.serverName)" }
        if state.cells.contains(where: \.checkingLegacy) { return "Checking with \(controller.serverName)…" }
        return demo + Self.backupSubtitle(state: state, server: controller.serverName)
    }

    static func backupSubtitle(state: LibraryState, server: String) -> String {
        let attention = state.count(.needsAttention)
        if attention > 0 { return "\(attention.formatted()) need attention · \(server)" }
        let open = state.count(.notBackedUp)
        return open == 0 ? "All backed up · \(server)" : "\(open.formatted()) not backed up · \(server)"
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
                LibraryAggregate {
                    let _ = counts.version
                    Button(allSelectableSelected ? "Deselect All" : "Select All") { toggleSelectAll() }
                        .accessibilityIdentifier("select.all")
                }
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
                Button("Newest", systemImage: "arrow.down.to.line") { newestTaps &+= 1 }
                    .accessibilityLabel("Go to Newest")
                    .accessibilityIdentifier("select.newest")
                Spacer()
                if filter == .atHome {
                    // What's at home, chosen to come back full size.
                    let ids = selectionParts.restorable
                    Button {
                        sheet = .restore(ids)
                    } label: {
                        Label(ids.isEmpty ? "Restore" : "Restore \(ids.count)", systemImage: "arrow.uturn.backward.circle")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(ids.isEmpty || settings.server?.mode == .immich)
                    .accessibilityIdentifier("restore.selected")
                } else {
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
            }
        } else if controller.access.allowsReading {
            ToolbarItemGroup(placement: .primaryAction) {
                selectButton
                filterButton
            }
            ToolbarItem(placement: .primaryAction) { moreMenu }
        }
    }

    private var selectButton: some View {
        Button("Select", systemImage: "checkmark.circle") {
            selecting = true
            controller.journey.used(.select)
        }
        .accessibilityIdentifier("select.start")
        .popoverTip(showsTips ? SelectTip() : nil)
    }

    private var filterButton: some View {
        LibraryAggregate { filterMenu }
            .popoverTip(showsTips ? BadgeTip() : nil) { action in
                if action.id == "guide" { openLegend() }
            }
    }

    private struct LibrarySubtitle: ViewModifier {
        var text: () -> String
        func body(content: Content) -> some View { content.navigationSubtitle(text()) }
    }

    private struct LibraryAggregate<Content: View>: View {
        @ViewBuilder var content: () -> Content
        var body: some View { content() }
    }

    private struct GridDataTrigger: ViewModifier {
        var key: () -> LibraryView.GridKey
        var rebuild: () async -> Void
        func body(content: Content) -> some View { content.task(id: key()) { await rebuild() } }
    }

    @MainActor private final class GridBuild {
        var key: LibraryView.GridKey?
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

    /// A cell's menu (none while selecting); `opening` opens the viewer with Details.
    private func menu(for cell: LibraryState.Cell, opening: @escaping () -> Void) -> UIMenu {
        var items: [UIMenuElement] = []
        if cell.canFree, let original = cell.original {
            items.append(UIAction(title: "Free Up Space", image: UIImage(systemName: "trash")) { _ in openFreeUp([original]) })
        }
        if cell.canCompact, settings.isPaired {
            items.append(UIAction(title: "Back Up", image: UIImage(systemName: "arrow.up.circle"),
                                  attributes: controller.backUpBlockedReason != nil ? .disabled : []) { _ in backUp([cell.id]) })
        }
        if ItemAction.canRestore(cell, immich: settings.server?.mode == .immich) {
            items.append(UIAction(title: "Restore Original", image: UIImage(systemName: "arrow.uturn.backward.circle")) { _ in
                sheet = .restore([cell.id])
            })
        }
        items.append(UIAction(title: "Show Details", image: UIImage(systemName: "info.circle")) { _ in
            opening()
        })
        items.append(UIAction(title: cell.badge.label, attributes: .disabled) { _ in })
        return UIMenu(children: items)
    }

    // MARK: Selecting

    private var allSelectableSelected: Bool {
        let selectable = counts.selectable
        return !selectable.isEmpty && selected.count >= selectable.count && selectable.isSubset(of: selected)
    }

    private var backUpCandidates: [String] { selectionParts.backUp }

    private var freeableInSelection: Set<String> { selectionParts.freeable }

    private func tapped(_ cell: LibraryState.Cell) {
        guard selecting else { return }
        guard counts.selectable.contains(cell.id) else { return }
        if selected.contains(cell.id) { selected.remove(cell.id) } else { selected.insert(cell.id) }
        Announce.say(selected.isEmpty ? "None selected" : "\(selected.count) selected")
    }

    /// Drag across cells to select (or deselect) a run, like Photos: from where the drag started to `id`.
    /// By id: the items can change during the drag (a backup ends, a photo is deleted).
    private func dragSelect(to id: String) {
        guard let index = data.positions[id] else { return }
        if dragAnchor == nil {
            dragAnchor = id
            dragBase = selected
            dragSelects = !selected.contains(id)
        }
        guard let anchor = dragAnchor.flatMap({ data.positions[$0] }) else { return }
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
        if settings.needsBackupUpdate { settings.showingBackUpUpdate = true }
        else if ids.count > 200 || bytes > 5_000_000_000 {
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
        let photos = settings.photos
        let result = await Task.detached(priority: .userInitiated) { photos.estimatedBytes(ids, sample: 300) }.value
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

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
    }
}

/// Each month's count of items not backed up, and what Select All selects; kept apart from the
/// grid's structure so badge changes update the headers alone.
@MainActor @Observable
final class SectionCounts {
    @ObservationIgnored private(set) var open: [Int: Int] = [:]
    @ObservationIgnored private(set) var selectable: Set<String> = []
    /// Bumped on every update, for the grid's headers.
    private(set) var version = 0
    @ObservationIgnored private(set) var changedSections = Set<Int>()

    func takeChangedSections() -> Set<Int> {
        defer { changedSections = [] }
        return changedSections
    }

    func update(_ data: GridData) {
        let new = Dictionary(data.sections.map { ($0.id, $0.open) }, uniquingKeysWith: { a, _ in a })
        guard new != open || selectable != data.selectable else { return }
        changedSections.formUnion(Set(open.keys).union(new.keys).filter { open[$0] != new[$0] })
        let changedSelection = selectable.symmetricDifference(data.selectable)
        for id in changedSelection {
            if let position = data.positions[id], let section = data.sections.first(where: { $0.range.contains(position) }) {
                changedSections.insert(section.id)
            }
        }
        open = new
        let old = selectable
        selectable = data.selectable
        version &+= 1
        releaseInBackground(old)
    }
}

/// What a selection holds for Back Up (items to back up, in library order) and for Free Up Space
/// (originals that can be removed).
struct SelectionParts: Sendable {
    var backUp: [String] = []
    var freeable: Set<String> = []
    /// Compact copies whose originals can come back (Restore Original), in library order.
    var restorable: [String] = []

    init() {}

    init(state: LibraryState, selected: Set<String>) {
        var positioned: [(Int, String)] = [], restoring: [(Int, String)] = []
        positioned.reserveCapacity(selected.count)
        for id in selected {
            guard let position = state.positions[id] else { continue }
            let cell = state.cells[position]
            if cell.canCompact { positioned.append((position, id)) }
            if cell.canFree, let original = cell.original { freeable.insert(original) }
            if cell.canRestore { restoring.append((position, id)) }
        }
        backUp = positioned.sorted { $0.0 < $1.0 }.map(\.1)
        restorable = restoring.sorted { $0.0 < $1.0 }.map(\.1)
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
            let ids = identifiers, photos = controller.settings.photos
            estimate = await Task.detached { photos.estimatedBytes(ids, sample: 300) }.value
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
