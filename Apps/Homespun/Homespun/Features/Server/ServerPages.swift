// SPDX-License-Identifier: Apache-2.0
import HomespunCore
import Photos
import SwiftUI
import UserNotifications

/// The slider's live count: "2,310 get compact copies now · 121 wait".
struct CompactPreview: Equatable {
    var days: Int
    var now: Int
    var wait: Int
    var favorites: Int

    var line: String {
        var parts = ["\(now.formatted()) get compact copies now"]
        if wait > 0 {
            let since = Date().addingTimeInterval(-Double(days) * 86_400).formatted(.dateTime.month(.abbreviated).day())
            parts.append("\(wait.formatted()) wait (newer than \(since))")
        }
        if favorites > 0 { parts.append("\(favorites.formatted()) favorite\(favorites == 1 ? "" : "s") kept as they are") }
        return parts.joined(separator: " · ")
    }
}

/// Automatic mode's settings with its status (DESIGN 05·2.1–2.2). Without the purchase the page is
/// the same; turning it on asks for the purchase first, then what to back up.
struct AutomaticModeView: View {
    let model: AppModel
    @State private var askingScope = false
    @State private var unlocking = false
    /// Unlocked on the sheet: ask what to back up once it has closed.
    @State private var turnOnAfterUnlock = false
    /// The slider's position while dragging (saved when it settles), and its live count.
    @State private var stop: Double?
    @State private var preview: CompactPreview?

    var body: some View {
        let automatic = model.automatic, settings = model.settings, premium = model.premium
        let enabled = automatic.enabled && premium.isUnlocked
        List {
            Section {
                Toggle("Automatic Mode", isOn: Binding(get: { enabled }, set: { on in
                    if !on {
                        automatic.disable()
                    } else if premium.isUnlocked {
                        askingScope = true
                    } else {
                        unlocking = true
                    }
                }))
                .tint(Theme.accent)
                .disabled(!settings.canCompact)
                .accessibilityIdentifier("automatic.toggle")
            } header: {
                Text("New photos and videos are backed up and get their compact copies on their own, without being "
                     + "selected.")
                    .font(.body).foregroundStyle(Theme.label).textCase(nil)
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Usually overnight while this iPhone charges, and whenever you open Homespun. iOS decides the "
                         + "exact time.")
                    if !premium.isUnlocked {
                        Text("Turning it on is a one-time purchase, which unlocks Cloud Copies too.")
                    }
                    if !settings.isPaired {
                        Text("Pair a server first.")
                    } else if UIApplication.shared.backgroundRefreshStatus == .denied {
                        Text("Turn on Background App Refresh for Homespun in Settings.")
                    }
                }
            }
            .listRowBackground(Theme.card)
            Section("Back up") {
                scopeRow("New Photos and Videos", detail: nil, selected: !automatic.backsUpEverything) {
                    automatic.setScope(everything: false)
                }
                .accessibilityIdentifier("automatic.scope.new")
                let count = model.library.library.state.count(.notBackedUp)
                scopeRow("Everything Not Backed Up", detail: "\(count.formatted()) item\(count == 1 ? "" : "s")",
                         selected: automatic.backsUpEverything) {
                    automatic.setScope(everything: true)
                }
                .accessibilityIdentifier("automatic.scope.everything")
            }
            .disabled(!enabled)
            .listRowBackground(Theme.card)
            compactSection(automatic, enabled: enabled)
            Section {
                Toggle(isOn: Binding(get: { automatic.state.notifies }, set: { automatic.setNotifies($0) })) {
                    Label("Tell Me When Space Can Be Freed", systemImage: "bell")
                }
                .tint(Theme.accent)
                .disabled(!enabled)
            }
            .listRowBackground(Theme.card)
            Section {
                LabeledContent("Last run", value: automatic.state.lastRun.map(Self.when) ?? "Not yet")
                if let summary = automatic.state.lastSummary {
                    LabeledContent("Result", value: summary)
                }
                LabeledContent("Next", value: enabled ? "Tonight, while charging" : "Off")
            } header: {
                Text("Status")
            } footer: {
                Text("Automatic mode never removes originals. You choose when to free up space.")
            }
            .listRowBackground(Theme.card)
        }
        .homespunList()
        .navigationTitle("Automatic Mode")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $unlocking, onDismiss: {
            if turnOnAfterUnlock {
                turnOnAfterUnlock = false
                askingScope = true
            }
        }) {
            UnlockSheet(feature: .automatic, premium: premium, server: model.library.serverName) {
                turnOnAfterUnlock = true
            }
        }
        .alert("Back up what's already here too?", isPresented: $askingScope) {
            Self.scopeButtons(automatic)
        } message: {
            Text(Self.scopeMessage(count: model.library.library.state.count(.notBackedUp)))
        }
        .task(id: automatic.compactSchedule) { await updatePreview(automatic.compactSchedule) }
    }

    // MARK: Compact copies

    /// When compact copies are made (DESIGN 05·2.1, revised 15 Nov): a slider with five stops.
    @ViewBuilder private func compactSection(_ automatic: AutomaticMode, enabled: Bool) -> some View {
        let schedule = automatic.compactSchedule
        let position = stop ?? Double(schedule.stop)
        let shown = CompactSchedule.stops[Int(position.rounded())]
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Make compact copies")
                    Spacer()
                    Text(CompactSchedule.label(days: shown)).font(.headline).foregroundStyle(Theme.accent)
                        .contentTransition(.numericText())
                }
                Slider(value: Binding(get: { position }, set: { stop = $0 }),
                       in: 0...Double(CompactSchedule.stops.count - 1), step: 1) { editing in
                    guard !editing, let stop else { return }
                    var changed = schedule
                    changed.stop = Int(stop.rounded())
                    automatic.setCompactSchedule(changed)
                    self.stop = nil
                }
                .tint(Theme.accent)
                .accessibilityLabel("Make compact copies")
                .accessibilityValue(CompactSchedule.label(days: shown))
                .accessibilityIdentifier("automatic.cutoff")
                HStack {
                    ForEach(Array(["Now", "1 wk", "1 mo", "2 mo", "3 mo"].enumerated()), id: \.offset) { index, mark in
                        Text(mark)
                        if index < 4 { Spacer() }
                    }
                }
                .font(.caption).foregroundStyle(Theme.secondaryLabel)
                .accessibilityHidden(true)
                if let preview, preview.days == shown {
                    Text(preview.line).font(.subheadline).foregroundStyle(Theme.secondaryLabel)
                        .accessibilityIdentifier("automatic.cutoff.preview")
                }
            }
            .padding(.vertical, 4)
            Toggle(isOn: Binding(get: { schedule.keepFavorites }, set: { keep in
                var changed = schedule
                changed.keepFavorites = keep
                automatic.setCompactSchedule(changed)
            })) {
                Label("Keep Favorites as They Are", systemImage: "heart")
            }
            .tint(Theme.accent)
            .accessibilityIdentifier("automatic.keepFavorites")
        } header: {
            Text("Compact copies")
        } footer: {
            Text(shown == 0
                 ? "Each new photo or video gets its compact copy as soon as it's backed up."
                 : "New photos and videos are backed up right away, and get their compact copies once they're older "
                    + "than this. Delete one before then and it never comes back as a compact copy; \(model.library.serverName) "
                    + "keeps its original in its trash for 30 days.")
        }
        .disabled(!enabled)
        .listRowBackground(Theme.card)
        .onChange(of: stop) { _, value in
            guard let value else { return }
            var trial = schedule
            trial.stop = Int(value.rounded())
            Task { await updatePreview(trial) }
        }
    }

    /// How many items get compact copies now with this schedule, and how many wait.
    private func updatePreview(_ schedule: CompactSchedule) async {
        let cells = model.library.library.state.cells.filter { [.none, .copyLater].contains($0.badge) }.map(\.id)
        let automatic = model.automatic
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }
        var now = 0, wait = 0, kept = 0
        PHAsset.fetchAssets(withLocalIdentifiers: cells, options: nil).enumerateObjects { asset, _, _ in
            let due = schedule.due(created: asset.creationDate, firstSeen: automatic.state.firstSeen[asset.localIdentifier],
                                   favorite: asset.isFavorite)
            if let due { if due <= Date() { now += 1 } else { wait += 1 } } else { kept += 1 }
        }
        preview = CompactPreview(days: schedule.days, now: now, wait: wait, favorites: kept)
    }


    private func scopeRow(_ title: String, detail: String?, selected: Bool,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(Theme.label)
                    if let detail { Text(detail).font(.subheadline).foregroundStyle(Theme.secondaryLabel) }
                }
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The choice when turning it on (05·2.2). The test suite taps "Everything not backed up yet".
    @ViewBuilder static func scopeButtons(_ automatic: AutomaticMode) -> some View {
        Button("Only New Ones") { Task { await automatic.enable(existing: false) } }
        Button("Everything not backed up yet") { Task { await automatic.enable(existing: true) } }
            .accessibilityIdentifier("automatic.everything")
        Button("Cancel", role: .cancel) {}
    }

    static func scopeMessage(count: Int) -> String {
        "Automatic mode can back up only new photos and videos, or everything that isn't backed up yet "
            + "(\(count.formatted()) item\(count == 1 ? "" : "s"))."
    }

    static func when(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(date) { return "Today, \(time)" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday, \(time)" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

/// Notifications: the three promises before iOS asks, then their state (05·2.3).
struct NotificationsView: View {
    let model: AppModel
    @State private var status: UNAuthorizationStatus?
    @Environment(\.openURL) private var openURL

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 18) {
                    Image(systemName: "bell").font(.largeTitle).foregroundStyle(Theme.accent).accessibilityHidden(true)
                    Text("Homespun tells you when space is ready").displayTitle().accessibilityAddTraits(.isHeader)
                    promise("iphone", "Only when space is ready",
                            "At most once a day, after a night of backing up: “1.2 GB ready to free up.”")
                    promise("exclamationmark.triangle", "Or when something needs you",
                            "Only if backing up has failed for 3 nights in a row.")
                    promise("hand.raised", "Nothing else", "No tips, no offers, no Premium, no streaks.")
                }
                .padding(.vertical, 8)
            } footer: {
                Text("Turn them off any time in Settings › Apps › Homespun › Notifications.")
            }
            .listRowBackground(Color.clear)
            Section {
                switch status {
                case .notDetermined?:
                    Button {
                        Task {
                            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge])
                            await load()
                        }
                    } label: {
                        Text("Continue").frame(maxWidth: .infinity)
                    }
                    .primaryAction()
                    .accessibilityIdentifier("notifications.continue")
                case .denied?:
                    InlineNotice(tone: .info, title: "Notifications are off",
                                 message: "Results wait in Activity. To get them, allow notifications for Homespun in Settings.") {
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                        }
                        .tint(Theme.accent)
                    }
                case nil:
                    EmptyView()
                default:
                    InlineNotice(tone: .success, title: "Notifications are on",
                                 message: model.automatic.enabled ? nil
                                    : "They come after automatic mode backs up overnight, so they start once it's on.")
                }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
        .homespunList()
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func promise(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.title3).foregroundStyle(Theme.accent).frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline).foregroundStyle(Theme.label)
                Text(text).font(.subheadline).foregroundStyle(Theme.secondaryLabel)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func load() async {
        status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
}

/// How compact copies are made (04·3.5). The server owns the settings, so every device makes the
/// same copies; they're shown here, and changing them from the app comes later.
struct CompactCopiesView: View {
    let server: ServerAPI.ServerInfo?

    var body: some View {
        let profile = server?.profile ?? .standard
        let name = server?.name ?? "The server"
        List {
            Section("Photos") {
                let edges = [2048, 3072].contains(profile.photoMaxEdge) ? [2048, 3072] : [profile.photoMaxEdge, 2048, 3072]
                ForEach(edges, id: \.self) { edge in
                    option("\(edge) px", Self.photoDetail(edge), selected: edge == profile.photoMaxEdge)
                }
                option("Original size", "Only recompressed.", selected: false)
            }
            .listRowBackground(Theme.card)
            Section("Videos") {
                let heights = [720, 1080].contains(profile.videoShortEdge) ? [720, 1080] : [profile.videoShortEdge, 720, 1080]
                ForEach(heights, id: \.self) { height in
                    option("\(height)p", height == 720 ? "HEVC. Recommended." : height == 1080
                           ? "HEVC, about twice the size of 720p." : "HEVC.", selected: height == profile.videoShortEdge)
                }
            }
            .listRowBackground(Theme.card)
            Section {
                LabeledContent("Live Photos", value: "Motion kept")
            } footer: {
                Text("\(name) makes every compact copy with these settings, so every device gets the same copies. "
                     + "Copies already made stay as they are.")
            }
            .listRowBackground(Theme.card)
        }
        .homespunList()
        .navigationTitle("Compact Copies")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func option(_ title: String, _ detail: String, selected: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(selected ? Theme.label : Theme.secondaryLabel)
                Text(detail).font(.subheadline).foregroundStyle(Theme.secondaryLabel)
            }
            Spacer()
            if selected { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    static func photoDetail(_ edge: Int) -> String {
        switch edge {
        case 2048: "About a fifth of the size. Recommended."
        case 3072: "Sharper when zoomed, about a third."
        default: "The long side, in pixels."
        }
    }
}

/// Help and About: the badge guide, setting up again, and versions.
struct HelpAboutView: View {
    let model: AppModel
    @State private var showingBadges = false

    var body: some View {
        let settings = model.settings
        List {
            Section {
                NavigationLink {
                    ReportProblemView(model: model)
                } label: {
                    ServerRow(title: "Report a Problem", symbol: "exclamationmark.bubble", value: nil)
                }
                .accessibilityIdentifier("help.report")
                if !SentReports.shared.reports.isEmpty {
                    NavigationLink {
                        SentReportsView()
                    } label: {
                        ServerRow(title: "Sent Reports", symbol: "tray.full", value: SentReports.shared.reports.count.formatted())
                    }
                    .accessibilityIdentifier("help.sentReports")
                }
                Button { showingBadges = true } label: {
                    ServerRow(title: "Badge Guide", symbol: "circle.lefthalf.filled", value: nil, chevron: true)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("help.badges")
                if model.library.journey.getStartedClosed, settings.freedBytes == 0 {
                    Button { model.library.journey.getStartedClosed = false } label: {
                        ServerRow(title: "Show Get Started in Activity", symbol: "checklist", value: nil)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("help.getStarted")
                }
                Link(destination: URL(string: "https://homespun.photos")!) {
                    ServerRow(title: "homespun.photos", symbol: "safari", value: nil)
                }
            }
            .listRowBackground(Theme.card)
            Section {
                Button { settings.onboardingComplete = false } label: {
                    ServerRow(title: "Set Up Again", symbol: "arrow.counterclockwise", value: nil)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings.onboarding")
            } footer: {
                Text("Shows the setup pages again. This iPhone stays paired, and nothing is removed.")
            }
            .listRowBackground(Theme.card)
            Section("About") {
                LabeledContent("Homespun", value: Self.version)
                if let server = settings.server {
                    LabeledContent(server.name, value: "Homespun Server \(server.version)")
                }
                Text("Homespun sends your photos and videos only to your own server. No accounts, no ads, no tracking; "
                     + "anonymous analytics only if you share them.")
                    .font(.subheadline).foregroundStyle(Theme.secondaryLabel)
            }
            .listRowBackground(Theme.card)
        }
        .homespunList()
        .navigationTitle("Help and About")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingBadges) { BadgeLegendView(serverName: model.library.serverName) }
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

/// Bringing in a library made with another tool (import E8–E9, S8): the server records the
/// originals, then this iPhone finds their compact copies.
struct ExistingLibraryView: View {
    let model: AppModel
    @State private var finding = false

    var body: some View {
        let settings = model.settings, finder = model.copyFinder
        let server = model.library.serverName
        let immich = settings.server?.mode == .immich
        List {
            if !immich {
                Section {
                    ActivityRow(symbol: "circle.dashed", tint: Theme.secondaryLabel, title: "Record your originals",
                                detail: "One command on \(server); your originals stay where they are.")
                    NavigationLink {
                        ImportGuideView(server: settings.server)
                    } label: {
                        Label("How to Import on \(server)", systemImage: "terminal").foregroundStyle(Theme.accent)
                    }
                    .accessibilityIdentifier("existing.guide")
                } header: {
                    VStack(alignment: .leading, spacing: 18) {
                        intro(immich: false, server: server)
                        Text("1 · On \(server)")
                    }
                }
                .listRowBackground(Theme.card)
            }
            Section {
                Button { finding = true } label: {
                    HStack {
                        ActivityRow(symbol: "magnifyingglass", title: immich ? "Find Copies Homespun Made" : "Find Compact Copies",
                                    detail: immich ? "Restores what this iPhone knew, for example after reinstalling Homespun."
                                        : "Also finds copies Homespun made, if this iPhone forgot them.")
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.tertiaryLabel).accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(settings.client == nil)
                .accessibilityIdentifier("settings.findCopies")
                if finder.isRunning {
                    HStack(spacing: 14) {
                        ProgressRing(fraction: Double(finder.checked) / Double(max(finder.total, 1)), size: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Finding compact copies").foregroundStyle(Theme.label)
                            Text("\(finder.checked.formatted()) of \(finder.total.formatted()) · \(finder.found.formatted()) found")
                                .font(.subheadline).foregroundStyle(Theme.secondaryLabel)
                        }
                    }
                    .accessibilityElement(children: .combine)
                } else if let summary = finder.summary {
                    ActivityRow(symbol: "checkmark.circle.fill", tint: Theme.teal, title: "\(summary.found.formatted()) found",
                                detail: Self.lastRun(summary))
                }
            } header: {
                if immich {
                    VStack(alignment: .leading, spacing: 18) {
                        intro(immich: true, server: server)
                        Text("On this iPhone")
                    }
                } else {
                    Text("2 · On this iPhone")
                }
            }
            .listRowBackground(Theme.card)
            if !immich {
                Section {
                    ActivityRow(symbol: "folder", tint: Theme.tertiaryLabel, title: "Choose Folders from Here",
                                detail: "Pick the archive on \(server) and let it match originals to copies.")
                        .opacity(0.6)
                } header: {
                    Text("Coming later")
                } footer: {
                    Text("Homespun reads originals where they are and never moves, changes or deletes them. Only "
                         + "fingerprints (SHA-256) leave this iPhone, and only to \(server).")
                }
                .listRowBackground(Theme.card)
            }
        }
        .homespunList()
        .navigationTitle("Existing Library")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $finding) {
            CopyFinderView(finder: finder, settings: settings, ledger: model.job.ledger)
        }
    }

    /// The page's opening sentence, above the first section.
    private func intro(immich: Bool, server: String) -> some View {
        Text(immich ? "\(server) reads originals from Immich, so there's no archive on its disks to bring in."
             : "Made compact copies with another tool, and kept the originals on \(server)'s disks? Bring them in, "
                + "so Homespun knows which is which.")
            .font(.body).foregroundStyle(Theme.label).textCase(nil)
    }

    static func lastRun(_ summary: CopyFinder.Summary) -> String {
        var parts: [String] = []
        if let finished = summary.finishedAt { parts.append("Last run \(ServerStatusCard.when(finished))") }
        if summary.needsAttention > 0 { parts.append("\(summary.needsAttention) need attention") }
        return parts.joined(separator: " · ")
    }
}

/// The commands that record an existing library on the server (import S1–S3).
struct ImportGuideView: View {
    let server: ServerAPI.ServerInfo?
    enum Kind: String, CaseIterable, Identifiable {
        case mac = "Mac", linux = "Linux", nas = "NAS (Docker)"
        var id: String { rawValue }
    }

    @State private var kind: Kind

    init(server: ServerAPI.ServerInfo?) {
        self.server = server
        let kind: Kind = server?.hardware?.kind == .container ? .nas : server?.platform?.os == .linux ? .linux : .mac
        _kind = State(initialValue: kind)
    }

    var body: some View {
        let name = server?.name ?? "the server"
        List {
            Section {
                Picker("Server", selection: $kind) {
                    ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Text("Do this on \(name). Homespun reads your originals where they are; it never moves, changes or "
                     + "deletes them.")
                    .font(.subheadline).foregroundStyle(Theme.secondaryLabel)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(index + 1) · \(step.title)").font(.headline).foregroundStyle(Theme.label)
                        Text(step.detail).font(.subheadline).foregroundStyle(Theme.secondaryLabel)
                        ForEach(step.commands, id: \.self) { ServerCommand(command: $0) }
                    }
                    .padding(.vertical, 4)
                }
                .listRowBackground(Theme.card)
            }
            Section {
                ShareLink(item: steps.flatMap(\.commands).joined(separator: "\n")) {
                    Label("Send to My Computer", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                }
                .primaryAction()
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
        .homespunList()
        .navigationTitle("Import on \(name)")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var steps: [(title: String, detail: String, commands: [String])] {
        let list = switch kind {
        case .mac: "~/Desktop/archive.jsonl"
        case .linux: "~/archive.jsonl"
        case .nas: "/archive/archive.jsonl"
        }
        let run = kind == .nas ? "docker exec -it homespun homespun-server import" : "homespun-server import"
        var steps: [(title: String, detail: String, commands: [String])] = []
        if kind == .nas {
            steps.append(("Let Homespun read the archive",
                          "Add a read-only volume to the homespun project's compose file, then rebuild the project:",
                          ["- /volume1/photo:/archive:ro"]))
        }
        steps.append(("Make a list of your originals",
                      "One line per item: where each original is, and the SHA-256 of the compact copy you made from it. "
                        + "The format is at homespun.photos/import.", []))
        steps.append(("Check the list first", kind == .nas
                      ? "Paths in the list are the container's: /archive/2021/11/… Nothing is recorded yet."
                      : "Nothing is recorded. It lists missing files.", ["\(run) \(list) --dry-run"]))
        steps.append(("Import", "Safe to run again; finished items are skipped."
                      + (kind == .mac ? " macOS may ask to let Terminal read the drive. Choose Allow." : ""),
                      ["\(run) \(list)"]))
        steps.append(("Come back here", "Then tap Find Compact Copies.", []))
        return steps
    }
}

/// A command to run on the server: monospaced, selectable, with a copy button.
struct ServerCommand: View {
    let command: String
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(command).font(.system(.footnote, design: .monospaced)).foregroundStyle(Theme.label)
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            Button {
                UIPasteboard.general.string = command
                copied = true
            } label: {
                Label(copied ? "Copied" : "Copy command", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless).tint(Theme.accent)
        }
        .padding(10)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
