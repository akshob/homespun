// SPDX-License-Identifier: Apache-2.0
import HomespunCore
import Photos
import SwiftUI

/// Setup until it's done, then the three tabs. Handles what belongs to the whole app: pairing
/// links, coming back to the foreground, and the job's progress.
struct RootView: View {
    let model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    /// A session starts when the app comes back from the background (or launches).
    @State private var wasBackground = true

    var body: some View {
        @Bindable var settings = model.settings
        Group {
            if settings.onboardingComplete {
                MainTabView(model: model)
            } else {
                OnboardingView(settings: settings, library: model.library)
            }
        }
        .tint(Theme.accent)
        .overlay(alignment: .topLeading) { PerfMonitorLabel() }
        .modifier(QuitUnexpectedly(model: model))
        .onChange(of: scenePhase, initial: true) { _, phase in
            // From the first moment on screen (onChange alone misses the launch).
            if phase == .active { SessionMarker.shared.active() }
        }
        .onOpenURL { url in
            if let link = PairingLink(url) {
                settings.pendingLink = link
            } else if let link = AppLink(url) {
                model.router.pending = link
            }
        }
        // Each item's phase, not its progress messages: badges change only when the phase does.
        .onChange(of: model.job.phaseVersion) { _, _ in model.library.jobChanged() }
        .onChange(of: model.job.isRunning) { _, running in
            if !running {
                Task {
                    await model.library.jobFinished()
                    await Telemetry.shared.flush()
                }
            }
        }
        .onChange(of: settings.onboardingComplete) { _, done in
            if done { model.library.journey.setupFinished() }
            Task { await model.library.refresh() }
        }
        .onChange(of: model.copyFinder.checked) { _, _ in
            Task {
                await model.library.refreshGrid()
                await model.library.refreshReady()
            }
        }
        .onChange(of: model.automatic.enabled) { _, on in
            if on { Task { await model.library.runAutomatic() } }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                if wasBackground {
                    wasBackground = false
                    model.library.journey.sessionStarted()
                }
                Task {
                    await model.library.refresh()
                    await model.library.runAutomatic()
                }
                // What an earlier session queued (it may have ended without reaching the background).
                Task {
                    try? await Task.sleep(for: .seconds(5))
                    await Telemetry.shared.flush()
                }
            case .background:
                wasBackground = true
                SessionMarker.shared.background()
                model.automatic.schedule()
                Telemetry.shared.flushInBackground()
            default: break
            }
        }
    }
}

/// Library, Activity and Server, with the status accessory above the tab bar (DESIGN §5).
struct MainTabView: View {
    enum TabID: String, Hashable { case library, activity, server }

    let model: AppModel
    @SceneStorage("tab") private var tab = TabID.library
    @State private var sheet: Sheet?
    /// Free Up Space on the open iPhone Duo: the whole screen (a sheet everywhere else).
    @State private var cover: Cover?
    @Environment(\.horizontalSizeClass) private var sizeClass

    enum Cover: Identifiable {
        case freeUp(Set<String>?)
        var id: String { "freeUp" }
    }

    enum Sheet: Identifiable {
        case freeUp(only: Set<String>?)
        case backUp([String])
        case pair(PairingLink)
        /// A Premium feature asked for while locked (a widget's Unlock).
        case unlock(PremiumFeature)
        var id: String {
            switch self {
            case .freeUp: "freeUp"
            case .backUp: "backUp"
            case .pair(let link): link.id
            case .unlock(let feature): "unlock." + feature.rawValue
            }
        }
    }

    var body: some View {
        @Bindable var settings = model.settings
        // The tab span starts as the selection changes (a tab's onAppear runs before onChange).
        TabView(selection: Binding(get: { tab }, set: { new in
            if new != tab { PerfMonitor.shared.begin("tab") }
            // Library tapped again: the newest items, like Photos (the grid's top is the oldest).
            if new == tab, new == .library { model.library.newestRequests &+= 1 }
            tab = new
        })) {
            Tab("Library", systemImage: "photo.on.rectangle", value: TabID.library) {
                LibraryView(model: model, freeUp: { openFreeUp($0) })
                    .onAppear { PerfMonitor.shared.endAfterFrame("tab") }
            }
            .accessibilityIdentifier("tab.library")
            Tab("Activity", systemImage: "clock.arrow.circlepath", value: TabID.activity) {
                ActivityTab(model: model, freeUp: { openFreeUp(nil) })
                    .onAppear { PerfMonitor.shared.endAfterFrame("tab") }
            }
            .accessibilityIdentifier("tab.activity")
            Tab("Server", systemImage: "server.rack", value: TabID.server) {
                ServerTab(model: model)
                    .onAppear { PerfMonitor.shared.endAfterFrame("tab") }
            }
            .accessibilityIdentifier("tab.server")
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        // Get Started's Choose Items opens the Library (in Select mode).
        .onChange(of: model.library.choosePending, initial: true) { _, pending in if pending { tab = .library } }
        .modifier(StatusAccessoryModifier(model: model, open: openFromAccessory))
        .fullScreenCover(item: $cover, onDismiss: dismissed) { cover in
            switch cover {
            case .freeUp(let scope): FreeUpSpaceScreen(controller: model.library, scope: scope)
            }
        }
        .sheet(item: $sheet, onDismiss: dismissed) { sheet in
            switch sheet {
            case .freeUp(let scope):
                FreeUpSpaceScreen(controller: model.library, scope: scope)
            case .backUp(let ids):
                BackUpSheet(controller: model.library, identifiers: ids) {}
            case .pair(let link):
                PairConfirmView(settings: model.settings, link: link) {}
            case .unlock(let feature):
                PremiumFeatureSheet(feature: feature, premium: model.premium) {
                    self.sheet = nil
                    tab = .server
                    model.router.serverRoute = .premium
                }
            }
        }
        .onChange(of: settings.pendingLink, initial: true) { _, link in
            if let link { sheet = .pair(link) }
        }
        .onChange(of: model.router.pending, initial: true) { _, link in
            guard let link else { return }
            model.router.pending = nil
            open(link)
        }
        .task {
            await model.library.start()
            model.status.start()
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-deleteNewestBackedUp") {
                await model.library.deleteNewestBackedUpForTesting()
            }
            #endif
        }
    }

    /// Free Up Space: a sheet on a phone and iPhone Duo's cover; the whole screen on the open Duo,
    /// for comparing side by side. Decided when it opens: folding or unfolding later changes its
    /// layout, never its presentation (that would interrupt a removal).
    private func openFreeUp(_ scope: Set<String>?) {
        if sizeClass == .regular { cover = .freeUp(scope) } else { sheet = .freeUp(only: scope) }
    }

    /// Where a widget's link leads.
    private func open(_ link: AppLink) {
        switch link {
        case .freeUp: openFreeUp(nil)
        case .activity: tab = .activity
        case .server: tab = .server
        case .automatic:
            tab = .server
            model.router.serverRoute = .automatic
        case .unlock(let feature):
            if model.premium.isUnlocked {
                tab = .server
                model.router.serverRoute = .premium
            } else {
                sheet = .unlock(PremiumFeature(rawValue: feature) ?? .widgets)
            }
        }
    }

    private func openFromAccessory(_ action: StatusAccessory.Action) {
        switch action {
        case .freeUp(let scope): openFreeUp(scope)
        case .activity: tab = .activity
        case .server: tab = .server
        case .backUpNew:
            Task {
                let ids = await model.library.newItems()
                if ids.count > 200 { sheet = .backUp(ids) } else { model.library.backUp(ids) }
            }
        }
    }

    private func dismissed() {
        model.settings.pendingLink = nil
        model.library.dismissRemoval()
        Task { await model.library.refresh() }
    }
}

/// After Homespun quit while on screen: asks once whether to report it (in setup, too).
private struct QuitUnexpectedly: ViewModifier {
    let model: AppModel
    @State private var reporting = false

    func body(content: Content) -> some View {
        content
            .alert("Homespun quit unexpectedly", isPresented: Binding(get: { SessionMarker.shared.offersReport && !reporting },
                                                                       set: { if !$0 { SessionMarker.shared.offersReport = false } })) {
                Button("Report a Problem") { reporting = true }
                Button("Not Now", role: .cancel) {}
            } message: {
                Text("Telling the developer what you were doing helps fix it.")
            }
            .sheet(isPresented: $reporting) {
                NavigationStack {
                    ReportProblemView(model: model, afterCrash: true)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Cancel", systemImage: "xmark") { reporting = false }
                            }
                        }
                }
            }
    }
}

/// The bottom accessory exists only when there's something to say (26.1 and later); on 26.0 it
/// stays, showing a quiet summary.
private struct StatusAccessoryModifier: ViewModifier {
    let model: AppModel
    let open: (StatusAccessory.Action) -> Void

    func body(content: Content) -> some View {
        let status = AccessoryLadder.pick(model.library.accessoryInputs)
        if #available(iOS 26.1, *) {
            // Hidden while an item is open full screen or the Library is selecting: it would cover
            // their bottom toolbar (the item's actions, Select mode's Back Up).
            content.tabViewBottomAccessory(isEnabled: status != nil && !ItemPresence.shared.isOpen
                                           && !model.library.isSelecting) {
                StatusAccessory(status: status, serverName: model.library.serverName, open: open)
            }
        } else {
            content.tabViewBottomAccessory {
                StatusAccessory(status: status, serverName: model.library.serverName, open: open)
            }
        }
    }
}

/// One line about what matters now, above the tab bar: the highest state on the ladder
/// (DESIGN 02·1.1, §16.4).
struct StatusAccessory: View {
    enum Action { case freeUp(Set<String>?), activity, server, backUpNew }

    let status: AccessoryLadder.State?
    var serverName = "your computer"
    let open: (Action) -> Void
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        switch status {
        case .unreachable(let name):
            row(icon: "wifi.exclamationmark", title: "Can't reach \(name)",
                detail: "Is this iPhone on your home Wi‑Fi?", button: "Retry") { open(.server) }
                .accessibilityIdentifier("accessory.unreachable")
        case .removing(let message):
            row(icon: "checkmark.shield", title: "Freeing up space", detail: message, button: nil) {}
                .accessibilityIdentifier("remove.progress")
        case .backingUp(let done, let total, let current):
            row(icon: "arrow.up.circle", title: "Backing up \(min(done + 1, total)) of \(total)",
                detail: current, button: nil) { open(.activity) }
                .accessibilityIdentifier("job.progress")
        case .almostFull(let bytes):
            row(icon: "exclamationmark.triangle.fill", title: "This iPhone is almost full",
                detail: "Free up \(LibraryController.bytes(bytes)) here", button: "Free Up") { open(.freeUp(nil)) }
                .accessibilityIdentifier("accessory.almostFull")
        case .finished(let count, let bytes, let originals):
            row(icon: "checkmark.circle.fill", title: "\(count) backed up",
                detail: "Free up \(LibraryController.bytes(bytes)) on this iPhone", button: "Free Up") {
                open(.freeUp(originals))
            }
            .accessibilityIdentifier("offer.free")
        case .ready(let count, let bytes):
            row(icon: "circle.lefthalf.filled", title: "\(count) ready to free up",
                detail: "\(LibraryController.bytes(bytes)) on this iPhone", button: "Free Up") { open(.freeUp(nil)) }
                .accessibilityIdentifier("remove.originals")
        case .newPhotos(let count):
            row(icon: "photo.badge.plus", title: "\(count.formatted()) new since your last backup",
                detail: nil, button: "Back Up") { open(.backUpNew) }
                .accessibilityIdentifier("accessory.new")
        case nil:
            Label("Everything's up to date", systemImage: "checkmark.circle").font(.subheadline)
                .foregroundStyle(Theme.secondaryLabel).frame(maxWidth: .infinity)
        }
    }

    private func row(icon: String, title: String, detail: String?, button: String?,
                     action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.body.weight(.semibold)).foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                if let detail, placement != .inline {
                    Text(detail).font(.caption).foregroundStyle(Theme.secondaryLabel).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let button {
                Button(button, action: action).buttonStyle(.glassProminent).tint(Theme.accent).controlSize(.small)
                    .accessibilityIdentifier("accessory.action")
                    .popoverTip(button == "Free Up" ? FreeUpTip(server: serverName) : nil)
            }
        }
        .padding(.horizontal, 14)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: button ?? title, action)
    }
}
