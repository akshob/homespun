// SPDX-License-Identifier: Apache-2.0
import HomespunCore
import Photos
import SwiftUI

/// Setup until it's done, then the three tabs. Handles what belongs to the whole app: pairing
/// links and coming back to the foreground.
struct RootView: View {
    let model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    /// A session starts when the app comes back from the background (or launches).
    @State private var wasBackground = true
    /// A pairing link opened while the demo is on.
    @State private var linkInDemo = false

    var body: some View {
        let _ = RenderProbe.count("render.root")
        @Bindable var settings = model.settings
        Group {
            if settings.onboardingComplete {
                MainTabView(model: model)
            } else {
                OnboardingView(settings: settings, library: model.library)
            }
        }
        .tint(Theme.accent)
        .task {
            if !settings.isDemo { await model.status?.clearDepartedDemo() }
            if settings.isPaired { await model.job.refreshQueue() }
        }
        .overlay(alignment: .topLeading) { PerfMonitorLabel() }
        .modifier(QuitUnexpectedly(model: model))
        .task {
            #if DEBUG
            guard ProcessInfo.processInfo.arguments.contains("-probeServerStatus") else { return }
            while !Task.isCancelled {
                await model.settings.refreshServerInfo()
                try? await Task.sleep(for: .seconds(5))
            }
            #endif
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            model.job.setVisible(phase == .active)
            // From the first moment on screen (onChange alone misses the launch).
            if phase == .active {
                SessionMarker.shared.active()
                Task { await settings.refreshServerInfo() }
            }
        }
        .onOpenURL { url in
            ItemViewerPresence.shared.close(animated: false) {
                if let link = PairingLink(url) {
                    // The demo pairs only with its pretend server: a link is for the person's own Homespun.
                    if settings.isDemo { linkInDemo = true } else { settings.pendingLink = link }
                } else if let link = AppLink(url), link.isAvailable {
                    model.router.pending = link
                }
            }
        }
        .alert("You're in the demo", isPresented: $linkInDemo) {
            Button("Stay in the Demo", role: .cancel) {}
            Button("Leave the Demo") { DemoMode.shared.leave() }
        } message: {
            Text("Leave the demo, then open the pairing link again to pair your own server.")
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
                if !settings.isDemo { AppModel.schedulePendingBackup() }
                model.status?.publishInBackground()
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
    @State private var freeUp: FreeUpRequest?
    @Environment(\.horizontalSizeClass) private var sizeClass

    enum Sheet: Identifiable {
        case backUp([String])
        case pair(PairingLink)
        /// The purchase, from a locked widget's tap (`homespun://unlock?feature=widgets`).
        case unlock(PremiumFeature)
        var id: String {
            switch self {
            case .backUp: "backUp"
            case .pair(let link): link.id
            case .unlock(let feature): "unlock." + feature.rawValue
            }
        }
    }

    var body: some View {
        let _ = RenderProbe.count("render.mainTab")
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
                    .equatable()
                    .onAppear { PerfMonitor.shared.endAfterFrame("tab") }
            }
            .accessibilityIdentifier("tab.library")
            Tab("Activity", systemImage: "clock.arrow.circlepath", value: TabID.activity) {
                ActivityTab(model: model, freeUp: { openFreeUp(nil) })
                    .modifier(StatusAccessoryScrollInset())
                    .onAppear { PerfMonitor.shared.endAfterFrame("tab") }
            }
            .accessibilityIdentifier("tab.activity")
            Tab("Server", systemImage: "server.rack", value: TabID.server) {
                ServerTab(model: model)
                    .modifier(StatusAccessoryScrollInset())
                    .onAppear { PerfMonitor.shared.endAfterFrame("tab") }
            }
            .accessibilityIdentifier("tab.server")
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        // Get Started's Choose Items opens the Library (in Select mode).
        .onChange(of: model.library.choosePending, initial: true) { _, pending in
            if pending { ItemViewerPresence.shared.close(animated: false) { tab = .library } }
        }
        .modifier(StatusAccessoryModifier(model: model, open: openFromAccessory))
        .modifier(FreeUpPresentation(model: model, request: $freeUp, onDismiss: { model.settings.pendingLink = nil }))
        .sheet(item: $sheet, onDismiss: dismissed) { sheet in
            switch sheet {
            case .backUp(let ids):
                BackUpSheet(controller: model.library, identifiers: ids) {}
            case .pair(let link):
                PairConfirmView(settings: model.settings, link: link) {}
            case .unlock(let feature):
                // Once unlocked the widgets fill in on their own (StatusPublisher): nothing to carry on with.
                if ReleaseFeatures.premium {
                    UnlockSheet(feature: feature, premium: model.premium, server: model.library.serverName) {}
                }
            }
        }
        .onChange(of: settings.pendingLink, initial: true) { _, link in
            if let link { ItemViewerPresence.shared.close(animated: false) { sheet = .pair(link) } }
        }
        .onChange(of: model.router.pending, initial: true) { _, link in
            guard let link else { return }
            model.router.pending = nil
            ItemViewerPresence.shared.close(animated: false) { open(link) }
        }
        .task {
            await model.library.start { model.status?.start() }
        }
        #if DEBUG
        .task {
            if ProcessInfo.processInfo.arguments.contains("-deleteNewestBackedUp") {
                await model.library.deleteNewestBackedUpForTesting()
            }
        }
        #endif
    }

    /// Free Up Space: a sheet on a phone and iPhone Duo's cover; the whole screen on the open Duo,
    /// for comparing side by side. Decided when it opens: folding or unfolding later changes its
    /// layout, never its presentation (that would interrupt a removal).
    private func openFreeUp(_ scope: Set<String>?) {
        freeUp = FreeUpRequest(scope: scope, wide: sizeClass == .regular)
    }

    /// Where a widget's link leads.
    private func open(_ link: AppLink) {
        guard link.isAvailable else { return }
        switch link {
        case .freeUp: openFreeUp(nil)
        case .activity: tab = .activity
        case .server: tab = .server
        case .automatic:
            tab = .server
            model.router.serverRoute = .automatic
        case .unlock(let feature):
            // Opened from a widget at launch: Premium may not have been checked yet.
            Task {
                await model.premium.refresh()
                if model.premium.isUnlocked {
                    tab = .server
                    model.router.serverRoute = .premium
                } else {
                    let requested = PremiumFeature(rawValue: feature) ?? .widgets
                    sheet = .unlock(requested.isAvailable ? requested : .widgets)
                }
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

struct FreeUpRequest: Identifiable {
    let id = UUID()
    let scope: Set<String>?
    let wide: Bool
}

/// Choose once on opening: folding changes the layout, not the presentation.
struct FreeUpPresentation: ViewModifier {
    let model: AppModel
    @Binding var request: FreeUpRequest?
    var onDismiss: () -> Void = {}

    func body(content: Content) -> some View {
        content
            .fullScreenCover(item: presentation(wide: true), onDismiss: dismissed) {
                FreeUpSpaceScreen(controller: model.library, scope: $0.scope)
            }
            .sheet(item: presentation(wide: false), onDismiss: dismissed) {
                FreeUpSpaceScreen(controller: model.library, scope: $0.scope)
            }
    }

    private func presentation(wide: Bool) -> Binding<FreeUpRequest?> {
        Binding(get: { request?.wide == wide ? request : nil }, set: { request = $0 })
    }

    private func dismissed() {
        model.library.dismissRemoval()
        Task { await model.library.refresh() }
        onDismiss()
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

/// One line about what matters now, above the tab bar: the highest state on the ladder
/// (DESIGN 02·1.1, §16.4).
struct StatusAccessory: View {
    enum Action { case freeUp(Set<String>?), activity, server, backUpNew }

    let status: AccessoryLadder.State?
    var serverName = "your computer"
    let width: CGFloat
    let open: (Action) -> Void
    let currentFreeUpOffer: () -> AccessoryLadder.Offer?
    @Environment(\.showsTips) private var showsTips

    var body: some View {
        switch status {
        case .unreachable(let name):
            row(icon: "wifi.exclamationmark", title: "Can't reach \(name)",
                detail: "Is this iPhone on your home Wi‑Fi?", button: "Retry") { open(.server) }
                .accessibilityIdentifier("accessory.unreachable")
        case .removing(let message):
            row(icon: "checkmark.shield", title: "Freeing up space", detail: message, button: nil) {}
                .accessibilityIdentifier("remove.progress")
        case .backingUp(let done, let total, let current, let offer):
            backingUp(done: done, total: total, detail: current ?? "Waiting to continue", offer: offer)
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

    private func backingUp(done: Int, total: Int, detail: String, offer: AccessoryLadder.Offer?) -> some View {
        HStack(spacing: 10) {
            Button { open(.activity) } label: {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.up.circle").font(.body.weight(.semibold)).foregroundStyle(Theme.accent)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Backing up \(min(done + 1, total)) of \(total)").font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(detail).font(.caption).foregroundStyle(Theme.secondaryLabel).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("job.progress")
            .accessibilityHint("Shows detailed backup progress in Activity.")
            if let offer {
                Button("Free Up") {
                    guard let current = currentFreeUpOffer(), let originals = current.originals, !originals.isEmpty else { return }
                    open(.freeUp(originals))
                }
                .buttonStyle(.glassProminent).tint(Theme.accent).controlSize(.small)
                .accessibilityIdentifier("accessory.action")
                .accessibilityLabel("Free Up, \(offer.count) ready, \(LibraryController.bytes(offer.bytes))")
                .accessibilityHint("Review the current ready originals. Nothing is removed yet.")
                .popoverTip(showsTips ? FreeUpTip(server: serverName) : nil)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: width)
        .accessibilityElement(children: .contain)
    }

    private func row(icon: String, title: String, detail: String?, button: String?,
                     action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.body.weight(.semibold)).foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(Theme.secondaryLabel).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let button {
                Button(button, action: action).buttonStyle(.glassProminent).tint(Theme.accent).controlSize(.small)
                    .accessibilityIdentifier("accessory.action")
                    .popoverTip(button == "Free Up" && showsTips ? FreeUpTip(server: serverName) : nil)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: width)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: button ?? title, action)
    }
}
