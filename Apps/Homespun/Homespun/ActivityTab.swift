// SPDX-License-Identifier: Apache-2.0
import HomespunCore
import SwiftUI

/// The Activity tab: what's happening now, what's ready to free up, and this session's items.
struct ActivityTab: View {
    let model: AppModel
    var freeUp: () -> Void

    var body: some View {
        let job = model.job, library = model.library
        NavigationStack {
            List {
                if library.ready.count > 0 {
                    Section("Ready") {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(library.ready.count) ready to free up").font(.headline)
                                Text("\(LibraryController.bytes(library.ready.bytes)) on this iPhone")
                                    .font(.subheadline).foregroundStyle(Theme.secondaryLabel)
                            }
                            Spacer()
                            Button("Free Up", action: freeUp).buttonStyle(.glassProminent).tint(Theme.accent)
                                .accessibilityIdentifier("activity.free")
                        }
                    }
                }
                if job.savedOriginalBytes > 0 {
                    Section("Saved this session") {
                        LabeledContent("Originals", value: bytes(job.savedOriginalBytes))
                        LabeledContent("Compact copies", value: bytes(job.savedCompactBytes))
                    }
                }
                if !job.items.isEmpty {
                    Section("Items") {
                        ForEach(job.items) { ItemRow(item: $0) }
                    }
                }
            }
            .overlay {
                if job.items.isEmpty, library.ready.count == 0 {
                    ContentUnavailableView("Nothing yet", systemImage: "clock.arrow.circlepath",
                                           description: Text("Backups and freed space appear here."))
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Activity")
            .toolbar {
                if !job.isRunning, !job.items.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Clear") { job.clearFinished() }.accessibilityIdentifier("activity.clear")
                    }
                }
            }
        }
    }
}

private struct ItemRow: View {
    let item: CompactJob.Item

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: item.symbol).foregroundStyle(.secondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).lineLimit(1).truncationMode(.middle)
                status.font(.caption).accessibilityIdentifier("status.\(stateName)")
            }
        }
    }

    /// Stable name for UI tests.
    private var stateName: String {
        switch item.state {
        case .waiting: "waiting"
        case .working: "working"
        case .saved: "saved"
        case .unchanged: "unchanged"
        case .notYet: "notYet"
        case .failed: "failed"
        }
    }

    @ViewBuilder private var status: some View {
        switch item.state {
        case .waiting:
            Text("Waiting").foregroundStyle(.secondary)
        case .working(let message):
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(message)
            }.foregroundStyle(.secondary)
        case .saved(let original, let compact):
            Text("\(bytes(original)) → \(bytes(compact))").foregroundStyle(Theme.teal)
        case .unchanged(let reason), .notYet(let reason):
            Text(reason).foregroundStyle(.secondary)
        case .failed(let reason):
            Text(reason).foregroundStyle(Theme.red)
        }
    }
}

private func bytes(_ count: Int) -> String {
    Int64(count).formatted(.byteCount(style: .file))
}
