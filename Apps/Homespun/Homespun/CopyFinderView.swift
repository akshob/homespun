// SPDX-License-Identifier: Apache-2.0
import SwiftUI

/// Finds compact copies made elsewhere (see `CopyFinder`), with progress and the last result.
struct CopyFinderView: View {
    let finder: CopyFinder
    let settings: AppSettings
    let ledger: CompactLedger

    private var server: String { settings.server?.name ?? "your server" }

    var body: some View {
        Form {
            Section {
                Text("Finds photos and videos on this iPhone that are compact copies of originals \(server) already "
                     + "has: copies made with other tools, or Homespun's own after reinstalling. They then count as "
                     + "backed up, so they're never backed up again as if they were originals.")
                Text("Only fingerprints of your photos go to \(server). Keep Homespun open; a large library takes a while.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            if finder.isRunning {
                Section {
                    ProgressView(value: Double(finder.checked), total: Double(max(finder.total, 1))) {
                        Text("Checked \(finder.checked) of \(finder.total)")
                    } currentValueLabel: {
                        Text("\(finder.found) compact copies found")
                    }
                    .accessibilityIdentifier("copies.progress")
                    Button("Stop", role: .destructive) { finder.stop() }
                        .accessibilityIdentifier("copies.stop")
                }
            } else {
                Section {
                    Button(finder.summary == nil ? "Find compact copies" : "Check new items") { start(again: false) }
                        .accessibilityIdentifier("copies.start")
                        .disabled(settings.client == nil)
                    if finder.summary != nil {
                        Button("Check everything again") { start(again: true) }
                            .accessibilityIdentifier("copies.again")
                            .disabled(settings.client == nil)
                    }
                }
            }

            if let error = finder.error {
                Section { Text(error).foregroundStyle(.red) }
            }

            if let summary = finder.summary, !finder.isRunning {
                Section {
                    row("Compact copies found", summary.found, id: "found",
                        detail: "Their originals are on \(server).")
                    if summary.readyToFree > 0 {
                        row("Ready to free up", summary.readyToFree, id: "ready",
                            detail: "Originals still on this iPhone whose compact copy was found too.")
                    }
                    if summary.alreadyAtHome > 0 {
                        row("Originals already at home", summary.alreadyAtHome, id: "home",
                            detail: "These are the originals themselves; \(server) has them too. Back them up to "
                                + "get compact copies.")
                    }
                    if summary.needsAttention > 0 {
                        row("Need attention", summary.needsAttention, id: "attention",
                            detail: "Only part of each matched, so they're left as they are.")
                    }
                    row("Not on the server", summary.notFound, id: "notFound", detail: "Back these up as usual.")
                    if summary.skipped > 0 {
                        row("Skipped", summary.skipped, id: "skipped", detail: "Only in iCloud, or unreadable.")
                    }
                } header: {
                    Text(summary.stopped ? "Stopped after \(summary.checked) items" : "Last check: \(summary.checked) items")
                } footer: {
                    if let finished = summary.finishedAt {
                        Text(finished.formatted(date: .abbreviated, time: .shortened))
                    }
                }
            }
        }
        .navigationTitle("Copies made elsewhere")
    }

    private func row(_ title: String, _ count: Int, id: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            LabeledContent(title, value: count.formatted())
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("copies.\(id)")
    }

    private func start(again: Bool) {
        guard let client = settings.client else { return }
        finder.start(lookup: { try await client.lookupCopies($0) }, ledger: ledger, again: again)
    }
}
