// SPDX-License-Identifier: Apache-2.0
import HomespunCore
import SwiftUI
import UIKit

/// Where every device's originals are on the server, and moving them all somewhere else
/// (DESIGN 04·5.1–5.6). The page follows a move every 2 seconds while it runs.
struct OriginalsFolderView: View {
    let settings: AppSettings
    @State private var info: ServerAPI.StorageInfo?
    @State private var devices: [ServerAPI.DeviceInfo] = []
    @State private var error: String?
    @State private var moveStarted: Date?

    private var server: String { settings.server?.name ?? "the server" }

    var body: some View {
        List {
            if let info {
                if let move = info.move, MoveCard.shows(move) {
                    Section {
                        MoveCard(move: move, started: moveStarted)
                    }
                    .listRowBackground(move.state == .failed ? Color.clear : Theme.card)
                    .listRowInsets(move.state == .failed ? EdgeInsets() : nil)
                }
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: "iphone").font(.title3).foregroundStyle(Theme.accent).frame(width: 28)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(UIDevice.current.name).foregroundStyle(Theme.label)
                            if let folder = info.deviceFolder {
                                Text(folder).font(.system(.footnote, design: .monospaced).weight(.medium))
                                    .foregroundStyle(Theme.secondaryLabel).textSelection(.enabled)
                                    .accessibilityLabel("Folder \((folder as NSString).lastPathComponent), \(folder)")
                                    .accessibilityIdentifier("originals.deviceFolder")
                            }
                        }
                    }
                    .padding(.vertical, 2)
                } header: {
                    Text("This iPhone's originals")
                } footer: {
                    Text("A folder named after this iPhone, by month (\(Self.monthFolder)).")
                }
                .listRowBackground(Theme.card)
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: "folder").font(.title3).foregroundStyle(Theme.accent).frame(width: 28)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(info.originalsFolder).font(.system(.subheadline, design: .monospaced).weight(.semibold))
                                .foregroundStyle(Theme.label).textSelection(.enabled)
                                .accessibilityLabel("Folder \((info.originalsFolder as NSString).lastPathComponent), "
                                                    + info.originalsFolder)
                                .accessibilityIdentifier("originals.folder")
                            Text(folderDetail(info)).font(.subheadline).foregroundStyle(Theme.secondaryLabel)
                        }
                    }
                    .padding(.vertical, 2)
                    ForEach(devices.filter { !$0.isThisDevice }) { device in
                        HStack(spacing: 14) {
                            Image(systemName: device.name.localizedCaseInsensitiveContains("ipad") ? "ipad" : "iphone")
                                .font(.title3).foregroundStyle(Theme.accent).frame(width: 28).accessibilityHidden(true)
                            Text(device.name).foregroundStyle(Theme.label)
                        }
                    }
                    NavigationLink {
                        ChooseOriginalsFolderView(settings: settings, info: info) {
                            self.info = $0
                            moveStarted = Date()
                        }
                    } label: {
                        Text("Change Folder…").foregroundStyle(moving ? Theme.tertiaryLabel : Theme.accent)
                    }
                    .disabled(moving)
                    .accessibilityHint(moving ? "Not while the originals are moving." : "")
                    .accessibilityIdentifier("originals.change")
                } header: {
                    Text("Originals folder on \(server)")
                } footer: {
                    Text("Every device's originals are here, each in its own folder. Originals brought in from an "
                         + "existing library stay where they are and aren't moved.")
                }
                .listRowBackground(Theme.card)
            } else if let error {
                Section {
                    InlineNotice(tone: .error, title: "Couldn't read the originals folder", message: error)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            } else {
                Section { ProgressView().frame(maxWidth: .infinity) }.listRowBackground(Color.clear)
            }
        }
        .homespunList()
        .navigationTitle("Originals Folder")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            devices = (try? await settings.client?.devices()) ?? []
            // Follow a move while it runs.
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(moving ? 2 : 30))
            }
        }
        .onChange(of: info?.move?.state) { old, new in
            switch new {
            case .copying?: if old == nil { Announce.say("Moving the originals.") }
            case .done?: if old != nil { Announce.say("Moved \(info?.move?.copied ?? 0) originals.") }
            case .failed?: Announce.say("The move stopped. Nothing has changed.")
            default: break
            }
        }
    }

    private var moving: Bool { info?.move.map { [.copying, .finishing].contains($0.state) } ?? false }

    /// "9,977 originals · 214 GB · 1.7 TB free of 4 TB".
    private func folderDetail(_ info: ServerAPI.StorageInfo) -> String {
        var parts = ["\(info.storedCount.formatted()) originals · \(Self.bytes(info.storedBytes))"]
        if let free = info.freeBytes {
            parts.append("\(Self.bytes(free)) free" + (info.capacityBytes.map { " of \(Self.bytes($0))" } ?? ""))
        }
        return parts.joined(separator: " · ")
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

    static var monthFolder: String {
        let parts = Calendar.current.dateComponents([.year, .month], from: Date())
        return String(format: "%d/%02d", parts.year ?? 0, parts.month ?? 0)
    }

    static func bytes(_ count: Int64) -> String { count.formatted(.byteCount(style: .file)) }
}

/// The move: progress while copying, the receipt when done (for a day), or why it stopped.
private struct MoveCard: View {
    let move: ServerAPI.MoveStatus
    /// When this page started it, for the time left.
    let started: Date?

    static func shows(_ move: ServerAPI.MoveStatus) -> Bool {
        guard move.state == .done else { return true }
        return (move.finishedAt ?? .distantPast) > Date().addingTimeInterval(-86_400)
    }

    var body: some View {
        Group {
            switch move.state {
            case .copying, .finishing:
                VStack(alignment: .leading, spacing: 10) {
                    Text(move.state == .finishing ? "Finishing the move to \(move.to)" : "Moving to \(move.to)")
                        .font(.headline).foregroundStyle(Theme.label)
                    ProgressView(value: Double(move.copiedBytes), total: Double(max(move.totalBytes, 1)))
                        .tint(Theme.accent)
                    HStack {
                        Text("\(move.copied.formatted()) of \(move.total.formatted()) · "
                             + "\(OriginalsFolderView.bytes(move.copiedBytes)) of \(OriginalsFolderView.bytes(move.totalBytes))")
                        Spacer(minLength: 8)
                        if let left = timeLeft { Text(left) }
                    }
                    .font(.subheadline).foregroundStyle(Theme.label)
                    Text("Backups keep working. They pause for a moment when the move finishes.")
                        .font(.footnote).foregroundStyle(Theme.secondaryLabel)
                }
                .padding(.vertical, 6)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Moving, \(move.copied.formatted()) of \(move.total.formatted()) originals")
            case .done:
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(Theme.teal)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Moved \(move.copied.formatted()) originals").font(.headline).foregroundStyle(Theme.label)
                        Text("from \(move.from), each checked. The old copies were removed.")
                            .font(.subheadline).foregroundStyle(Theme.secondaryLabel)
                    }
                }
                .padding(.vertical, 6)
                .accessibilityElement(children: .combine)
            case .failed:
                InlineNotice(tone: .warning, title: "The move stopped",
                             message: (move.message.map { "\($0). " } ?? "")
                                + "Nothing has changed: every original is still in \(move.from).")
            }
        }
        .accessibilityIdentifier("originals.move")
    }

    private var timeLeft: String? {
        guard let started, move.copiedBytes > 0, move.totalBytes > move.copiedBytes else { return nil }
        let elapsed = Date().timeIntervalSince(started)
        let left = elapsed / Double(move.copiedBytes) * Double(move.totalBytes - move.copiedBytes)
        return "About " + Duration.seconds(max(left, 60)).formatted(
            .units(allowed: [.hours, .minutes], width: .abbreviated, maximumUnitCount: 2))
    }
}

/// Picks a disk or folder on the server (or types one) and moves the originals there (5.2–5.3).
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

    private var server: String { settings.server?.name ?? "the server" }

    var body: some View {
        List {
            Section("On \(server)") {
                ForEach(locations) { location in
                    Button { confirming = location.path } label: {
                        HStack(spacing: 14) {
                            Image(systemName: location.path.hasPrefix("/Volumes/") || location.path.hasPrefix("/mnt/")
                                  || location.path.hasPrefix("/media/") ? "externaldrive" : "folder")
                                .font(.title3).foregroundStyle(Theme.accent).frame(width: 28).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(location.name).foregroundStyle(Theme.label)
                                Text([location.path, location.freeBytes.map { "\(OriginalsFolderView.bytes($0)) free" }]
                                        .compactMap { $0 }.joined(separator: " · "))
                                    .font(.subheadline).foregroundStyle(Theme.secondaryLabel)
                            }
                            Spacer(minLength: 8)
                            if location.isCurrent {
                                Text("Current").foregroundStyle(Theme.secondaryLabel)
                            } else {
                                Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                                    .foregroundStyle(Theme.tertiaryLabel).accessibilityHidden(true)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .allowsHitTesting(!location.isCurrent)
                    .accessibilityElement(children: .combine)
                }
            }
            .listRowBackground(Theme.card)
            Section {
                TextField("/Volumes/Photos/Homespun", text: $path)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                    .accessibilityLabel("Folder path on \(server)")
                    .accessibilityIdentifier("originals.path")
                Button { confirming = path } label: {
                    BusyLabel(title: "Move Here", busy: working)
                }
                .tint(Theme.accent)
                .disabled(path.isEmpty || working)
                .accessibilityIdentifier("originals.moveHere")
                if let error {
                    Text(error).font(.subheadline).foregroundStyle(Theme.red).accessibilityIdentifier("originals.error")
                }
            } header: {
                Text("Another folder")
            } footer: {
                Text("A full path on \(server). Its parent folder must exist.")
            }
            .listRowBackground(Theme.card)
        }
        .homespunList()
        .navigationTitle("Change Folder")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            locations = (try? await settings.client?.storageLocations()) ?? []
        }
        .alert("Move \(info.storedCount.formatted()) originals to \(target)?", isPresented: Binding(
            get: { confirming != nil }, set: { if !$0 { confirming = nil } })) {
            Button("Cancel", role: .cancel) {}
            Button("Move") { if let target = confirming { Task { await move(to: target) } } }
                .accessibilityIdentifier("originals.confirmMove")
        } message: {
            Text("\(OriginalsFolderView.bytes(info.storedBytes)). \(server) copies and checks each one, then removes "
                 + "the old copies. Backups pause for a moment at the end.")
        }
    }

    private var target: String {
        guard let confirming else { return "" }
        return locations.first { $0.path == confirming }?.name ?? (confirming as NSString).lastPathComponent
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
