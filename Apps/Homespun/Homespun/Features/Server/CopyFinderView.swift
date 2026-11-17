// SPDX-License-Identifier: Apache-2.0
import SwiftUI

/// Finds compact copies made elsewhere (see `CopyFinder`) in one sheet that changes state: what it
/// does, then progress, then results (import E4, 3.2, 3.8, 4.1). Closing it never stops a scan.
struct CopyFinderView: View {
    let finder: CopyFinder
    let settings: AppSettings
    let ledger: CompactLedger
    @State private var confirmingStop = false
    @Environment(\.dismiss) private var dismiss

    private var server: String { settings.server?.name ?? "your server" }

    var body: some View {
        NavigationStack {
            ScrollView {
                Group {
                    if finder.isRunning {
                        progress
                    } else if let summary = finder.summary {
                        results(summary)
                    } else {
                        explanation
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.background)
            .safeAreaBar(edge: .bottom) { buttons.padding(.horizontal, 24).padding(.bottom, 8) }
            .navigationTitle(finder.isRunning || finder.summary != nil ? "Find Compact Copies" : "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Label("Close", systemImage: "xmark") }
                        .accessibilityHint(finder.isRunning ? "Finding keeps going." : "")
                        .accessibilityIdentifier("copies.close")
                }
            }
            .alert("Stop finding compact copies?", isPresented: $confirmingStop) {
                Button("Keep Going", role: .cancel) {}
                Button("Stop") { finder.stop() }.accessibilityIdentifier("copies.stop.confirm")
            } message: {
                Text("The \(finder.found.formatted()) found so far stay Original at home. Run it again any time; it "
                     + "skips what it already checked.")
            }
            .onChange(of: finder.isRunning) { _, running in
                if !running, let summary = finder.summary {
                    Announce.say(summary.stopped ? "Stopped. \(summary.found) found." : "Done. \(summary.found) found.")
                }
            }
        }
    }

    // MARK: Explanation (E4)

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "photo.stack").font(.system(size: 38)).foregroundStyle(Theme.accent)
                .frame(width: 84, height: 84).background(Theme.accentSoft, in: Circle())
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)
            Text("Find compact copies made elsewhere").font(.title.weight(.semibold)).foregroundStyle(Theme.label)
                .multilineTextAlignment(.center).frame(maxWidth: .infinity)
                .accessibilityAddTraits(.isHeader)
            Text("Homespun looks for copies of originals \(server) keeps, including copies Homespun made before, so "
                 + "it never backs up a compact copy as if it were an original.")
                .foregroundStyle(Theme.secondaryLabel)
            bullet("checkmark.circle.fill", Theme.teal,
                   "Found copies become Original at home. Nothing is uploaded, changed or removed.")
            bullet("lock.fill", Theme.accent,
                   "Only fingerprints (SHA-256) go to \(server), your own server. Not the photos, not their names.")
            bullet("clock", Theme.accent, "Found copies show up as it goes. Keep Homespun open while it checks.")
            bullet("icloud", Theme.accent, "Items only in iCloud are skipped. Nothing is downloaded.")
            if let error = finder.error {
                InlineNotice(tone: .error, title: "Couldn't finish", message: error)
            }
        }
        .padding(.top, 8)
    }

    // MARK: Progress (3.2)

    private var progress: some View {
        let fraction = Double(finder.checked) / Double(max(finder.total, 1))
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: "checkmark.circle.fill").font(.title).foregroundStyle(Theme.teal)
                    .accessibilityHidden(true)
                Text(finder.found.formatted()).font(.system(size: 44, weight: .semibold, design: .rounded))
                    .monospacedDigit().contentTransition(.numericText()).foregroundStyle(Theme.label)
                Text("found so far").foregroundStyle(Theme.secondaryLabel)
            }
            .accessibilityElement(children: .combine)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Finding compact copies").foregroundStyle(Theme.label)
                    Spacer()
                    Text(fraction.formatted(.percent.precision(.fractionLength(0)))).foregroundStyle(Theme.secondaryLabel)
                }
                ProgressView(value: fraction).tint(Theme.accent)
                Text("\(finder.checked.formatted()) of \(finder.total.formatted()) checked")
                    .font(.subheadline).foregroundStyle(Theme.secondaryLabel)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("copies.progress")
            bullet("lock.fill", Theme.accent, "Only fingerprints go to \(server).")
            bullet("iphone", Theme.accent, "Keep Homespun open; a large library takes a while.")
        }
        .padding(.top, 8)
    }

    // MARK: Results (4.1)

    private func results(_ summary: CopyFinder.Summary) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: summary.found > 0 ? "checkmark.circle.fill" : "circle.dashed").font(.title)
                    .foregroundStyle(summary.found > 0 ? Theme.teal : Theme.secondaryLabel)
                    .accessibilityHidden(true)
                Text("\(summary.found.formatted()) found").font(.system(.title, design: .rounded, weight: .semibold))
                    .foregroundStyle(Theme.label)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("copies.found")
            Text(summary.found > 0
                 ? "They're Original at home now: their originals are on \(server), so Homespun won't back them up again."
                 : "None of the items checked is a compact copy of an original on \(server).")
                .foregroundStyle(Theme.secondaryLabel)
            if summary.stopped {
                InlineNotice(tone: .info, title: "Stopped after \(summary.checked.formatted()) items",
                             message: "Run Again picks up where it stopped.")
            }
            if let error = finder.error {
                InlineNotice(tone: .error, title: "Couldn't finish", message: error)
            }
            VStack(spacing: 0) {
                let rows = Self.rows(summary)
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if index > 0 { Divider().overlay(Theme.separator).padding(.leading, 44) }
                    HStack(spacing: 14) {
                        Image(systemName: row.symbol).font(.title3).foregroundStyle(row.tint).frame(width: 30)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title).foregroundStyle(Theme.label)
                            Text(row.detail).font(.subheadline).foregroundStyle(Theme.secondaryLabel)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 10)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("copies.\(row.id)")
                }
            }
            .card(padding: 14)
            if let finished = summary.finishedAt {
                Text("Checked \(summary.checked.formatted()) items · \(ServerStatusCard.when(finished))")
                    .font(.footnote).foregroundStyle(Theme.secondaryLabel)
            }
        }
        .padding(.top, 8)
    }

    private static func rows(_ summary: CopyFinder.Summary)
        -> [(id: String, symbol: String, tint: Color, title: String, detail: String)] {
        var rows: [(id: String, symbol: String, tint: Color, title: String, detail: String)] = []
        rows.append(("foundRow", "checkmark.circle.fill", Theme.teal, "\(summary.found.formatted()) found", "Original at home"))
        if summary.readyToFree > 0 {
            rows.append(("ready", "circle.lefthalf.filled", Theme.amber, "\(summary.readyToFree.formatted()) ready to free up",
                         "Their originals are still on this iPhone too"))
        }
        if summary.alreadyAtHome > 0 {
            rows.append(("home", "equal.circle", Theme.secondaryLabel, "\(summary.alreadyAtHome.formatted()) kept as is",
                         "The originals themselves, already at home"))
        }
        if summary.needsAttention > 0 {
            rows.append(("attention", "exclamationmark.triangle.fill", Theme.red,
                         "\(summary.needsAttention.formatted()) need attention",
                         "Only part of each matched, so they're left as they are"))
        }
        rows.append(("notFound", "circle.dashed", Theme.secondaryLabel, "\(summary.notFound.formatted()) not found",
                     "Not backed up yet · only on this iPhone"))
        if summary.skipped > 0 {
            rows.append(("skipped", "icloud", Theme.secondaryLabel, "\(summary.skipped.formatted()) only in iCloud",
                         "Skipped · checked when they're on this iPhone"))
        }
        return rows
    }

    // MARK: Buttons

    @ViewBuilder private var buttons: some View {
        VStack(spacing: 10) {
            if finder.isRunning {
                Button { confirmingStop = true } label: {
                    Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).controlSize(.large).tint(Theme.accent)
                .accessibilityIdentifier("copies.stop")
            } else if finder.summary != nil {
                Button { dismiss() } label: { Text("Done").frame(maxWidth: .infinity) }
                    .primaryAction()
                    .accessibilityIdentifier("copies.done")
                HStack(spacing: 20) {
                    Button("Run Again") { start(again: false) }
                        .accessibilityHint("Only checks what changed.")
                        .accessibilityIdentifier("copies.start")
                    Button("Check Everything Again") { start(again: true) }
                        .accessibilityIdentifier("copies.again")
                }
                .tint(Theme.accent)
                .disabled(settings.client == nil)
            } else {
                Button { start(again: false) } label: {
                    Label("Find Compact Copies", systemImage: "magnifyingglass").frame(maxWidth: .infinity)
                }
                .primaryAction()
                .disabled(settings.client == nil)
                .accessibilityIdentifier("copies.start")
                Button("Not Now") { dismiss() }.tint(Theme.accent)
            }
        }
    }

    private func bullet(_ symbol: String, _ tint: Color, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.title3).foregroundStyle(tint).frame(width: 28).accessibilityHidden(true)
            Text(text).foregroundStyle(Theme.label).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func start(again: Bool) {
        guard let client = settings.client else { return }
        Announce.say("Finding compact copies.")
        finder.start(lookup: { try await client.lookupCopies($0) }, ledger: ledger, again: again)
    }
}
