// SPDX-License-Identifier: Apache-2.0
import HomespunCore
import Photos
import SwiftUI

/// Setup until it's done, then the three tabs. Handles what belongs to the whole app: pairing
/// links, coming back to the foreground, and the job's progress.
struct RootView: View {
    let model: AppModel
    @Environment(\.scenePhase) private var scenePhase

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
            if !running { Task { await model.library.jobFinished() } }
        }
        .onChange(of: settings.onboardingComplete) { _, _ in Task { await model.library.refresh() } }
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
                Task {
                    await model.library.refresh()
                    await model.library.runAutomatic()
                }
            case .background: model.automatic.schedule()
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

    enum Sheet: Identifiable {
        case freeUp(only: Set<String>?)
        case pair(PairingLink)
        var id: String {
            switch self {
            case .freeUp: "freeUp"
            case .pair(let link): link.id
            }
        }
    }

    var body: some View {
        @Bindable var settings = model.settings
        TabView(selection: $tab) {
            Tab("Library", systemImage: "photo.on.rectangle", value: TabID.library) {
                LibraryView(model: model, freeUp: { sheet = .freeUp(only: $0) })
            }
            .accessibilityIdentifier("tab.library")
            Tab("Activity", systemImage: "clock.arrow.circlepath", value: TabID.activity) {
                ActivityTab(model: model, freeUp: { sheet = .freeUp(only: nil) })
            }
            .accessibilityIdentifier("tab.activity")
            Tab("Server", systemImage: "server.rack", value: TabID.server) {
                ServerTab(model: model)
            }
            .accessibilityIdentifier("tab.server")
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .modifier(StatusAccessoryModifier(model: model, open: openFromAccessory))
        .sheet(item: $sheet, onDismiss: dismissed) { sheet in
            switch sheet {
            case .freeUp(let scope):
                FreeUpSpaceSheet(controller: model.library, scope: scope)
            case .pair(let link):
                PairConfirmView(settings: model.settings, link: link) {}
            }
        }
        .onChange(of: settings.pendingLink, initial: true) { _, link in
            if let link { sheet = .pair(link) }
        }
        .task { await model.library.start() }
    }

    private func openFromAccessory(_ action: StatusAccessory.Action) {
        switch action {
        case .freeUp(let scope): sheet = .freeUp(only: scope)
        case .activity: tab = .activity
        case .server: tab = .server
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
        let status = StatusAccessory.Status(model: model)
        if #available(iOS 26.1, *) {
            // Hidden while an item is open full screen: it would cover the item's toolbar.
            content.tabViewBottomAccessory(isEnabled: status != nil && !ItemPresence.shared.isOpen) {
                StatusAccessory(status: status, open: open)
            }
        } else {
            content.tabViewBottomAccessory { StatusAccessory(status: status, open: open) }
        }
    }
}

/// One line about what matters now, above the tab bar: a running backup, then a problem, then
/// space ready to free up (DESIGN 02·1.1).
struct StatusAccessory: View {
    enum Action { case freeUp(Set<String>?), activity, server }

    enum Status: Equatable {
        case backingUp(done: Int, total: Int, current: String?)
        case removing(String)
        case unreachable(String)
        case finished(count: Int, bytes: Int, originals: Set<String>)
        case ready(count: Int, bytes: Int)

        @MainActor init?(model: AppModel) {
            let job = model.job, library = model.library
            if case .checking(let message) = library.removal {
                self = .removing(message)
            } else if job.isRunning {
                let open = job.items.filter { $0.state == .waiting || $0.isWorking }
                let total = job.items.count
                self = .backingUp(done: total - open.count, total: total,
                                  current: job.items.first(where: \.isWorking)?.name)
            } else if model.settings.isPaired, case .unreachable = model.settings.serverStatus {
                self = .unreachable(model.settings.server?.name ?? "your server")
            } else if let finished = library.finished {
                self = .finished(count: finished.count, bytes: finished.bytes, originals: Set(finished.originals))
            } else if library.ready.count > 0 {
                self = .ready(count: library.ready.count, bytes: library.ready.bytes)
            } else {
                return nil
            }
        }
    }

    let status: Status?
    let open: (Action) -> Void
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        Group {
            switch status {
            case .backingUp(let done, let total, let current):
                row(icon: "arrow.up.circle", title: "Backing up \(min(done + 1, total)) of \(total)",
                    detail: current, button: nil) { open(.activity) }
                    .accessibilityIdentifier("job.progress")
            case .removing(let message):
                row(icon: "checkmark.shield", title: "Freeing up space", detail: message, button: nil) {}
                    .accessibilityIdentifier("remove.progress")
            case .unreachable(let name):
                row(icon: "wifi.exclamationmark", title: "Can't reach \(name)",
                    detail: "Is this iPhone on your home Wi‑Fi?", button: "Retry") { open(.server) }
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
            case nil:
                Label("Everything's up to date", systemImage: "checkmark.circle").font(.subheadline)
                    .foregroundStyle(Theme.secondaryLabel).frame(maxWidth: .infinity)
            }
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
