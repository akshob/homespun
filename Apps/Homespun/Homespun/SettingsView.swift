// SPDX-License-Identifier: Apache-2.0
import CoreImage.CIFilterBuiltins
import HomespunCore
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    let premium: Premium
    let automatic: AutomaticMode
    let copyFinder: CopyFinder
    let ledger: CompactLedger
    /// In a sheet it has a Done button; as the Server tab it doesn't.
    var showsDone = true
    @Environment(\.dismiss) private var dismiss
    @State private var askExisting = false

    var body: some View {
        NavigationStack {
            Form {
                if let server = settings.server, settings.isPaired {
                    Section("Server") {
                        LabeledContent("Name", value: server.name)
                        LabeledContent("Originals", value: server.mode == .immich ? "In Immich" : "On the server")
                        LabeledContent("Address", value: settings.serverURL.flatMap { url in
                            url.host.map { "\($0):\(url.port ?? 80)" } } ?? "")
                        if let platform = server.platform { LabeledContent("System", value: platform.name) }
                        NavigationLink("Server check") { ServerCheckView(settings: settings) }
                            .accessibilityIdentifier("settings.check")
                        NavigationLink("Originals folder") { OriginalsFolderView(settings: settings) }
                            .accessibilityIdentifier("settings.originals")
                        NavigationLink(server.mode == .immich ? "Immich" : "Connect Immich") {
                            ImmichConnectView(settings: settings)
                        }
                        NavigationLink {
                            if premium.isUnlocked { ConnectorsView(settings: settings) } else { PremiumView(premium: premium) }
                        } label: {
                            premiumLabel("Cloud copies")
                        }
                        .accessibilityIdentifier("settings.connectors")
                        NavigationLink("Add another device") { AddDeviceView(settings: settings) }
                            .accessibilityIdentifier("settings.addDevice")
                        NavigationLink("Find compact copies made elsewhere") {
                            CopyFinderView(finder: copyFinder, settings: settings, ledger: ledger)
                        }
                        .accessibilityIdentifier("settings.findCopies")
                        Button("Unpair", role: .destructive) { settings.unpair() }
                    }
                } else {
                    Section {
                        NavigationLink("Connect a server") { ConnectView(settings: settings) { dismiss() } }
                            .accessibilityIdentifier("settings.connect")
                    } header: {
                        Text("Server")
                    }
                }

                Section {
                    if premium.isUnlocked {
                        Toggle(isOn: Binding(get: { automatic.enabled }, set: { on in
                            if on { askExisting = true } else { automatic.disable() }
                        })) {
                            Text("Automatic mode")
                        }
                        .disabled(!settings.canCompact)
                        .accessibilityIdentifier("automatic.toggle")
                        if automatic.enabled, let lastRun = automatic.state.lastRun {
                            LabeledContent("Last run", value: lastRun.formatted(date: .abbreviated, time: .shortened))
                            if let summary = automatic.state.lastSummary {
                                Text(summary).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        NavigationLink { PremiumView(premium: premium) } label: { premiumLabel("Automatic mode") }
                            .accessibilityIdentifier("automatic.premium")
                    }
                } header: {
                    Text("Automatic mode")
                } footer: {
                    Text("New photos and videos are backed up and compacted on their own, usually overnight while "
                         + "charging, and when you open Homespun. You still choose when to free up space; Homespun "
                         + "tells you when there's space to free.")
                }
                .confirmationDialog("Back up what's already on this iPhone too?", isPresented: $askExisting,
                                    titleVisibility: .visible) {
                    Button("Only new photos and videos") { Task { await automatic.enable(existing: false) } }
                    Button("Everything not backed up yet") { Task { await automatic.enable(existing: true) } }
                        .accessibilityIdentifier("automatic.everything")
                }

                Section {
                    NavigationLink { PremiumView(premium: premium) } label: {
                        LabeledContent("Premium", value: premium.isUnlocked ? "Unlocked" : "Not unlocked")
                    }
                    .accessibilityIdentifier("settings.premium")
                }

                Section {
                    let profile = settings.server?.profile ?? .standard
                    LabeledContent("Photos", value: "JPEG, up to \(profile.photoMaxEdge) px")
                    LabeledContent("Videos", value: "HEVC, up to \(profile.videoShortEdge)p")
                    LabeledContent("Live Photos", value: "Still paired")
                } header: {
                    Text("Compact copies")
                } footer: {
                    switch settings.server?.platform?.os {
                    case .macOS?: Text("Your Mac server makes every compact copy, Live Photos included.")
                    case .linux?: Text("Your server makes the compact copies. Live Photo motion is compressed on this iPhone, "
                                       + "because only Apple's video tools keep it paired with the photo.")
                    case nil: Text("Your server makes the compact copies.")
                    }
                }

                Section {
                    Button("Show the welcome screens again") {
                        settings.onboardingComplete = false
                        dismiss()
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                if showsDone { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            }
        }
    }
}

extension SettingsView {
    /// A settings row for a Premium feature, marked when it isn't unlocked.
    func premiumLabel(_ title: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            if !premium.isUnlocked {
                Text("Premium").font(.caption.weight(.semibold)).foregroundStyle(.tint)
            }
        }
    }
}

/// A one-time code and QR code that pair another iPhone or iPad with this server.
struct AddDeviceView: View {
    let settings: AppSettings
    @State private var link: PairingLink?
    @State private var error: String?

    var body: some View {
        List {
            if let link {
                Section {
                    if let image = Self.qrCode(link.url.absoluteString) {
                        Image(uiImage: image).interpolation(.none).resizable().scaledToFit()
                            .frame(maxWidth: 220).frame(maxWidth: .infinity)
                            .accessibilityLabel("Pairing QR code")
                    }
                } footer: {
                    Text("On the other iPhone or iPad, scan this with the Camera app.")
                }
                Section {
                    LabeledContent("Address", value: link.serverURL.host.map { "\($0):\(link.serverURL.port ?? 8787)" } ?? "")
                    LabeledContent("Code", value: link.code)
                        .accessibilityIdentifier("addDevice.code")
                } header: {
                    Text("Or enter these in Homespun there")
                } footer: {
                    Text("The code works once, for 10 minutes.")
                }
                Section { Button("New code") { Task { await load() } } }
            } else if let error {
                Section {
                    Text(error).foregroundStyle(.red)
                    Button("Try again") { Task { await load() } }
                }
            } else {
                Section { ProgressView().frame(maxWidth: .infinity) }
            }
        }
        .navigationTitle("Add another device")
        .task { await load() }
    }

    private func load() async {
        guard let client = settings.client, let url = settings.serverURL else { return }
        do {
            let code = try await client.newPairingCode()
            link = PairingLink(serverURL: url, code: code.code, name: settings.server?.name)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    static func qrCode(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let image = filter.outputImage,
              let cgImage = CIContext().createCGImage(image, from: image.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
