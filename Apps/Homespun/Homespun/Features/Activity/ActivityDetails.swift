// SPDX-License-Identifier: Apache-2.0
import SwiftUI

/// One run's receipt and its items (DESIGN 03·2.3, 07·BK-2): how long it took, what happened,
/// what it produced, then each item with its thumbnail and result. `runID` nil is the run in
/// progress.
struct RunDetailView: View {
    let model: AppModel
    let runID: UUID?
    /// The run in progress, rebuilt when one of its items finishes (not for each progress message).
    @State private var liveItems: [RunHistory.Item]?
    /// Which originals are still on this iPhone (looked up in the background; a whole-library run is
    /// tens of thousands of items).
    @State private var present: Set<String>?

    var body: some View {
        let live = runID == nil
        let run = runID.flatMap { id in model.history.runs.first { $0.id == id } }
        let items = run?.items ?? liveItems ?? []
        let server = model.library.serverName
        List {
            if let run {
                Section {
                    Receipt(run: run, server: server)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                if run.kind == .backUp {
                    Section("What happened") {
                        count("Backed up", run.count(.saved), symbol: "checkmark.circle.fill", tint: Theme.teal)
                        count("Backed up, compact copy later", run.count(.backedUp), symbol: "checkmark.circle", tint: Theme.teal)
                        count("Need attention", run.count(.failed) + run.count(.notYet),
                              symbol: "exclamationmark.triangle.fill", tint: Theme.red)
                        count("Kept as is", run.count(.kept), symbol: "equal.circle", tint: Theme.secondaryLabel)
                    }
                    .listRowBackground(Theme.card)
                    if run.originalBytes > 0 {
                        Section {
                            LabeledContent("Originals on \(server)", value: LibraryController.bytes(run.originalBytes))
                            LabeledContent("Compact copies in Photos", value: LibraryController.bytes(run.compactBytes))
                        } header: {
                            Text("What it produced")
                        } footer: {
                            Text("Each original was checked by SHA-256 on \(server).")
                        }
                        .listRowBackground(Theme.card)
                    }
                }
            }
            if !items.isEmpty {
                Section(run == nil ? "" : "Items") {
                    ForEach(items) { item in
                        RunItemRow(item: item, job: live ? model.job : nil,
                                   present: present?.contains(item.assetID) ?? true, server: server,
                                   library: model.library.library)
                    }
                }
                .listRowBackground(Theme.card)
            }
        }
        .homespunList()
        .task(id: live ? model.job.phaseVersion : -1) {
            guard live else { return }
            liveItems = model.job.runItems.map { CompactJob.historyItem($0) }
        }
        .task(id: PresenceKey(run: runID, count: items.count)) {
            let ids = items.map(\.assetID).filter { !$0.isEmpty }
            let photos = model.settings.photos
            present = await Task.detached(priority: .userInitiated) { photos.existing(ids, includeHidden: false) }.value
        }
        .overlay {
            if !live, run == nil {
                ContentUnavailableView("This run is no longer kept", systemImage: "clock.arrow.circlepath",
                                       description: Text("Activity keeps runs for 90 days."))
            } else if live, liveItems?.isEmpty == true {
                ContentUnavailableView("Nothing running", systemImage: "checkmark.circle",
                                       description: Text("The run finished. It's in History."))
            }
        }
        .navigationTitle(run?.title() ?? "Backing Up")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private func count(_ title: String, _ value: Int, symbol: String, tint: Color) -> some View {
        if value > 0 {
            LabeledContent {
                Text(value.formatted())
            } label: {
                Label { Text(title).foregroundStyle(Theme.label) } icon: { Image(systemName: symbol).foregroundStyle(tint) }
            }
            .accessibilityElement(children: .combine)
        }
    }
}

private struct PresenceKey: Hashable {
    let run: UUID?
    let count: Int
}

/// "Done in 2 min" / "Today, 1:12 AM to 1:14 AM", or "Freed 2.1 GB".
private struct Receipt: View {
    let run: RunHistory.Run
    let server: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol).font(.largeTitle).foregroundStyle(tint).accessibilityHidden(true)
            Text(headline).font(.title.weight(.semibold)).foregroundStyle(Theme.label)
                .accessibilityAddTraits(.isHeader)
            Text(detail).font(.subheadline).foregroundStyle(Theme.secondaryLabel)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private var failed: Int { run.count(.failed) + run.count(.notYet) }
    private var symbol: String {
        run.kind == .freeUp ? "iphone" : failed > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
    }
    private var tint: Color { run.kind == .freeUp ? Theme.accent : failed > 0 ? Theme.amber : Theme.teal }

    private var headline: String {
        if run.kind == .freeUp { return "Freed \(LibraryController.bytes(run.freedBytes))" }
        let seconds = max(1, run.end.timeIntervalSince(run.start))
        let duration = Duration.seconds(seconds).formatted(
            .units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))
        return failed > 0 ? "Backed up \(run.count(.saved)) · \(failed) need\(failed == 1 ? "s" : "") attention"
            : "Done in \(duration)"
    }

    private var detail: String {
        if run.kind == .freeUp {
            let count = run.items.count
            return "\(count) original\(count == 1 ? "" : "s") moved to Recently Deleted. Their compact copies stay."
        }
        let start = run.start.formatted(date: .omitted, time: .shortened)
        let end = run.end.formatted(date: .omitted, time: .shortened)
        let day = Calendar.current.isDateInToday(run.end) ? "Today"
            : Calendar.current.isDateInYesterday(run.end) ? "Yesterday"
            : run.end.formatted(.dateTime.month(.abbreviated).day())
        let how = switch run.trigger {
        case .automatic: ReleaseFeatures.automaticMode ? ", automatic" : ""
        case .firstTask: ", your 10 newest"
        case .manual: ""
        }
        return start == end ? "\(day), \(end)\(how)" : "\(day), \(start) to \(end)\(how)"
    }
}

/// One item of a run: its thumbnail and badge, its name, and "12.4 MB → 2.3 MB" or why not.
struct RunItemRow: View {
    let item: RunHistory.Item
    /// The job, while the run is in progress: the item being worked on shows what it's doing.
    var job: CompactJob?
    /// The original is still on this iPhone.
    var present: Bool
    var server: String
    let library: LibraryModel

    /// What it's doing now, while the run is in progress.
    private var working: String? {
        guard let current = job?.runProgress.current, current.asset == item.assetID else { return nil }
        return job?.currentMessage
    }

    var body: some View {
        HStack(spacing: 14) {
            ZStack(alignment: .topTrailing) {
                if item.result == .freed {
                    Theme.fill.frame(width: 44, height: 44)
                        .overlay { Image(systemName: "trash").foregroundStyle(Theme.secondaryLabel) }
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    Thumbnail(identifier: thumbnail, library: library, side: 44)
                }
                badge.offset(x: 6, y: -6)
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.live ? "\(item.name) · Live" : item.name)
                    .foregroundStyle(Theme.label).lineLimit(1).truncationMode(.middle)
                Text(detail).font(.subheadline)
                    .foregroundStyle(item.result == .failed && working == nil ? Theme.red : Theme.secondaryLabel)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("status.\(stateName)")
    }

    /// Stable names for UI tests.
    private var stateName: String {
        if working != nil { return "working" }
        return switch item.result {
        case .saved: "saved"
        case .kept: "unchanged"
        case .notYet: "notYet"
        case .failed: "failed"
        case .waiting: "waiting"
        case .freed: "freed"
        case .backedUp: "backedUp"
        }
    }

    private var thumbnail: String {
        item.result == .saved && !present ? item.compactID ?? item.assetID : item.assetID
    }

    private var detail: String {
        if let working { return working }
        let reason = item.reason.map { " · \($0)" } ?? ""
        switch item.result {
        case .saved:
            return "\(LibraryController.bytes(item.originalBytes ?? 0)) → \(LibraryController.bytes(item.compactBytes ?? 0))"
        case .kept: return "Kept as is" + reason
        case .notYet: return item.reason ?? "Not yet"
        case .failed: return "Failed" + reason
        case .waiting: return "Waiting"
        case .freed: return "Moved to Recently Deleted"
        case .backedUp: return "Backed up · compact copy later"
        }
    }

    @ViewBuilder private var badge: some View {
        if working != nil {
            BadgeView(badge: .working, size: 18)
        } else {
            switch item.result {
            case .saved: BadgeView(badge: present ? .originalOnPhone : .backedUp, size: 18)
            case .kept: BadgeView(badge: .kept, size: 18)
            case .failed: BadgeView(badge: .failed, size: 18)
            case .waiting: BadgeView(badge: .waiting, size: 18)
            case .backedUp: BadgeView(badge: .copyLater, size: 18)
            case .notYet:
                Image(systemName: "hourglass").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.BadgeColor.grey)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(.white).padding(-1.5))
                    .shadow(color: .black.opacity(0.25), radius: 1)
            case .freed: EmptyView()
            }
        }
    }
}

/// What needs attention, grouped by cause so one fix clears many (DESIGN 03·2.4).
struct NeedsAttentionView: View {
    let model: AppModel

    var body: some View {
        let server = model.library.serverName
        let groups = AttentionCause.group(ActivityTab.attention(model), server: server)
        let sections = Dictionary(grouping: groups, by: \.cause.section)
        let order = groups.map(\.cause.section).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let blocked = model.library.backUpBlockedReason
        List {
            ForEach(order, id: \.self) { section in
                Section(section) {
                    ForEach(sections[section] ?? [], id: \.cause) { group in
                        HStack(spacing: 14) {
                            ActivityRow(symbol: group.cause.symbol, title: group.cause.title,
                                        detail: ["\(group.items.count) item\(group.items.count == 1 ? "" : "s")",
                                                 group.cause.detail].filter { !$0.isEmpty }.joined(separator: " · "))
                            Spacer(minLength: 8)
                            Button("Try Again") {
                                model.library.backUp(group.items.map(\.assetID))
                            }
                            .buttonStyle(.bordered).tint(Theme.accent)
                            .disabled(blocked != nil)
                            .accessibilityHint(blocked ?? "Backs up these \(group.items.count) again.")
                            .accessibilityIdentifier("attention.retry")
                        }
                        ThumbnailStrip(identifiers: group.items.map(\.assetID), library: model.library.library)
                    }
                }
                .listRowBackground(Theme.card)
            }
        }
        .homespunList()
        .overlay {
            if groups.isEmpty {
                ContentUnavailableView("Nothing needs attention", systemImage: "checkmark.circle",
                                       description: Text("Everything has been backed up or is being tried again."))
            }
        }
        .navigationTitle("Needs Attention")
        .navigationBarTitleDisplayMode(.inline)
    }
}
