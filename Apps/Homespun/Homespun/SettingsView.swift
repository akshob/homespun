// SPDX-License-Identifier: Apache-2.0
import CoreImage.CIFilterBuiltins
import HomespunCore
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

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
                        NavigationLink(server.mode == .immich ? "Immich" : "Connect Immich") {
                            ImmichConnectView(settings: settings)
                        }
                        NavigationLink("Add another device") { AddDeviceView(settings: settings) }
                            .accessibilityIdentifier("settings.addDevice")
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
                    Picker("Make compact copies", selection: $settings.mode) {
                        Text("On my server").tag(AppSettings.Mode?.some(.server))
                        Text("On this iPhone").tag(AppSettings.Mode?.some(.device))
                        if settings.mode == nil { Text("Not set up").tag(AppSettings.Mode?.none) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .accessibilityIdentifier("mode.picker")
                } header: {
                    Text("Make compact copies")
                } footer: {
                    Text(settings.mode == .device
                         ? "On this iPhone, Homespun only adds compact copies; it removes nothing, because there is no "
                           + "verified copy of the original elsewhere."
                         : "With a server, originals are kept there and can be removed from this iPhone once verified.")
                }

                Section("Compact copies") {
                    let profile = settings.server?.profile ?? .standard
                    LabeledContent("Photos", value: "JPEG, up to \(profile.photoMaxEdge) px")
                    LabeledContent("Videos", value: "HEVC, up to \(profile.videoShortEdge)p")
                    LabeledContent("Live Photos", value: "Motion re-encoded, still paired")
                }

                Section {
                    Button("Show the welcome screens again") {
                        settings.onboardingComplete = false
                        dismiss()
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onChange(of: settings.mode) { _, mode in
                if mode == .server, !settings.isPaired { settings.mode = nil }
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
