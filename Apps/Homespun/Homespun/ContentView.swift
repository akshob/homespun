// SPDX-License-Identifier: Apache-2.0
import HomespunCore
import Photos
import PhotosUI
import SwiftUI

struct ContentView: View {
    @State private var settings: AppSettings
    @State private var job: CompactJob
    @State private var selection: [PhotosPickerItem] = []
    @State private var access = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    /// One sheet at a time; several `.sheet` modifiers on one view can block each other.
    enum Sheet: Identifiable {
        case settings, connect, removalExplanation
        case pair(PairingLink)
        var id: String {
            switch self {
            case .settings: "settings"
            case .connect: "connect"
            case .removalExplanation: "removal"
            case .pair(let link): link.id
            }
        }
    }

    @State private var sheet: Sheet?
    @State private var removeAfterSheet = false
    @State private var removable = 0
    @State private var removing: String?
    @State private var removal: OriginalRemover.Report?
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let settings = AppSettings()
        _settings = State(initialValue: settings)
        _job = State(initialValue: CompactJob(settings: settings))
    }

    var body: some View {
        NavigationStack {
            List {
                header
                if settings.canCompact { pickSection }
                if settings.isPaired, removable > 0 || removal != nil { removalSection }
                if !job.items.isEmpty { itemsSection }
                if job.savedOriginalBytes > 0 { savedSection }
            }
            .navigationTitle("Homespun")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { sheet = .settings } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                        .accessibilityIdentifier("settings")
                }
            }
            .sheet(item: $sheet, onDismiss: sheetDismissed) { sheet in
                switch sheet {
                case .settings:
                    SettingsView(settings: settings)
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
            .onChange(of: selection) { _, items in
                let identifiers = items.compactMap(\.itemIdentifier)
                selection = []
                if !identifiers.isEmpty { job.enqueue(identifiers) }
            }
            .onChange(of: job.isRunning) { _, running in
                if !running { Task { await refreshRemovable() } }
            }
            .onChange(of: settings.onboardingComplete) { _, _ in Task { await refresh() } }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await refresh() } }
            }
            .onOpenURL { url in
                if let link = PairingLink(url) { settings.pendingLink = link }
            }
            .task { await refresh() }
        }
    }

    // MARK: Sections

    @ViewBuilder private var header: some View {
        if settings.usesServer, let server = settings.server {
            Section {
                Button { sheet = .settings } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "server.rack").font(.title2).foregroundStyle(.tint).frame(width: 34)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(server.name).font(.headline).foregroundStyle(.primary)
                            Text(server.mode == .immich ? "Originals in Immich" : "Originals on the server")
                                .font(.subheadline).foregroundStyle(.secondary)
                            statusLine
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("server.card")
            }
        } else if settings.mode == .device {
            Section {
                Label("On this iPhone", systemImage: "iphone")
            } footer: {
                Text("Compact copies are added to the \(PhotoLibrary.albumTitle) album. Nothing is removed, so this frees "
                     + "no space; connect a server for that.")
            }
        } else {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Connect your Homespun Server").font(.headline)
                    Text("Homespun keeps your originals on your own computer and puts compact copies in Photos.")
                        .foregroundStyle(.secondary)
                    Button { sheet = .connect } label: { Text("Connect").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("connect.open")
                }
                .padding(.vertical, 6)
            } footer: {
                Text("No server? You can make compact copies on this iPhone in Settings, but that frees no space.")
            }
        }
    }

    @ViewBuilder private var statusLine: some View {
        switch settings.serverStatus {
        case .reachable:
            Label("Connected", systemImage: "circle.fill").font(.caption).foregroundStyle(.green)
                .accessibilityIdentifier("server.status.connected")
        case .unreachable(let message):
            Label(message, systemImage: "exclamationmark.circle.fill").font(.caption).foregroundStyle(.orange)
                .accessibilityIdentifier("server.status.unreachable")
        case .checking, .unknown:
            Label("Checking…", systemImage: "circle.dotted").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var pickSection: some View {
        Section {
            if access == .authorized {
                PhotosPicker(selection: $selection, matching: .any(of: [.images, .videos, .livePhotos]),
                             preferredItemEncoding: .current, photoLibrary: .shared()) {
                    Label("Choose photos and videos", systemImage: "photo.stack")
                }
                .disabled(settings.usesServer && settings.serverStatus != .reachable)
            } else {
                accessPrompt
            }
        } footer: {
            if job.items.isEmpty {
                Text("Start with a few photos and videos. Their compact copies appear in the \(PhotoLibrary.albumTitle) "
                     + "album in Photos, so you can compare them before removing anything. Keep Homespun open while it works.")
            }
        }
    }

    private var itemsSection: some View {
        Section {
            ForEach(job.items) { ItemRow(item: $0) }
        } header: {
            HStack {
                Text("Items")
                Spacer()
                if !job.isRunning { Button("Clear") { job.clearFinished() }.font(.caption) }
            }
        }
    }

    private var savedSection: some View {
        Section("Saved this session") {
            LabeledContent("Originals", value: bytes(job.savedOriginalBytes))
            LabeledContent("Compact copies", value: bytes(job.savedCompactBytes))
            LabeledContent("Ratio", value: (Double(job.savedCompactBytes) / Double(job.savedOriginalBytes))
                .formatted(.percent.precision(.fractionLength(0))))
        }
    }

    private var removalSection: some View {
        Section {
            if removable > 0 {
                Button {
                    if settings.removalExplained { Task { await removeOriginals() } } else { sheet = .removalExplanation }
                } label: {
                    Label(removing ?? removeTitle, systemImage: "trash")
                }
                .disabled(removing != nil || job.isRunning)
                .accessibilityIdentifier("remove.originals")
            }
            if let removal { Text(summary(removal)).font(.callout).accessibilityIdentifier("remove.summary") }
            if !settings.trialConfirmed, let removal, !removal.removed.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Check a few compact copies in the \(PhotoLibrary.albumTitle) album. If they look right, "
                         + "Homespun removes the rest next time.")
                        .font(.callout)
                    HStack {
                        Button("Open Photos") { if let url = URL(string: "photos-redirect://") { openURL(url) } }
                            .buttonStyle(.bordered)
                        Button("They look right") { settings.trialConfirmed = true }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("trial.confirm")
                    }
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("Free up space")
        } footer: {
            Text("Each original is checked again against your server and its compact copy first. "
                 + "iOS asks you to confirm, and removed items stay in Recently Deleted for 30 days.")
        }
    }

    private var removeTitle: String {
        let count = settings.trialConfirmed ? removable : min(removable, AppSettings.trialLimit)
        let noun = "original\(count == 1 ? "" : "s")"
        return settings.trialConfirmed || removable <= AppSettings.trialLimit
            ? "Remove \(count) \(noun) from this iPhone"
            : "Remove \(count) \(noun) to try it (of \(removable))"
    }

    @ViewBuilder private var accessPrompt: some View {
        switch access {
        case .notDetermined:
            Button("Allow access to Photos") {
                Task { access = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
            }
        default:
            VStack(alignment: .leading, spacing: 8) {
                Text("Homespun needs Full Access to your photos to read originals and save compact copies.")
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            }
        }
    }

    // MARK: Actions

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
        if settings.isPaired { await settings.refreshServerInfo() }
        await refreshRemovable()
    }

    private func refreshRemovable() async {
        removable = await settings.remover(ledger: job.ledger)?.candidates().count ?? 0
    }

    private func removeOriginals() async {
        guard let remover = settings.remover(ledger: job.ledger) else { return }
        removing = "Checking"
        defer { removing = nil }
        do {
            removal = try await remover.removeEligible(limit: settings.trialConfirmed ? nil : AppSettings.trialLimit) { message in
                Task { @MainActor in removing = message }
            }
        } catch {
            removal = OriginalRemover.Report(blocked: [error.localizedDescription])
        }
        await refreshRemovable()
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
        case .unchanged(let reason):
            Text(reason).foregroundStyle(.secondary)
        case .failed(let reason):
            Text(reason).foregroundStyle(.red)
        }
    }
}

private func bytes(_ count: Int) -> String {
    Int64(count).formatted(.byteCount(style: .file))
}
