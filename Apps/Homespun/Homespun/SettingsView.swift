// SPDX-License-Identifier: Apache-2.0
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
