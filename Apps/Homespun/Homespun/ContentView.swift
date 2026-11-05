// SPDX-License-Identifier: Apache-2.0
import HomespunCore
import Photos
import PhotosUI
import SwiftUI

struct ContentView: View {
    @State private var settings: AppSettings
    @State private var job: CompactJob
    @State private var showSettings = false
    @State private var removable = 0
    @State private var removing: String?
    @State private var removal: OriginalRemover.Report?

    init() {
        let settings = AppSettings()
        _settings = State(initialValue: settings)
        _job = State(initialValue: CompactJob(settings: settings))
    }

    @State private var selection: [PhotosPickerItem] = []
    @State private var access = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    private let profile = CompressionProfile.standard

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if access == .authorized {
                        PhotosPicker(selection: $selection, matching: .any(of: [.images, .videos, .livePhotos]),
                                     preferredItemEncoding: .current, photoLibrary: .shared()) {
                            Label("Choose photos and videos", systemImage: "photo.stack")
                        }
                    } else {
                        accessPrompt
                    }
                } header: {
                    Text(settings.usesServer ? "With \(settings.server?.name ?? "your server")" : "On this iPhone")
                } footer: {
                    Text(settings.usesServer
                         ? "Originals go to your server (or are found in Immich); compact copies are saved to the "
                           + "\(PhotoLibrary.albumTitle) album. Keep Homespun open while it works."
                         : "Compact copies are saved to the \(PhotoLibrary.albumTitle) album. "
                           + "Originals are not changed or deleted. Keep Homespun open while it works.")
                }

                if !job.items.isEmpty {
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

                if job.savedOriginalBytes > 0 {
                    Section("Saved this session") {
                        LabeledContent("Originals", value: bytes(job.savedOriginalBytes))
                        LabeledContent("Compact copies", value: bytes(job.savedCompactBytes))
                        LabeledContent("Ratio", value: (Double(job.savedCompactBytes) / Double(job.savedOriginalBytes))
                            .formatted(.percent.precision(.fractionLength(0))))
                    }
                }

                if settings.isPaired, removable > 0 || removal != nil {
                    Section {
                        if removable > 0 {
                            Button {
                                Task { await removeOriginals() }
                            } label: {
                                Label(removing ?? "Remove \(removable) original\(removable == 1 ? "" : "s") from this iPhone",
                                      systemImage: "trash")
                            }
                            .disabled(removing != nil || job.isRunning)
                            .accessibilityIdentifier("remove.originals")
                        }
                        if let removal { Text(summary(removal)).font(.callout).accessibilityIdentifier("remove.summary") }
                    } header: {
                        Text("Free up space")
                    } footer: {
                        Text("Each original is checked again against your server and its compact copy first. "
                             + "iOS asks you to confirm, and removed items stay in Recently Deleted.")
                    }
                }

                Section("Compact copies") {
                    LabeledContent("Photos", value: "JPEG, up to \(profile.photoMaxEdge) px")
                    LabeledContent("Videos", value: "HEVC, up to \(profile.videoShortEdge)p")
                    LabeledContent("Live Photos", value: "Motion re-encoded, still paired")
                }
            }
            .navigationTitle("Homespun")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                        .accessibilityIdentifier("settings")
                }
            }
            .sheet(isPresented: $showSettings, onDismiss: { Task { await refreshRemovable() } }) {
                SettingsView(settings: settings)
            }
            .onChange(of: job.isRunning) { _, running in
                if !running { Task { await refreshRemovable() } }
            }
            .onChange(of: selection) { _, items in
                let identifiers = items.compactMap(\.itemIdentifier)
                selection = []
                if !identifiers.isEmpty { job.enqueue(identifiers) }
            }
            .onChange(of: scenePhase) { _, phase in
                // Access may have changed in Settings.
                if phase == .active { access = PHPhotoLibrary.authorizationStatus(for: .readWrite) }
            }
            .task {
                if access == .notDetermined {
                    access = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
                }
                await refreshRemovable()
            }
        }
    }

    private func refreshRemovable() async {
        removable = await settings.remover(ledger: job.ledger)?.candidates().count ?? 0
    }

    private func removeOriginals() async {
        guard let remover = settings.remover(ledger: job.ledger) else { return }
        removing = "Checking"
        defer { removing = nil }
        do {
            removal = try await remover.removeEligible { message in
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

    @ViewBuilder private var accessPrompt: some View {
        switch access {
        case .notDetermined:
            Button("Allow access to Photos") {
                Task { access = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
            }
        default:
            VStack(alignment: .leading, spacing: 8) {
                Text("Homespun needs access to all photos to read originals and save compact copies.")
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            }
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
