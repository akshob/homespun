// SPDX-License-Identifier: Apache-2.0
import AVKit
import HomespunCore
import Photos
import PhotosUI
import SwiftUI

/// One item, full screen, with its state and the one action that fits it (DESIGN 03·1.1). Swipe
/// between items; pinch or double-tap to zoom; touch and hold plays a Live Photo.
struct ItemViewer: View {
    let model: AppModel
    let ids: [String]
    let start: String
    var freeUp: (Set<String>?) -> Void
    /// On the right page of the open iPhone Duo: the tabs stay, and Close returns to the Overview.
    var close: (() -> Void)?
    @State private var current: String?
    @State private var zoomed = false
    @State private var showDetails = false
    @State private var comparing: String?
    @ScaledMetric(relativeTo: .subheadline) private var lineHeight: CGFloat = 52

    init(model: AppModel, ids: [String], start: String, freeUp: @escaping (Set<String>?) -> Void,
         close: (() -> Void)? = nil) {
        self.model = model
        self.ids = ids
        self.start = start
        self.freeUp = freeUp
        self.close = close
        _current = State(initialValue: start)
    }

    private var shown: String { current ?? start }
    private var server: String { model.library.serverName }
    private var immich: Bool { model.settings.server?.mode == .immich }

    var body: some View {
        let cell = cell(shown), asset = model.library.library.asset(shown)
        ZStack {
            Color.black.ignoresSafeArea()
            pager.ignoresSafeArea()
            if let cell, !zoomed { stateLine(cell, asset: asset) }
        }
        .navigationTitle(ItemText.title(asset?.creationDate))
        .navigationSubtitle(ItemText.subtitle(asset?.creationDate, kind: asset.flatMap(PhotoLibrary.kind),
                                              duration: asset?.duration ?? 0))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar, .bottomBar)
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar, .bottomBar)
        .toolbar(close == nil ? .hidden : .automatic, for: .tabBar)
        .toolbar {
            if let close {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark", action: close).accessibilityIdentifier("item.close")
                }
            }
            toolbar(cell)
        }
        .itemScreen()
        .onChange(of: current) { _, _ in zoomed = false }
        .sheet(isPresented: $showDetails) {
            if let cell {
                ItemDetailsSheet(model: model, cell: cell, job: jobState(cell))
            }
        }
        .navigationDestination(item: $comparing) { id in
            CompareView(model: model, compactIdentifier: id)
        }
    }

    // MARK: Pages

    private var pager: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(ids, id: \.self) { id in
                    ItemViewerPage(asset: model.library.library.asset(id), isCurrent: id == shown, label: spokenLabel(id)) { zoomed in
                        if id == shown { self.zoomed = zoomed }
                    }
                    .containerRelativeFrame([.horizontal, .vertical])
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $current)
        .scrollIndicators(.hidden)
        .scrollDisabled(zoomed)
        .scrollEdgeEffectHidden(true, for: .all)
        .accessibilityIdentifier("item.viewer")
    }

    /// The cell for an item. A linear search, but only for the few pages on screen.
    private func cell(_ id: String) -> LibraryState.Cell? {
        guard let cell = model.library.library.state.cells.first(where: { $0.id == id }) else { return nil }
        return demo(cell)
    }

    /// VoiceOver's label for a page: the kind and date, then the badge sentence (DESIGN 03·1.1).
    private func spokenLabel(_ id: String) -> String {
        let asset = model.library.library.asset(id)
        let kind = asset.flatMap(PhotoLibrary.kind)?.name ?? "Item"
        let date = asset?.creationDate?.formatted(date: .long, time: .shortened)
        let head = [kind, date].compactMap(\.self).joined(separator: ", ")
        guard let cell = cell(id) else { return head }
        return head + ". " + ItemText.spoken(ItemText.sentence(cell.badge, server: server, immich: immich, job: jobState(cell),
                                                             compactAfter: cell.compactAfter))
    }

    // MARK: State line

    /// The badge and its sentence, just under the photo; over it, on a scrim, when the photo
    /// fills the height.
    private func stateLine(_ cell: LibraryState.Cell, asset: PHAsset?) -> some View {
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

    @ToolbarContentBuilder private func toolbar(_ cell: LibraryState.Cell?) -> some ToolbarContent {
        ToolbarItem(placement: .bottomBar) {
            Button("Details", systemImage: "info.circle") { showDetails = true }
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
                .popoverTip(CompareTip())
            }
        }
        ToolbarSpacer(.flexible, placement: .bottomBar)
        if let cell, ItemAction.for(cell) != .none {
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
            .accessibilityHint("Removes this original from this iPhone. Its compact copy stays. Recently Deleted keeps it for 30 days.")
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
            EmptyView()
        }
    }

    // MARK: Job state

    private func jobState(_ cell: LibraryState.Cell) -> CompactJob.State? {
        #if DEBUG
        if let state = Self.demoState(server: server), cell.badge == state.badge { return state.job }
        #endif
        return model.job.states[cell.id]
    }

    private func demo(_ cell: LibraryState.Cell) -> LibraryState.Cell {
        #if DEBUG
        if cell.badge == .none, let state = Self.demoState(server: server) {
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

/// Whether an item screen (the viewer, Compare) is showing. The tab view hides its bottom
/// accessory meanwhile, which would otherwise cover their toolbar; it comes back a moment after
/// the last one closes, so it doesn't flash while Compare opens over the viewer.
@MainActor @Observable
final class ItemPresence {
    static let shared = ItemPresence()
    private var count = 0
    var isOpen: Bool { count > 0 }

    fileprivate func opened() { count += 1 }

    fileprivate func closed() {
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            count = max(0, count - 1)
        }
    }
}

extension View {
    /// Marks a full-screen item screen (see `ItemPresence`).
    func itemScreen() -> some View {
        onAppear { ItemPresence.shared.opened() }
            .onDisappear { ItemPresence.shared.closed() }
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

/// One item in the viewer: a zoomable photo or Live Photo, or a video. The page on screen loads
/// at full size; its neighbours at about screen size.
struct ItemViewerPage: View {
    let asset: PHAsset?
    let isCurrent: Bool
    let label: String
    var onZoom: (Bool) -> Void
    @State private var image: UIImage?
    @State private var livePhoto: PHLivePhoto?
    @State private var player: AVPlayer?
    @Environment(\.displayScale) private var displayScale

    private struct Load: Equatable {
        var id: String?
        var current: Bool
    }

    var body: some View {
        Group {
            if asset?.mediaType == .video {
                if let player {
                    VideoPlayer(player: player)
                        .accessibilityLabel(label)
                } else {
                    poster
                }
            } else {
                ZoomableMedia(image: image, livePhoto: livePhoto, isCurrent: isCurrent, label: label,
                              aspect: CGSize(width: asset?.pixelWidth ?? 0, height: asset?.pixelHeight ?? 0), onZoom: onZoom)
            }
        }
        .task(id: Load(id: asset?.localIdentifier, current: isCurrent)) { await load() }
        .onChange(of: isCurrent) { _, current in if !current { player?.pause() } }
        .onDisappear { player?.pause() }
    }

    private var poster: some View {
        Color.black.overlay {
            if let image { Image(uiImage: image).resizable().scaledToFit() }
        }
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isImage)
    }

    private func load() async {
        guard let asset else { return }
        let width = Double(asset.pixelWidth), height = Double(asset.pixelHeight)
        if image == nil {
            let scale = min(1, 1000 * displayScale / max(width, height, 1))
            image = await ItemMedia.image(asset, size: CGSize(width: width * scale, height: height * scale))
        }
        guard isCurrent, !Task.isCancelled else { return }
        if asset.mediaType == .video {
            if player == nil { player = await ItemMedia.player(asset) }
            return
        }
        let scale = min(1, 4096 / max(width, height, 1))
        let full = CGSize(width: width * scale, height: height * scale)
        if asset.mediaSubtypes.contains(.photoLive) {
            if livePhoto == nil { livePhoto = await ItemMedia.livePhoto(asset, size: full) }
        } else if let sharper = await ItemMedia.image(asset, size: full), !Task.isCancelled {
            image = sharper
        }
    }
}

/// A photo, or a Live Photo that plays while touched and held, in a `ZoomScrollView`.
private struct ZoomableMedia: UIViewRepresentable {
    var image: UIImage?
    var livePhoto: PHLivePhoto?
    var isCurrent: Bool
    var label: String
    var aspect: CGSize
    var onZoom: (Bool) -> Void

    final class Content: UIView {
        let imageView = UIImageView()
        let liveView = PHLivePhotoView()

        override init(frame: CGRect) {
            super.init(frame: frame)
            for view in [imageView, liveView] {
                view.frame = bounds
                view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                view.contentMode = .scaleAspectFit
                addSubview(view)
            }
            liveView.isHidden = true
            isAccessibilityElement = true
            accessibilityTraits = .image
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }

    func makeUIView(context: Context) -> ZoomScrollView {
        ZoomScrollView(content: Content())
    }

    func updateUIView(_ view: ZoomScrollView, context: Context) {
        guard let content = view.content as? Content else { return }
        if content.imageView.image !== image { content.imageView.image = image }
        if content.liveView.livePhoto !== livePhoto {
            content.liveView.livePhoto = livePhoto
            content.liveView.isHidden = livePhoto == nil
        }
        view.aspect = aspect.width > 0 ? aspect : image?.size ?? .zero
        content.accessibilityLabel = label
        let report = onZoom
        view.onZoom = { zoomed in Task { @MainActor in report(zoomed) } }
        if !isCurrent { view.reset() }
    }
}
