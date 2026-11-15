// SPDX-License-Identifier: Apache-2.0
import HomespunCore
import SwiftUI
import UserNotifications

/// The Server tab (DESIGN 04·1.1–1.5, 05): the paired server at a glance, where originals are,
/// Premium features, devices, and this iPhone's settings. Not paired: a way to set one up.
struct ServerTab: View {
    let model: AppModel

    enum Route: Hashable {
        case check, originals, existingLibrary, immich, automatic, connectors, compactCopies, devices, addDevice
        case notifications, premium, help, analytics
    }

    @State private var path: [Route] = []
    @State private var storage: ServerAPI.StorageInfo?
    @State private var checks: [ServerSetup.Check]?
    @State private var devices: [ServerAPI.DeviceInfo]?
    @State private var cloud: [ServerAPI.ConnectorInfo]?
    @State private var notifications: UNAuthorizationStatus?
    @State private var settingUp = false
    @State private var confirmingUnpair = false
    @State private var confirmingSwitch = false
    @State private var askingScope = false
    @State private var locked: PremiumFeature?
    /// When the server last answered, for "Last seen" while it can't be reached.
    @AppStorage("serverLastSeen") private var lastSeen: Double = 0

    var body: some View {
        let settings = model.settings
        BookNavigation(path: $path) {
            Group {
                if let server = settings.server, settings.isPaired {
                    paired(server)
                } else {
                    unpaired
                }
            }
        } destination: { route in
            destination(route)
        } placeholder: {
            ContentUnavailableView("Choose a setting", systemImage: "server.rack",
                                   description: Text("What you open on the left shows here."))
                .background(Theme.background)
        }
        .sheet(isPresented: $settingUp) { OnboardingView(settings: settings, library: model.library) }
        .sheet(item: $locked) { feature in
            PremiumFeatureSheet(feature: feature, premium: model.premium) {
                locked = nil
                path.append(.premium)
            }
        }
        .alert("Back up what's already here too?", isPresented: $askingScope) {
            AutomaticModeView.scopeButtons(model.automatic)
        } message: {
            Text(AutomaticModeView.scopeMessage(count: model.library.library.state.count(.notBackedUp)))
        }
    }

    // MARK: Paired

    private func paired(_ server: ServerAPI.ServerInfo) -> some View {
        let settings = model.settings
        let unreachable: String? = if case .unreachable(let reason) = settings.serverStatus { reason } else { nil }
        return List {
            Section {
                ServerStatusCard(server: server, status: settings.serverStatus, storage: storage,
                                 lastSeen: lastSeen > 0 ? Date(timeIntervalSince1970: lastSeen) : nil)
            }
            .listRowBackground(Theme.card)
            if let unreachable {
                UnreachableChecks(server: server, reason: unreachable, checking: settings.serverStatus == .checking) {
                    Task { await settings.refreshServerInfo() }
                }
            }
            Section {
                NavigationLink(value: Route.check) {
                    ServerRow(title: "Server Check", symbol: "checkmark.shield", value: checkValue.text,
                              valueTint: checkValue.tint)
                }
                .accessibilityIdentifier("settings.check")
                if let os = server.platform?.os {
                    ServerRow(title: "Live Photos", symbol: "livephoto", value: os == .macOS ? "On the Mac" : "On this iPhone")
                }
            } footer: {
                if server.platform?.os == .linux {
                    Text("Linux can't keep Live Photo motion paired with its photo, so this iPhone compresses the motion part.")
                }
            }
            .listRowBackground(Theme.card)
            Section("Originals") {
                if server.mode == .files {
                    NavigationLink(value: Route.originals) {
                        ServerRow(title: "Originals Folder", symbol: "folder",
                                  value: storage.map { ($0.originalsFolder as NSString).lastPathComponent })
                    }
                    .accessibilityIdentifier("settings.originals")
                }
                NavigationLink(value: Route.existingLibrary) {
                    ServerRow(title: "Existing Library", symbol: "archivebox", value: existingLibraryValue)
                }
                .accessibilityIdentifier("settings.existingLibrary")
                NavigationLink(value: Route.immich) {
                    ServerRow(title: "Immich", symbol: "circle.hexagongrid",
                              value: server.mode == .immich ? "Connected" : "Not connected")
                }
                .accessibilityIdentifier("settings.immich")
            }
            .listRowBackground(Theme.card)
            premiumSection
            Section {
                NavigationLink(value: Route.compactCopies) {
                    ServerRow(title: "Compact Copies", symbol: "slider.horizontal.3",
                              value: "\(server.profile.photoMaxEdge) px · \(server.profile.videoShortEdge)p")
                }
                .accessibilityIdentifier("settings.compactCopies")
                NavigationLink(value: Route.devices) {
                    ServerRow(title: "Devices", symbol: "iphone", value: devices.map { "\($0.count)" })
                }
                .accessibilityIdentifier("settings.devices")
            }
            .listRowBackground(Theme.card)
            thisIPhoneSection
            Section {
                Button("Unpair from \(server.name)…", role: .destructive) { confirmingUnpair = true }
                    .foregroundStyle(Theme.red)
                    .accessibilityIdentifier("server.unpair")
            } footer: {
                Text("Unpairing keeps every original on the server and every compact copy in Photos.")
            }
            .listRowBackground(Theme.card)
        }
        .homespunList()
        .navigationTitle(server.name)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { path.append(.check) } label: { Label("Server Check", systemImage: "checkmark.shield") }
                    Button { path.append(.addDevice) } label: { Label("Add Device", systemImage: "plus") }
                        .accessibilityIdentifier("settings.addDevice")
                    Button { confirmingSwitch = true } label: {
                        Label("Switch Server", systemImage: "arrow.left.arrow.right")
                    }
                    .accessibilityIdentifier("server.switch")
                    Button(role: .destructive) { confirmingUnpair = true } label: {
                        Label("Unpair", systemImage: "minus.circle")
                    }
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
                .accessibilityIdentifier("server.more")
            }
        }
        .refreshable { await refresh() }
        .task(id: settings.serverStatus == .reachable) { await load() }
        .onChange(of: settings.serverStatus, initial: true) { _, status in
            if status == .reachable { lastSeen = Date().timeIntervalSince1970 }
        }
        .alert("Unpair from \(server.name)?", isPresented: $confirmingUnpair) {
            Button("Cancel", role: .cancel) {}
            Button("Unpair", role: .destructive) { unpair() }
                .accessibilityIdentifier("server.unpair.confirm")
        } message: {
            Text("This iPhone stops backing up. Originals stay on the server and compact copies stay in Photos. "
                 + "You can pair again any time.")
        }
        .alert("Switch to another server?", isPresented: $confirmingSwitch) {
            Button("Cancel", role: .cancel) {}
            Button("Switch") {
                unpair()
                settingUp = true
            }
        } message: {
            Text("This iPhone unpairs from \(server.name) first. Originals stay there and compact copies stay in "
                 + "Photos. Then set up the other server.")
        }
    }

    // MARK: Not paired

    private var unpaired: some View {
        List {
            Section {
                VStack(spacing: 14) {
                    Image(systemName: "server.rack").font(.system(size: 34)).foregroundStyle(Theme.accent)
                        .frame(width: 72, height: 72).background(Theme.accentSoft, in: Circle())
                        .accessibilityHidden(true)
                    Text("Set up your home computer").font(.title2.weight(.semibold)).foregroundStyle(Theme.label)
                        .multilineTextAlignment(.center).accessibilityAddTraits(.isHeader)
                    Text("Homespun keeps your originals on a Mac, a Linux PC or a NAS at home, and compact copies on "
                         + "this iPhone. Nothing is backed up until you set one up.")
                        .font(.subheadline).foregroundStyle(Theme.secondaryLabel).multilineTextAlignment(.center)
                    Button { settingUp = true } label: {
                        Label("Set Up", systemImage: "arrow.right").frame(maxWidth: .infinity)
                    }
                    .primaryAction()
                    .accessibilityIdentifier("server.setUp")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            .listRowBackground(Theme.card)
            premiumSection
            thisIPhoneSection
        }
        .homespunList()
        .navigationTitle("Server")
        .task { await loadNotifications() }
    }

    // MARK: Sections

    private var premiumSection: some View {
        let premium = model.premium, automatic = model.automatic, settings = model.settings
        return Section("Premium") {
            if premium.isUnlocked {
                HStack(spacing: 12) {
                    Button { path.append(.automatic) } label: {
                        HStack {
                            ActivityRow(symbol: "bolt.fill", title: "Automatic Mode", detail: automaticDetail)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens what automatic mode backs up, and its last run.")
                    .accessibilityIdentifier("settings.automatic")
                    Toggle("Automatic Mode", isOn: Binding(get: { automatic.enabled }, set: { on in
                        if on { askingScope = true } else { automatic.disable() }
                    }))
                    .labelsHidden()
                    .tint(Theme.accent)
                    .disabled(!settings.canCompact)
                    .accessibilityIdentifier("automatic.toggle")
                }
                NavigationLink(value: Route.connectors) {
                    ServerRow(title: "Cloud Copies", symbol: "icloud.and.arrow.up", value: cloudValue)
                }
                .disabled(!settings.isPaired)
                .accessibilityIdentifier("settings.connectors")
            } else {
                Button { locked = .automatic } label: {
                    ServerRow(title: "Automatic Mode", symbol: "bolt.fill", value: "Premium", valueTint: Theme.accent,
                              chevron: true)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("automatic.premium")
                Button { locked = .cloudCopies } label: {
                    ServerRow(title: "Cloud Copies", symbol: "icloud.and.arrow.up", value: "Premium",
                              valueTint: Theme.accent, chevron: true)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings.connectors")
            }
        }
        .listRowBackground(Theme.card)
    }

    private var thisIPhoneSection: some View {
        Section("This iPhone") {
            NavigationLink(value: Route.notifications) {
                ServerRow(title: "Notifications", symbol: "bell", value: notificationsValue)
            }
            .accessibilityIdentifier("settings.notifications")
            NavigationLink(value: Route.analytics) {
                ServerRow(title: "Share Analytics", symbol: "chart.bar",
                          value: Telemetry.shared.isSharing ? "On" : "Off")
            }
            .accessibilityIdentifier("settings.analytics")
            NavigationLink(value: Route.premium) {
                ServerRow(title: "Premium", symbol: "sparkles",
                          value: model.premium.isUnlocked ? "Unlocked" : nil)
            }
            .accessibilityIdentifier("settings.premium")
            NavigationLink(value: Route.help) {
                ServerRow(title: "Help and About", symbol: "questionmark.circle", value: nil)
            }
            .accessibilityIdentifier("settings.help")
        }
        .listRowBackground(Theme.card)
    }

    @ViewBuilder private func destination(_ route: Route) -> some View {
        let settings = model.settings
        switch route {
        case .check: ServerCheckView(settings: settings).homespunList()
        case .originals: OriginalsFolderView(settings: settings)
        case .existingLibrary: ExistingLibraryView(model: model)
        case .immich: ImmichConnectView(settings: settings).homespunList()
        case .automatic: AutomaticModeView(model: model)
        case .connectors: ConnectorsView(settings: settings)
        case .compactCopies: CompactCopiesView(server: settings.server)
        case .devices: DevicesView(settings: settings) { path.append(.addDevice) }
        case .addDevice: AddDeviceView(settings: settings)
        case .notifications: NotificationsView(model: model)
        case .premium: PremiumView(premium: model.premium, model: model)
        case .help: HelpAboutView(model: model)
        case .analytics: AnalyticsSettingsView()
        }
    }

    // MARK: Values

    private var checkValue: (text: String?, tint: Color) {
        guard let checks else { return (nil, Theme.secondaryLabel) }
        let problems = checks.filter { $0.status == .problem }.count
        let warnings = checks.filter { $0.status == .warning }.count
        if problems > 0 { return ("\(problems) to fix", Theme.red) }
        if warnings > 0 { return ("\(warnings) warning\(warnings == 1 ? "" : "s")", Theme.amber) }
        return ("All good", Theme.secondaryLabel)
    }

    private var existingLibraryValue: String {
        let finder = model.copyFinder
        if finder.isRunning { return "Finding…" }
        if let summary = finder.summary, summary.found > 0 { return "\(summary.found.formatted()) found" }
        return "Not set up"
    }

    private var automaticDetail: String {
        guard model.settings.isPaired else { return "Pair a server first." }
        guard model.automatic.enabled else { return "Off" }
        if let run = model.history.runs.first(where: { $0.kind == .backUp && $0.trigger == .automatic }) {
            let when = run.title().replacingOccurrences(of: " · automatic", with: "")
            return "\(when): \(run.count(.saved)) backed up"
        }
        return "Next run tonight while charging"
    }

    private var cloudValue: String? {
        guard let cloud else { return nil }
        let on = cloud.filter(\.enabled).map(\.name)
        return on.isEmpty ? "Off" : on.joined(separator: ", ")
    }

    private var notificationsValue: String? {
        switch notifications {
        case .authorized?, .provisional?, .ephemeral?: "On"
        case .denied?: "Off"
        case .notDetermined?: "Not set"
        default: nil
        }
    }

    // MARK: Loading

    private func load() async {
        await loadNotifications()
        guard model.settings.serverStatus == .reachable, let client = model.settings.client else {
            if model.settings.serverStatus == .unknown { await model.settings.refreshServerInfo() }
            return
        }
        let wantsCloud = model.premium.isUnlocked
        async let storage = try? client.storage()
        async let report = try? client.setup()
        async let devices = try? client.devices()
        async let cloud = wantsCloud ? try? client.connectors() : nil
        let (newStorage, newReport, newDevices, newCloud) = await (storage, report, devices, cloud)
        self.storage = newStorage ?? self.storage
        checks = newReport?.checks ?? checks
        self.devices = newDevices ?? self.devices
        self.cloud = newCloud ?? self.cloud
    }

    private func loadNotifications() async {
        notifications = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    private func refresh() async {
        await model.settings.refreshServerInfo()
        await load()
    }

    private func unpair() {
        model.settings.unpair()
        storage = nil
        checks = nil
        devices = nil
        cloud = nil
        path = []
        Announce.say("Unpaired.")
    }
}

/// A row with an icon, a title and a value (and the chevron a NavigationLink adds).
struct ServerRow: View {
    let title: String
    let symbol: String
    var value: String?
    var valueTint: Color = Theme.secondaryLabel
    /// Draws a chevron for rows that are buttons rather than links.
    var chevron = false

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.body).foregroundStyle(Theme.accent).frame(width: 28)
                .accessibilityHidden(true)
            Text(title).foregroundStyle(Theme.label).layoutPriority(1)
            Spacer(minLength: 8)
            if let value {
                Text(value).foregroundStyle(valueTint).lineLimit(1).minimumScaleFactor(0.8).truncationMode(.middle)
            }
            if chevron {
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Theme.tertiaryLabel)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// The server at a glance: what it runs on, whether it answers, and its storage (04·1.1, 1.4).
struct ServerStatusCard: View {
    let server: ServerAPI.ServerInfo
    let status: AppSettings.ServerStatus
    let storage: ServerAPI.StorageInfo?
    let lastSeen: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(systemName: Self.symbol(for: server)).font(.title2).foregroundStyle(Theme.accent)
                    .frame(width: 52, height: 52)
                    .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(Self.machine(server)).font(.subheadline.weight(.medium)).foregroundStyle(Theme.label)
                    HStack(spacing: 6) {
                        Circle().fill(statusTint).frame(width: 8, height: 8)
                        Text(statusText).font(.subheadline).foregroundStyle(statusTint)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(statusText)
                    .accessibilityIdentifier("server.status")
                }
            }
            if status == .reachable || lastSeen == nil {
                if let fraction = usedFraction {
                    ProgressView(value: fraction).tint(Theme.accent).accessibilityHidden(true)
                }
                HStack {
                    if let storage {
                        Text("\(storage.storedCount.formatted()) originals · \(Self.bytes(storage.storedBytes))")
                    }
                    Spacer(minLength: 8)
                    if let free = storage?.freeBytes ?? server.freeBytes { Text("\(Self.bytes(free)) free") }
                }
                .font(.footnote).foregroundStyle(Theme.secondaryLabel)
                .accessibilityElement(children: .combine)
            } else if let lastSeen {
                Text("Last seen \(Self.when(lastSeen))").font(.footnote).foregroundStyle(Theme.secondaryLabel)
            }
        }
        .padding(.vertical, 6)
    }

    private var statusText: String {
        switch status {
        case .reachable: "Connected"
        case .unreachable: "Can't reach it"
        case .checking, .unknown: "Checking…"
        }
    }

    private var statusTint: Color {
        switch status {
        case .reachable: Theme.teal
        case .unreachable: Theme.amber
        case .checking, .unknown: Theme.secondaryLabel
        }
    }

    private var usedFraction: Double? {
        guard let capacity = storage?.capacityBytes, capacity > 0, let free = storage?.freeBytes else { return nil }
        return Double(capacity - free) / Double(capacity)
    }

    /// "Mac mini · macOS 27.2", "Linux · Ubuntu 24.04", "Synology DS923+ · Docker".
    static func machine(_ server: ServerAPI.ServerInfo) -> String {
        let model = server.hardware?.model ?? server.platform.map { $0.os == .macOS ? "Mac" : "Linux" }
        let system = server.hardware?.kind == .container && server.platform?.os == .linux ? "Docker" : server.platform?.name
        return [model, system].compactMap { $0 }.joined(separator: " · ").nonEmpty ?? "Homespun Server \(server.version)"
    }

    static func symbol(for server: ServerAPI.ServerInfo) -> String {
        let model = server.hardware?.model?.lowercased() ?? ""
        switch (server.platform?.os, server.hardware?.kind) {
        case (_, .container?): return "externaldrive.connected.to.line.below"
        case (.macOS?, .laptop?): return "laptopcomputer"
        case (.macOS?, _):
            if model.contains("mini") { return "macmini" }
            if model.contains("studio") { return "macstudio" }
            return "desktopcomputer"
        case (.linux?, .server?): return "server.rack"
        case (.linux?, _): return "terminal"
        default: return "server.rack"
        }
    }

    static func bytes(_ count: Int64) -> String { count.formatted(.byteCount(style: .file)) }

    static func when(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(date) { return "today, \(time)" }
        if Calendar.current.isDateInYesterday(date) { return "yesterday, \(time)" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

/// Can't reach the server: likely causes in order, and Try Again (04·1.4).
private struct UnreachableChecks: View {
    let server: ServerAPI.ServerInfo
    let reason: String
    let checking: Bool
    let retry: () -> Void

    var body: some View {
        Section("Check") {
            if reason.contains("Pair it again") {
                ActivityRow(symbol: "person.badge.key", title: "\(server.name) doesn't recognise this iPhone",
                            detail: "It was removed on the server. Unpair, then pair again with a new code.")
            } else {
                ForEach(Self.causes(server), id: \.title) { cause in
                    ActivityRow(symbol: cause.symbol, title: cause.title, detail: cause.detail)
                }
            }
        }
        .listRowBackground(Theme.card)
        Section {
            Button(action: retry) {
                BusyLabel(title: "Try Again", busy: checking).frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered).controlSize(.large).tint(Theme.accent)
            .disabled(checking)
            .accessibilityIdentifier("server.retry")
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
    }

    static func causes(_ server: ServerAPI.ServerInfo) -> [(symbol: String, title: String, detail: String)] {
        let wifi = (symbol: "wifi", title: "Is this iPhone on home Wi‑Fi?",
                    detail: "Homespun reaches the server on your home network.")
        switch (server.platform?.os, server.hardware?.kind) {
        case (_, .container?):
            return [wifi, ("power", "Is the NAS on?", "Homespun runs in a container on it."),
                    ("shippingbox", "Is the Homespun container running?", "Check the NAS's container app.")]
        case (.linux?, _):
            return [wifi, ("power", "Is the computer on?", "Homespun Server stops when it sleeps or shuts down."),
                    ("terminal", "Is Homespun Server running?", "systemctl --user status homespun")]
        default:
            return [wifi, ("moon", "Is \(server.name) awake?", "Turn off sleep, or wake it with a key press."),
                    ("server.rack", "Is Homespun Server running?", "It starts with the Mac; check Login Items.")]
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
