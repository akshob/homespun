// SPDX-License-Identifier: Apache-2.0
import Photos
import SwiftUI

/// Free Up Space (DESIGN 02·3.1–3.5): one sheet that explains, checks each original with the server
/// again, lets iOS ask, and shows what was freed. The first time it removes at most 10 and asks
/// whether the compact copies look right.
struct FreeUpSpaceSheet: View {
    let controller: LibraryController
    /// Only these originals (from a selection or a finished backup), or everything ready.
    let scope: Set<String>?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var somethingWrong = false

    private var settings: AppSettings { controller.settings }
    private var trial: Bool { !settings.trialConfirmed }

    private var originals: [String] {
        guard let scope else { return controller.ready.originals }
        return controller.ready.originals.filter { scope.contains($0) }
    }

    private var count: Int { trial ? min(originals.count, AppSettings.trialLimit) : originals.count }

    private var bytes: Int {
        let sizes = controller.readySizes
        return originals.prefix(count).reduce(0) { $0 + (sizes[$1] ?? 0) }
    }

    var body: some View {
        NavigationStack {
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
            .navigationTitle("Free Up Space")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !controller.isRemoving {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", systemImage: "xmark") { dismiss() }.accessibilityIdentifier("remove.close")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { actions.padding(.horizontal, 24).padding(.bottom, 12) }
        }
        .presentationDetents(trial ? [.large] : [.medium, .large])
        .interactiveDismissDisabled(controller.isRemoving)
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
            ThumbnailStrip(identifiers: Array(originals.prefix(count).prefix(12)), manager: controller.library.thumbnails)
            if trial {
                promise("checkmark.shield", "First, Homespun checks each original with \(controller.serverName) again, byte for byte.")
                promise("trash", "Then iOS asks you. Removed originals stay in Recently Deleted for 30 days.")
                promise("icloud", "With iCloud Photos, they're also removed from iCloud and your other devices. Compact copies stay.")
                if originals.count > AppSettings.trialLimit {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "hand.raised").foregroundStyle(Theme.accent).accessibilityHidden(true)
                        Text("First time: \(count) of \(originals.count). Check how the compact copies look, then free up the rest.")
                            .font(.subheadline)
                    }
                    .card(padding: 14)
                    .accessibilityElement(children: .combine)
                }
            } else {
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
            Label("Freed \(LibraryController.bytes(report.freedBytes))", systemImage: "checkmark.circle.fill")
                .font(.title2.weight(.semibold)).foregroundStyle(Theme.label)
                .symbolRenderingMode(.palette).foregroundStyle(Theme.teal, Theme.label)
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
        if trial, !report.removed.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Do the compact copies look right?").font(.headline)
                Text("Open a few in Photos (the \(PhotoLibrary.albumTitle) album) and compare. If they look right, Homespun "
                     + "frees up everything that's ready next time.")
                    .font(.subheadline).foregroundStyle(Theme.secondaryLabel)
                Button("Open Photos", systemImage: "photo.on.rectangle") {
                    if let url = URL(string: "photos-redirect://") { openURL(url) }
                }
                .font(.subheadline.weight(.semibold))
            }
            .card()
            if somethingWrong {
                InlineNotice(tone: .info, title: "Your originals are still safe",
                             message: "They're on \(controller.serverName), and in Recently Deleted in Photos for 30 days: "
                                + "open Photos › Recently Deleted › Recover. Homespun keeps freeing up at most "
                                + "\(AppSettings.trialLimit) at a time until you say the copies look right.")
            }
        }
    }

    // MARK: Actions

    @ViewBuilder private var actions: some View {
        switch controller.removal {
        case .idle:
            if !originals.isEmpty {
                VStack(spacing: 8) {
                    Button {
                        Task { await controller.freeUp(only: scope) }
                    } label: {
                        Text("Free Up \(count) Original\(count == 1 ? "" : "s")").frame(maxWidth: .infinity)
                    }
                    .primaryAction()
                    .disabled(controller.job.isRunning)
                    .accessibilityIdentifier("remove.confirm")
                    Button("Not Now") { dismiss() }.accessibilityIdentifier("remove.notNow")
                }
            }
        case .checking:
            EmptyView()
        case .done(let report):
            if trial, !report.removed.isEmpty {
                VStack(spacing: 8) {
                    Button {
                        settings.trialConfirmed = true
                        dismiss()
                    } label: {
                        Text("They Look Right").frame(maxWidth: .infinity)
                    }
                    .primaryAction()
                    .accessibilityIdentifier("trial.confirm")
                    Button("Something's Wrong") { somethingWrong = true }
                }
            } else {
                Button { dismiss() } label: { Text("Done").frame(maxWidth: .infinity) }
                    .primaryAction()
                    .accessibilityIdentifier("remove.dismiss")
            }
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
