// SPDX-License-Identifier: Apache-2.0
import HomespunCore
import SwiftUI

// MARK: 1.7 Ready · 2.2 Ready (Linux) · 3.5 Found and paired · 8.3 the check is slow

/// After pairing: the server's check, and where this iPhone's originals go (a folder named after it).
struct ReadyPage: View {
    let flow: SetupFlow
    @State private var report: ServerSetup.Report?
    @State private var storage: ServerAPI.StorageInfo?
    @State private var checkFailed: String?
    @State private var checking = true
    @State private var slow = false
    @State private var skipped = false
    @State private var attempt = 0
    @State private var sheet: Sheet?

    enum Sheet: String, Identifiable {
        case check, folder
        var id: String { rawValue }
    }

    private var settings: AppSettings { flow.settings }
    private var name: String { flow.serverName }
    private var isMac: Bool { (report?.platform.os ?? settings.server?.platform?.os) == .macOS }
    private var problems: [ServerSetup.Check] { report?.checks.filter { $0.status == .problem } ?? [] }

    var body: some View {
        Group {
            if checking, !skipped { checkingPage } else { readyPage }
        }
        .navigationBarBackButtonHidden()
        .task(id: attempt) { await check() }
        .sheet(item: $sheet) { sheet in
            NavigationStack {
                Group {
                    switch sheet {
                    case .check: ServerCheckView(settings: settings)
                    case .folder: OriginalsFolderView(settings: settings)
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { self.sheet = nil }
                    }
                }
            }
            .onDisappear { attempt += 1 }
        }
    }

    // MARK: Checking (SC-1, SC-S)

    private var checkingPage: some View {
        SetupScaffold(symbol: "clock", symbolColor: Theme.secondaryLabel, title: "Checking \(name)…",
                      subtitle: slow ? "Still checking. Measuring a large disk can take a minute; \(name) is answering."
                        : "Usually a second or two.") {
            SetupCard {
                StepRow(state: .done, title: "Paired with \(name)")
                StepRow(state: .running, title: "Server check", detail: "Photos, videos, Live Photos and free space")
                StepRow(state: storage == nil ? .waiting : .done, title: "Where originals go")
            }
        } actions: {
            SecondaryButton(title: "Cancel", id: "ready.cancel") {
                // Keeps the pairing; the full check stays in Server › Server Check.
                skipped = true
            }
        }
    }

    // MARK: Ready (SC-2), or what needs attention (SC-W, SC-E)

    private var title: String {
        if !problems.isEmpty { return "\(name) needs attention" }
        switch flow.pairing {
        case .waited: return "Paired with \(name)"
        case .returning: return "Reconnected to \(name)"
        default: return "\(name) is ready"
        }
    }

    private var subtitle: String {
        if !problems.isEmpty { return "Fix this on \(name), then check again." }
        if skipped || checkFailed != nil { return "Run the server check any time in Server › Server Check." }
        if flow.pairing == .waited { return "Your new server showed up on this Wi‑Fi, and this iPhone paired with it." }
        return "Everything Homespun needs is installed."
    }

    private var readyPage: some View {
        SetupScaffold(symbol: problems.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                      symbolColor: problems.isEmpty ? Theme.teal : Theme.amber, title: title, subtitle: subtitle) {
            ForEach(problems) { problem in
                InlineNotice(tone: .error, title: problem.title, message: problem.detail) {
                    ForEach(problem.fix, id: \.self) { CommandBox(command: $0) }
                }
                .accessibilityIdentifier("check.\(problem.id).problem")
            }
            if let checkFailed {
                InlineNotice(tone: .warning, title: "The server check didn't finish", message: checkFailed)
            }
            SetupCard { rows }
            if !isMac, settings.server?.mode != .immich {
                Text("Linux can't keep Live Photo motion paired with its photo, so this iPhone compresses the motion part.")
                    .font(.footnote).foregroundStyle(Theme.secondaryLabel).padding(.horizontal, 16)
            }
        } actions: {
            if !problems.isEmpty {
                PrimaryButton(title: "Check Again", systemImage: "arrow.clockwise", busy: checking, id: "check.again") {
                    attempt += 1
                }
                SecondaryButton(title: "See Full Server Check", id: "ready.fullCheck") { sheet = .check }
            } else {
                if flow.pairing == .waited || flow.pairing == .returning {
                    ConsequenceLine(text: "Next: see what Homespun could free up here. It reads your library on this "
                                    + "iPhone; nothing is uploaded yet.")
                }
                PrimaryButton(title: flow.pairOnly ? "Done" : "See What You Can Free Up",
                              systemImage: flow.pairOnly ? nil : "photo.on.rectangle", id: "ready.continue") {
                    flow.afterReady()
                }
                SecondaryButton(title: "See Full Server Check", id: "ready.fullCheck") { sheet = .check }
            }
        }
    }

    @ViewBuilder private var rows: some View {
        if settings.server?.mode == .immich {
            SetupRow(symbol: "camera.macro", title: "Originals", value: "In Immich")
        } else if let storage {
            let canChange = storage.storedCount == 0 && storage.move == nil
            Button { if canChange { sheet = .folder } } label: {
                SetupRow(symbol: "folder", title: "Originals go to", detail: storage.deviceFolder ?? storage.originalsFolder,
                         monospacedDetail: true, chevron: canChange)
            }
            .buttonStyle(.plain)
            .disabled(!canChange)
            .accessibilityHint(canChange ? "Choose another folder. Nothing is stored there yet."
                               : "Change it later in Server › Originals Folder.")
            .accessibilityIdentifier("ready.folder")
            if let free = storage.freeBytes {
                SetupRow(symbol: "internaldrive", title: "Free space", value: SetupAdvisor.roughBytes(free))
            }
        }
        SetupRow(symbol: "livephoto", title: "Live Photos", value: isMac ? "On the Mac" : "On this iPhone")
        if let discovery = report?.checks.first(where: { $0.id == "discovery" }) {
            SetupRow(symbol: "wifi", title: "Home network", value: discovery.status == .ok ? "Found" : "Not announced")
        }
        if let service = report?.checks.first(where: { $0.id == "service" }) {
            SetupRow(symbol: "bolt.fill", title: isMac ? "Starts with the Mac" : "Starts with the computer",
                     value: service.status == .ok ? "Yes" : "No")
        }
    }

    // MARK: Checking

    private func check() async {
        guard let client = settings.client else {
            checking = false
            return
        }
        checking = true
        slow = false
        checkFailed = nil
        let timer = Task {
            try? await Task.sleep(for: .seconds(10))
            if !Task.isCancelled { slow = true }
        }
        async let setup = client.setup()
        async let folder = client.storage()
        storage = try? await folder
        do {
            report = try await setup
        } catch {
            checkFailed = error.localizedDescription
        }
        timer.cancel()
        await settings.refreshServerInfo()
        checking = false
        if problems.isEmpty {
            Announce.say(title)
        } else {
            Announce.say("\(name) needs attention: \(problems.map(\.title).joined(separator: ", ")).")
        }
    }
}

/// The server's self-check (DESIGN 04·2.1): what works and what to install. Check Again after fixing.
struct ServerCheckView: View {
    @Bindable var settings: AppSettings
    var onContinue: (() -> Void)?
    @State private var report: ServerSetup.Report?
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        List {
            Section {
                if let url = settings.serverURL {
                    LabeledContent("Current address", value: url.absoluteString)
                        .accessibilityIdentifier("check.connection.address")
                }
                if let notice = settings.addressNotice {
                    Text(notice).foregroundStyle(Theme.teal)
                        .accessibilityIdentifier("check.connection.addressChanged")
                }
                if settings.findingAddress {
                    HStack { ProgressView(); Text("Looking for the server’s new address…") }
                        .accessibilityIdentifier("check.connection.findingAddress")
                } else if settings.addressSearchFailed {
                    Text("No server with the paired key was found at a new address.")
                        .foregroundStyle(Theme.secondaryLabel)
                        .accessibilityIdentifier("check.connection.addressNotFound")
                }
                if let problem = settings.connectionProblem {
                    Label(problem, systemImage: "xmark.shield.fill").foregroundStyle(Theme.red)
                } else if settings.pins != nil || settings.isDemo {
                    Label("Encrypted connection", systemImage: "checkmark.shield.fill")
                        .foregroundStyle(Theme.teal)
                        .accessibilityIdentifier("check.connection.encrypted")
                    Text(settings.pins?.pins.isEmpty == true
                         ? "\(settings.tlsVersion) with a certificate for \(settings.serverURL?.host ?? "your server")."
                         : "\(settings.tlsVersion). This iPhone checks the server's key on every connection.")
                        .font(.callout).foregroundStyle(Theme.secondaryLabel)
                    if let key = settings.pins?.pins.first {
                        LabeledContent("Server key") {
                            Button(key.display) { UIPasteboard.general.string = key.base64url }
                                .font(.callout.monospaced())
                        }
                        .accessibilityIdentifier("check.connection.key")
                    }
                }
            } header: {
                Text("Connection")
            } footer: {
                Text("Matches homespun-server certificate on the server."
                     + (settings.pins?.changedAt.map { " Changed on \($0.formatted(date: .abbreviated, time: .omitted)); this iPhone checked it with its pairing." } ?? ""))
            }
            Section {
                if let server = settings.server {
                    LabeledContent(server.name, value: report?.platform.name ?? server.platform?.name ?? "")
                        .accessibilityIdentifier("check.server")
                }
                if let report {
                    Label(report.ready ? "Ready to use" : "Needs attention",
                          systemImage: report.ready ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(report.ready ? Theme.teal : Theme.amber)
                        .accessibilityIdentifier(report.ready ? "check.ready" : "check.attention")
                } else if let error {
                    Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(Theme.red)
                } else {
                    StepRow(state: .running, title: "Checking \(settings.server?.name ?? "the server")…")
                        .listRowInsets(EdgeInsets())
                }
            }

            if let report {
                ForEach(report.checks) { check in
                    Section {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            icon(check.status)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(check.title).font(.headline)
                                Text(check.detail).font(.callout).foregroundStyle(Theme.secondaryLabel)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("check.\(check.id).\(check.status.rawValue)")
                        ForEach(check.fix, id: \.self) { CommandBox(command: $0) }
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
                    BusyLabel(title: "Check Again", systemImage: "arrow.clockwise", busy: loading)
                }
                .allowsHitTesting(!loading)
                .accessibilityIdentifier("check.again")
            } footer: {
                Text("After installing something on the server, come back and check again.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Server Check")
        .safeAreaBar(edge: .bottom) {
            if let onContinue {
                Button(action: onContinue) { Text("Continue").frame(maxWidth: .infinity) }
                    .primaryAction()
                    .padding(.horizontal, 20).padding(.bottom, 8)
                    .accessibilityIdentifier("onboarding.continue")
            }
        }
        .task { await load() }
    }

    private func icon(_ status: ServerSetup.CheckStatus) -> some View {
        Group {
            switch status {
            case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.teal)
            case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.amber)
            case .problem: Image(systemName: "xmark.octagon.fill").foregroundStyle(Theme.red)
            case .info: Image(systemName: "info.circle.fill").foregroundStyle(Theme.blue)
            }
        }
        .accessibilityLabel(status == .ok ? "OK" : status == .warning ? "Warning" : status == .problem ? "Problem" : "Note")
    }

    private func load() async {
        loading = true
        defer { loading = false }
        await settings.refreshServerInfo()
        guard settings.connectionProblem == nil, let client = settings.client else { return }
        do {
            report = try await client.setup()
            error = nil
            await settings.refreshServerInfo()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: 5.1–5.4 Immich

/// Use Homespun with Immich (01·5.1): after pairing, when "I already use Immich" was chosen.
struct ImmichIntroPage: View {
    let flow: SetupFlow

    var body: some View {
        SetupScaffold(symbol: "camera.macro", title: "Use Homespun with Immich",
                      subtitle: "\(flow.serverName) reads originals your Immich already has, checks each one byte for "
                        + "byte, and stores none itself.") {
            VStack(alignment: .leading, spacing: 16) {
                PromiseRow(symbol: "lock.fill", title: "It only reads",
                           detail: "It never changes or deletes anything in Immich.")
                PromiseRow(symbol: "server.rack", title: "Homespun Server keeps running on \(flow.serverName)",
                           detail: "Often the computer that runs Immich.")
            }
        } actions: {
            PrimaryButton(title: "Connect Immich", id: "immich.start") { flow.go(.immichConnect) }
            SecondaryButton(title: "Store Originals on \(flow.serverName) Instead", id: "immich.skip") {
                flow.usesImmich = false
                flow.go(.ready)
            }
        }
        .navigationBarBackButtonHidden()
    }
}

/// Connect Immich (01·5.2): the server tests the address and key, then keeps the key.
struct ImmichConnectPage: View {
    let flow: SetupFlow
    @State private var url = ""
    @State private var key = ""
    @State private var working = false
    @State private var error: String?
    @FocusState private var focus: Int?

    var body: some View {
        SetupScaffold(title: "Connect Immich") {
            SetupField(label: "Immich address", focused: focus == 0) {
                TextField("Immich address", text: $url, prompt: Text(verbatim: "http://192.168.1.20:2283"))
                    .focused($focus, equals: 0)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    .accessibilityIdentifier("immich.url")
            }
            SetupField(label: "API key", error: error != nil, focused: focus == 1) {
                SecureField("API key", text: $key)
                    .focused($focus, equals: 1)
                    .accessibilityIdentifier("immich.key")
            }
            if let error { FieldError(text: error).padding(.horizontal, 16) }
            Text("In Immich: Account Settings › API Keys › New API Key. Allow only asset.read and asset.download.")
                .font(.footnote).foregroundStyle(Theme.secondaryLabel).padding(.horizontal, 16)
        } actions: {
            PrimaryButton(title: "Connect", busy: working, id: "immich.connect") { Task { await connect() } }
                .disabled(url.isEmpty || key.isEmpty)
        }
    }

    private func connect() async {
        guard let client = flow.settings.client else { return }
        working = true
        defer { working = false }
        do {
            _ = try await client.connectImmich(url: url, apiKey: key)
            key = ""
            error = nil
            await flow.settings.refreshServerInfo()
            flow.go(.immichExclude)
        } catch {
            self.error = error.localizedDescription
            Announce.say(error.localizedDescription)
        }
    }
}

/// One more step in the Immich app (01·5.3): keep compact copies out of Immich's backup.
struct ImmichExcludePage: View {
    let flow: SetupFlow

    var body: some View {
        SetupScaffold(symbol: "exclamationmark.triangle", title: "One more step in the Immich app",
                      subtitle: "Compact copies go to a \"\(PhotoLibrary.albumTitle)\" album. If the Immich app backs "
                        + "them up, your Immich fills with duplicates.") {
            SetupCard {
                SetupRow(title: "1  Open the Immich app")
                SetupRow(title: "2  Backup › Backup Albums")
                SetupRow(title: "3  Tap \"\(PhotoLibrary.albumTitle)\" until it shows Excluded")
            }
            Text("Homespun's server check warns if copies show up in Immich.")
                .font(.footnote).foregroundStyle(Theme.secondaryLabel).padding(.horizontal, 16)
        } actions: {
            PrimaryButton(title: "I've Excluded It", id: "immich.excluded") { flow.go(.immichReady) }
            SecondaryButton(title: "Remind Me Later", id: "immich.later") { flow.go(.immichReady) }
        }
        .navigationBarBackButtonHidden()
    }
}

/// Immich is connected (01·5.4).
struct ImmichReadyPage: View {
    let flow: SetupFlow
    @State private var host: String?

    var body: some View {
        SetupScaffold(symbol: "checkmark.circle.fill", title: "Immich is connected",
                      subtitle: "\(flow.serverName) reads originals from Immich" + (host.map { " at \($0)." } ?? ".")) {
            SetupCard {
                SetupRow(symbol: "camera.macro", title: "Originals", value: "In Immich")
                SetupRow(symbol: "hourglass", title: "New photos",
                         detail: "Back up with the Immich app first; Homespun picks them up after.")
            }
        } actions: {
            ConsequenceLine(text: "Next: see what Homespun could free up here. It reads your library on this iPhone; "
                            + "nothing is uploaded yet.")
            PrimaryButton(title: "See What You Can Free Up", systemImage: "photo.on.rectangle", id: "ready.continue") {
                flow.afterReady()
            }
        }
        .navigationBarBackButtonHidden()
        .task {
            host = (try? await flow.settings.client?.immichSettings())?.url.flatMap { URL(string: $0)?.host }
        }
    }
}

/// Connects the server to Immich from Server settings: the server tests the address and key, then keeps the key.
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
                        .foregroundStyle(current.connected ? Theme.teal : Theme.red)
                    if current.connected, let message = current.message {
                        Text(message).font(.callout).foregroundStyle(Theme.amber)
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
                    BusyLabel(title: current?.connected == true ? "Replace" : "Connect", busy: working)
                }
                .disabled(url.isEmpty || key.isEmpty)
                .allowsHitTesting(!working)
                .accessibilityIdentifier("immich.connect")
                if let error { FieldError(text: error) }
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
