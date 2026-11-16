// SPDX-License-Identifier: Apache-2.0
import Photos
import SwiftUI

/// Free Up Space (DESIGN 02·3.1–3.5): one sheet that explains, checks each original with the server
/// again, lets iOS ask, and shows what was freed. The first time, before anything is removed, it
/// shows the compact copies to compare with their originals; "They Look Right" frees them up.
struct FreeUpSpaceSheet: View {
    let controller: LibraryController
    let scope: Set<String>?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            FreeUpSpacePanel(controller: controller, scope: scope) { dismiss() }
                .navigationTitle("Free Up Space")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if !controller.isRemoving {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close", systemImage: "xmark") { dismiss() }.accessibilityIdentifier("remove.close")
                        }
                    }
                }
        }
        .presentationDetents(controller.settings.trialConfirmed ? [.medium, .large] : [.large])
        .interactiveDismissDisabled(controller.isRemoving)
    }
}

/// The review, the check, and the result; a sheet on iPhone, the right page of the open book on Duo.
struct FreeUpSpacePanel: View {
    let controller: LibraryController
    /// Only these originals (from a selection or a finished backup), or everything ready.
    let scope: Set<String>?
    var close: () -> Void
    @State private var somethingWrong = false
    /// The compact copies of the first few, to compare before the first removal.
    @State private var compacts: [String] = []
    @State private var comparing: Comparing?

    private struct Comparing: Identifiable {
        let id: String
    }

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
            VStack(alignment: .leading, spacing: 20) {
                switch controller.removal {
                case .idle: review
                case .checking(let message): checking(message)
                case .done(let report): result(report)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.background)
        .safeAreaBar(edge: .bottom) { actions.padding(.horizontal, 24).padding(.bottom, 12) }
        .task(id: trial ? originals.prefix(12).joined() : "") {
            guard trial else { return }
            var found: [String] = []
            for original in originals.prefix(12) {
                if let compact = await controller.job.ledger.entry(for: original)?.compactIdentifier { found.append(compact) }
            }
            compacts = found
        }
        .sheet(item: $comparing) { item in
            NavigationStack {
                CompareView(model: AppModel.shared, compactIdentifier: item.id)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close", systemImage: "xmark") { comparing = nil }
                                .accessibilityIdentifier("compare.close")
                        }
                    }
            }
        }
    }

    // MARK: Review

    @ViewBuilder private var review: some View {
        if originals.isEmpty {
            ContentUnavailableView("Nothing to free up yet", systemImage: "circle.lefthalf.filled",
                                   description: Text("Back up some photos first. Their originals can then be removed here."))
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
                ThumbnailStrip(identifiers: Array(originals.prefix(12)), manager: controller.library.thumbnails)
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

    /// The first time: the compact copies that will stay, each opening Compare with its original.
    private var compareCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Check the compact copies first").font(.headline).foregroundStyle(Theme.label)
            Text("They take the originals' place in Photos. Tap one to compare it with its original on \(controller.serverName).")
                .font(.subheadline).foregroundStyle(Theme.secondaryLabel)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(compacts, id: \.self) { compact in
                        Button { comparing = Comparing(id: compact) } label: {
                            Thumbnail(identifier: compact, manager: controller.library.thumbnails, side: 72)
                                .overlay(alignment: .bottomTrailing) {
                                    Image(systemName: "rectangle.split.2x1.fill").font(.caption)
                                        .foregroundStyle(.white).padding(5).shadow(radius: 2)
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Compare with the original")
                        .accessibilityIdentifier("remove.compare")
                    }
                }
            }
        }
        .card()
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
