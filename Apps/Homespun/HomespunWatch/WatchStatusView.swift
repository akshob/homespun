// SPDX-License-Identifier: Apache-2.0
import SwiftUI

/// The four facts as the iPhone last saw them, and how long ago that was.
struct WatchStatusView: View {
    let status: WatchStatus
    @State private var now = Date()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            // A TimelineView around this List loops in layout when its self-updating footer appears.
            List { content(now: now) }
                .navigationTitle("Homespun")
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            now = Date()
            while !Task.isCancelled {
                let next = Calendar.current.nextDate(after: Date(), matching: DateComponents(second: 0),
                                                     matchingPolicy: .nextTime) ?? Date().addingTimeInterval(60)
                do {
                    try await Task.sleep(for: .seconds(max(1, next.timeIntervalSinceNow)))
                } catch {
                    return
                }
                now = Date()
            }
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
        .accessibilityLabel("\(title): \(StatusWords.spokenFact(value))")
    }

    private func message(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol).font(.body)
    }

    private func updated(_ date: Date) -> some View { UpdatedText(date: date) }
}
