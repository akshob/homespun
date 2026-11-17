// SPDX-License-Identifier: Apache-2.0
import SwiftUI

/// The four facts as the iPhone last saw them, and how long ago that was.
struct WatchStatusView: View {
    let status: WatchStatus

    var body: some View {
        NavigationStack {
            TimelineView(.everyMinute) { context in
                List { content(now: context.date) }
            }
            .navigationTitle("Homespun")
        }
    }

    @ViewBuilder private func content(now: Date) -> some View {
        let snapshot = status.snapshot
        switch StatusWords.state(snapshot, now: now, watch: true) {
        case .facts:
            if let snapshot {
                Section {
                    row("Ready to free up", FactSymbol.ready, StatusWords.ready(snapshot.ready))
                    row("Last backup", FactSymbol.backup, StatusWords.lastBackup(snapshot.lastBackup, now: now))
                    let reachable = snapshot.server?.reachable ?? false
                    row("Server", reachable ? FactSymbol.server : FactSymbol.unreachable, StatusWords.server(snapshot.server))
                    row("Automatic Mode", FactSymbol.automatic, StatusWords.automatic(snapshot.automatic))
                } footer: {
                    updated(snapshot.updatedAt)
                }
            }
        case .locked:
            message(FactSymbol.locked, "\(StatusWords.locked) on your iPhone.")
        case .notPaired:
            message(FactSymbol.server, "\(StatusWords.notPaired) on your iPhone.")
        case .notStarted:
            message(FactSymbol.phone, StatusWords.openOnPhone + ".")
        case .stale:
            Section {
                message(FactSymbol.phone, StatusWords.openOnPhone + ".")
            } footer: {
                if let snapshot { updated(snapshot.updatedAt) }
            }
        }
    }

    private func row(_ title: String, _ symbol: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: symbol).font(.footnote).foregroundStyle(WidgetPalette.accent)
            Text(value).font(.body)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(value.replacingOccurrences(of: " · ", with: ", "))")
    }

    private func message(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol).font(.body)
    }

    private func updated(_ date: Date) -> some View { UpdatedText(date: date) }
}
