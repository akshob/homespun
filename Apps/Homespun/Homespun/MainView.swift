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
        .onOpenURL { url in
            if let link = PairingLink(url) { settings.pendingLink = link }
        }
        .onChange(of: model.job.items.map(\.state.phase)) { _, _ in Task { await model.library.jobChanged() } }
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
                SessionMarker.shared.active()
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
    @State private var libraryRoute = LibraryRoute.overview
    @SceneStorage("library.showsPage") private var showsPage = true
    @Environment(\.horizontalSizeClass) private var sizeClass

    enum Sheet: Identifiable {
        case freeUp(only: Set<String>?)
        case backUp([String])
        case pair(PairingLink)
        case report
        var id: String {
            switch self {
            case .report: "report"
            case .freeUp: "freeUp"
            case .backUp: "backUp"
            case .pair(let link): link.id
            }
        }
    }

    var body: some View {
        @Bindable var settings = model.settings
        TabView(selection: $tab) {
            Tab("Library", systemImage: "photo.on.rectangle", value: TabID.library) {
                LibraryView(model: model, freeUp: { sheet = .freeUp(only: $0) }, route: $libraryRoute)
            }
            .accessibilityIdentifier("tab.library")
            Tab("Activity", systemImage: "clock.arrow.circlepath", value: TabID.activity) {
                ActivityTab(model: model, freeUp: { openFreeUp(nil) })
            }
            .accessibilityIdentifier("tab.activity")
            Tab("Server", systemImage: "server.rack", value: TabID.server) {
                ServerTab(model: model)
            }
            .accessibilityIdentifier("tab.server")
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .modifier(StatusAccessoryModifier(model: model, open: openFromAccessory))
        .alert("Homespun quit unexpectedly", isPresented: Binding(get: { SessionMarker.shared.offersReport && sheet == nil },
                                                                   set: { if !$0 { SessionMarker.shared.offersReport = false } })) {
            Button("Report a Problem") { sheet = .report }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text("Telling the developer what you were doing helps fix it.")
        }
        .sheet(item: $sheet, onDismiss: dismissed) { sheet in
            switch sheet {
            case .report:
                NavigationStack {
                    ReportProblemView(model: model, afterCrash: true)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Cancel", systemImage: "xmark") { self.sheet = nil }
                            }
                        }
                }
            case .freeUp(let scope):
                FreeUpSpaceSheet(controller: model.library, scope: scope)
            case .backUp(let ids):
                BackUpSheet(controller: model.library, identifiers: ids) {}
            case .pair(let link):
                PairConfirmView(settings: model.settings, link: link) {}
            }
        }
        .onChange(of: settings.pendingLink, initial: true) { _, link in
            if let link { sheet = .pair(link) }
        }
        .task {
            await model.library.start()
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-deleteNewestBackedUp") {
                await model.library.deleteNewestBackedUpForTesting()
            }
            #endif
        }
    }

    /// On the open iPhone Duo, Free Up Space is the Library's right page; elsewhere a sheet.
    private func openFreeUp(_ scope: Set<String>?) {
        if sizeClass == .regular, showsPage, model.library.access.allowsReading {
            tab = .library
            libraryRoute = .review(scope)
        } else {
            sheet = .freeUp(only: scope)
        }
    }

    private func openFromAccessory(_ action: StatusAccessory.Action) {
        switch action {
        case .freeUp(let scope): openFreeUp(scope)
        case .activity: tab = .activity
        case .server: tab = .server
        case .backUpNew:
            let ids = model.library.newItems
            if ids.count > 200 { sheet = .backUp(ids) } else { model.library.backUp(ids) }
        }
    }

    private func dismissed() {
        model.settings.pendingLink = nil
        model.library.dismissRemoval()
        Task { await model.library.refresh() }
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
