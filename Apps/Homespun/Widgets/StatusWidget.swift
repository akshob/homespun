// SPDX-License-Identifier: Apache-2.0
import SwiftUI
import WidgetKit

/// Homespun at a glance: what's ready to free up, the last backup, the server and Automatic Mode
/// (Premium). On the iPhone's Home Screen and Lock Screen, and on Apple Watch faces and Smart Stack.
/// It never asks the network: it shows what the iPhone app last wrote (`StatusStore`).
struct StatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: StatusStore.widgetKind, provider: StatusProvider()) { entry in
            StatusWidgetView(entry: entry)
        }
        .configurationDisplayName("Homespun")
        .description("What's ready to free up, your last backup, your server and Automatic Mode. Part of Homespun Premium.")
        .supportedFamilies(Self.families)
    }

    #if os(watchOS)
    static let families: [WidgetFamily] = [.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner]
    #else
    static let families: [WidgetFamily] = [.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular,
                                           .accessoryInline]
    #endif
}

struct StatusEntry: TimelineEntry {
    var date: Date
    var snapshot: StatusSnapshot?
    var relevance: TimelineEntryRelevance?
    /// Drawn for the watch: says how old the news is, and when it's too old.
    var watch = StatusProvider.watch
}

struct StatusProvider: TimelineProvider {
    #if os(watchOS)
    static let watch = true
    #else
    static let watch = false
    #endif

    func placeholder(in context: Context) -> StatusEntry { StatusEntry(date: Date(), snapshot: .sample()) }

    func getSnapshot(in context: Context, completion: @escaping (StatusEntry) -> Void) {
        let now = Date()
        var snapshot = StatusStore.read()
        // The gallery shows what the widget looks like, also before there's anything to show.
        if context.isPreview, StatusWords.state(snapshot, now: now, watch: Self.watch) != .facts {
            snapshot = .sample(now: now)
        }
        completion(Self.entry(snapshot, at: now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StatusEntry>) -> Void) {
        let now = Date(), snapshot = StatusStore.read()
        let dates = StatusWords.timelineDates(snapshot, now: now, watch: Self.watch)
        completion(Timeline(entries: dates.map { Self.entry(snapshot, at: $0) }, policy: .after(dates.last ?? now)))
    }

    static func entry(_ snapshot: StatusSnapshot?, at date: Date) -> StatusEntry {
        StatusEntry(date: date, snapshot: snapshot,
                    relevance: TimelineEntryRelevance(score: StatusWords.relevance(snapshot, now: date, watch: watch)))
    }
}
