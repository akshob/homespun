// SPDX-License-Identifier: Apache-2.0
import HomespunCore
import SwiftUI

/// The server's self-check: what works and what to install. "Check again" after fixing.
struct ServerCheckView: View {
    @Bindable var settings: AppSettings
    var onContinue: (() -> Void)?
    @State private var report: ServerSetup.Report?
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        List {
            Section {
                if let server = settings.server {
                    LabeledContent(server.name, value: report?.platform.name ?? server.platform?.name ?? "")
                        .accessibilityIdentifier("check.server")
                }
                if let report {
                    Label(report.ready ? "Ready to use" : "Needs attention",
                          systemImage: report.ready ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(report.ready ? .green : .orange)
                        .accessibilityIdentifier(report.ready ? "check.ready" : "check.attention")
                } else if let error {
                    Text(error).foregroundStyle(.red)
                } else {
                    HStack { ProgressView(); Text("Checking the server…") }
                }
            }

            if let report {
                ForEach(report.checks) { check in
                    Section {
                        HStack(alignment: .firstTextBaseline) {
                            icon(check.status)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(check.title).font(.headline)
                                Text(check.detail).font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("check.\(check.id).\(check.status.rawValue)")
                        ForEach(check.fix, id: \.self) { CommandRow(command: $0) }
                        if check.id == "immich" {
                            NavigationLink(settings.server?.mode == .immich ? "Immich settings" : "Connect Immich") {
                                ImmichConnectView(settings: settings)
                            }
                            .accessibilityIdentifier("check.immich.open")
                        }
                    }
                }
            }

            Section {
                Button {
                    Task { await load() }
                } label: {
                    Label("Check again", systemImage: "arrow.clockwise")
                }
                .disabled(loading)
                .accessibilityIdentifier("check.again")
            } footer: {
                Text("After installing something on the server, come back and check again.")
            }
        }
        .navigationTitle("Server check")
        .safeAreaInset(edge: .bottom) {
            if let onContinue {
                Button(action: onContinue) { Text("Continue").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .padding(.horizontal, 24).padding(.vertical, 12)
                    .background(.bar)
                    .accessibilityIdentifier("onboarding.continue")
            }
        }
        .task { await load() }
    }

    private func icon(_ status: ServerSetup.CheckStatus) -> some View {
        switch status {
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .problem: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .info: Image(systemName: "info.circle.fill").foregroundStyle(.blue)
        }
    }

    private func load() async {
        guard let client = settings.client else { return }
        loading = true
        defer { loading = false }
        do {
            report = try await client.setup()
            error = nil
            await settings.refreshServerInfo()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Connects the server to Immich: the server tests the address and key, then keeps the key.
struct ImmichConnectView: View {
    @Bindable var settings: AppSettings
    @State private var current: ServerAPI.ImmichSettings?
    @State private var url = ""
    @State private var key = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        Form {
            if let current, current.connected || current.url != nil {
                Section("Connected") {
                    LabeledContent("Immich", value: current.url ?? "")
                    LabeledContent("API key", value: "…" + (current.keyHint ?? ""))
                    Label(current.connected ? "Working" : (current.message ?? "Not reachable"),
                          systemImage: current.connected ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(current.connected ? .green : .red)
                    if current.connected, let message = current.message {
                        Text(message).font(.callout).foregroundStyle(.orange)
                    }
                    Button("Disconnect Immich", role: .destructive) { Task { await disconnect() } }
                        .disabled(working)
                }
            }

            Section {
                TextField("Immich address, e.g. http://192.168.1.20:2283", text: $url)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    .accessibilityIdentifier("immich.url")
                SecureField("API key", text: $key)
                    .accessibilityIdentifier("immich.key")
                Button {
                    Task { await connect() }
                } label: {
                    if working { ProgressView() } else { Text(current?.connected == true ? "Replace" : "Connect") }
                }
                .disabled(url.isEmpty || key.isEmpty || working)
                .accessibilityIdentifier("immich.connect")
                if let error { Text(error).foregroundStyle(.red).font(.callout) }
            } header: {
                Text(current?.connected == true ? "Use a different Immich" : "Connect Immich")
            } footer: {
                Text("In Immich, open Account Settings › API Keys › New API Key, and allow only asset.read and "
                     + "asset.download. Homespun never changes or deletes anything in Immich.\n\n"
                     + "Then, in the Immich app, exclude the Homespun album from backup so compact copies aren't uploaded.")
            }
        }
        .navigationTitle("Immich")
        .task { current = try? await settings.client?.immichSettings() }
    }

    private func connect() async {
        guard let client = settings.client else { return }
        working = true
        defer { working = false }
        do {
            current = try await client.connectImmich(url: url, apiKey: key)
            key = ""
            error = nil
            await settings.refreshServerInfo()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func disconnect() async {
        guard let client = settings.client else { return }
        working = true
        defer { working = false }
        current = try? await client.disconnectImmich()
        await settings.refreshServerInfo()
    }
}
