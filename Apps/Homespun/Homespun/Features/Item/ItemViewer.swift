// SPDX-License-Identifier: Apache-2.0
import HomespunCore
import Photos
import SwiftUI

/// One item, full screen, with its state and the one action that fits it (DESIGN 03·1.1). Swipe
/// between items; pinch or double-tap to zoom; touch and hold plays a Live Photo.
struct ItemViewer: View {
    let model: AppModel
    @Bindable var state: ItemViewerState
    var freeUp: (Set<String>?) -> Void
    /// Restore Original's sheet is up.
    @State private var restoring = false
    @State private var comparing: String?
    @State private var playback = VideoPlayback()
    @Environment(\.showsTips) private var showsTips
    @ScaledMetric(relativeTo: .subheadline) private var lineHeight: CGFloat = 52

    private var shown: String { state.shown }
    private var server: String { model.library.serverName }
    private var immich: Bool { model.settings.server?.mode == .immich }

    var body: some View {
        let cell = cell(shown), asset = model.library.library.item(shown)
        ZStack {
            Color.black.ignoresSafeArea()
            pager.ignoresSafeArea()
            if let cell, !state.zoomed { stateLine(cell, asset: asset) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if asset?.itemKind == .video, !state.zoomed {
                VideoScrubber(playback: playback).padding(.horizontal, 20).padding(.bottom, 8)
            }
        }
        .navigationTitle(ItemText.title(asset?.creationDate))
        .navigationSubtitle(ItemText.subtitle(asset?.creationDate, kind: asset?.itemKind,
                                              duration: asset?.duration ?? 0))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar, .bottomBar)
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar, .bottomBar)
        .toolbar { toolbar(cell, isVideo: asset?.itemKind == .video) }
        .accessibilityAction(.escape) { state.close() }
        .onAppear { PerfMonitor.shared.endAfterFrame("open") }
        .onChange(of: state.shown) { _, id in
            state.zoomed = false
            state.onShow(id)
            // Open Details follow the item shown.
            if state.details != nil { state.details = id }
        }
        // Compare goes over the viewer, and Back leaves it: Details close.
        .onDisappear {
            state.details = nil
            playback.pause()
        }
        .sheet(isPresented: $restoring) {
            RestoreOriginalSheet(controller: model.library, compacts: [shown]) { restored in
                // The compact copy shown is gone: back to the grid, where the original is.
                if restored { state.close() }
            }
        }
        .navigationDestination(item: $comparing) { id in
            CompareView(model: model, compactIdentifier: id)
        }
    }

    // MARK: Pages

    /// Every item the viewer goes through, a page each (UIKit: exact pages, reused).
    private var pager: some View {
        // From the item shown, should SwiftUI make the pager again while the viewer stays.
        ItemPager(ids: state.ids, start: shown,
                  current: Binding(get: { state.shown }, set: { if let id = $0 { state.shown = id } }),
                  zoomed: $state.zoomed, playback: playback,
                  item: { model.library.library.item($0) }, label: spokenLabel,
                  contentVersion: model.library.library.contentVersion,
                  changedContent: { model.library.library.changedContent(since: $0) })
    }

    /// The cell for an item (the library state keeps an index by identifier).
    private func cell(_ id: String) -> LibraryState.Cell? { Self.cell(id, model: model) }

    static func cell(_ id: String, model: AppModel) -> LibraryState.Cell? {
        guard let cell = model.library.library.state.cell(id) else { return nil }
        return demo(cell, server: model.library.serverName)
    }

    /// VoiceOver's label for a page: the kind and date, then the badge sentence (DESIGN 03·1.1).
    private func spokenLabel(_ id: String) -> String {
        // From what the library read already (asking Photos for each page is slow).
        let info = model.library.library.info(id)
        let kind = switch info?.kind {
        case .photo?: "Photo"
        case .livePhoto?: "Live Photo"
        case .video?: "Video"
        case nil: "Item"
        }
        let date = info?.created?.formatted(date: .long, time: .shortened)
        let head = [kind, date].compactMap(\.self).joined(separator: ", ")
        guard let cell = cell(id) else { return head }
        return head + ". " + ItemText.spoken(ItemText.sentence(cell.badge, server: server, immich: immich, job: jobState(cell),
                                                             compactAfter: cell.compactAfter))
    }

    // MARK: State line

    /// The badge and its sentence, just under the photo; over it, on a scrim, when the photo
    /// fills the height.
    private func stateLine(_ cell: LibraryState.Cell, asset: (any LibraryItem)?) -> some View {
        GeometryReader { geo in
            let insets = geo.safeAreaInsets
            let screen = CGSize(width: geo.size.width + insets.leading + insets.trailing,
                                height: geo.size.height + insets.top + insets.bottom)
            let aspect = CGSize(width: asset?.pixelWidth ?? 0, height: asset?.pixelHeight ?? 0)
            let photo = ZoomScrollView.fitted(aspect, in: screen)
            let below = (screen.height + photo.height) / 2 - insets.top + 14
            let top = max(0, min(below, geo.size.height - lineHeight))
            let action = ItemAction.for(cell)
            VStack(alignment: .leading, spacing: 0) {
                ItemStateLine(badge: cell.badge,
                              sentence: ItemText.sentence(cell.badge, server: server, immich: immich, job: jobState(cell),
                                                          compactAfter: cell.compactAfter),
                              blocked: action == .backUp || action == .tryAgain ? model.library.backUpBlockedReason : nil,
                              scrim: top < below)
                    .padding(.top, top)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .allowsHitTesting(false)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private func toolbar(_ cell: LibraryState.Cell?, isVideo: Bool) -> some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Back", systemImage: "chevron.backward") { state.close() }
                .tint(.white)
                .accessibilityIdentifier("item.close")
        }
        ToolbarItem(placement: .bottomBar) {
            Button("Details", systemImage: "info.circle") { state.details = shown }
                .tint(.white)
                .disabled(cell == nil)
                .accessibilityIdentifier("item.details")
        }
        if let cell, ItemAction.canCompare(cell, immich: immich) {
            ToolbarItem(placement: .bottomBar) {
                Button("Compare", systemImage: "rectangle.split.2x1") {
                    model.library.journey.used(.compare)
                    comparing = cell.id
                }
                .tint(.white)
                .accessibilityIdentifier("item.compare")
                .popoverTip(showsTips ? CompareTip() : nil)
            }
        }
        if isVideo {
            ToolbarItem(placement: .bottomBar) {
                Button(playback.isPlaying ? "Pause" : "Play", systemImage: playback.isPlaying ? "pause.fill" : "play.fill") {
                    playback.toggle()
                }
                .tint(.white)
                .disabled(playback.status != .ready)
                .accessibilityIdentifier("item.play")
            }
        }
        ToolbarSpacer(.flexible, placement: .bottomBar)
        if let cell, ItemAction.for(cell) != .none || ItemAction.canRestore(cell, immich: immich) {
            ToolbarItem(placement: .bottomBar) { action(cell) }
        }
    }

    @ViewBuilder private func action(_ cell: LibraryState.Cell) -> some View {
        let blocked = model.library.backUpBlockedReason
        switch ItemAction.for(cell) {
        case .freeUp(let original):
            Button { freeUp([original]) } label: {
                TitleAndIcon(title: "Free Up Space", systemImage: "iphone")
            }
            .buttonStyle(.glassProminent).tint(Theme.accent)
            .accessibilityHint(model.settings.isDemo
                               ? "Removes this original from the demo. Its compact copy stays. Nothing is deleted."
                               : "Removes this original from this iPhone. Its compact copy stays. Recently Deleted keeps it for 30 days.")
            .accessibilityIdentifier("item.action")
        case .backUp, .tryAgain:
            let again = ItemAction.for(cell) == .tryAgain
            Button { model.library.backUp([cell.id]) } label: {
                TitleAndIcon(title: again ? "Try Again" : "Back Up", systemImage: again ? "arrow.clockwise" : "arrow.up.circle")
            }
            .buttonStyle(.glassProminent).tint(Theme.accent)
            .disabled(blocked != nil)
            .accessibilityHint(blocked ?? "Copies the original to \(server). Nothing is removed from this iPhone.")
            .accessibilityIdentifier("item.action")
        case .compactNow:
            Button { model.library.backUp([cell.id]) } label: {
                TitleAndIcon(title: "Make Compact Copy", systemImage: "arrow.down.right.and.arrow.up.left")
            }
            .buttonStyle(.glassProminent).tint(Theme.accent)
            .disabled(blocked != nil)
            .accessibilityHint(blocked ?? "Makes its compact copy now instead of waiting. Nothing is removed from this iPhone.")
            .accessibilityIdentifier("item.action")
        case .none:
            if ItemAction.canRestore(cell, immich: immich) {
                Button { restoring = true } label: {
                    TitleAndIcon(title: "Restore Original", systemImage: "arrow.uturn.backward.circle")
                }
                .buttonStyle(.glassProminent).tint(Theme.accent)
                .accessibilityHint(model.settings.isDemo
                                   ? "Brings the full-size original back from \(server) and deletes this compact copy from the demo. You're asked first."
                                   : "Brings the full-size original back from \(server) and deletes this compact copy. iOS asks first.")
                .accessibilityIdentifier("item.action")
            }
        }
    }

    // MARK: Job state

    private func jobState(_ cell: LibraryState.Cell) -> CompactJob.State? { Self.jobState(cell, model: model) }

    static func jobState(_ cell: LibraryState.Cell, model: AppModel) -> CompactJob.State? {
        #if DEBUG
        if let state = demoState(server: model.library.serverName), cell.badge == state.badge { return state.job }
        #endif
        return model.job.states[cell.id]
    }

    private static func demo(_ cell: LibraryState.Cell, server: String) -> LibraryState.Cell {
        #if DEBUG
        if cell.badge == .none, let state = demoState(server: server) {
            var cell = cell
            cell.badge = state.badge
            return cell
        }
        #endif
        return cell
    }

    #if DEBUG
    /// Debug builds launched with `-itemDemoState failed` or `kept` show that state on items not
    /// backed up, so the Details variants (03·1.3, 1.4) can be checked without a failing server.
    private static func demoState(server: String) -> (badge: Badge, job: CompactJob.State)? {
        switch UserDefaults.standard.string(forKey: "itemDemoState") {
        case "failed": (.failed, .failed("\(server) is almost full (3.1 GB free). Free up space on \(server), then try again."))
        case "kept": (.kept, .unchanged("Dolby Vision video isn't compressed yet, so there's no compact copy. The original stays on this iPhone."))
        default: nil
        }
    }
    #endif
}

/// Details beside the photo on the open iPhone Duo (the photo narrows to make room), a
/// half-height sheet on a phone. Its own view, so job progress redraws only it.
struct ItemDetailsPanel: View {
    let model: AppModel
    let id: String
    var close: () -> Void

    var body: some View {
        if let cell = ItemViewer.cell(id, model: model) {
            ItemDetailsSheet(model: model, cell: cell, job: ItemViewer.jobState(cell, model: model), close: close)
        }
    }
}

/// A toolbar button's title beside its symbol. A `Label` there shows only its symbol, but the
/// viewer's one action reads as words on iPhone (DESIGN 03·1.1).
private struct TitleAndIcon: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            Text(title)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }
}

/// The badge and its sentence under the photo; shape and words, never colour alone.
struct ItemStateLine: View {
    let badge: Badge
    let sentence: String
    var blocked: String?
    var scrim = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Group {
                    if badge == .none {
                        Circle().strokeBorder(.white.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, dash: [3]))
                            .frame(width: 20, height: 20)
                    } else {
                        BadgeView(badge: badge, size: 22)
                    }
                }
                .accessibilityHidden(true)
                Text(sentence).font(.subheadline).foregroundStyle(.white)
                    .accessibilityIdentifier("item.state")
            }
            if let blocked {
                Text(blocked).font(.footnote).foregroundStyle(.white.opacity(0.75)).padding(.leading, 32)
                    .accessibilityIdentifier("item.blocked")
            }
        }
        .padding(.vertical, scrim ? 8 : 0)
        .padding(.horizontal, scrim ? 12 : 0)
        .background {
            if scrim { RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.black.opacity(0.55)) }
        }
    }
}
