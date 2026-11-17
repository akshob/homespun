// SPDX-License-Identifier: Apache-2.0
import AVKit
import HomespunCore
import Photos
import SwiftUI

/// What Compare shows: one version, or both split by a line.
enum CompareMode: String, CaseIterable, Identifiable {
    case original, compact, split
    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: "Original"
        case .compact: "Compact Copy"
        case .split: "Split"
        }
    }
}

/// Loads an item's original and its compact copy for Compare. The original comes from this
/// iPhone while it's here; otherwise it's downloaded from the server into a temporary folder that
/// is deleted when Compare closes.
@MainActor @Observable
final class CompareModel {
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
    private(set) var server = "your server"
    @ObservationIgnored private var client: ServerClient?
    @ObservationIgnored private var download: Task<Void, Never>?
    @ObservationIgnored private var folder: URL?

    var isVideo: Bool { kind == .video }
    var hasOriginal: Bool { original != nil || originalPlayer != nil }
    var hasCompact: Bool { compact != nil || compactPlayer != nil }

    func load(model: AppModel, compactIdentifier: String) async {
        close()
        status = .loading
        original = nil
        compact = nil
        originalPlayer = nil
        compactPlayer = nil
        server = model.library.serverName
        client = model.settings.client
        guard let asset = PhotoLibrary.asset(compactIdentifier) else {
            status = .failed("The compact copy isn't in Photos any more.")
            return
        }
        kind = PhotoLibrary.kind(of: asset) ?? .photo
        compactFacts = ItemMedia.facts(asset).main
        let match = await model.job.ledger.snapshot().first { $0.value.compactIdentifier == compactIdentifier }
        guard !Task.isCancelled else { return }
        let originalAsset = match.flatMap { PhotoLibrary.asset($0.key) }
        source = OriginalSource.choose(original: match?.key, onPhone: originalAsset != nil,
                                       serverAssetID: match?.value.serverAssetID, mode: model.settings.server?.mode)
        switch source {
        case .phone: if let originalAsset { originalFacts = ItemMedia.facts(originalAsset).main }
        case .server: fetchOriginal()
        case .immich: status = .inImmich
        case .unknown: status = .noOriginal
        }
        if isVideo {
            compactPlayer = await ItemMedia.player(asset)
        } else {
            compact = await ItemMedia.image(asset, size: nil)
        }
        if case .phone = source, let originalAsset, !Task.isCancelled {
            if isVideo {
                originalPlayer = await ItemMedia.player(originalAsset)
            } else {
                original = await ItemMedia.image(originalAsset, size: nil)
            }
            status = hasOriginal ? .ready : .failed("The original couldn't be read from Photos.")
        }
    }

    /// Downloads the original from the server (again, after Cancel), with progress.
    func fetchOriginal() {
        guard case .server(let assetID) = source, let client, download == nil else { return }
        let folder: URL
        do {
            folder = try self.folder ?? PhotoLibrary.workDirectory()
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
                let url = try await Self.fetch(client, assetID: assetID, role: OriginalSource.role(for: kind), to: folder,
                                               name: OriginalSource.fileName(for: kind)) { received, expected in
                    Task { @MainActor in
                        guard case .downloading = self.status else { return }
                        self.status = .downloading(received: received, expected: expected)
                    }
                }
                try Task.checkCancellation()
                if kind == .video {
                    originalFacts = await ItemMedia.videoFacts(at: url)
                    originalPlayer = AVPlayer(url: url)
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
        download?.cancel()
        download = nil
        originalPlayer?.pause()
        compactPlayer?.pause()
        if let folder { try? FileManager.default.removeItem(at: folder) }
        folder = nil
    }

    /// Videos: the other version carries on from the same moment.
    func switchVideo(from old: CompareMode, to new: CompareMode) {
        guard isVideo, let from = player(old), let to = player(new), from !== to else { return }
        let playing = from.timeControlStatus == .playing
        from.pause()
        to.seek(to: from.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero)
        if playing { to.play() }
    }

    private func player(_ mode: CompareMode) -> AVPlayer? {
        mode == .original ? originalPlayer : compactPlayer
    }

    /// `ServerClient.downloadOriginal` on a session of its own, so its progress can be read while
    /// it runs. Cancelling the calling task cancels the download.
    nonisolated static func fetch(_ client: ServerClient, assetID: String, role: ServerAPI.ResourceRole, to folder: URL,
                                  name: String, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> URL {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var client = client
        client.session = session
        let watcher = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                if let task = await session.allTasks.first {
                    progress(task.countOfBytesReceived, task.countOfBytesExpectedToReceive)
                }
            }
        }
        defer { watcher.cancel() }
        return try await client.downloadOriginal(assetID: assetID, role: role, to: folder, name: name)
    }
}

/// Compare (DESIGN 01·1.13; iPhone Duo 03): an item's original next to its compact copy, with one
/// zoom for both. Split shows the original left of a line and the compact copy right of it; drag
/// the line, or pick Original or Compact Copy and touch and hold to see the other one. Videos
/// switch between the two, from the same moment.
///
/// Push it on a `NavigationStack`: it sets its own title and has no Close button. Add actions
/// below it with `.safeAreaBar(edge: .bottom)`. A downloaded original is deleted when it closes.
struct CompareView: View {
    let model: AppModel
    /// The compact copy's local identifier; its original is found in the ledger.
    let compactIdentifier: String
    @State private var compare = CompareModel()
    @State private var mode = CompareMode.split
    @State private var split = 0.5
    @State private var holding = false
    @State private var zoomed = false

    static let stage = "compare.stage"

    init(model: AppModel, compactIdentifier: String) {
        self.model = model
        self.compactIdentifier = compactIdentifier
    }

    /// Touch and hold shows the other version.
    private var shown: CompareMode {
        guard holding else { return mode }
        switch mode {
        case .original: return .compact
        case .compact: return .original
        case .split: return .split
        }
    }

    private var modes: [CompareMode] { compare.isVideo ? [.original, .compact] : CompareMode.allCases }

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
            facts
        }
        .background(Theme.background)
        .navigationTitle("Compare")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .itemScreen()
        .task(id: compactIdentifier) {
            await compare.load(model: model, compactIdentifier: compactIdentifier)
            if compare.isVideo, mode == .split { mode = .compact }
        }
        .onChange(of: mode) { old, new in compare.switchVideo(from: old, to: new) }
        .onDisappear { compare.close() }
    }

    // MARK: The photo

    private var stage: some View {
        GeometryReader { geo in
            ZStack {
                if compare.isVideo {
                    let player = shown == .original ? compare.originalPlayer : compare.compactPlayer
                    if let player {
                        VideoPlayer(player: player).id(shown)
                    } else {
                        Theme.fill
                    }
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
                pills
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
        VStack(spacing: 4) {
            line("Original", compare.originalFacts, emphasised: shown != .compact)
                .accessibilityIdentifier("compare.originalFacts")
            line("Compact copy", compare.compactFacts, emphasised: shown != .original)
                .accessibilityIdentifier("compare.compactFacts")
            Text(hint).font(.footnote).foregroundStyle(Theme.secondaryLabel)
                .multilineTextAlignment(.center).padding(.top, 8)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
    }

    private func line(_ title: String, _ facts: MediaFacts, emphasised: Bool) -> some View {
        Text(facts.isEmpty ? title : "\(title) · \(facts.line)")
            .font(.subheadline.weight(emphasised ? .semibold : .regular))
            .foregroundStyle(emphasised ? Theme.label : Theme.secondaryLabel)
            .multilineTextAlignment(.center)
    }

    private var hint: String {
        var text = compare.isVideo ? "Switch between them; the other carries on from the same moment."
            : shown == .split ? "Zoom in to compare the details. Drag the line to move it."
            : "Zoom in to compare the details. Touch and hold to see the other one."
        if case .server = compare.source, compare.status == .ready {
            text += " The original came from \(compare.server) for this and isn't kept on this iPhone."
        }
        return text
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
