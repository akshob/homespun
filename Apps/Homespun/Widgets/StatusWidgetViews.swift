// SPDX-License-Identifier: Apache-2.0
import SwiftUI
import WidgetKit

/// The widget for each size. Full colour on the Home Screen and in the watch's Smart Stack; on the
/// Lock Screen (vibrant) and tinted faces (accented) the system colours it, so only the main figure
/// is marked accentable and everything else uses primary and secondary.
struct StatusWidgetView: View {
    let entry: StatusEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        content
            .containerBackground(for: .widget) { background }
        #if os(iOS)
            .widgetURL(StatusWords.link(entry.snapshot).url)
        #endif
    }

    @ViewBuilder private var content: some View {
        switch family {
        #if os(iOS)
        case .systemSmall: SmallStatusView(entry: entry)
        case .systemMedium: MediumStatusView(entry: entry)
        #endif
        #if os(watchOS)
        case .accessoryCorner: CornerStatusView(entry: entry)
        #endif
        case .accessoryCircular: CircularStatusView(entry: entry)
        case .accessoryInline: InlineStatusView(entry: entry)
        default: RectangularStatusView(entry: entry)
        }
    }

    @ViewBuilder private var background: some View {
        switch family {
        case .systemSmall, .systemMedium: WidgetPalette.background
        // Only the watch's Smart Stack shows it (faces and the Lock Screen leave it out).
        case .accessoryRectangular: WidgetPalette.stackBackground
        default: Color.clear
        }
    }
}

/// A colour on the Home Screen and in the Smart Stack; the system's own when it tints the widget.
private struct Tinted: ViewModifier {
    let color: Color
    @Environment(\.widgetRenderingMode) private var mode

    func body(content: Content) -> some View {
        if mode == .fullColor { content.foregroundStyle(color) } else { content }
    }
}

private extension View {
    func tinted(_ color: Color) -> some View { modifier(Tinted(color: color)) }
}

/// When there's nothing to show yet: locked, not set up, or (watch) no recent word from the iPhone.
private struct MessageContent {
    let symbol: String
    let title: String

    init?(_ state: StatusWords.State, watch: Bool) {
        switch state {
        case .facts: return nil
        case .locked: (symbol, title) = (FactSymbol.locked, StatusWords.locked)
        case .notStarted: (symbol, title) = (watch ? FactSymbol.phone : FactSymbol.ready,
                                             watch ? StatusWords.openOnPhone : StatusWords.notStarted)
        case .notPaired: (symbol, title) = (FactSymbol.server, StatusWords.notPaired)
        case .stale: (symbol, title) = (FactSymbol.phone, StatusWords.openOnPhone)
        }
    }
}

extension StatusEntry {
    var state: StatusWords.State { StatusWords.state(snapshot, now: date, watch: watch) }
    var spoken: String { StatusWords.spoken(snapshot, now: date, watch: watch) }
}

// MARK: Home Screen

#if os(iOS)
/// The ready size large, then one line for each of the other facts.
struct SmallStatusView: View {
    let entry: StatusEntry

    var body: some View {
        Group {
            if let snapshot = entry.snapshot, let server = snapshot.server, entry.state == .facts {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Ready to free up", systemImage: FactSymbol.ready)
                        .font(.caption.weight(.semibold)).tinted(WidgetPalette.accent).lineLimit(1)
                    if snapshot.ready.count > 0 {
                        Text(StatusWords.bytes(snapshot.ready.bytes)).font(.title.weight(.bold))
                            .lineLimit(1).minimumScaleFactor(0.6).widgetAccentable()
                        Text(StatusWords.items(snapshot.ready.count)).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Nothing right now").font(.headline).lineLimit(2).minimumScaleFactor(0.8)
                    }
                    Spacer(minLength: 4)
                    VStack(alignment: .leading, spacing: 3) {
                        FactLine(symbol: FactSymbol.backup,
                                 text: snapshot.lastBackup.map { StatusWords.day($0.date, now: entry.date) } ?? "No backups yet")
                        ServerLine(server: server)
                        FactLine(symbol: FactSymbol.automatic, text: "Automatic: \(StatusWords.automaticShort(snapshot.automatic).lowercased())")
                    }
                    .font(.caption2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if let message = MessageContent(entry.state, watch: false) {
                MessageView(message: message)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.spoken)
    }
}

/// The four facts, each opening its own place in the app.
struct MediumStatusView: View {
    let entry: StatusEntry

    var body: some View {
        if let snapshot = entry.snapshot, entry.state == .facts {
            Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 12) {
                GridRow {
                    FactCell(title: "Ready to free up", symbol: FactSymbol.ready, value: StatusWords.ready(snapshot.ready),
                             link: snapshot.ready.count > 0 ? .freeUp : .activity, accent: true)
                    FactCell(title: "Last backup", symbol: FactSymbol.backup,
                             value: StatusWords.lastBackup(snapshot.lastBackup, now: entry.date), link: .activity)
                }
                GridRow {
                    let reachable = snapshot.server?.reachable ?? false
                    FactCell(title: "Server", symbol: reachable ? FactSymbol.server : FactSymbol.unreachable,
                             value: StatusWords.server(snapshot.server), link: .server,
                             tint: reachable ? WidgetPalette.teal : WidgetPalette.amber)
                    FactCell(title: "Automatic Mode", symbol: FactSymbol.automatic,
                             value: StatusWords.automatic(snapshot.automatic), link: .automatic)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if let message = MessageContent(entry.state, watch: false) {
            MessageView(message: message)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(entry.spoken)
        }
    }
}

private struct FactCell: View {
    let title: String
    let symbol: String
    let value: String
    let link: AppLink
    var accent = false
    var tint = WidgetPalette.accent

    var body: some View {
        Link(destination: link.url) {
            VStack(alignment: .leading, spacing: 2) {
                Label(title, systemImage: symbol).font(.caption.weight(.semibold)).tinted(tint).lineLimit(1)
                // A link's label takes the tint colour (`.primary` included) unless given a colour.
                Text(value).font(.subheadline.weight(.semibold)).foregroundStyle(Color.primary)
                    .multilineTextAlignment(.leading).lineLimit(2).minimumScaleFactor(0.8)
                    .widgetAccentable(accent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .accessibilityLabel("\(title): \(StatusWords.spokenFact(value))")
    }
}

private struct MessageView: View {
    let message: MessageContent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: message.symbol).font(.title2).tinted(WidgetPalette.accent).widgetAccentable()
            Text("Homespun").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(message.title).font(.headline).lineLimit(3).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
#endif

/// A symbol and a short fact, on one line.
private struct FactLine: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).frame(width: 14)
            Text(text).lineLimit(1).minimumScaleFactor(0.8)
        }
    }
}

/// The server by name, or that it can't be reached (in amber on the Home Screen).
private struct ServerLine: View {
    let server: StatusSnapshot.Server

    var body: some View {
        if server.reachable {
            FactLine(symbol: FactSymbol.server, text: server.name)
        } else {
            FactLine(symbol: FactSymbol.unreachable, text: "Can't reach \(server.name)").tinted(WidgetPalette.amber)
        }
    }
}

// MARK: Lock Screen and watch

/// The ready size (or what needs attention) in a circle.
struct CircularStatusView: View {
    let entry: StatusEntry

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            if let snapshot = entry.snapshot, let server = snapshot.server, entry.state == .facts {
                if !server.reachable {
                    Image(systemName: FactSymbol.unreachable).font(.title2).widgetAccentable()
                } else if snapshot.ready.count > 0 {
                    let parts = StatusWords.bytesParts(snapshot.ready.bytes)
                    VStack(spacing: -1) {
                        Image(systemName: FactSymbol.ready).font(.caption2)
                        Text(parts.number).font(.system(.title3, design: .rounded).weight(.semibold))
                            .lineLimit(1).minimumScaleFactor(0.5).widgetAccentable()
                        Text(parts.unit).font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 4)
                } else {
                    Image(systemName: "checkmark").font(.title2.weight(.semibold)).widgetAccentable()
                }
            } else {
                Image(systemName: MessageContent(entry.state, watch: entry.watch)?.symbol ?? FactSymbol.ready)
                    .font(.title2).widgetAccentable()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.spoken)
    }
}

/// The four facts in three (or four, on the watch) short lines.
struct RectangularStatusView: View {
    let entry: StatusEntry

    var body: some View {
        Group {
            if let snapshot = entry.snapshot, let server = snapshot.server, entry.state == .facts {
                VStack(alignment: .leading, spacing: 1) {
                    Text(StatusWords.readyHeadline(snapshot.ready)).font(.headline).lineLimit(1).minimumScaleFactor(0.7)
                        .widgetAccentable()
                        .accessibilityLabel("Ready to free up: \(StatusWords.spokenFact(StatusWords.ready(snapshot.ready)))")
                    ViewThatFits(in: .horizontal) {
                        FactLine(symbol: FactSymbol.backup, text: StatusWords.lastBackup(snapshot.lastBackup, now: entry.date))
                        FactLine(symbol: FactSymbol.backup,
                                 text: snapshot.lastBackup.map { StatusWords.day($0.date, now: entry.date) } ?? "No backups yet")
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Last backup: \(StatusWords.spokenFact(StatusWords.lastBackup(snapshot.lastBackup, now: entry.date)))")
                    HStack(spacing: 8) {
                        ServerLine(server: server)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Server: \(StatusWords.spokenFact(StatusWords.server(server)))")
                        if server.reachable {
                            FactLine(symbol: FactSymbol.automatic, text: StatusWords.automaticShort(snapshot.automatic))
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel("Automatic Mode: \(StatusWords.automatic(snapshot.automatic))")
                        }
                    }
                    if entry.watch {
                        UpdatedText(date: snapshot.updatedAt).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .font(.caption)
                .accessibilityElement(children: .combine)
            } else if let message = MessageContent(entry.state, watch: entry.watch) {
                VStack(alignment: .leading, spacing: 2) {
                    Label(message.title, systemImage: message.symbol).font(.headline).lineLimit(3).minimumScaleFactor(0.7)
                        .widgetAccentable()
                    if entry.state == .stale, let snapshot = entry.snapshot {
                        UpdatedText(date: snapshot.updatedAt).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One line: what matters most.
struct InlineStatusView: View {
    let entry: StatusEntry

    var body: some View {
        let headline = StatusWords.headline(entry.snapshot, now: entry.date, watch: entry.watch)
        Label(headline, systemImage: symbol)
            .accessibilityLabel(entry.spoken)
    }

    private var symbol: String {
        if let message = MessageContent(entry.state, watch: entry.watch) { return message.symbol }
        if entry.snapshot?.server?.reachable == false { return FactSymbol.unreachable }
        return (entry.snapshot?.ready.count ?? 0) > 0 ? FactSymbol.ready : FactSymbol.backup
    }
}

/// A symbol in the corner of the face, with the headline along its curve (watch).
struct CornerStatusView: View {
    let entry: StatusEntry

    var body: some View {
        Image(systemName: symbol).font(.title2).widgetAccentable()
            .widgetLabel { Text(StatusWords.headline(entry.snapshot, now: entry.date, watch: entry.watch)) }
            .accessibilityLabel(entry.spoken)
    }

    private var symbol: String {
        if let message = MessageContent(entry.state, watch: entry.watch) { return message.symbol }
        if entry.snapshot?.server?.reachable == false { return FactSymbol.unreachable }
        return (entry.snapshot?.ready.count ?? 0) > 0 ? FactSymbol.ready : FactSymbol.backup
    }
}
