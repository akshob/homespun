// SPDX-License-Identifier: Apache-2.0
import HomespunCore
import SwiftUI

/// The server's connectors: places it copies originals to, such as OneDrive.
struct ConnectorsView: View {
    let settings: AppSettings
    @State private var connectors: [ServerAPI.ConnectorInfo]?
    @State private var error: String?

    var body: some View {
        List {
            Section {
                Text("Your server can also copy each original somewhere else, as an extra backup. Removing originals "
                     + "from this iPhone still depends only on your server's own copy.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let connectors {
                if connectors.isEmpty {
                    Text("This server has no connectors yet. Update Homespun Server to get them.").foregroundStyle(.secondary)
                }
                ForEach(connectors) { connector in
                    NavigationLink {
                        ConnectorDetailView(settings: settings, connector: connector) { updated in replace(updated) }
                    } label: {
                        ConnectorRow(connector: connector)
                    }
                    .accessibilityIdentifier("connector.\(connector.id)")
                }
            } else if let error {
                Text(error).foregroundStyle(.red)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Cloud copies")
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        guard let client = settings.client else { return }
        do {
            connectors = try await client.connectors()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func replace(_ updated: ServerAPI.ConnectorInfo?) {
        Task { await load() }
    }
}

private struct ConnectorRow: View {
    let connector: ServerAPI.ConnectorInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(connector.name).font(.headline)
                Spacer()
                Text(connector.enabled ? "On" : "Off").font(.caption).foregroundStyle(connector.enabled ? .green : .secondary)
            }
            Text(connector.enabled ? countsText(connector.counts) : connector.summary)
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            if connector.enabled, let message = connector.message {
                Text(message).font(.caption).foregroundStyle(.orange).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

private func countsText(_ counts: ServerAPI.ConnectorCounts) -> String {
    var parts = ["\(counts.copied) copied"]
    if counts.pending > 0 { parts.append("\(counts.pending) waiting") }
    if counts.failed > 0 { parts.append("\(counts.failed) failed") }
    return parts.joined(separator: " · ")
}

/// One connector: its settings, sign-in, and turning it on or off.
struct ConnectorDetailView: View {
    let settings: AppSettings
    @State var connector: ServerAPI.ConnectorInfo
    var changed: (ServerAPI.ConnectorInfo?) -> Void
    @State private var values: [String: String] = [:]
    @State private var copyExisting = false
    @State private var working = false
    @State private var error: String?
    @State private var signingIn = false
    @Environment(\.dismiss) private var dismiss

    init(settings: AppSettings, connector: ServerAPI.ConnectorInfo, changed: @escaping (ServerAPI.ConnectorInfo?) -> Void) {
        self.settings = settings
        _connector = State(initialValue: connector)
        self.changed = changed
        _values = State(initialValue: Dictionary(uniqueKeysWithValues: connector.fields.map {
            ($0.key, $0.kind == .secret ? "" : ($0.value ?? ""))
        }))
    }

    var body: some View {
        Form {
            Section {
                Text(connector.summary).font(.callout)
                if connector.enabled {
                    LabeledContent("Copies", value: countsText(connector.counts))
                }
                if let message = connector.message {
                    Text(message).font(.callout).foregroundStyle(.orange).accessibilityIdentifier("connector.message")
                }
            }
            if connector.signsIn {
                Section("Account") {
                    if let account = connector.account {
                        LabeledContent("Signed in as", value: account)
                    }
                    Button(connector.account == nil ? "Sign in" : "Sign in again") { signingIn = true }
                        .accessibilityIdentifier("connector.signIn")
                }
            }
            if !connector.fields.isEmpty {
                Section("Settings") {
                    ForEach(connector.fields, id: \.key) { field in fieldEditor(field) }
                }
            }
            Section {
                Toggle("Also copy originals already on the server", isOn: $copyExisting)
                    .accessibilityIdentifier("connector.copyExisting")
                Button {
                    Task { await save(enable: true) }
                } label: {
                    if working { ProgressView() } else { Text(connector.enabled ? "Save" : "Turn on") }
                }
                .disabled(working || (connector.signsIn && connector.account == nil))
                .accessibilityIdentifier("connector.save")
                if connector.enabled {
                    Button("Turn off") { Task { await save(enable: false) } }.disabled(working)
                }
            } footer: {
                if connector.signsIn && connector.account == nil { Text("Sign in first.") }
            }
            if let error {
                Section { Text(error).foregroundStyle(.red).accessibilityIdentifier("connector.error") }
            }
            if connector.enabled || connector.account != nil || connector.fields.contains(where: \.isSet) {
                Section {
                    Button("Remove and sign out", role: .destructive) { Task { await remove() } }
                } footer: {
                    Text("Copies already made stay where they are.")
                }
            }
        }
        .navigationTitle(connector.name)
        .sheet(isPresented: $signingIn) {
            ConnectorSignInView(settings: settings, connector: connector) { account in
                connector.account = account
                changed(connector)
            }
        }
    }

    @ViewBuilder private func fieldEditor(_ field: ServerAPI.ConnectorField) -> some View {
        let binding = Binding(get: { values[field.key] ?? "" }, set: { values[field.key] = $0 })
        Group {
            switch field.kind {
            case .text:
                TextField(field.label, text: binding, prompt: field.placeholder.map { Text($0) })
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            case .secret:
                SecureField(field.label, text: binding,
                            prompt: Text(field.isSet ? "Saved (leave empty to keep)" : field.placeholder ?? field.label))
            case .toggle:
                Toggle(field.label, isOn: Binding(get: { binding.wrappedValue == "true" },
                                                  set: { binding.wrappedValue = $0 ? "true" : "false" }))
            case .choice:
                Picker(field.label, selection: binding) {
                    ForEach(field.choices ?? [], id: \.self) { Text($0).tag($0) }
                }
            }
        }
        .accessibilityIdentifier("connector.field.\(field.key)")
        if let help = field.help {
            Text(help).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func save(enable: Bool) async {
        guard let client = settings.client else { return }
        working = true
        defer { working = false }
        do {
            connector = try await client.updateConnector(connector.id, .init(
                enabled: enable, settings: enable ? values : nil, copyExisting: enable && copyExisting ? true : nil))
            error = nil
            copyExisting = false
            changed(connector)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func remove() async {
        guard let client = settings.client else { return }
        do {
            try await client.removeConnector(connector.id)
            changed(nil)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Signs the server in to a service: shows a code to enter on the service's web page and
/// waits until the server has signed in.
struct ConnectorSignInView: View {
    let settings: AppSettings
    let connector: ServerAPI.ConnectorInfo
    var signedIn: (String?) -> Void
    @State private var challenge: ServerAPI.ConnectorSignIn?
    @State private var error: String?
    @State private var copied = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                if let challenge {
                    Text(challenge.message ?? "Open the page below, sign in, and enter this code.")
                        .multilineTextAlignment(.center)
                    Text(challenge.userCode)
                        .font(.system(size: 34, weight: .semibold, design: .monospaced))
                        .textSelection(.enabled)
                        .accessibilityIdentifier("signIn.code")
                    Button(copied ? "Copied" : "Copy code") {
                        UIPasteboard.general.string = challenge.userCode
                        copied = true
                    }
                    .buttonStyle(.bordered)
                    if let url = URL(string: challenge.url) {
                        Button("Open \(url.host ?? challenge.url)") { openURL(url) }
                            .buttonStyle(.borderedProminent)
                    }
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Waiting for you to sign in…").foregroundStyle(.secondary)
                    }
                } else if let error {
                    Text(error).foregroundStyle(.red).multilineTextAlignment(.center)
                } else {
                    ProgressView()
                }
                Spacer()
            }
            .padding(24)
            .navigationTitle("Sign in to \(connector.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .task { await run() }
    }

    private func run() async {
        guard let client = settings.client else { return }
        do {
            let challenge = try await client.beginConnectorSignIn(connector.id)
            self.challenge = challenge
            let deadline = Date().addingTimeInterval(TimeInterval(challenge.expiresIn))
            while !Task.isCancelled, Date() < deadline {
                try await Task.sleep(for: .seconds(3))
                let status = try await client.connectorSignInStatus(connector.id)
                switch status.state {
                case .waiting: continue
                case .done:
                    signedIn(status.account)
                    dismiss()
                    return
                case .failed:
                    self.challenge = nil
                    error = status.message ?? "Signing in didn't work. Try again."
                    return
                }
            }
            if !Task.isCancelled {
                self.challenge = nil
                error = "The code expired. Try again."
            }
        } catch is CancellationError {
        } catch {
            self.challenge = nil
            self.error = error.localizedDescription
        }
    }
}
