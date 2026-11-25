// SPDX-License-Identifier: Apache-2.0
import HomespunCore
import SwiftUI
import UserNotifications

/// The Server tab (DESIGN 04·1.1–1.5, 05): the paired server at a glance, where originals are,
/// automatic mode and cloud copies, devices, and this iPhone's settings. Not paired: a way to set one up.
struct ServerTab: View {
    let model: AppModel

    enum Route: Hashable {
        case check, originals, existingLibrary, immich, automatic, connectors, compactCopies, devices, addDevice
        case notifications, wake, premium, help, analytics, deviceName

        var isAvailable: Bool {
            switch self {
            case .automatic: ReleaseFeatures.automaticMode
            case .connectors: ReleaseFeatures.cloudCopies
            case .premium: ReleaseFeatures.premium
            default: true
            }
        }
    }

    @State private var path: [Route] = []
    @State private var nameDraft = DeviceNameDraft()
    @State private var storage: ServerAPI.StorageInfo?
    @State private var checks: [ServerSetup.Check]?
    @State private var devices: [ServerAPI.DeviceInfo]?
    /// This iPhone as the server knows it (its name names its originals folder there).
    @State private var thisDevice: ServerAPI.DeviceInfo?
    @State private var cloud: [ServerAPI.ConnectorInfo]?
    @State private var notifications: UNAuthorizationStatus?
    @State private var settingUp = false
    @State private var confirmingUnpair = false
    @State private var confirmingSwitch = false
    @State private var showingIdentity = false
    /// When the server last answered, for "Last seen" while it can't be reached.
    @AppStorage("serverLastSeen") private var lastSeen: Double = 0

    var body: some View {
        let settings = model.settings
        let isPaired = settings.server != nil && settings.isPaired
        // Beside the list on the open iPhone Duo: Server Check (Help and About before pairing).
        SplitNavigation(path: $path, defaultRoute: isPaired ? .check : .help,
                        retainsOnFold: { $0 == .deviceName },
                        confirmation: { route in route == .deviceName ? AnyView(nameEditor.saveButton) : nil }) { selection in
            Group {
                if let server = settings.server, settings.isPaired {
                    paired(server, selection: selection)
                } else {
                    unpaired(selection: selection)
                }
            }
        } destination: { route in
            destination(route)
        } empty: {
            EmptyView()
        }
        .sheet(isPresented: $settingUp) { OnboardingView(settings: settings, library: model.library) }
        .onChange(of: path) { old, new in
            if old.contains(.deviceName), !new.contains(.deviceName) { nameDraft = DeviceNameDraft() }
        }
        // A widget's link to one of these pages.
        .onChange(of: model.router.serverRoute, initial: true) { _, route in
            guard let route else { return }
            model.router.serverRoute = nil
            if route.isAvailable { path = [route] }
        }
    }

    // MARK: Paired

    private func paired(_ server: ServerAPI.ServerInfo, selection: Binding<Route?>?) -> some View {
        let settings = model.settings
        let unreachable: String? = if case .unreachable(let reason) = settings.serverStatus { reason } else { nil }
        return List(selection: selection) {
            if settings.isDemo { DemoCard() }
            if let problem = settings.connectionProblem {
                Section {
                    Button { showingIdentity = true } label: {
                        Label(problem, systemImage: "lock.trianglebadge.exclamationmark")
                            .foregroundStyle(Theme.red)
                    }
                    .accessibilityIdentifier("server.identityProblem")
                }
            }
            if let date = settings.identityNotice {
                Section {
                    Text("\(server.name)'s security key changed on \(date.formatted(date: .abbreviated, time: .omitted)). "
                         + "This iPhone checked it with its pairing, so it's still your server.")
                        .accessibilityIdentifier("server.keyChanged.confirmed")
                    Link("Learn more", destination: URL(string: "https://homespun.photos/support#server-identity")!)
                    Button("Dismiss") { settings.identityNotice = nil }
                }
            }
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
                .sidebarRow(Route.check)
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
                    .sidebarRow(Route.originals)
                }
                NavigationLink(value: Route.existingLibrary) {
                    ServerRow(title: "Existing Library", symbol: "archivebox", value: existingLibraryValue)
                }
                .accessibilityIdentifier("settings.existingLibrary")
                .sidebarRow(Route.existingLibrary)
                NavigationLink(value: Route.immich) {
                    ServerRow(title: "Immich", symbol: "circle.hexagongrid",
                              value: server.mode == .immich ? "Connected" : "Not connected")
                }
                .accessibilityIdentifier("settings.immich")
                .sidebarRow(Route.immich)
            }
            .listRowBackground(Theme.card)
            if ReleaseFeatures.premium { backupsSection }
            Section {
                NavigationLink(value: Route.compactCopies) {
                    ServerRow(title: "Compact Copies", symbol: "slider.horizontal.3",
                              value: "\(server.profile.photoMaxEdge) px · \(server.profile.videoShortEdge)p")
                }
                .accessibilityIdentifier("settings.compactCopies")
                .sidebarRow(Route.compactCopies)
                NavigationLink(value: Route.devices) {
                    ServerRow(title: "Devices", symbol: "iphone", value: devices.map { "\($0.count)" })
                }
                .accessibilityIdentifier("settings.devices")
                .sidebarRow(Route.devices)
            }
            .listRowBackground(Theme.card)
            thisIPhoneSection
            // The demo's pairing is pretend: the way out is leaving the demo (its card, above).
            if !settings.isDemo {
                Section {
                    Button("Unpair from \(server.name)…", role: .destructive) { confirmingUnpair = true }
                        .foregroundStyle(Theme.red)
                        .accessibilityIdentifier("server.unpair")
                } footer: {
                    Text("Unpairing keeps every original on the server and every compact copy in Photos.")
                }
                .listRowBackground(Theme.card)
            }
        }
        .homespunList()
        .navigationTitle(server.name)
        .sheet(isPresented: $showingIdentity) {
            IdentityProblemView(settings: settings) { settingUp = true }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    // On the list: replaces what's open beside it (on a phone the stack is at the list anyway).
                    Button { path = [.check] } label: { Label("Server Check", systemImage: "checkmark.shield") }
                    Button { path = [.addDevice] } label: { Label("Add Device", systemImage: "plus") }
                        .accessibilityIdentifier("settings.addDevice")
                    if !settings.isDemo {
                        Button { confirmingSwitch = true } label: {
                            Label("Switch Server", systemImage: "arrow.left.arrow.right")
                        }
                        .accessibilityIdentifier("server.switch")
                        Button(role: .destructive) { confirmingUnpair = true } label: {
                            Label("Unpair", systemImage: "minus.circle")
                        }
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

    private func unpaired(selection: Binding<Route?>?) -> some View {
        List(selection: selection) {
            if model.settings.isDemo { DemoCard() }
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
            if ReleaseFeatures.premium { backupsSection }
            thisIPhoneSection
        }
        .homespunList()
        .perfScrollTracking()
        .navigationTitle("Server")
        .task { await loadNotifications() }
    }

    // MARK: Sections

    /// Automatic mode and cloud copies: the same rows with or without the purchase, which each page
    /// asks for when the feature is turned on.
    private var backupsSection: some View {
        Section("Backups") {
            ForEach(PremiumFeature.backupFeatures) { feature in
                let route = feature == .automatic ? Route.automatic : .connectors
                NavigationLink(value: route) {
                    ServerRow(title: feature.name, symbol: feature.symbol,
                              value: feature == .automatic ? automaticValue : cloudValue)
                }
                .disabled(feature == .cloudCopies && !model.settings.isPaired)
                .accessibilityIdentifier(feature == .automatic ? "settings.automatic" : "settings.connectors")
                .sidebarRow(route)
            }
        }
        .listRowBackground(Theme.card)
    }

    private var thisIPhoneSection: some View {
        Section("This iPhone") {
            // Its name on the server, which names its originals folder there too.
            if model.settings.isPaired {
                NavigationLink(value: Route.deviceName) {
                    ServerRow(title: "Name", symbol: "iphone", value: model.settings.pairingName)
                }
                .accessibilityIdentifier("settings.deviceName")
                .sidebarRow(Route.deviceName)
            }
            NavigationLink(value: Route.notifications) {
                ServerRow(title: "Notifications", symbol: "bell", value: notificationsValue)
            }
            .accessibilityIdentifier("settings.notifications")
            .sidebarRow(Route.notifications)
            NavigationLink(value: Route.wake) {
                ServerRow(title: "Background Wakeups", symbol: "antenna.radiowaves.left.and.right",
                          value: model.settings.isDemo ? "Off in the demo" : nil)
            }
            .accessibilityIdentifier("settings.wake")
            .sidebarRow(Route.wake)
            NavigationLink(value: Route.analytics) {
                ServerRow(title: "Share Analytics", symbol: "chart.bar",
                          value: model.settings.isDemo ? "Off in the demo" : Telemetry.shared.isSharing ? "On" : "Off")
            }
            .accessibilityIdentifier("settings.analytics")
            .sidebarRow(Route.analytics)
            if ReleaseFeatures.premium {
                NavigationLink(value: Route.premium) {
                    ServerRow(title: "Premium", symbol: "sparkles",
                              value: model.premium.isUnlocked ? "Unlocked" : nil)
                }
                .accessibilityIdentifier("settings.premium")
                .sidebarRow(Route.premium)
            }
            NavigationLink(value: Route.help) {
                ServerRow(title: "Help and About", symbol: "questionmark.circle", value: nil)
            }
            .accessibilityIdentifier("settings.help")
            .sidebarRow(Route.help)
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
        case .automatic:
            if ReleaseFeatures.automaticMode { AutomaticModeView(model: model) }
        case .connectors:
            if PremiumFeature.cloudCopies.isAvailable {
                ConnectorsView(settings: settings, premium: model.premium) { cloud = $0 }
            }
        case .compactCopies: CompactCopiesView(server: settings.server)
        case .devices: DevicesView(settings: settings, rename: { path.append(.deviceName) }) { path.append(.addDevice) }
        case .deviceName: nameEditor
        case .addDevice: AddDeviceView(settings: settings)
        case .notifications: NotificationsView(model: model)
        case .wake: WakeSettingsView(enrollment: WakeSystem.enrollment, demo: settings.isDemo)
        case .premium:
            if ReleaseFeatures.premium { PremiumView(premium: model.premium, model: model) }
        case .help: HelpAboutView(model: model)
        case .analytics: AnalyticsSettingsView(demo: settings.isDemo)
        }
    }

    private var nameEditor: DeviceNameView {
        let draft = nameDraft
        return DeviceNameView(settings: model.settings, draft: draft, renamed: { updated in
            thisDevice = updated
            devices = devices?.map { $0.isThisDevice ? updated : $0 }
        }, close: {
            guard nameDraft === draft, path.last == .deviceName else { return }
            path.removeLast()
        })
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

    private var automaticValue: String {
        let automatic = model.automatic
        return AutomaticMode.status(on: automatic.enabled && model.premium.isUnlocked, lastRun: automatic.state.lastRun)
    }

    private var cloudValue: String? {
        guard model.settings.isPaired else { return "Off" }
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
        // Beside the server's answers, not before them: iOS can take a while to answer this.
        async let notifications: Void = loadNotifications()
        guard model.settings.serverStatus == .reachable, let client = model.settings.client else {
            if model.settings.serverStatus == .unknown { await model.settings.refreshServerInfo() }
            return
        }
        async let storage = try? client.storage()
        async let report = try? client.setup()
        async let devices = try? client.devices()
        async let cloud = loadCloud(client)
        let (newStorage, newReport, newDevices, newCloud) = await (storage, report, devices, cloud)
        self.storage = newStorage ?? self.storage
        checks = newReport?.checks ?? checks
        self.devices = newDevices ?? self.devices
        thisDevice = newDevices?.first(where: \.isThisDevice) ?? thisDevice
        if let device = thisDevice { model.settings.confirmDeviceName(device.name) }
        self.cloud = newCloud ?? self.cloud
        await notifications
    }

    private func loadCloud(_ client: ServerClient) async -> [ServerAPI.ConnectorInfo]? {
        guard ReleaseFeatures.cloudCopies else { return nil }
        return try? await client.connectors()
    }

    private func loadNotifications() async {
        guard !model.settings.isDemo else { return }
        // Off the main thread: the first call sets up the notification framework.
        notifications = await Task.detached(priority: .userInitiated) {
            await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        }.value
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
        thisDevice = nil
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
        // The value beside the title when both fit; else under it (the open iPhone Duo's sidebar, large
        // text), never cut short.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                icon
                Text(title).foregroundStyle(Theme.label).lineLimit(1)
                Spacer(minLength: 8)
                if let value { Text(value).foregroundStyle(valueTint).lineLimit(1) }
                disclosure
            }
            HStack(spacing: 14) {
                icon
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(Theme.label)
                    if let value { Text(value).font(.subheadline).foregroundStyle(valueTint) }
                }
                Spacer(minLength: 0)
                disclosure
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var icon: some View {
        Image(systemName: symbol).font(.body).foregroundStyle(Theme.accent).frame(width: 28).accessibilityHidden(true)
    }

    @ViewBuilder private var disclosure: some View {
        if chevron {
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Theme.tertiaryLabel)
                .accessibilityHidden(true)
        }
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
        case .identityProblem, .needsServerUpdate: "Needs attention"
        case .securing: "Securing…"
        case .checking, .unknown: "Checking…"
        }
    }

    private var statusTint: Color {
        switch status {
        case .reachable: Theme.teal
        case .unreachable, .identityProblem, .needsServerUpdate: Theme.amber
        case .checking, .unknown, .securing: Theme.secondaryLabel
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
