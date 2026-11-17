// SPDX-License-Identifier: Apache-2.0
import HomespunCore
import SwiftUI

/// The server's connectors: places it copies originals to, such as OneDrive (DESIGN 05·3.1).
struct ConnectorsView: View {
    let settings: AppSettings
    @State private var connectors: [ServerAPI.ConnectorInfo]?
    @State private var error: String?

    private var server: String { settings.server?.name ?? "Your server" }

    var body: some View {
        List {
            Section {
            } header: {
                Text("\(server) also copies each original to another place, as an extra backup. Freeing up space on "
                     + "this iPhone still depends only on \(server)'s own copy.")
                    .font(.body).foregroundStyle(Theme.label).textCase(nil)
            }
            if let connectors {
                let on = connectors.filter(\.enabled), off = connectors.filter { !$0.enabled }
                if connectors.isEmpty {
                    Section {
                        InlineNotice(tone: .info, title: "This server has no connectors yet",
                                     message: "Update Homespun Server to get them.")
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                if !on.isEmpty {
                    Section("On") { ForEach(on) { link($0) } }.listRowBackground(Theme.card)
                }
                Section("More services") {
                    ForEach(off) { link($0) }
                    ForEach(Self.later.filter { name in !connectors.contains { $0.name == name.0 } }, id: \.0) { later in
                        ConnectorRow(name: later.0, symbol: later.1, detail: "Coming later", tile: Theme.tertiaryLabel)
                            .opacity(0.7)
                    }
                    Link(destination: URL(string: "https://homespun.photos")!) {
                        ConnectorRow(name: "Your own connector", symbol: "externaldrive",
                                     detail: "For developers: see homespun.photos", tile: Theme.tertiaryLabel)
                    }
                }
                .listRowBackground(Theme.card)
            } else if let error {
                Section {
                    InlineNotice(tone: .error, title: "Couldn't load cloud copies", message: error) {
                        Button("Try Again") { Task { await load() } }.tint(Theme.accent)
                    }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            } else {
                Section { ProgressView().frame(maxWidth: .infinity) }.listRowBackground(Color.clear)
            }
        }
        .homespunList()
        .navigationTitle("Cloud Copies")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private static let later = [("Google Photos", "photo"), ("Amazon Photos", "shippingbox")]

    private func link(_ connector: ServerAPI.ConnectorInfo) -> some View {
        NavigationLink {
            ConnectorDetailView(settings: settings, connector: connector) { _ in Task { await load() } }
        } label: {
            ConnectorRow(name: connector.name, symbol: connector.name.contains("Drive") ? "cloud" : "icloud",
                         detail: connector.enabled ? "On · " + countsText(connector.counts) : connector.summary,
                         tile: connector.enabled ? Theme.blue : Theme.secondaryLabel, message: connector.message)
        }
        .accessibilityIdentifier("connector.\(connector.id)")
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
}

/// A service: a neutral glyph tile, its name, and its state.
private struct ConnectorRow: View {
    let name: String
    let symbol: String
    let detail: String
    var tile: Color
    var message: String?

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.body.weight(.semibold)).foregroundStyle(.white)
                .frame(width: 32, height: 32).background(tile, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).foregroundStyle(Theme.label)
                Text(detail).font(.subheadline).foregroundStyle(Theme.secondaryLabel).lineLimit(2)
                if let message { Text(message).font(.subheadline).foregroundStyle(Theme.amber).lineLimit(2) }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

private func countsText(_ counts: ServerAPI.ConnectorCounts) -> String {
    var parts = ["\(counts.copied.formatted()) copied"]
    if counts.pending > 0 { parts.append("\(counts.pending.formatted()) waiting") }
    if counts.failed > 0 { parts.append("\(counts.failed.formatted()) failed") }
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
        List {
            Section {
                if connector.signsIn {
                    LabeledContent("Signed in as", value: connector.account ?? "Not signed in")
                }
                if connector.enabled {
                    LabeledContent("Copies", value: countsText(connector.counts))
                } else {
                    Text(connector.summary).font(.subheadline).foregroundStyle(Theme.secondaryLabel)
                }
                if connector.signsIn {
                    Button(connector.account == nil ? "Sign In" : "Sign In Again") { signingIn = true }
                        .foregroundStyle(Theme.accent)
                        .accessibilityIdentifier("connector.signIn")
                }
            }
            .listRowBackground(Theme.card)
            if let message = connector.message {
                Section {
                    InlineNotice(tone: .warning, title: message).accessibilityIdentifier("connector.message")
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            if !connector.fields.isEmpty {
                Section("Settings") {
                    ForEach(connector.fields, id: \.key) { field in fieldEditor(field) }
                }
                .listRowBackground(Theme.card)
            }
            Section {
                Toggle("Copy Originals Already on the Server", isOn: $copyExisting)
                    .tint(Theme.accent)
                    .accessibilityIdentifier("connector.copyExisting")
            } footer: {
                Text("Each upload is checked with the service's own hash. A full or offline service is retried later.")
            }
            .listRowBackground(Theme.card)
            Section {
                Button {
                    Task { await save(enable: true) }
                } label: {
                    BusyLabel(title: connector.enabled ? "Save" : "Turn On", busy: working)
                }
                .foregroundStyle(Theme.accent)
                .disabled(working || (connector.signsIn && connector.account == nil))
                .accessibilityIdentifier("connector.save")
                if connector.enabled {
                    Button("Turn Off") { Task { await save(enable: false) } }
                        .foregroundStyle(Theme.accent)
                        .disabled(working)
                }
            } footer: {
                if connector.signsIn && connector.account == nil { Text("Sign in first.") }
            }
            .listRowBackground(Theme.card)
            if let error {
                Section {
                    InlineNotice(tone: .error, title: error).accessibilityIdentifier("connector.error")
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            if connector.enabled || connector.account != nil || connector.fields.contains(where: \.isSet) {
                Section {
                    Button("Remove and Sign Out", role: .destructive) { Task { await remove() } }
                        .foregroundStyle(Theme.red)
                        .disabled(working)
                } footer: {
                    Text("Copies already made stay in \(connector.name).")
                }
                .listRowBackground(Theme.card)
            }
        }
        .homespunList()
        .navigationTitle(connector.name)
        .navigationBarTitleDisplayMode(.inline)
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
            VStack(spacing: 20) {
                if let challenge {
                    Text(challenge.message ?? "On any device, open the page below, sign in, and enter this code:")
                        .font(.subheadline).foregroundStyle(Theme.secondaryLabel).multilineTextAlignment(.center)
                    Text(challenge.userCode)
                        .font(.system(size: 34, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.label)
                        .textSelection(.enabled)
                        .accessibilityValue(challenge.userCode.map { String($0) }.joined(separator: " "))
                        .accessibilityIdentifier("signIn.code")
                    Button {
                        UIPasteboard.general.string = challenge.userCode
                        copied = true
                    } label: {
                        Label(copied ? "Copied" : "Copy Code", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.bordered).tint(Theme.accent)
                    if let url = URL(string: challenge.url) {
                        Button { openURL(url) } label: {
                            Text("Open \(url.host ?? challenge.url)\(url.path)").frame(maxWidth: .infinity)
                        }
                        .primaryAction()
                    }
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Waiting for you to sign in…").foregroundStyle(Theme.secondaryLabel)
                    }
                    .accessibilityElement(children: .combine)
                } else if let error {
                    InlineNotice(tone: .error, title: error)
                    Button("Try Again") {
                        self.error = nil
                        Task { await run() }
                    }
                    .tint(Theme.accent)
                } else {
                    ProgressView()
                }
                Spacer()
            }
            .padding(24)
            .frame(maxWidth: .infinity)
            .background(Theme.background)
            .navigationTitle("Sign In to \(connector.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Label("Close", systemImage: "xmark") }
                }
            }
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
