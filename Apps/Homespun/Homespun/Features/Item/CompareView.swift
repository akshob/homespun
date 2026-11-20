// SPDX-License-Identifier: Apache-2.0
import AVKit
import HomespunCore
import SwiftUI

/// What Compare shows: one version, or both split by a line.
enum CompareMode: String, CaseIterable, Identifiable {
    case original, compact, split
    /// Both whole, next to each other (or one above the other held tall): the open iPhone Duo.
    case sideBySide
    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: "Original"
        case .compact: "Compact Copy"
        case .split: "Split"
        case .sideBySide: "Side by Side"
        }
    }
}

/// Loads an item's original and its compact copy for Compare. The original comes from this
/// iPhone while it's here; otherwise it's downloaded from the server into a temporary folder that
/// is deleted when Compare closes.
@MainActor @Observable
final class CompareModel {
    struct Downloads: Sendable {
        var directory: @Sendable () throws -> URL = { try PhotoLibrary.workDirectory() }
        var fetch: @Sendable (ServerClient, String, ServerAPI.ResourceRole, URL, String,
                             @escaping @Sendable (Int64, Int64) -> Void) async throws -> URL = {
            try await CompareModel.fetch($0, assetID: $1, role: $2, to: $3, name: $4, progress: $5)
        }
    }

    enum Status: Equatable {
        case loading
        case downloading(received: Int64, expected: Int64)
        case ready
        /// The download was cancelled.
        case stopped
        case failed(String)
        case inImmich
        case noOriginal
    }

    private(set) var kind = PhotoLibrary.Kind.photo
    private(set) var status = Status.loading
    private(set) var source = OriginalSource.unknown
    private(set) var original: UIImage?
    private(set) var compact: UIImage?
    private(set) var originalPlayer: AVPlayer?
    private(set) var compactPlayer: AVPlayer?
    private(set) var originalFacts = MediaFacts()
    private(set) var compactFacts = MediaFacts()
    private(set) var duration: TimeInterval = 0
    private(set) var server = "your server"
    @ObservationIgnored private var client: ServerClient?
    @ObservationIgnored private var download: Task<Void, Never>?
    @ObservationIgnored private var folder: URL?
    @ObservationIgnored let pair = VideoPair()
    @ObservationIgnored private var videoSwitch = 0
    @ObservationIgnored private let downloads: Downloads

    init(downloads: Downloads = Downloads()) { self.downloads = downloads }

    var isVideo: Bool { kind == .video }
    var hasOriginal: Bool { original != nil || originalPlayer != nil }
    var hasCompact: Bool { compact != nil || compactPlayer != nil }
    var videoSize: CGSize? {
        for facts in [compactFacts, originalFacts] {
            if let width = facts.width, let height = facts.height, width > 0, height > 0 {
                return CGSize(width: width, height: height)
            }
        }
        return nil
    }

    func load(model: AppModel, compactIdentifier: String, presentation: MediaPresentation = .interactive) async {
        close()
        status = .loading
        original = nil
        compact = nil
        originalPlayer = nil
        compactPlayer = nil
        originalFacts = MediaFacts()
        compactFacts = MediaFacts()
        duration = 0
        server = model.library.serverName
        client = model.settings.client
        let photos = model.settings.photos
        guard let asset = photos.item(compactIdentifier) else {
            status = .failed("The compact copy isn't in Photos any more.")
            return
        }
        kind = asset.itemKind ?? .photo
        duration = asset.duration
        compactFacts = asset.mediaFacts().main
        let match = await model.job.ledger.snapshot().first { $0.value.compactIdentifier == compactIdentifier }
        guard !Task.isCancelled else { return }
        let originalAsset = match.flatMap { photos.item($0.key) }
        source = OriginalSource.choose(original: match?.key, onPhone: originalAsset != nil,
                                       serverAssetID: match?.value.serverAssetID, mode: model.settings.server?.mode)
        switch source {
        case .phone: if let originalAsset { originalFacts = originalAsset.mediaFacts().main }
        case .server: fetchOriginal()
        case .immich: status = .inImmich
        case .unknown: status = .noOriginal
        }
        if isVideo, presentation == .interactive {
            let player = await asset.player()
            guard !Task.isCancelled else { return }
            compactPlayer = player
            pair.attach(original: originalPlayer, compact: compactPlayer)
        } else {
            compact = await asset.image(size: nil, fast: false)
        }
        if case .phone = source, let originalAsset, !Task.isCancelled {
            if isVideo, presentation == .interactive {
                let player = await originalAsset.player()
                guard !Task.isCancelled else { return }
                originalPlayer = player
                pair.attach(original: originalPlayer, compact: compactPlayer)
            } else {
                original = await originalAsset.image(size: nil, fast: false)
            }
            status = hasOriginal ? .ready : .failed("The original couldn't be read from Photos.")
        }
    }

    /// Downloads the original from the server (again, after Cancel), with progress.
    func fetchOriginal() {
        guard case .server(let assetID) = source, let client, download == nil else { return }
        let folder: URL
        do {
            folder = try self.folder ?? downloads.directory()
        } catch {
            status = .failed(error.localizedDescription)
            return
        }
        self.folder = folder
        let kind = kind
        status = .downloading(received: 0, expected: 0)
        Announce.say("Getting the original from \(server).")
        download = Task {
            do {
                let url = try await downloads.fetch(client, assetID, OriginalSource.role(for: kind), folder,
                                                    OriginalSource.fileName(for: kind)) { received, expected in
                    Task { @MainActor in
                        guard case .downloading = self.status else { return }
                        self.status = .downloading(received: received, expected: expected)
                    }
                }
                try Task.checkCancellation()
                if kind == .video {
                    originalFacts = await ItemMedia.videoFacts(at: url)
                    try Task.checkCancellation()
                    originalPlayer = AVPlayer(url: url)
                    pair.attach(original: originalPlayer, compact: compactPlayer)
                } else {
                    guard let loaded = await Task.detached(operation: { ItemMedia.image(at: url) }).value else {
                        throw PhotoLibrary.Failure.unsupported("The original couldn't be opened on this iPhone.")
                    }
                    originalFacts = loaded.facts
                    original = await loaded.image.byPreparingForDisplay() ?? loaded.image
                }
                try Task.checkCancellation()
                status = .ready
                Announce.say("The original is ready to compare.")
            } catch let error as URLError where error.code == .cancelled {
                status = .stopped
            } catch is CancellationError {
                status = .stopped
            } catch {
                status = .failed(error.localizedDescription)
            }
            download = nil
        }
    }

    /// Cancels the download; the compact copy stays.
    func stop() {
        download?.cancel()
    }

    /// Stops any download and deletes the downloaded original.
    func close() {
        videoSwitch += 1
        download?.cancel()
        download = nil
        originalPlayer?.pause()
        compactPlayer?.pause()
        pair.stop()
        if let folder { try? FileManager.default.removeItem(at: folder) }
        folder = nil
    }

    /// Videos: the other version carries on from the same moment.
    func switchVideo(from old: CompareMode, to new: CompareMode) {
        guard isVideo, old != new else { return }
        videoSwitch += 1
        let version = videoSwitch
        let time: Double
        let playing: Bool
        if old == .sideBySide {
            time = pair.time
            playing = pair.isPlaying
            pair.pause()
            pair.active = false
        } else {
            let from = player(old)
            time = from?.currentTime().seconds ?? 0
            playing = from?.timeControlStatus != .paused && from != nil
            from?.pause()
        }
        let position = time.isFinite ? time : 0
        if new == .sideBySide {
            pair.active = true
            pair.seek(to: position) { [weak self] in
                guard let self, videoSwitch == version, pair.active, playing else { return }
                pair.play()
            }
        } else if let to = player(new) {
            to.isMuted = false
            to.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) {
                [weak self, weak to] finished in
                Task { @MainActor [weak self, weak to] in
                    guard let self, videoSwitch == version, !pair.active, finished, playing else { return }
                    to?.play()
                }
            }
        }
    }

    private func player(_ mode: CompareMode) -> AVPlayer? {
        mode == .original ? originalPlayer : compactPlayer
    }

    /// `ServerClient.downloadOriginal` on a session of its own, so its progress can be read while
    /// it runs. Cancelling the calling task cancels the download.
    nonisolated static func fetch(_ client: ServerClient, assetID: String, role: ServerAPI.ResourceRole, to folder: URL,
                                  name: String, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> URL {
        let (session, delegate) = ServerSessions.shared.freshSession(trust: client.trust)
        defer { session.invalidateAndCancel() }
        var isolated = ServerClient(baseURL: client.baseURL, token: client.token, trust: client.trust,
                                    session: session, delegate: delegate, reconnect: client.reconnect)
        isolated.timeout = client.timeout
        let watcher = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                if let task = await session.allTasks.first {
                    progress(task.countOfBytesReceived, task.countOfBytesExpectedToReceive)
                }
            }
        }
        defer { watcher.cancel() }
        return try await isolated.downloadOriginal(assetID: assetID, role: role, to: folder, name: name)
    }
}

/// Compare (DESIGN 01·1.13; iPhone Duo 03): an item's original next to its compact copy, with one
/// zoom for both. Split shows the original left of a line and the compact copy right of it; drag
/// the line, or pick Original or Compact Copy and touch and hold to see the other one. Videos
/// play together side by side where both fit, or switch between them from the same moment.
///
/// Push it on a `NavigationStack`: it sets its own title and has no Close button. Add actions
/// below it with `.safeAreaBar(edge: .bottom)`. A downloaded original is deleted when it closes.
struct CompareView: View {
    let model: AppModel
    /// The compact copy's local identifier; its original is found in the ledger.
    let compactIdentifier: String
    /// False when it's part of another screen (Free Up Space on the open iPhone Duo), which has the title.
    var standalone = true
    private let loadsOnAppear: Bool
    @State private var compare: CompareModel
    @State private var mode = CompareMode.split
    @State private var split: Double
    @State private var holding = false
    @State private var zoomed = false
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.mediaPresentation) private var mediaPresentation

    static let stage = "compare.stage"

    /// A supplied comparison is already loaded; otherwise the view owns loading.
    init(model: AppModel, compactIdentifier: String, standalone: Bool = true, split: Double = 0.5,
         comparison: CompareModel? = nil) {
        self.model = model
        self.compactIdentifier = compactIdentifier
        self.standalone = standalone
        loadsOnAppear = comparison == nil
        _split = State(initialValue: min(1, max(0, split)))
        _compare = State(initialValue: comparison ?? CompareModel())
    }

    /// Touch and hold shows the other version.
    private var shown: CompareMode {
        guard holding else { return mode }
        switch mode {
        case .original: return .compact
        case .compact: return .original
        case .split, .sideBySide: return mode
        }
    }

    /// Side by Side where there's room for both (the open iPhone Duo), first; the slider on a phone.
    private var modes: [CompareMode] {
        Self.modes(video: compare.isVideo, regular: sizeClass == .regular)
    }

    static func modes(video: Bool, regular: Bool) -> [CompareMode] {
        if video { return regular ? [.sideBySide, .original, .compact] : [.original, .compact] }
        return regular ? [.sideBySide, .split, .original, .compact] : [.original, .compact, .split]
    }

    static func adjusted(_ mode: CompareMode, video: Bool, regular: Bool) -> CompareMode {
        if regular, mode == .split { return .sideBySide }
        if !regular, mode == .sideBySide { return video ? .compact : .split }
        if video, mode == .split { return regular ? .sideBySide : .compact }
        let offered = modes(video: video, regular: regular)
        return offered.contains(mode) ? mode : offered[0]
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Show", selection: $mode) {
                ForEach(modes) { mode in Text(mode.title).tag(mode) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .accessibilityIdentifier("compare.mode")
            stage
            if compare.isVideo, shown == .sideBySide {
                CompareTransport(pair: compare.pair, durationOverride: mediaPresentation == .poster ? compare.duration : nil)
            }
            facts
        }
        .background(Theme.background)
        .modifier(CompareScreen(standalone: standalone))
        .task(id: compactIdentifier) {
            guard loadsOnAppear else { return }
            await compare.load(model: model, compactIdentifier: compactIdentifier, presentation: mediaPresentation)
            guard !Task.isCancelled else { return }
            mode = Self.adjusted(mode, video: compare.isVideo, regular: sizeClass == .regular)
            if compare.isVideo, mode == .sideBySide { compare.pair.active = true }
        }
        // Side by side where both fit (opening iPhone Duo too); the slider when it folds.
        .onChange(of: sizeClass, initial: true) { _, size in
            mode = Self.adjusted(mode, video: compare.isVideo, regular: size == .regular)
        }
        .onChange(of: mode) { old, new in compare.switchVideo(from: old, to: new) }
        .onDisappear { compare.close() }
    }

    // MARK: The photo

    private var stage: some View {
        GeometryReader { geo in
            ZStack {
                if compare.isVideo, mediaPresentation == .interactive, shown == .sideBySide {
                    SideBySide(media: .videos(original: compare.originalPlayer, compact: compare.compactPlayer,
                                              size: compare.videoSize),
                               originalLabel: originalPill, compactLabel: "Compact copy · in Photos")
                } else if compare.isVideo, mediaPresentation == .interactive {
                    let player = shown == .original ? compare.originalPlayer : compare.compactPlayer
                    if let player {
                        VideoPlayer(player: player).id(shown)
                    } else {
                        Theme.fill
                    }
                } else if shown == .sideBySide {
                    SideBySide(media: .photos(original: compare.original, compact: compare.compact), originalLabel: originalPill,
                               compactLabel: "Compact copy · in Photos")
                } else {
                    CompareCanvas(original: compare.original, compact: compare.compact, mode: shown, split: split,
                                  label: imageLabel, onZoom: { zoomed = $0 }) { holding = $0 }
                    if shown == .split, compare.hasOriginal, compare.hasCompact {
                        // The line spans the photo; the whole height once it's zoomed in.
                        let photo = ZoomScrollView.fitted(compare.compact?.size ?? .zero, in: geo.size)
                        SplitHandle(split: $split, size: geo.size, height: zoomed ? geo.size.height : photo.height,
                                    knobY: Self.knobY(in: geo, height: zoomed ? geo.size.height : photo.height))
                    }
                }
                if shown != .sideBySide { pills }
                status.frame(maxHeight: .infinity, alignment: .bottom).padding(16)
            }
            .coordinateSpace(.named(Self.stage))
        }
        .clipped()
    }

    /// The split line's knob: in the middle of the line, unless iPhone Duo is partly folded with the
    /// crease across it (held tall, like a laptop). Then just below the crease, so it's never on it
    /// (HIG: keep controls on one side of an active division; the photo itself runs across).
    static func knobY(in proxy: GeometryProxy, height: CGFloat) -> CGFloat {
        let middle = proxy.size.height / 2
        guard #available(iOS 27.1, *),
              let fold = proxy.reservedRegions(kind: .division).first?.frame, fold.width > fold.height else { return middle }
        return knobY(middle: middle, line: (middle - height / 2)...(middle + height / 2), fold: fold)
    }

    /// Off a horizontal fold, staying on the line: below it if there's room, else above.
    static func knobY(middle: CGFloat, line: ClosedRange<CGFloat>, fold: CGRect, knob: CGFloat = 44) -> CGFloat {
        let half = knob / 2
        guard middle + half > fold.minY, middle - half < fold.maxY else { return middle }
        if fold.maxY + knob <= line.upperBound { return fold.maxY + half + 8 }
        return max(line.lowerBound + half, fold.minY - half - 8)
    }

    private var imageLabel: String {
        switch shown {
        case .original: "Original"
        case .compact: "Compact copy"
        case .split: "Original on the left, compact copy on the right"
        case .sideBySide: "Original and compact copy, side by side"
        }
    }

    private var originalPill: String {
        switch compare.source {
        case .phone: "Original · on this iPhone"
        case .server: "Original · from \(compare.server)"
        default: "Original"
        }
    }

    private var pills: some View {
        HStack(alignment: .top) {
            if shown != .compact, compare.hasOriginal {
                pill(originalPill).accessibilityIdentifier("compare.original")
            }
            Spacer(minLength: 8)
            if shown != .original, compare.hasCompact {
                pill("Compact copy · in Photos").accessibilityIdentifier("compare.compact")
            }
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
    }

    private func pill(_ text: String) -> some View {
        Text(text).font(.footnote.weight(.medium)).foregroundStyle(Theme.label)
            .lineLimit(1).minimumScaleFactor(0.8)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Theme.card.opacity(0.92), in: Capsule())
    }

    @ViewBuilder private var status: some View {
        switch compare.status {
        case .downloading(let received, let expected):
            VStack(alignment: .leading, spacing: 8) {
                Text("Getting the original from \(compare.server)").font(.subheadline.weight(.semibold))
                ProgressView(value: expected > 0 ? Double(min(received, expected)) : nil, total: Double(max(expected, 1)))
                    .accessibilityValue(expected > 0 ? "\(MediaFacts.size(Int(received))) of \(MediaFacts.size(Int(expected)))" : "")
                HStack {
                    Text(expected > 0 ? "\(MediaFacts.size(Int(received))) of \(MediaFacts.size(Int(expected)))"
                         : MediaFacts.size(Int(received)))
                        .font(.footnote.monospacedDigit()).foregroundStyle(Theme.secondaryLabel)
                        .accessibilityHidden(true)
                    Spacer()
                    Button("Cancel") { compare.stop() }.font(.subheadline.weight(.semibold))
                        .accessibilityIdentifier("compare.cancel")
                }
            }
            .card(padding: 14)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("compare.progress")
        case .stopped:
            notice("The original wasn't downloaded", "Only the compact copy is shown.", button: "Get the Original")
        case .failed(let message):
            notice("Couldn't get the original", message, button: compare.source == .unknown ? nil : "Try Again")
        case .inImmich:
            notice("Original is in Immich", "\(compare.server) reads originals from Immich, so open it there to see it at full quality.")
        case .noOriginal:
            notice("No original to compare", "This iPhone has no record of where this copy's original is.")
        case .loading, .ready:
            EmptyView()
        }
    }

    private func notice(_ title: String, _ message: String, button: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.label)
            Text(message).font(.footnote).foregroundStyle(Theme.secondaryLabel)
            if let button, case .server = compare.source {
                Button(button) { compare.fetchOriginal() }.font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("compare.retry")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 14)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("compare.notice")
    }

    // MARK: Sizes

    private var facts: some View {
        let tight = compare.isVideo && shown == .sideBySide && !standalone
        return VStack(spacing: 4) {
            line("Original", compare.originalFacts, emphasised: shown != .compact)
                .accessibilityIdentifier("compare.originalFacts")
            line("Compact copy", compare.compactFacts, emphasised: shown != .original)
                .accessibilityIdentifier("compare.compactFacts")
            Text(hint).font(.footnote).foregroundStyle(Theme.secondaryLabel)
                .multilineTextAlignment(.center).padding(.top, tight ? 0 : 8)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, tight ? 0 : 14)
        .frame(maxWidth: .infinity)
    }

    private func line(_ title: String, _ facts: MediaFacts, emphasised: Bool) -> some View {
        Text(facts.isEmpty ? title : "\(title) · \(facts.line)")
            .font(.subheadline.weight(emphasised ? .semibold : .regular))
            .foregroundStyle(emphasised ? Theme.label : Theme.secondaryLabel)
            .multilineTextAlignment(.center)
    }

    private var hint: String {
        var text = compare.isVideo ? (shown == .sideBySide ? "They play together. Zoom or move either one; the other follows."
                                     : "Switch between them; the other carries on from the same moment.")
            : shown == .sideBySide ? "Zoom or move either one; the other follows."
            : shown == .split ? "Zoom in to compare the details. Drag the line to move it."
            : "Zoom in to compare the details. Touch and hold to see the other one."
        if case .server = compare.source, compare.status == .ready {
            text += " The original came from \(compare.server) for this and isn't kept on this iPhone."
        }
        return text
    }
}

/// Compare on its own screen supplies its title; embedded Compare uses its parent's title.
private struct CompareScreen: ViewModifier {
    let standalone: Bool

    func body(content: Content) -> some View {
        if standalone {
            content.navigationTitle("Compare").navigationBarTitleDisplayMode(.inline)
        } else {
            content
        }
    }
}

/// The original and the compact copy each whole, next to each other or one above the other,
/// whichever shows the photo larger (a tall photo side by side, a wide one stacked); zooming or
/// moving one moves the other. On a partly folded iPhone Duo the two meet at the crease, so neither
/// has it across it.
struct SideBySide: View {
    enum Media {
        case photos(original: UIImage?, compact: UIImage?)
        case videos(original: AVPlayer?, compact: AVPlayer?, size: CGSize?)

        var size: CGSize? {
            switch self {
            case .photos(let original, let compact): (original ?? compact)?.size
            case .videos(_, _, let size): size
            }
        }

        func has(_ first: Bool) -> Bool {
            switch self {
            case .photos(let original, let compact): (first ? original : compact) != nil
            case .videos(let original, let compact, _): (first ? original : compact) != nil
            }
        }
    }

    var media: Media
    var originalLabel: String
    var compactLabel: String
    @State private var link = ZoomLink()

    var body: some View {
        GeometryReader { proxy in
            let panes = Self.panes(size: proxy.size, fold: Self.fold(proxy), photo: media.size)
            ZStack(alignment: .topLeading) {
                pane(first: true, label: originalLabel, id: "compare.original", image: "compare.image.original")
                    .frame(width: panes.first.width, height: panes.first.height)
                    .offset(x: panes.first.minX, y: panes.first.minY)
                pane(first: false, label: compactLabel, id: "compare.compact", image: "compare.image.compact")
                    .frame(width: panes.second.width, height: panes.second.height)
                    .offset(x: panes.second.minX, y: panes.second.minY)
            }
        }
    }

    private func pane(first: Bool, label: String, id: String, image imageID: String) -> some View {
        picture(first: first, label: label, identifier: imageID)
            .background(Color.black)
            .overlay(alignment: .topLeading) {
                if media.has(first) {
                    Text(label).font(.footnote.weight(.medium)).foregroundStyle(Theme.label)
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Theme.card.opacity(0.92), in: Capsule())
                        .padding(12)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier(id)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
    }

    @ViewBuilder private func picture(first: Bool, label: String, identifier: String) -> some View {
        switch media {
        case .photos(let original, let compact):
            LinkedZoomImage(image: first ? original : compact, link: link, label: label, identifier: identifier)
        case .videos(let original, let compact, let size):
            LinkedZoomPlayer(player: first ? original : compact, size: size, link: link, label: label, identifier: identifier)
        }
    }

    /// An active fold (partly folded iPhone Duo), in the stage's coordinates.
    static func fold(_ proxy: GeometryProxy) -> CGRect? {
        guard #available(iOS 27.1, *) else { return nil }
        return proxy.reservedRegions(kind: .division).first?.frame
    }

    /// Two halves: at the fold when it crosses the stage the long way and leaves room on both sides;
    /// otherwise left and right or top and bottom, whichever fits the photo larger (without a photo
    /// yet: left and right when the stage is wide).
    static func panes(size: CGSize, fold: CGRect?, photo: CGSize? = nil, gap: CGFloat = 2) -> (first: CGRect, second: CGRect) {
        var wide = size.width >= size.height
        if let photo, photo.width > 0, photo.height > 0 {
            func shown(_ pane: CGSize) -> CGFloat {
                let scale = min(pane.width / photo.width, pane.height / photo.height)
                return photo.width * scale * photo.height * scale
            }
            let beside = shown(CGSize(width: (size.width - gap) / 2, height: size.height))
            let stacked = shown(CGSize(width: size.width, height: (size.height - gap) / 2))
            if beside != stacked { wide = beside > stacked }
        }
        if let fold {
            if fold.height > fold.width, fold.minX > 120, fold.maxX < size.width - 120 {
                return (CGRect(x: 0, y: 0, width: fold.minX, height: size.height),
                        CGRect(x: fold.maxX, y: 0, width: size.width - fold.maxX, height: size.height))
            }
            if fold.width > fold.height, fold.minY > 120, fold.maxY < size.height - 120 {
                return (CGRect(x: 0, y: 0, width: size.width, height: fold.minY),
                        CGRect(x: 0, y: fold.maxY, width: size.width, height: size.height - fold.maxY))
            }
        }
        if wide {
            let width = (size.width - gap) / 2
            return (CGRect(x: 0, y: 0, width: width, height: size.height),
                    CGRect(x: width + gap, y: 0, width: width, height: size.height))
        }
        let height = (size.height - gap) / 2
        return (CGRect(x: 0, y: 0, width: size.width, height: height),
                CGRect(x: 0, y: height + gap, width: size.width, height: height))
    }
}

/// Zoom views that move together: the same zoom and the same point of the photo in the middle.
@MainActor
final class ZoomLink {
    private let views = NSHashTable<ZoomScrollView>.weakObjects()
    private var following = false

    func add(_ view: ZoomScrollView) {
        views.add(view)
        view.onTransform = { [weak self, weak view] in
            guard let self, let view else { return }
            follow(view)
        }
    }

    private func follow(_ source: ZoomScrollView) {
        guard !following else { return }
        following = true
        defer { following = false }
        for other in views.allObjects where other !== source {
            if abs(other.zoomScale - source.zoomScale) > 0.0001 { other.zoomScale = source.zoomScale }
            let from = source.contentSize, to = other.contentSize
            guard from.width > 0, from.height > 0 else { continue }
            let middle = CGPoint(x: (source.contentOffset.x + source.bounds.width / 2) / from.width,
                                 y: (source.contentOffset.y + source.bounds.height / 2) / from.height)
            let insets = other.contentInset
            let x = min(max(middle.x * to.width - other.bounds.width / 2, -insets.left),
                        max(-insets.left, to.width - other.bounds.width + insets.right))
            let y = min(max(middle.y * to.height - other.bounds.height / 2, -insets.top),
                        max(-insets.top, to.height - other.bounds.height + insets.bottom))
            other.contentOffset = CGPoint(x: x, y: y)
        }
    }
}

/// One photo in a `ZoomScrollView` that moves with the others in its `ZoomLink`.
private struct LinkedZoomImage: UIViewRepresentable {
    var image: UIImage?
    let link: ZoomLink
    var label: String
    var identifier: String

    func makeUIView(context: Context) -> ZoomScrollView {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.isAccessibilityElement = true
        imageView.accessibilityTraits = .image
        let view = ZoomScrollView(content: imageView)
        link.add(view)
        return view
    }

    func updateUIView(_ view: ZoomScrollView, context: Context) {
        guard let imageView = view.content as? UIImageView else { return }
        if imageView.image !== image { imageView.image = image }
        view.aspect = image?.size ?? .zero
        imageView.accessibilityLabel = label
        imageView.accessibilityIdentifier = identifier
    }
}

/// The line between the original (left) and the compact copy (right). VoiceOver adjusts it by
/// tenths.
private struct SplitHandle: View {
    @Binding var split: Double
    let size: CGSize
    let height: CGFloat
    /// Where the knob sits on the line (off the fold of a partly folded iPhone Duo).
    var knobY: CGFloat? = nil

    var body: some View {
        ZStack {
            Rectangle().fill(.white).frame(width: 2, height: height).shadow(color: .black.opacity(0.35), radius: 1.5)
            Image(systemName: "arrow.left.and.right")
                .font(.footnote.weight(.bold)).foregroundStyle(Color(hex: 0x2B2622))
                .frame(width: 36, height: 36)
                .background(Circle().fill(.white))
                .shadow(color: .black.opacity(0.3), radius: 3)
                .offset(y: (knobY ?? size.height / 2) - size.height / 2)
        }
        .frame(width: 44, height: height)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(CompareView.stage)).onChanged { value in
            split = SplitPosition.at(x: value.location.x, width: size.width)
        })
        .accessibilityElement()
        .accessibilityLabel("Split line")
        .accessibilityValue(SplitPosition.spoken(split))
        .accessibilityHint("The original is on the left, the compact copy on the right.")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: split = SplitPosition.adjusted(split, increment: true)
            case .decrement: split = SplitPosition.adjusted(split, increment: false)
            @unknown default: break
            }
        }
        .accessibilityIdentifier("compare.split")
        .position(x: size.width * split, y: size.height / 2)
    }
}

/// Both versions in one `ZoomScrollView`, so they zoom and pan together. In Split the compact
/// copy shows right of a line that stays put on screen while the photo zooms under it.
private struct CompareCanvas: UIViewRepresentable {
    var original: UIImage?
    var compact: UIImage?
    var mode: CompareMode
    var split: Double
    var label: String
    var onZoom: (Bool) -> Void
    var onHold: (Bool) -> Void

    final class Content: UIView {
        let original = UIImageView()
        let compact = UIImageView()
        private let reveal = CALayer()
        var mode = CompareMode.split
        var split = 0.5

        override init(frame: CGRect) {
            super.init(frame: frame)
            for view in [original, compact] {
                view.frame = bounds
                view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                view.contentMode = .scaleAspectFit
                addSubview(view)
            }
            reveal.backgroundColor = UIColor.black.cgColor
            isAccessibilityElement = true
            accessibilityTraits = .image
            accessibilityIdentifier = "compare.image"
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func update(in scroll: UIScrollView) {
            original.isHidden = mode == .compact
            compact.isHidden = mode == .original
            guard mode == .split else {
                compact.layer.mask = nil
                return
            }
            let line = CGPoint(x: scroll.bounds.minX + scroll.bounds.width * split, y: scroll.bounds.minY)
            let x = scroll.convert(line, to: compact).x
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            reveal.frame = CGRect(x: x, y: 0, width: max(0, compact.bounds.width - x), height: compact.bounds.height)
            if compact.layer.mask !== reveal { compact.layer.mask = reveal }
            CATransaction.commit()
        }
    }

    func makeUIView(context: Context) -> ZoomScrollView {
        let content = Content()
        let view = ZoomScrollView(content: content)
        view.onTransform = { [weak view, weak content] in
            guard let view, let content else { return }
            content.update(in: view)
        }
        return view
    }

    func updateUIView(_ view: ZoomScrollView, context: Context) {
        guard let content = view.content as? Content else { return }
        if content.original.image !== original { content.original.image = original }
        if content.compact.image !== compact { content.compact.image = compact }
        view.aspect = (compact ?? original)?.size ?? .zero
        content.mode = mode
        content.split = split
        content.accessibilityLabel = label
        let hold = onHold, zoom = onZoom
        view.onHold = { held in Task { @MainActor in hold(held) } }
        view.onZoom = { zoomed in Task { @MainActor in zoom(zoomed) } }
        content.update(in: view)
    }
}
