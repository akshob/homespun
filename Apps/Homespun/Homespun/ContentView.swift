// SPDX-License-Identifier: Apache-2.0
import HomespunCore
import Photos
import SwiftUI

struct ContentView: View {
    @State private var settings: AppSettings
    @State private var job: CompactJob
    private let premium: Premium
    private let automatic: AutomaticMode
    @State private var library = LibraryModel()
    @State private var access = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @State private var filter = LibraryState.Filter.all
    /// The grid has its first contents, so it can open scrolled to the newest items.
    @State private var gridLoaded = false
    @State private var selected = Set<String>()
    /// Originals compacted by the last selection; offered for removal when the job finishes.
    @State private var batch = Set<String>()
    @State private var offer = Set<String>()
    /// One sheet at a time; several `.sheet` modifiers on one view can block each other.
    enum Sheet: Identifiable {
        case settings, connect, removalExplanation, activity, legend
        case pair(PairingLink)
        var id: String {
            switch self {
            case .settings: "settings"
            case .connect: "connect"
            case .removalExplanation: "removal"
            case .activity: "activity"
            case .legend: "legend"
            case .pair(let link): link.id
            }
        }
    }

    @State private var sheet: Sheet?
    @State private var removeAfterSheet = false
    /// The originals the pending removal is limited to (`nil`: every eligible one).
    @State private var removalScope: Set<String>?
    @State private var removable = 0
    @State private var removing: String?
    /// A removal is running; only one at a time, so the trial cap holds.
    @State private var isRemoving = false
    @State private var removal: OriginalRemover.Report?
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    init(model: AppModel) {
        _settings = State(initialValue: model.settings)
        _job = State(initialValue: model.job)
        premium = model.premium
        automatic = model.automatic
    }

    var body: some View {
        NavigationStack {
            Group {
                if access.allowsReading { grid } else { accessView }
            }
            .safeAreaInset(edge: .top, spacing: 0) { topBar }
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
            .navigationTitle("Homespun")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("Select all not backed up", systemImage: "checkmark.circle") { selectAllNotBackedUp() }
                            .accessibilityIdentifier("select.all")
                        if !selected.isEmpty {
                            Button("Clear selection", systemImage: "xmark.circle") { selected.removeAll() }
                        }
                        Divider()
                        Button("What the badges mean", systemImage: "info.circle") { sheet = .legend }
                    } label: {
                        Image(systemName: "checklist")
                    }
                    .accessibilityLabel("Select")
                    .accessibilityIdentifier("grid.menu")
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    if !job.items.isEmpty {
                        Button { sheet = .activity } label: { Image(systemName: "list.bullet.rectangle") }
                            .accessibilityLabel("Activity")
                            .accessibilityIdentifier("activity.open")
                    }
                    Button { sheet = .settings } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                        .accessibilityIdentifier("settings")
                }
            }
            .sheet(item: $sheet, onDismiss: sheetDismissed) { sheet in
                switch sheet {
                case .settings:
                    SettingsView(settings: settings, premium: premium, automatic: automatic)
                case .connect:
                    NavigationStack {
                        ConnectView(settings: settings) { self.sheet = nil }
                            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { self.sheet = nil } } }
                    }
                case .removalExplanation:
                    RemovalExplanationView(trial: !settings.trialConfirmed) {
                        settings.removalExplained = true
                        removeAfterSheet = true
                        self.sheet = nil
                    }
                case .activity:
                    ActivityView(job: job)
                case .legend:
                    BadgeLegendView()
                case .pair(let link):
                    PairConfirmView(settings: settings, link: link) {}
                }
            }
            .onChange(of: settings.pendingLink, initial: true) { _, link in
                if let link, settings.onboardingComplete { sheet = .pair(link) }
            }
            .fullScreenCover(isPresented: Binding(get: { !settings.onboardingComplete },
                                                  set: { settings.onboardingComplete = !$0 })) {
                OnboardingView(settings: settings)
            }
            .onChange(of: job.items.map(\.state.phase)) { _, _ in Task { await refreshGrid() } }
            .onChange(of: job.isRunning) { _, running in
                if !running { Task { await jobFinished() } }
            }
            .onChange(of: settings.onboardingComplete) { _, _ in Task { await refresh() } }
            .onChange(of: automatic.enabled) { _, on in
                if on { Task { await runAutomatic() } }
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active:
                    Task {
                        await refresh()
                        await runAutomatic()
                    }
                case .background: automatic.schedule()
                default: break
                }
            }
            .onOpenURL { url in
                if let link = PairingLink(url) { settings.pendingLink = link }
            }
            .task {
                library.onChange = { @MainActor in Task { await refreshGrid() } }
                await refresh()
                // Only what this Apple Account owns; the product itself loads on the Premium screen.
                await premium.refresh()
                await runAutomatic()
            }
        }
    }

    // MARK: Grid

    private var cells: [LibraryState.Cell] { library.state.cells(filter) }

    @ViewBuilder private var grid: some View {
        if gridLoaded { scrollingGrid } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
    }

    private var scrollingGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 86), spacing: 2)], spacing: 2) {
                ForEach(cells) { cell in
                    GridCell(cell: cell, asset: library.asset(cell.id), manager: library.thumbnails,
                             selected: selected.contains(cell.id))
                        .onTapGesture { toggle(cell) }
                }
            }
            if cells.isEmpty {
                Text(library.count == 0 ? "No photos or videos yet." : "Nothing here.")
                    .foregroundStyle(.secondary).padding(40)
            }
        }
        .modifier(OpensAtNewest())
        .accessibilityIdentifier("grid")
    }

    private func toggle(_ cell: LibraryState.Cell) {
        guard !isRemoving, cell.canCompact || cell.canFree else { return }
        if selected.contains(cell.id) { selected.remove(cell.id) } else { selected.insert(cell.id) }
    }

    private func selectAllNotBackedUp() {
        selected = Set(library.state.cells.filter { $0.badge == .none || $0.badge == .failed }.map(\.id))
    }

    // MARK: Bars

    private var topBar: some View {
        VStack(spacing: 10) {
            serverRow
            if access == .limited {
                Button("Homespun sees only some of your photos. Allow Full Access in Settings.") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .font(.caption)
            }
            if access.allowsReading {
                Picker("Show", selection: $filter) {
                    ForEach(LibraryState.Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("grid.filter")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder private var serverRow: some View {
        if settings.usesServer, let server = settings.server {
            Button { sheet = .settings } label: {
                HStack(spacing: 10) {
                    Image(systemName: "server.rack").foregroundStyle(.tint)
                    Text(server.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                    statusLine
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("server.card")
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Connect your Homespun Server").font(.headline)
                Text("It keeps your originals on your own computer and puts compact copies in Photos.")
                    .font(.callout).foregroundStyle(.secondary)
                Button { sheet = .connect } label: { Text("Connect").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("connect.open")
            }
        }
    }

    @ViewBuilder private var statusLine: some View {
        switch settings.serverStatus {
        case .reachable:
            Label("Connected", systemImage: "circle.fill").font(.caption).foregroundStyle(.green)
                .labelStyle(StatusLabelStyle())
                .accessibilityIdentifier("server.status.connected")
        case .unreachable(let message):
            Label(message, systemImage: "exclamationmark.circle.fill").font(.caption).foregroundStyle(.orange)
                .lineLimit(1)
                .accessibilityIdentifier("server.status.unreachable")
        case .checking, .unknown:
            Label("Checking…", systemImage: "circle.dotted").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var bottomBar: some View {
        let content = bottomContent
        if let content {
            content
                .padding(.horizontal)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(.bar)
        }
    }

    private var bottomContent: AnyView? {
        if isRemoving {
            return AnyView(HStack(spacing: 10) { ProgressView(); Text(removing ?? "Checking") }
                .accessibilityIdentifier("remove.progress"))
        }
        if !selected.isEmpty { return AnyView(selectionBar) }
        if job.isRunning { return AnyView(progressBar) }
        if !offer.isEmpty { return AnyView(offerCard) }
        if let removal { return AnyView(removalCard(removal)) }
        if settings.isPaired, removable > 0 { return AnyView(freeUpSpaceBar) }
        if job.items.isEmpty, access.allowsReading, settings.canCompact,
           !library.state.cells.contains(where: { $0.badge != .none }) {
            return AnyView(Text("Tap photos and videos to select them, then Compact. Start with a few: their compact "
                                + "copies go to the \(PhotoLibrary.albumTitle) album, so you can compare.")
                .font(.footnote).foregroundStyle(.secondary))
        }
        return nil
    }

    private var selectionBar: some View {
        let chosen = library.state.cells.filter { selected.contains($0.id) }
        let compactable = chosen.filter(\.canCompact).map(\.id)
        let freeable = Set(chosen.filter(\.canFree).compactMap(\.original))
        let blocked = compactBlockedReason
        return VStack(spacing: 6) {
            HStack(spacing: 12) {
                Button("Clear") { selected.removeAll() }
                Text("\(selected.count) selected").font(.subheadline).foregroundStyle(.secondary)
                    .accessibilityIdentifier("selection.count")
                Spacer()
                if !freeable.isEmpty {
                    Button("Free up space") { startRemoval(only: freeable) }
                        .buttonStyle(.bordered)
                        .disabled(!settings.isPaired || isRemoving || job.isRunning)
                        .accessibilityIdentifier("selection.free")
                }
                if !compactable.isEmpty {
                    Button("Compact \(compactable.count)") { compact(compactable) }
                        .buttonStyle(.borderedProminent)
                        .disabled(blocked != nil)
                        .accessibilityIdentifier("compact.selected")
                }
            }
            if let blocked, !compactable.isEmpty {
                Text(blocked).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var compactBlockedReason: String? {
        if !settings.canCompact { return "Connect your Homespun Server first." }
        if settings.usesServer, settings.serverStatus != .reachable { return "The server isn't reachable right now." }
        return nil
    }

    private var progressBar: some View {
        let remaining = job.items.filter { $0.state == .waiting || $0.isWorking }.count
        let current = job.items.first(where: \.isWorking)
        return Button { sheet = .activity } label: {
            HStack(spacing: 10) {
                ProgressView()
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(remaining) left").font(.subheadline.weight(.semibold))
                    if let current, case .working(let message) = current.state {
                        Text("\(current.name): \(message)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                Text("Details").font(.caption)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("job.progress")
    }

    private var offerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(offer.count) compact cop\(offer.count == 1 ? "y is" : "ies are") ready, and the originals are on "
                 + "your server. Remove the originals from this iPhone to free up space?")
                .font(.callout)
            HStack {
                Button("Not now") { offer = [] }.buttonStyle(.bordered)
                Button("Free up space") { startRemoval(only: offer) }
                    .buttonStyle(.borderedProminent)
                    .disabled(isRemoving || job.isRunning)
                    .accessibilityIdentifier("offer.free")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func removalCard(_ report: OriginalRemover.Report) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(summary(report)).font(.callout).accessibilityIdentifier("remove.summary")
            if !settings.trialConfirmed, !report.removed.isEmpty {
                Text("Check a few compact copies in Photos. If they look right, Homespun removes more at a time next time.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Open Photos") { if let url = URL(string: "photos-redirect://") { openURL(url) } }
                        .buttonStyle(.bordered)
                    Button("They look right") {
                        settings.trialConfirmed = true
                        removal = nil
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("trial.confirm")
                }
            } else {
                Button("OK") { removal = nil }.accessibilityIdentifier("remove.dismiss")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var freeUpSpaceBar: some View {
        VStack(spacing: 4) {
            Button { startRemoval(only: nil) } label: {
                Label(removeTitle, systemImage: "trash").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(isRemoving || job.isRunning)
            .accessibilityIdentifier("remove.originals")
            Text("Each is checked against your server first; iOS asks you to confirm.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var removeTitle: String {
        let count = settings.trialConfirmed ? removable : min(removable, AppSettings.trialLimit)
        let noun = "original\(count == 1 ? "" : "s")"
        return settings.trialConfirmed || removable <= AppSettings.trialLimit
            ? "Free up space: remove \(count) \(noun)"
            : "Free up space: remove \(count) \(noun) to try it (of \(removable))"
    }

    @ViewBuilder private var accessView: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.on.rectangle.angled").font(.system(size: 44)).foregroundStyle(.tint)
            Text("Homespun needs Full Access to your photos to show them, read originals, and save compact copies.")
                .multilineTextAlignment(.center)
            if access == .notDetermined {
                Button("Allow access to Photos") {
                    Task {
                        access = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
                        await refresh()
                    }
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Actions

    private func compact(_ identifiers: [String]) {
        selected.removeAll()
        offer = []
        removal = nil
        batch.formUnion(identifiers)
        job.enqueue(identifiers)
    }

    private func startRemoval(only scope: Set<String>?) {
        guard !isRemoving, !removeAfterSheet else { return }
        selected.removeAll()
        offer = []
        removal = nil
        removalScope = scope
        if settings.removalExplained { Task { await removeOriginals() } } else { sheet = .removalExplanation }
    }

    private func sheetDismissed() {
        settings.pendingLink = nil
        // iOS shows its delete confirmation only once the explanation sheet has gone.
        if removeAfterSheet {
            removeAfterSheet = false
            Task { await removeOriginals() }
        }
        Task { await refresh() }
    }

    private func refresh() async {
        access = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        library.reload()
        if settings.isPaired { await settings.refreshServerInfo() }
        await refreshRemovable()
        await refreshGrid()
    }

    /// Automatic mode catches up whenever the app opens (unless something is already running).
    private func runAutomatic() async {
        guard automatic.enabled, premium.isUnlocked, !job.isRunning, !isRemoving, settings.onboardingComplete else { return }
        await automatic.run(settings: settings, job: job, premium: premium, notify: false)
        await refreshRemovable()
        await refreshGrid()
    }

    private func refreshGrid() async {
        library.update(ledger: await job.ledger.snapshot(), job: job.states)
        gridLoaded = true
    }

    private func refreshRemovable() async {
        removable = await settings.remover(ledger: job.ledger)?.candidates().count ?? 0
    }

    /// Offers to free up space for what the last selection compacted.
    private func jobFinished() async {
        await refreshRemovable()
        await refreshGrid()
        let compacted = batch
        batch = []
        guard settings.isPaired, let remover = settings.remover(ledger: job.ledger), !compacted.isEmpty else { return }
        offer = Set(await remover.candidates(only: compacted).map(\.original))
    }

    private func removeOriginals() async {
        guard !isRemoving, let remover = settings.remover(ledger: job.ledger) else { return }
        isRemoving = true
        let scope = removalScope
        removalScope = nil
        removing = "Checking"
        defer {
            removing = nil
            isRemoving = false
        }
        do {
            removal = try await remover.removeEligible(limit: settings.trialConfirmed ? nil : AppSettings.trialLimit,
                                                       only: scope) { message in
                Task { @MainActor in removing = message }
            }
        } catch {
            removal = OriginalRemover.Report(blocked: [error.localizedDescription])
        }
        await refreshRemovable()
        await refreshGrid()
    }

    private func summary(_ report: OriginalRemover.Report) -> String {
        var lines: [String] = []
        if report.cancelled { lines.append("Nothing was removed.") }
        if !report.removed.isEmpty {
            lines.append("Removed \(report.removed.count), freeing \(bytes(report.freedBytes)). They stay in Recently Deleted.")
        }
        lines += report.blocked.map { "Kept \($0)" }
        return lines.isEmpty ? "Nothing to remove." : lines.joined(separator: "\n")
    }
}

/// Opens a long library at the newest items, like Photos, while a short one stays at the top.
private struct OpensAtNewest: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(.top, for: .alignment)
        } else {
            content
        }
    }
}

/// A status dot and text, tight together.
private struct StatusLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 7))
            configuration.title
        }
    }
}

/// What was picked this session, with each item's progress or result.
struct ActivityView: View {
    let job: CompactJob
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if job.savedOriginalBytes > 0 {
                    Section("Saved this session") {
                        LabeledContent("Originals", value: bytes(job.savedOriginalBytes))
                        LabeledContent("Compact copies", value: bytes(job.savedCompactBytes))
                        LabeledContent("Ratio", value: (Double(job.savedCompactBytes) / Double(job.savedOriginalBytes))
                            .formatted(.percent.precision(.fractionLength(0))))
                    }
                }
                Section("Items") {
                    ForEach(job.items) { ItemRow(item: $0) }
                }
            }
            .navigationTitle("Activity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                if !job.isRunning {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Clear") {
                            job.clearFinished()
                            dismiss()
                        }
                    }
                }
            }
        }
    }
}

/// Shown once, before the first removal.
struct RemovalExplanationView: View {
    let trial: Bool
    var proceed: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Before removing originals").font(.title2.bold())
                    point("checkmark.shield", "Each original is checked again: this iPhone's file and the server's copy must "
                          + "match byte for byte, and its compact copy must be in Photos.")
                    point("icloud", "If you use iCloud Photos, removing an original here also removes it from iCloud and "
                          + "your other devices. The compact copy stays everywhere.")
                    point("trash", "iOS asks you to confirm. Removed items stay in Recently Deleted for 30 days; Homespun "
                          + "never empties it.")
                    if trial {
                        point("hand.raised", "The first time, Homespun removes at most \(AppSettings.trialLimit), so you can "
                              + "check the result before removing the rest.")
                    }
                }
                .padding(24)
            }
            .safeAreaInset(edge: .bottom) {
                Button(action: proceed) { Text("Continue").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large).padding(24)
                    .accessibilityIdentifier("removal.continue")
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private func point(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.title3).foregroundStyle(.tint).frame(width: 30)
            Text(text)
        }
    }
}

private struct ItemRow: View {
    let item: CompactJob.Item

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: item.symbol).foregroundStyle(.secondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).lineLimit(1).truncationMode(.middle)
                status.font(.caption).accessibilityIdentifier("status.\(stateName)")
            }
        }
    }

    /// Stable name for UI tests.
    private var stateName: String {
        switch item.state {
        case .waiting: "waiting"
        case .working: "working"
        case .saved: "saved"
        case .unchanged: "unchanged"
        case .notYet: "notYet"
        case .failed: "failed"
        }
    }

    @ViewBuilder private var status: some View {
        switch item.state {
        case .waiting:
            Text("Waiting").foregroundStyle(.secondary)
        case .working(let message):
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(message)
            }.foregroundStyle(.secondary)
        case .saved(let original, let compact):
            Text("\(bytes(original)) → \(bytes(compact))").foregroundStyle(.green)
        case .unchanged(let reason), .notYet(let reason):
            Text(reason).foregroundStyle(.secondary)
        case .failed(let reason):
            Text(reason).foregroundStyle(.red)
        }
    }
}

private func bytes(_ count: Int) -> String {
    Int64(count).formatted(.byteCount(style: .file))
}
