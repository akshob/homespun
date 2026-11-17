// SPDX-License-Identifier: Apache-2.0
import Photos
import SwiftUI

/// An original ready to free up, and its compact copy in Photos.
struct FreeUpPair: Hashable, Identifiable, Sendable {
    let original: String
    let compact: String
    var id: String { original }
}

/// Free Up Space (DESIGN 02·3.1–3.5): explains, checks each original with the server again, lets
/// iOS ask, and shows what was freed. Each compact copy can be compared with its original first
/// (the first time, before anything is removed, that's the point), and any item can keep its
/// original instead (its compact copy goes). On a phone and iPhone Duo's cover it's one sheet, and
/// Compare opens inside it; on the open iPhone Duo it's the whole screen: the review beside the item
/// compared side by side.
struct FreeUpSpaceScreen: View {
    let controller: LibraryController
    let scope: Set<String>?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var path: [FreeUpPair] = []
    @State private var pairs: [FreeUpPair] = []
    @State private var selected: FreeUpPair?
    @State private var detent: PresentationDetent

    init(controller: LibraryController, scope: Set<String>?) {
        self.controller = controller
        self.scope = scope
        _detent = State(initialValue: controller.settings.trialConfirmed ? .medium : .large)
    }

    private var originals: [String] {
        guard let scope else { return controller.ready.originals }
        return controller.ready.originals.filter { scope.contains($0) }
    }

    private var reviewing: Bool {
        if case .idle = controller.removal { return true }
        return false
    }

    var body: some View {
        Group {
            if sizeClass == .regular, reviewing, !pairs.isEmpty { whole } else { stacked }
        }
        .presentationDetents(controller.settings.trialConfirmed ? [.medium, .large] : [.large], selection: $detent)
        .interactiveDismissDisabled(controller.isRemoving)
        .task(id: originals) { await loadPairs() }
    }

    private var closeButton: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            if !controller.isRemoving {
                Button("Close", systemImage: "xmark") { dismiss() }.accessibilityIdentifier("remove.close")
            }
        }
    }

    /// One sheet; a photo's Compare opens inside it (Back returns to the review).
    private var stacked: some View {
        NavigationStack(path: $path) {
            FreeUpSpacePanel(controller: controller, scope: scope, pairs: pairs, close: { dismiss() }) { path.append($0) }
                .navigationTitle("Free Up Space")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { closeButton }
                .navigationDestination(for: FreeUpPair.self) { pair in
                    CompareView(model: AppModel.shared, compactIdentifier: pair.compact)
                        .safeAreaBar(edge: .bottom) {
                            KeepOriginalButton(controller: controller, pair: pair) { path.removeAll() }
                                .padding(.horizontal, 24).padding(.bottom, 8)
                        }
                }
        }
        .onChange(of: path) { _, path in if !path.isEmpty { detent = .large } }
    }

    /// The whole screen of the open iPhone Duo: held wide, the review as a column beside the item
    /// compared side by side; held tall, the comparison above and the review below it.
    private var whole: some View {
        NavigationStack {
            GeometryReader { proxy in
                if proxy.size.height > proxy.size.width {
                    VStack(spacing: 0) {
                        comparison
                        Divider()
                        FreeUpSpacePanel(controller: controller, scope: scope, pairs: pairs, selected: selected, brief: true,
                                         close: { dismiss() }) { selected = $0 }
                            .frame(height: min(300, proxy.size.height * 0.34))
                    }
                } else {
                    HStack(spacing: 0) {
                        FreeUpSpacePanel(controller: controller, scope: scope, pairs: pairs, selected: selected, grid: true,
                                         close: { dismiss() }) { selected = $0 }
                            .frame(width: min(400, max(320, proxy.size.width * 0.36)))
                        Divider()
                        comparison
                    }
                }
            }
            .navigationTitle("Free Up Space")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { closeButton }
        }
    }

    @ViewBuilder private var comparison: some View {
        if let selected {
            CompareView(model: AppModel.shared, compactIdentifier: selected.compact, standalone: false)
                .id(selected)
                .safeAreaBar(edge: .bottom) {
                    KeepOriginalButton(controller: controller, pair: selected) { advance(from: selected) }
                        .padding(.horizontal, 24).padding(.bottom, 8)
                }
        } else {
            ContentUnavailableView("Choose a photo to compare", systemImage: "rectangle.split.2x1")
        }
    }

    /// After keeping one original, the next item (it leaves the list as the library updates).
    private func advance(from kept: FreeUpPair) {
        guard let index = pairs.firstIndex(of: kept) else { return }
        let rest = pairs.filter { $0 != kept }
        selected = rest.isEmpty ? nil : rest[min(index, rest.count - 1)]
    }

    /// Each original's compact copy, from the ledger.
    private func loadPairs() async {
        let wanted = originals
        let ledger = await controller.job.ledger.snapshot()
        let found = wanted.compactMap { original in
            ledger[original].map { FreeUpPair(original: original, compact: $0.compactIdentifier) }
        }
        pairs = found
        if selected.map({ !found.contains($0) }) ?? true { selected = found.first }
    }
}

/// Keep Original: the compact copy goes (iOS asks first) and the original stays on this iPhone,
/// kept full size, out of Free Up Space and automatic mode until Make Compact Copy.
struct KeepOriginalButton: View {
    let controller: LibraryController
    let pair: FreeUpPair
    var kept: () -> Void
    @State private var working = false

    var body: some View {
        VStack(spacing: 6) {
            Button {
                Task {
                    working = true
                    let done = await controller.keepOriginals([pair.original])
                    working = false
                    if done { kept() }
                }
            } label: {
                BusyLabel(title: "Keep Original", busy: working).frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .disabled(working || controller.isRemoving)
            .accessibilityHint("Keeps this original on this iPhone full size and deletes its compact copy. iOS asks first.")
            .accessibilityIdentifier("remove.keepOriginal")
            Text("Keeps this one full size here; its compact copy is deleted.")
                .font(.footnote).foregroundStyle(Theme.secondaryLabel).multilineTextAlignment(.center)
        }
    }
}

/// The review, the check, and the result: the sheet's page, or the open Duo's column.
struct FreeUpSpacePanel: View {
    let controller: LibraryController
    /// Only these originals (from a selection or a finished backup), or everything ready.
    let scope: Set<String>?
    /// Each original's compact copy, to compare (and keep originals) before freeing up.
    var pairs: [FreeUpPair] = []
    /// The item compared beside the panel (the open Duo).
    var selected: FreeUpPair? = nil
    /// The compact copies as a grid (a column beside the comparison) rather than a row.
    var grid = false
    /// Under the comparison on the open iPhone Duo held tall: one line and the row of compact
    /// copies, so the comparison gets the room.
    var brief = false
    var close: () -> Void
    var compare: (FreeUpPair) -> Void = { _ in }
    @State private var somethingWrong = false

    private var settings: AppSettings { controller.settings }
    private var trial: Bool { !settings.trialConfirmed }

    private var originals: [String] {
        guard let scope else { return controller.ready.originals }
        return controller.ready.originals.filter { scope.contains($0) }
    }

    private var count: Int { originals.count }

    private var bytes: Int {
        let sizes = controller.readySizes
        return originals.prefix(count).reduce(0) { $0 + (sizes[$1] ?? 0) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: brief ? 10 : 20) {
                switch controller.removal {
                case .idle: review
                case .checking(let message): checking(message)
                case .done(let report): result(report)
                }
            }
            .padding(brief ? 16 : 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.background)
        .safeAreaBar(edge: .bottom) { actions.padding(.horizontal, 24).padding(.bottom, 12) }
    }

    // MARK: Review

    @ViewBuilder private var review: some View {
        if originals.isEmpty {
            ContentUnavailableView("Nothing to free up yet", systemImage: "circle.lefthalf.filled",
                                   description: Text("Back up some photos first. Their originals can then be removed here."))
        } else if brief {
            Text("\(LibraryController.bytes(bytes)) · \(count) original\(count == 1 ? "" : "s") safe on \(controller.serverName)")
                .font(.headline).monospacedDigit().foregroundStyle(Theme.label)
                .accessibilityIdentifier("remove.bytes")
            Text("Homespun checks each original with \(controller.serverName) again, then iOS asks you. "
                 + "Removed originals stay in Recently Deleted for 30 days.")
                .font(.footnote).foregroundStyle(Theme.secondaryLabel)
            if !pairs.isEmpty { strip }
        } else {
            Text(LibraryController.bytes(bytes)).font(.system(size: 44, weight: .semibold, design: .rounded))
                .monospacedDigit().foregroundStyle(Theme.label)
                .accessibilityIdentifier("remove.bytes")
            Text("\(count) original\(count == 1 ? " is" : "s are") safe on \(controller.serverName). "
                 + (trial ? "Their compact copies stay in Photos."
                    : "Homespun checks each one again, then iOS asks you."))
                .foregroundStyle(Theme.secondaryLabel)
            if trial {
                compareCard
                promise("checkmark.shield", "First, Homespun checks each original with \(controller.serverName) again, byte for byte.")
                promise("trash", "Then iOS asks you. Removed originals stay in Recently Deleted for 30 days.")
                promise("icloud", "With iCloud Photos, they're also removed from iCloud and your other devices. Compact copies stay.")
                if somethingWrong {
                    InlineNotice(tone: .info, title: "Nothing has been removed",
                                 message: "Keep the originals on this iPhone for now. Server › Report a Problem tells us "
                                    + "what looked wrong.")
                }
            } else {
                if !pairs.isEmpty { compareCard }
                DisclosureGroup("How it works") {
                    VStack(alignment: .leading, spacing: 12) {
                        promise("checkmark.shield", "Each original on this iPhone must match \(controller.serverName)'s copy exactly.")
                        promise("trash", "Removed originals stay in Recently Deleted for 30 days.")
                        promise("icloud", "With iCloud Photos, they're also removed from iCloud. Compact copies stay.")
                    }
                    .padding(.top, 8)
                }
                .tint(Theme.accent)
            }
        }
    }

    /// The compact copies that will stay, each comparing with its original (and able to keep the
    /// original instead). The first time, checking them is the point.
    private var compareCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(trial ? "Check the compact copies first" : "Compare before freeing up").font(.headline).foregroundStyle(Theme.label)
            Text(trial ? "They take the originals' place in Photos. Tap one to compare it with its original on \(controller.serverName)."
                 : "Tap one to compare it with its original, or to keep that original instead.")
                .font(.subheadline).foregroundStyle(Theme.secondaryLabel)
            if grid {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 6)], spacing: 6) {
                    ForEach(pairs) { thumbnail($0) }
                }
            } else {
                strip
            }
        }
        .card()
    }

    private var strip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 8) {
                ForEach(pairs) { thumbnail($0) }
            }
        }
        .frame(height: 76)
    }

    private func thumbnail(_ pair: FreeUpPair) -> some View {
        Button { compare(pair) } label: {
            Thumbnail(identifier: pair.compact, manager: controller.library.thumbnails, side: 72)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "rectangle.split.2x1.fill").font(.caption)
                        .foregroundStyle(.white).padding(5).shadow(radius: 2)
                }
                .overlay {
                    if pair == selected {
                        RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.accent, lineWidth: 3)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Compare with the original")
        .accessibilityAddTraits(pair == selected ? .isSelected : [])
        .accessibilityIdentifier("remove.compare")
    }

    // MARK: Checking

    @ViewBuilder private func checking(_ message: String) -> some View {
        Text("Checking with \(controller.serverName)").font(.title2.weight(.semibold))
        ProgressView().frame(maxWidth: .infinity)
        Text(message).font(.subheadline.monospacedDigit()).foregroundStyle(Theme.secondaryLabel)
            .accessibilityIdentifier("remove.progress")
        Text("Each original on this iPhone must match the server's copy exactly (SHA-256). Nothing is removed until iOS asks you.")
            .font(.footnote).foregroundStyle(Theme.secondaryLabel)
    }

    // MARK: Result

    @ViewBuilder private func result(_ report: OriginalRemover.Report) -> some View {
        if !report.removed.isEmpty {
            Label {
                Text("Freed \(LibraryController.bytes(report.freedBytes))").foregroundStyle(Theme.label)
            } icon: {
                Image(systemName: "checkmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, Theme.teal)
            }
            .font(.title2.weight(.semibold))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("remove.summary")
            Text("\(report.removed.count) original\(report.removed.count == 1 ? " is" : "s are") in Recently Deleted until "
                 + "\(Date.now.addingTimeInterval(30 * 86_400).formatted(.dateTime.month(.wide).day())).")
                .foregroundStyle(Theme.secondaryLabel)
        } else if report.cancelled {
            Label("Nothing was removed", systemImage: "hand.raised").font(.title2.weight(.semibold))
                .accessibilityIdentifier("remove.summary")
            Text("iOS asked, and you chose not to delete them. They stay on this iPhone.")
                .foregroundStyle(Theme.secondaryLabel)
        } else if report.blocked.isEmpty {
            Label("Nothing to free up", systemImage: "circle.dashed").font(.title2.weight(.semibold))
                .accessibilityIdentifier("remove.summary")
        }
        if !report.blocked.isEmpty {
            InlineNotice(tone: .warning, title: "Kept \(report.blocked.count)",
                         message: report.blocked.joined(separator: "\n"))
                .accessibilityIdentifier("remove.blocked")
        }
    }

    // MARK: Actions

    @ViewBuilder private var actions: some View {
        switch controller.removal {
        case .idle:
            if !originals.isEmpty {
                VStack(spacing: 8) {
                    Button {
                        // Looked at (or not) before anything is removed: the answer is this tap.
                        if trial { settings.trialConfirmed = true }
                        Task { await controller.freeUp(only: scope) }
                    } label: {
                        Text((trial ? "They Look Right · " : "") + "Free Up \(count) Original\(count == 1 ? "" : "s")")
                            .frame(maxWidth: .infinity)
                    }
                    .primaryAction()
                    .disabled(controller.job.isRunning)
                    .accessibilityIdentifier("remove.confirm")
                    if trial {
                        Button("Something Looks Wrong") { withAnimation { somethingWrong = true } }
                            .accessibilityIdentifier("remove.wrong")
                    }
                    Button("Not Now", action: close).accessibilityIdentifier("remove.notNow")
                }
            }
        case .checking:
            EmptyView()
        case .done:
            Button(action: close) { Text("Done").frame(maxWidth: .infinity) }
                .primaryAction()
                .accessibilityIdentifier("remove.dismiss")
        }
    }

    private func promise(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.title3).foregroundStyle(Theme.accent).frame(width: 28).accessibilityHidden(true)
            Text(text).font(.subheadline).foregroundStyle(Theme.label)
        }
    }
}

/// A row of small thumbnails, for what a sheet is about to act on.
struct ThumbnailStrip: View {
    let identifiers: [String]
    let manager: PHCachingImageManager

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(identifiers, id: \.self) { Thumbnail(identifier: $0, manager: manager, side: 56) }
            }
        }
        .accessibilityHidden(true)
    }
}

/// One item's thumbnail, loaded on appear.
struct Thumbnail: View {
    let identifier: String
    let manager: PHCachingImageManager
    var side: CGFloat = 56
    @State private var image: UIImage?

    var body: some View {
        Theme.fill
            .frame(width: side, height: side)
            .overlay { if let image { Image(uiImage: image).resizable().scaledToFill() } }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .task(id: identifier) {
                guard let asset = PhotoLibrary.asset(identifier) else { return }
                let options = PHImageRequestOptions()
                options.deliveryMode = .opportunistic
                options.isNetworkAccessAllowed = true
                let size = CGSize(width: side * 3, height: side * 3)
                manager.requestImage(for: asset, targetSize: size, contentMode: .aspectFill, options: options) { result, _ in
                    MainActor.assumeIsolated { if let result { image = result } }
                }
            }
    }
}
