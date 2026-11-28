// SPDX-License-Identifier: Apache-2.0
import SwiftUI

/// Restore Original: for compact copies whose originals were freed up, brings each original back
/// from home into Photos (the same favorite, hidden and albums), then iOS asks to delete the compact
/// copies. Says first how much room it takes and whether there is room, and if a compact copy was
/// edited (its edits don't carry over to the original).
struct RestoreOriginalSheet: View {
    let controller: LibraryController
    let compacts: [String]
    /// When it closes: whether anything was restored.
    var finished: (Bool) -> Void = { _ in }
    @State private var items: [OriginalRestorer.Item]?
    @State private var edited = 0
    @State private var room: (enough: Bool, free: Int)?
    @Environment(\.dismiss) private var dismiss

    private var server: String { controller.serverName }
    private var bytes: Int { items?.reduce(0) { $0 + $1.originalBytes } ?? 0 }
    private var title: String { compacts.count == 1 ? "Restore Original" : "Restore Originals" }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch controller.restoring {
                    case .idle: confirm
                    case .running(let progress): running(progress)
                    case .done(let report): result(report)
                    }
                }
                .padding(24)
                .frame(maxWidth: 600, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(Theme.background)
            .safeAreaBar(edge: .bottom) { actions.padding(.horizontal, 24).padding(.bottom, 12) }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !controller.isRestoring {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", systemImage: "xmark") { close() }.accessibilityIdentifier("restore.close")
                    }
                }
            }
        }
        .interactiveDismissDisabled(controller.isRestoring)
        .task {
            let found = await controller.restorable(compacts)
            let photos = controller.settings.photos
            let total = found.reduce(0) { $0 + $1.originalBytes }
            let (edits, available) = await PhotoKitReads.run {
                (found.filter { photos.item($0.compact)?.isEdited ?? false }.count,
                 OriginalRestorer.room(for: total))
            }
            guard !Task.isCancelled else { return }
            edited = edits
            room = available
            items = found
        }
    }

    // MARK: Before

    @ViewBuilder private var confirm: some View {
        if let items {
            if items.isEmpty {
                ContentUnavailableView("Nothing to restore", systemImage: "arrow.uturn.backward.circle",
                                       description: Text(controller.settings.server?.mode == .immich
                                                         ? "These originals are in Immich. Restore them from Immich."
                                                         : "These originals are on this iPhone already, or \(server) doesn't have them."))
            } else {
                Text(LibraryController.bytes(bytes)).font(.system(size: 44, weight: .semibold, design: .rounded))
                    .monospacedDigit().foregroundStyle(Theme.label)
                    .accessibilityIdentifier("restore.bytes")
                Text(items.count == 1 ? "The original comes back from \(server) and takes its compact copy's place in Photos."
                     : "\(items.count) originals come back from \(server) and take their compact copies' place in Photos.")
                    .foregroundStyle(Theme.secondaryLabel)
                promise("checkmark.shield", "Each one is checked against \(server)'s copy as it arrives, and again in Photos.")
                promise("heart", "Favorites, hidden photos and albums stay as they are.")
                promise("trash", controller.settings.isDemo
                        ? "Then Homespun asks to delete the compact copies, as iOS would. In the demo, nothing is deleted."
                        : "Then iOS asks to delete the compact copies. They stay in Recently Deleted for 30 days.")
                promise("lock", ReleaseFeatures.automaticMode
                        ? "It stays full size: Free Up Space and automatic mode leave it alone until you make a compact copy again."
                        : "It stays full size: Free Up Space leaves it alone until you make a compact copy again.")
                if edited > 0 {
                    InlineNotice(tone: .warning, title: edited == 1 && items.count == 1 ? "You edited this compact copy"
                                    : "You edited \(edited) of these compact copies",
                                 message: "Those edits don't carry over to the original.")
                        .accessibilityIdentifier("restore.edited")
                }
                if let room, !room.enough {
                    InlineNotice(tone: .error, title: "Not enough room on this iPhone",
                                 message: "It needs \(LibraryController.bytes(bytes + (1 << 30))) free (with 1 GB to spare); "
                                    + "\(LibraryController.bytes(room.free)) is free.")
                        .accessibilityIdentifier("restore.noRoom")
                }
            }
        } else {
            ProgressView().frame(maxWidth: .infinity)
        }
    }

    // MARK: During

    @ViewBuilder private func running(_ progress: OriginalRestorer.Progress) -> some View {
        Text(progress.message).font(.title2.weight(.semibold))
        ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
            .accessibilityValue("\(progress.done) of \(progress.total)")
            .accessibilityIdentifier("restore.progress")
        Text(controller.settings.isDemo
             ? "Keep Homespun open. Nothing is removed until every original is safely back and you say so; in the demo, nothing is deleted."
             : "Keep Homespun open. Nothing is deleted until every original is safely in Photos and iOS asks you.")
            .font(.footnote).foregroundStyle(Theme.secondaryLabel)
    }

    // MARK: After

    @ViewBuilder private func result(_ report: OriginalRestorer.Report) -> some View {
        if !report.restored.isEmpty {
            Label {
                Text(report.restored.count == 1 ? "Restored the original" : "Restored \(report.restored.count) originals")
                    .foregroundStyle(Theme.label)
            } icon: {
                Image(systemName: "checkmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, Theme.teal)
            }
            .font(.title2.weight(.semibold))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("restore.summary")
            Text(report.copiesKept
                 ? "You kept the compact copies, so both are in Photos. Free Up Space can remove the originals again."
                 : controller.settings.isDemo
                 ? "\(LibraryController.bytes(report.bytes)) back, full size. In the demo, the compact copies only left its library; "
                    + "with your own photos, they'd stay in Recently Deleted for 30 days."
                 : "\(LibraryController.bytes(report.bytes)) back on this iPhone, full size. The compact copies are in Recently "
                    + "Deleted until \(Date.now.addingTimeInterval(30 * 86_400).formatted(.dateTime.month(.wide).day())).")
                .foregroundStyle(Theme.secondaryLabel)
        } else {
            Label("Nothing was restored", systemImage: "hand.raised").font(.title2.weight(.semibold))
                .accessibilityIdentifier("restore.summary")
        }
        if !report.problems.isEmpty {
            InlineNotice(tone: .warning, title: "Kept \(report.problems.count) as compact copies",
                         message: report.problems.joined(separator: "\n"))
                .accessibilityIdentifier("restore.problems")
        }
    }

    // MARK: Actions

    @ViewBuilder private var actions: some View {
        switch controller.restoring {
        case .idle:
            if let items, !items.isEmpty {
                Button {
                    controller.restore(items)
                } label: {
                    Text(items.count == 1 ? "Restore Original" : "Restore \(items.count) Originals").frame(maxWidth: .infinity)
                }
                .primaryAction()
                .disabled(room?.enough != true)
                .accessibilityIdentifier("restore.confirm")
            }
        case .running:
            Button("Stop After This One") { controller.stopRestoring() }
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("restore.stop")
        case .done:
            Button { close() } label: { Text("Done").frame(maxWidth: .infinity) }
                .primaryAction()
                .accessibilityIdentifier("restore.done")
        }
    }

    private func close() {
        let restored: Bool = if case .done(let report) = controller.restoring { !report.restored.isEmpty } else { false }
        controller.dismissRestore()
        dismiss()
        finished(restored)
    }

    private func promise(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.title3).foregroundStyle(Theme.accent).frame(width: 28).accessibilityHidden(true)
            Text(text).font(.subheadline).foregroundStyle(Theme.label)
        }
    }
}
