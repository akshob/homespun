// SPDX-License-Identifier: Apache-2.0
import SwiftUI

/// The problem reports sent from this iPhone (their number, when, and how the message began), kept
/// on this iPhone so a report can be found and quoted later without a screenshot.
@MainActor @Observable
final class SentReports {
    static let shared = SentReports()
    static let key = "sentReports"
    static let limit = 50

    struct Report: Codable, Equatable, Identifiable, Sendable {
        var id: String
        var sentAt: Date
        /// The message's first line, shortened.
        var summary: String
    }

    private let defaults: UserDefaults
    private(set) var reports: [Report]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        reports = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([Report].self, from: $0) } ?? []
    }

    /// Newest first; the oldest go past `limit`.
    func add(id: String, message: String, at date: Date = Date()) {
        let firstLine = message.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let summary = firstLine.count > 120 ? String(firstLine.prefix(119)) + "…" : firstLine
        reports = Array(([Report(id: id, sentAt: date, summary: summary)] + reports.filter { $0.id != id }).prefix(Self.limit))
        defaults.set(try? JSONEncoder().encode(reports), forKey: Self.key)
    }
}

/// Help and About › Sent Reports: each report's number to copy or share, newest first.
struct SentReportsView: View {
    var reports = SentReports.shared
    @State private var copied: String?

    var body: some View {
        List {
            if reports.reports.isEmpty {
                ContentUnavailableView("No reports yet", systemImage: "exclamationmark.bubble",
                                       description: Text("Reports you send from Report a Problem show up here with their number."))
                    .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(reports.reports) { report in
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(report.id).font(.body.monospaced().weight(.semibold)).foregroundStyle(Theme.label)
                                    .textSelection(.enabled)
                                Text(report.sentAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.subheadline).foregroundStyle(Theme.secondaryLabel)
                                if !report.summary.isEmpty {
                                    Text(report.summary).font(.subheadline).foregroundStyle(Theme.secondaryLabel).lineLimit(2)
                                }
                            }
                            Spacer(minLength: 8)
                            Button {
                                UIPasteboard.general.string = report.id
                                copied = report.id
                                Announce.say("Copied \(report.id).")
                            } label: {
                                Label(copied == report.id ? "Copied" : "Copy Report Number",
                                      systemImage: copied == report.id ? "checkmark" : "doc.on.doc")
                                    .labelStyle(.iconOnly)
                            }
                            .buttonStyle(.borderless).tint(Theme.accent)
                        }
                        .padding(.vertical, 2)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("reports.row")
                        .contextMenu {
                            Button("Copy Report Number", systemImage: "doc.on.doc") { UIPasteboard.general.string = report.id }
                            ShareLink(item: "Homespun report \(report.id)")
                        }
                    }
                } footer: {
                    Text("Quote a report's number when you write to support@homespun.photos. Kept on this iPhone only.")
                }
                .listRowBackground(Theme.card)
            }
        }
        .homespunList()
        .navigationTitle("Sent Reports")
        .navigationBarTitleDisplayMode(.inline)
    }
}
