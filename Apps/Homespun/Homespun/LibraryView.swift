// SPDX-License-Identifier: Apache-2.0
import HomespunCore
import Photos
import SwiftUI

/// The Library tab (DESIGN 02): every photo and video with its badge, a Filter menu, Select mode
/// with Back Up, and Free Up Space. Tapping an item opens it.
struct LibraryView: View {
    let model: AppModel
    var freeUp: (Set<String>?) -> Void
    @State private var filter = LibraryState.Filter.all
    @State private var media = LibraryModel.Media.all
    @State private var selecting = false
    @State private var selected = Set<String>()
    @State private var selectionBytes: (bytes: Int, exact: Bool)?
    @State private var sheet: Sheet?
    @State private var path: [String] = []
    @State private var pinch: CGFloat = 1
    @AppStorage("gridColumns") private var columns = 4
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var typeSize

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
    private var settings: AppSettings { model.settings }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .background(Theme.background)
                .navigationTitle(selecting ? selectionTitle : "Library")
                .navigationSubtitle(subtitle)
                .toolbarTitleDisplayMode(selecting ? .inline : .large)
                .toolbar { toolbar }
                .toolbar(selecting ? .hidden : .automatic, for: .tabBar)
                .navigationDestination(for: String.self) { id in
                    ItemViewer(model: model, ids: visibleIDs, start: id, freeUp: freeUp)
                }
                .sheet(item: $sheet) { sheet in
                    switch sheet {
                    case .backUp(let ids): BackUpSheet(controller: controller, identifiers: ids) { endSelecting() }
                    case .legend: BadgeLegendView(serverName: controller.serverName)
                    case .setup: OnboardingView(settings: model.settings, library: controller)
                    }
                }
                .task(id: selected) { await measureSelection() }
        }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch controller.access {
        case .authorized, .limited:
            if controller.loaded { grid } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
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

    private var cells: [LibraryState.Cell] {
        let state = controller.library.state.cells(filter)
        guard let kind = controller.library.identifiers(media) else { return state }
        return state.filter { kind.contains($0.id) }
    }

    private var visibleIDs: [String] { cells.map(\.id) }

    private var gridColumns: Int {
        typeSize.isAccessibilitySize ? min(columns, 2) : columns
    }

    private var grid: some View {
        let cells = cells
        return ScrollView {
            VStack(spacing: 12) {
                notice
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: gridColumns), spacing: 2) {
                    ForEach(cells) { cell in
                        GridCell(cell: cell, asset: controller.library.asset(cell.id), manager: controller.library.thumbnails,
                                 selecting: selecting, selected: selected.contains(cell.id), serverName: controller.serverName)
                            .onTapGesture { tapped(cell) }
                            .contextMenu { menu(for: cell) }
                    }
                }
                if cells.isEmpty { empty }
            }
        }
        .modifier(OpensAtNewest())
        .simultaneousGesture(MagnifyGesture().onEnded { value in resize(value.magnification) })
        .accessibilityIdentifier("grid")
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
            return "\(name) · \(cells.count.formatted())"
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
                            freeUp(freeable)
                        }
                        .accessibilityIdentifier("selection.free")
                    }
                    Button("Badge Guide", systemImage: "info.circle") { sheet = .legend }
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
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Select", systemImage: "checkmark.circle") { selecting = true }
                    .accessibilityIdentifier("select.start")
                filterMenu
            }
            ToolbarItem(placement: .primaryAction) { moreMenu }
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
                    selecting = true
                    selected = Set(controller.library.state.cells.filter(\.canCompact).map(\.id))
                }
                .accessibilityIdentifier("select.notBackedUp")
            }
            Picker("Grid Size", selection: $columns) {
                Text("Large").tag(2)
                Text("Medium").tag(4)
                Text("Small").tag(6)
            }
            .pickerStyle(.menu)
            Button("Badge Guide", systemImage: "info.circle") { sheet = .legend }
                .accessibilityIdentifier("legend.open")
        } label: {
            Label("More", systemImage: "ellipsis")
        }
        .accessibilityIdentifier("grid.menu")
    }

    @ViewBuilder private func menu(for cell: LibraryState.Cell) -> some View {
        if cell.canFree, let original = cell.original {
            Button("Free Up Space", systemImage: "trash") { freeUp([original]) }
        }
        if cell.canCompact, settings.isPaired {
            Button("Back Up", systemImage: "arrow.up.circle") { backUp([cell.id]) }
                .disabled(controller.backUpBlockedReason != nil)
        }
        Button("Show Details", systemImage: "info.circle") { path.append(cell.id) }
        Text(cell.badge.label)
    }

    // MARK: Selecting

    private var allSelectableSelected: Bool {
        let selectable = cells.filter { $0.canCompact || $0.canFree }
        return !selectable.isEmpty && selectable.allSatisfy { selected.contains($0.id) }
    }

    private var backUpCandidates: [String] {
        controller.library.state.cells.filter { selected.contains($0.id) && $0.canCompact }.map(\.id)
    }

    private var freeableInSelection: Set<String> {
        Set(controller.library.state.cells.filter { selected.contains($0.id) && $0.canFree }.compactMap(\.original))
    }

    private func tapped(_ cell: LibraryState.Cell) {
        guard selecting else {
            path.append(cell.id)
            return
        }
        guard cell.canCompact || cell.canFree else { return }
        if selected.contains(cell.id) { selected.remove(cell.id) } else { selected.insert(cell.id) }
        Announce.say(selected.isEmpty ? "None selected" : "\(selected.count) selected")
    }

    private func toggleSelectAll() {
        if allSelectableSelected {
            selected.removeAll()
        } else {
            selected = Set(cells.filter { $0.canCompact || $0.canFree }.map(\.id))
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
        if magnification > 1.25, index > 0 { withAnimation { columns = sizes[index - 1] } }
        if magnification < 0.8, index < sizes.count - 1 { withAnimation { columns = sizes[index + 1] } }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
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
