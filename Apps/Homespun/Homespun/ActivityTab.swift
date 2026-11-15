// SPDX-License-Identifier: Apache-2.0
import HomespunCore
import SwiftUI

/// The Activity tab (DESIGN 03·2.1–2.4): what's running now, what's ready to free up, what needs
/// attention, and the last 90 days of runs.
struct ActivityTab: View {
    let model: AppModel
    var freeUp: () -> Void

    enum Route: Hashable {
        case run(UUID)
        case liveRun
        case attention
        case automatic
    }

    @State private var path: [Route] = []

    var body: some View {
        let job = model.job, history = model.history
        let attention = ActivityTab.attention(model)
        BookNavigation(path: $path) {
            List {
                if job.isRunning {
                    Section {
                        NowCard(job: job, server: model.library.serverName)
                        NavigationLink(value: Route.liveRun) {
                            Text("Show Items").foregroundStyle(Theme.accent)
                        }
                        .accessibilityIdentifier("activity.live")
                    }
                    .listRowBackground(Theme.card)
                } else if model.settings.freedBytes > 0 {
                    Section {
                        FreedCard(bytes: model.settings.freedBytes, since: model.settings.freedSince,
                                  months: history.freedByMonth())
                    }
                    .listRowBackground(Theme.card)
                }
                JourneyCard(model: model)
                readySection
                if !attention.isEmpty {
                    Section("Needs attention") {
                        NavigationLink(value: Route.attention) {
                            ActivityRow(symbol: "exclamationmark.triangle.fill", tint: Theme.red,
                                        title: "\(attention.count) need\(attention.count == 1 ? "s" : "") attention",
                                        detail: AttentionCause.group(attention, server: model.library.serverName)
                                            .first?.cause.title)
                        }
                        .accessibilityIdentifier("activity.attention")
                    }
                    .listRowBackground(Theme.card)
                }
                if !history.runs.isEmpty {
                    Section {
                        ForEach(history.runs) { run in
                            NavigationLink(value: Route.run(run.id)) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(run.title()).foregroundStyle(Theme.label)
                                    Text(run.summary).font(.subheadline).foregroundStyle(Theme.secondaryLabel)
                                }
                                .padding(.vertical, 2)
                                .accessibilityElement(children: .combine)
                            }
                            .accessibilityIdentifier("activity.run")
                        }
                    } header: {
                        Text("History")
                    } footer: {
                        Text("Kept for 90 days.")
                    }
                    .listRowBackground(Theme.card)
                }
            }
            .homespunList()
            .overlay {
                if isEmpty {
                    ContentUnavailableView("Nothing here yet", systemImage: "clock.arrow.circlepath",
                                           description: Text("Each backup and each time you free up space shows up "
                                                             + "here, with what changed."))
                }
            }
            .navigationTitle("Activity")
            .navigationSubtitle(subtitle(attention: attention.count))
        } destination: { route in
            switch route {
            case .run(let id): RunDetailView(model: model, runID: id)
            case .liveRun: RunDetailView(model: model, runID: nil)
            case .attention: NeedsAttentionView(model: model)
            case .automatic: AutomaticModeView(model: model)
            }
        } placeholder: {
            ContentUnavailableView("Choose a run", systemImage: "clock.arrow.circlepath",
                                   description: Text("Its items and what changed show here."))
                .background(Theme.background)
        }
    }

    @ViewBuilder private var readySection: some View {
        let ready = model.library.ready
        let automatic = model.premium.isUnlocked && model.automatic.enabled
        if ready.count > 0 || automatic {
            Section("Ready") {
                if ready.count > 0 {
                    HStack(spacing: 14) {
                        ActivityRow(symbol: "circle.lefthalf.filled", tint: Theme.amber,
                                    title: "\(ready.count) ready to free up",
                                    detail: "\(LibraryController.bytes(ready.bytes)) on this iPhone")
                        Spacer(minLength: 8)
                        Button("Free Up", action: freeUp)
                            .buttonStyle(.glassProminent).tint(Theme.accent)
                            .disabled(model.library.isRemoving)
                            .accessibilityHint("Shows what Free Up Space removes before anything is removed.")
                            .accessibilityIdentifier("activity.free")
                    }
                }
                if automatic {
                    NavigationLink(value: Route.automatic) {
                        ActivityRow(symbol: "bolt.fill", tint: Theme.accent, title: "Automatic mode",
                                    detail: "Next run tonight while charging")
                    }
                    .accessibilityIdentifier("activity.automatic")
                }
            }
            .listRowBackground(Theme.card)
        }
    }

    private var isEmpty: Bool {
        !model.job.isRunning && model.history.runs.isEmpty && model.library.ready.count == 0
            && model.settings.freedBytes == 0 && !(model.premium.isUnlocked && model.automatic.enabled)
    }

    private func subtitle(attention: Int) -> String {
        let settings = model.settings, server = model.library.serverName
        guard settings.isPaired else { return "Not set up yet" }
        if model.job.isRunning { return model.job.isPaused ? "Paused · \(server)" : "Backing up to \(server)" }
        if case .unreachable = settings.serverStatus { return "Can't reach \(server)" }
        if attention > 0 { return "\(attention) need\(attention == 1 ? "s" : "") attention · \(server)" }
        if model.history.lastBackUp == nil { return "Nothing backed up yet · \(server)" }
        return "Everything up to date · \(server)"
    }

    /// Items whose last try failed or has to wait, still on this iPhone and not being tried now.
    static func attention(_ model: AppModel) -> [RunHistory.Item] {
        let items = model.history.needsAttention
        guard !items.isEmpty else { return [] }
        let busy = Set(model.job.items.filter { $0.state == .waiting || $0.isWorking }.map(\.assetIdentifier))
        let present = PhotoLibrary.existing(items.map(\.assetID))
        return items.filter { present.contains($0.assetID) && !busy.contains($0.assetID) }
    }
}

/// An icon, a title and a line under it: the Activity and Server rows.
struct ActivityRow: View {
    let symbol: String
    var tint: Color = Theme.accent
    let title: String
    var detail: String?

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.title3).foregroundStyle(tint).frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(Theme.label)
                if let detail, !detail.isEmpty {
                    Text(detail).font(.subheadline).foregroundStyle(Theme.secondaryLabel)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// The run in progress: "Backing up 4 of 12", the current item, a bar, and Pause and Stop
/// (DESIGN 03·2.1, BK-1 and BK-P).
private struct NowCard: View {
    let job: CompactJob
    let server: String
    @State private var confirmingStop = false

    var body: some View {
        let items = job.runItems
        let open = items.filter { $0.state == .waiting || $0.isWorking }.count
        let done = items.count - open
        let current = items.first(where: \.isWorking)
        let fraction = items.isEmpty ? 0 : Double(done) / Double(items.count)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                ProgressRing(fraction: fraction)
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.isPaused ? "Paused · \(done) of \(items.count) backed up"
                         : "Backing up \(min(done + 1, items.count)) of \(items.count)")
                        .font(.headline).foregroundStyle(Theme.label)
                    if job.isPaused {
                        Text("Continue picks up where it stopped.").font(.subheadline)
                            .foregroundStyle(Theme.secondaryLabel)
                    } else if let current, case .working(let message) = current.state {
                        Text("\(current.name) · \(message)").font(.subheadline).foregroundStyle(Theme.secondaryLabel)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue("\(done) of \(items.count)")
                .accessibilityIdentifier("activity.now")
                Spacer(minLength: 4)
                // One glass capsule holding both controls.
                HStack(spacing: 0) {
                    if job.isPaused {
                        Button { job.resume() } label: { control("Continue", "play.fill") }
                            .accessibilityIdentifier("activity.resume")
                    } else {
                        Button { job.pause() } label: { control("Pause", "pause.fill") }
                            .accessibilityIdentifier("activity.pause")
                    }
                    Button { confirmingStop = true } label: { control("Stop", "stop.fill") }
                        .accessibilityIdentifier("activity.stop")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.label)
                .padding(.horizontal, 4)
                .glassEffect(.regular.interactive(), in: .capsule)
            }
            ProgressView(value: fraction).tint(Theme.accent).accessibilityHidden(true)
            if let line = detailLine(items: items, done: done) {
                Text(line).font(.footnote).foregroundStyle(Theme.secondaryLabel)
            }
        }
        .padding(.vertical, 6)
        .alert("Stop backing up?", isPresented: $confirmingStop) {
            Button("Keep Going", role: .cancel) {}
            Button("Stop") {
                job.stop()
                Announce.say("Stopped. Items already backed up stay backed up.")
            }
            .accessibilityIdentifier("activity.stop.confirm")
        } message: {
            Text("Items already backed up stay backed up.")
        }
    }

    /// An icon-only control with a 44 pt target.
    private func control(_ title: String, _ symbol: String) -> some View {
        Label { Text(title) } icon: {
            Image(systemName: symbol).font(.body.weight(.semibold)).frame(width: 44, height: 44)
        }
        .labelStyle(.iconOnly)
        .contentShape(Rectangle())
    }

    /// "About 2 min left · 1.4 GB → 0.3 GB".
    private func detailLine(items: [CompactJob.Item], done: Int) -> String? {
        var parts: [String] = []
        if !job.isPaused, done > 0, let started = job.runStarted, items.count > done {
            let left = Date().timeIntervalSince(started) / Double(done) * Double(items.count - done)
            let duration = Duration.seconds(max(left, 60))
            parts.append("About \(duration.formatted(.units(allowed: [.hours, .minutes], width: .abbreviated, maximumUnitCount: 2))) left")
        }
        var original = 0, compact = 0
        for item in items { if case .saved(let o, let c) = item.state { original += o; compact += c } }
        if original > 0 { parts.append("\(LibraryController.bytes(original)) → \(LibraryController.bytes(compact))") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// A determinate ring (the circular ProgressView on iOS only spins).
struct ProgressRing: View {
    let fraction: Double
    var size: CGFloat = 36

    var body: some View {
        ZStack {
            Circle().stroke(Theme.fill, lineWidth: 4)
            Circle().trim(from: 0, to: max(0.02, min(fraction, 1)))
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .animation(.default, value: fraction)
        .accessibilityHidden(true)
    }
}

/// "186 GB freed on this iPhone since March", with a small decorative chart by month (2.2).
private struct FreedCard: View {
    let bytes: Int
    let since: Date?
    let months: [Int]

    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(LibraryController.bytes(bytes)).bigNumber().foregroundStyle(Theme.label)
                Text(caption).font(.subheadline).foregroundStyle(Theme.secondaryLabel)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("activity.freed")
            Spacer(minLength: 8)
            if let largest = months.max(), largest > 0 {
                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(Array(months.enumerated()), id: \.offset) { index, value in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Theme.accent.opacity(0.35 + 0.65 * Double(index + 1) / Double(months.count)))
                            .frame(width: 9, height: max(4, 48 * CGFloat(value) / CGFloat(largest)))
                    }
                }
                .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 8)
    }

    private var caption: String {
        guard let since else { return "freed on this iPhone" }
        let sameYear = Calendar.current.isDate(since, equalTo: Date(), toGranularity: .year)
        return "freed on this iPhone since "
            + since.formatted(sameYear ? .dateTime.month(.wide) : .dateTime.month(.wide).year())
    }
}

extension View {
    /// An inset-grouped list on warm paper (DESIGN §8): solid cards, never glass.
    func homespunList() -> some View {
        listStyle(.insetGrouped).scrollContentBackground(.hidden).background(Theme.background)
    }
}
