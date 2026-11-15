// SPDX-License-Identifier: Apache-2.0
import HomespunCore
import SwiftUI

/// Where this iPhone's originals are kept on the server, and moving them all somewhere else.
struct OriginalsFolderView: View {
    let settings: AppSettings
    @State private var info: ServerAPI.StorageInfo?
    @State private var error: String?

    private var server: String { settings.server?.name ?? "the server" }

    var body: some View {
        Form {
            if let info {
                Section {
                    if let folder = info.deviceFolder {
                        Text(folder).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                            .accessibilityIdentifier("originals.deviceFolder")
                    }
                    if let free = info.freeBytes {
                        LabeledContent("Free space", value: Self.bytes(free)
                                       + (info.capacityBytes.map { " of \(Self.bytes($0))" } ?? ""))
                    }
                } header: {
                    Text("This iPhone's originals")
                } footer: {
                    Text("On \(server), in a folder named after this iPhone, by month.")
                }

                Section {
                    Text(info.originalsFolder).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        .accessibilityIdentifier("originals.folder")
                    LabeledContent("Originals", value: "\(info.storedCount.formatted()) · \(Self.bytes(info.storedBytes))")
                    if let move = info.move { MoveRow(move: move) }
                    NavigationLink("Change folder") {
                        ChooseOriginalsFolderView(settings: settings, info: info) { self.info = $0 }
                    }
                    .disabled(info.move.map { [.copying, .finishing].contains($0.state) } ?? false)
                    .accessibilityIdentifier("originals.change")
                } header: {
                    Text("Originals folder on \(server)")
                } footer: {
                    Text("Every device's originals are in this folder, each in its own folder. Originals imported "
                         + "from elsewhere and left where they were aren't counted or moved.")
                }
            } else if let error {
                Text(error).foregroundStyle(.red)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Originals folder")
        .task {
            // Follow a move while it runs.
            while !Task.isCancelled {
                await load()
                let moving = info?.move.map { [.copying, .finishing].contains($0.state) } ?? false
                try? await Task.sleep(for: .seconds(moving ? 2 : 30))
            }
        }
    }

    private func load() async {
        guard let client = settings.client else { return }
        do {
            info = try await client.storage()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    static func bytes(_ count: Int64) -> String { count.formatted(.byteCount(style: .file)) }
}

private struct MoveRow: View {
    let move: ServerAPI.MoveStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch move.state {
            case .copying, .finishing:
                ProgressView(value: Double(move.copiedBytes), total: Double(max(move.totalBytes, 1))) {
                    Text(move.state == .finishing ? "Finishing the move" : "Moving to \(move.to)")
                } currentValueLabel: {
                    Text("\(move.copied.formatted()) of \(move.total.formatted()) · "
                         + "\(OriginalsFolderView.bytes(move.copiedBytes)) of \(OriginalsFolderView.bytes(move.totalBytes))")
                }
            case .done:
                Label("Moved \(move.copied.formatted()) originals from \(move.from)", systemImage: "checkmark.circle")
            case .failed:
                Label("The move stopped: \(move.message ?? "unknown error"). The originals stay in \(move.from).",
                      systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("originals.move")
    }
}

/// Picks a folder on the server's disks (or types one) and starts moving the originals there.
struct ChooseOriginalsFolderView: View {
    let settings: AppSettings
    let info: ServerAPI.StorageInfo
    var moved: (ServerAPI.StorageInfo) -> Void
    @State private var locations: [ServerAPI.StorageLocation] = []
    @State private var path = ""
    @State private var confirming: String?
    @State private var working = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                ForEach(locations) { location in
                    Button { confirming = location.path } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(location.name)
                                if location.isCurrent { Text("Current").font(.caption).foregroundStyle(.secondary) }
                            }
                            Text(location.path).font(.caption.monospaced()).foregroundStyle(.secondary)
                            if let free = location.freeBytes {
                                Text("\(OriginalsFolderView.bytes(free)) free").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(location.isCurrent)
                }
            } header: {
                Text("On \(settings.server?.name ?? "the server")")
            }
            Section {
                TextField("/Volumes/Photos/Homespun", text: $path)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                    .accessibilityIdentifier("originals.path")
                Button("Move here") { confirming = path }
                    .disabled(path.isEmpty)
                    .accessibilityIdentifier("originals.moveHere")
            } header: {
                Text("Another folder")
            } footer: {
                Text("A full path on the server. Its parent folder must exist.")
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }
        .navigationTitle("Change folder")
        .disabled(working)
        .task {
            locations = (try? await settings.client?.storageLocations()) ?? []
        }
        .alert("Move \(info.storedCount.formatted()) originals?", isPresented: Binding(
            get: { confirming != nil }, set: { if !$0 { confirming = nil } })) {
            Button("Move") { if let target = confirming { Task { await move(to: target) } } }
                .accessibilityIdentifier("originals.confirmMove")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(OriginalsFolderView.bytes(info.storedBytes)) to \(confirming ?? ""). The server copies and checks each "
                 + "one, then removes the old copies. New backups pause for a moment at the end.")
        }
    }

    private func move(to target: String) async {
        guard let client = settings.client else { return }
        working = true
        defer { working = false }
        do {
            moved(try await client.moveOriginals(to: target))
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
