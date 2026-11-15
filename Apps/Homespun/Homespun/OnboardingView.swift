// SPDX-License-Identifier: Apache-2.0
import HomespunCore
import Photos
import SwiftUI

/// The first run (DESIGN 01, §5): find or set up the home computer, pair, see where originals go,
/// then the first task on the 10 newest. Also opened as a sheet from the Library's Set Up notice
/// (it starts at looking, and closes itself when done) and from the Server tab (pairing only).
struct OnboardingView: View {
    @Bindable var settings: AppSettings
    /// Runs the first task once paired.
    var library: LibraryController?
    /// Starts somewhere other than Welcome (or Looking, from the Library).
    var start: SetupFlow.Page?
    /// Ends once paired and checked, with no first task (the Server tab's Connect).
    var pairOnly = false
    /// Opens Compare for an original (01·1.13); the Compare button is hidden while this is nil.
    var onCompare: ((String) -> Void)?
    /// Called when pairing finishes in `pairOnly` mode.
    var onPaired: (() -> Void)?
    @State private var flow: SetupFlow?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let flow {
                SetupNavigation(flow: flow, onCompare: onCompare)
            } else {
                Theme.background.ignoresSafeArea()
            }
        }
        .onAppear {
            guard flow == nil else { return }
            let flow = SetupFlow(settings: settings, library: library, start: start, pairOnly: pairOnly)
            flow.onPaired = onPaired
            // A sheet closes itself; on first run, RootView shows the tabs once setup is complete.
            flow.close = { [weak flow, dismiss] in if flow?.isSheet == true { dismiss() } }
            self.flow = flow
        }
    }
}

/// The stack of setup pages.
private struct SetupNavigation: View {
    @Bindable var flow: SetupFlow
    var onCompare: ((String) -> Void)?
    /// The compact copy the receipt's Compare opened (when the caller doesn't handle it).
    @State private var comparing: String?

    var body: some View {
        NavigationStack(path: $flow.path) {
            page(flow.root)
                .toolbar {
                    if flow.isSheet {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close", systemImage: "xmark") { flow.close() }
                                .accessibilityIdentifier("setup.close")
                        }
                    }
                }
                .navigationDestination(for: SetupFlow.Page.self) { page($0) }
        }
        .sheet(item: Binding(get: { comparing.map(ComparedItem.init) }, set: { comparing = $0?.id })) { item in
            NavigationStack {
                CompareView(model: .shared, compactIdentifier: item.id)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { comparing = nil }.accessibilityIdentifier("compare.done")
                        }
                    }
            }
            .onAppear { AppModel.shared.library.journey.used(.compare) }
        }
        .tint(Theme.accent)
        .sheet(item: $flow.link) { link in
            PairConfirmView(settings: flow.settings, link: link) { flow.paired(.link) }
        }
        // On first run setup handles links opened from other apps; as a sheet, the tabs below do.
        .modifier(PendingLinkSheet(settings: flow.settings, active: !flow.isSheet) { flow.paired(.link) })
        .onDisappear { flow.stop() }
    }

    @ViewBuilder private func page(_ page: SetupFlow.Page) -> some View {
        switch page {
        case .welcome: WelcomePage(flow: flow)
        case .welcomeBack: WelcomeBackPage(flow: flow)
        case .localNetwork: LocalNetworkPage(flow: flow)
        case .looking: LookingPage(flow: flow)
        case .found: FoundPage(flow: flow)
        case .question: QuestionPage(flow: flow)
        case .recommendation: AnswerRecommendationPage(flow: flow)
        case .notShowingUp: NotShowingUpPage(flow: flow)
        case .noneOfThese: NoneOfThesePage(flow: flow)
        case .splitRole: SplitRolePage(flow: flow)
        case .guide(.mac): MacGuidePage(flow: flow)
        case .guide(.linux): LinuxGuidePage(flow: flow)
        case .guide(.nas): NASBrandsPage(flow: flow)
        case .terminalSteps(let os): TerminalStepsPage(flow: flow, os: os)
        case .nasGuide(let brand): NASGuidePage(flow: flow, brand: brand)
        case .waiting(let machine): WaitingPage(flow: flow, machine: machine)
        case .pair(let target): PairPage(flow: flow, target: target)
        case .otherWays: OtherWaysPage(flow: flow)
        case .address: AddressPage(flow: flow)
        case .ready: ReadyPage(flow: flow)
        case .immich: ImmichIntroPage(flow: flow)
        case .immichConnect: ImmichConnectPage(flow: flow)
        case .immichExclude: ImmichExcludePage(flow: flow)
        case .immichReady: ImmichReadyPage(flow: flow)
        case .photos: PhotosPromisesPage(flow: flow)
        case .limitedPhotos: LimitedPhotosPage(flow: flow)
        case .estimate: EstimatePage(flow: flow)
        case .firstTask: FirstTaskPage(flow: flow)
        case .receipt: ReceiptPage(flow: flow, onCompare: onCompare ?? { comparing = $0 })
        case .freed: FreedPage(flow: flow)
        }
    }
}

/// A pairing link opened while setup is up (01·6.5).
private struct PendingLinkSheet: ViewModifier {
    @Bindable var settings: AppSettings
    let active: Bool
    var paired: () -> Void

    func body(content: Content) -> some View {
        if active {
            content.sheet(item: $settings.pendingLink) { link in
                PairConfirmView(settings: settings, link: link, paired: paired)
            }
        } else {
            content
        }
    }
}

// MARK: 1.1 Welcome

private struct WelcomePage: View {
    let flow: SetupFlow

    var body: some View {
        SetupScaffold(art: AnyView(ThreadArt().padding(.top, 32)), title: "Free up space. Keep every original.") {
            Text("Homespun keeps your full-quality photos and videos on your own computer, and leaves copies a fifth "
                 + "of the size in Photos.")
                .font(.body).foregroundStyle(Theme.secondaryLabel)
            Label {
                Text("An original is removed from this iPhone only after your computer proves it has an exact copy.")
                    .font(.subheadline).foregroundStyle(Theme.secondaryLabel)
            } icon: {
                Image(systemName: "checkmark.shield").foregroundStyle(Theme.accent)
            }
        } actions: {
            Text("First, Homespun looks for its server on this Wi‑Fi.")
                .font(.footnote).foregroundStyle(Theme.secondaryLabel).multilineTextAlignment(.center)
            PrimaryButton(title: "Find My Home Computer", systemImage: "wifi", id: "setup.find") { flow.findHomeComputer() }
            SecondaryPair {
                SecondaryButton(title: "Use a Pairing Code", id: "setup.code") { flow.go(.otherWays) }
            } second: {
                SecondaryButton(title: "Set Up Later", id: "setup.later") { flow.finish() }
            }
        }
        .task { await flow.checkReturning() }
    }
}

// MARK: 6.9 Welcome back

private struct WelcomeBackPage: View {
    let flow: SetupFlow
    @State private var error: String?

    var body: some View {
        SetupScaffold(art: AnyView(ThreadArt(end: "macmini").padding(.top, 32)), title: "Welcome back",
                      subtitle: "This iPhone was paired with \(flow.returningName) before. Reconnect to keep using the "
                        + "originals already there.") {
            if let error { FieldError(text: error) }
        } actions: {
            PrimaryButton(title: "Reconnect to \(flow.returningName)", id: "setup.reconnect") {
                do { try flow.reconnect() } catch { self.error = error.localizedDescription }
            }
            SecondaryButton(title: "Set Up Something Else", id: "setup.somethingElse") { flow.setUpSomethingElse() }
        }
    }
}

// MARK: 1.2 Local Network: three promises

private struct LocalNetworkPage: View {
    let flow: SetupFlow

    var body: some View {
        SetupScaffold(symbol: "wifi", title: "Homespun looks on your Wi‑Fi") {
            VStack(alignment: .leading, spacing: 20) {
                PromiseRow(symbol: "house", title: "Only on this Wi‑Fi",
                           detail: "It looks for a computer running Homespun Server, nothing else.")
                PromiseRow(symbol: "lock.fill", title: "Only with your own computer",
                           detail: "No account and no cloud. Nothing goes anywhere else.")
                PromiseRow(symbol: "hand.raised", title: "Nothing pairs until you choose",
                           detail: "Finding a computer doesn't connect to it.")
            }
            .padding(.top, 8)
        } actions: {
            ConsequenceLine(text: "Turn it off any time in Settings › Apps › Homespun › Local Network.")
            PrimaryButton(title: "Continue", id: "network.continue") { flow.localNetworkContinue() }
        }
        .navigationBarBackButtonHidden()
    }
}

// MARK: 1.8 Photos: three promises

struct PhotosPromisesPage: View {
    let flow: SetupFlow
    @State private var asking = false

    var body: some View {
        SetupScaffold(symbol: "photo.on.rectangle", title: "Homespun reads your library") {
            VStack(alignment: .leading, spacing: 20) {
                PromiseRow(symbol: "iphone", title: "On this iPhone first",
                           detail: "It shows what you could free up before anything is uploaded.")
                PromiseRow(symbol: "house",
                           title: flow.settings.isPaired ? "Originals go only to \(flow.serverName)"
                            : "Originals go only to your own computer",
                           detail: "Never to Homespun's developer, never to a cloud.")
                PromiseRow(symbol: "checkmark.shield", title: "Nothing is removed without you",
                           detail: "iOS asks before any original is deleted.")
            }
            .padding(.top, 8)
        } actions: {
            ConsequenceLine(text: "Change it any time in Settings › Apps › Homespun › Photos.")
            PrimaryButton(title: "Continue", busy: asking, id: "photos.continue") {
                asking = true
                Task {
                    let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
                    asking = false
                    flow.afterPhotos(status)
                }
            }
        }
        .navigationBarBackButtonHidden()
    }
}

// MARK: 6.8 Limited photo access

private struct LimitedPhotosPage: View {
    let flow: SetupFlow
    @State private var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Environment(\.openURL) private var openURL

    var body: some View {
        SetupScaffold(symbol: "photo.on.rectangle", title: "Homespun needs all photos",
                      subtitle: status == .limited
                        ? "With limited access, Homespun can't read originals, show what you could free up, or free up "
                            + "space for photos it can't see."
                        : "Access to Photos is off, so Homespun can't read originals, show what you could free up, or "
                            + "free up space.") {
            EmptyView()
        } actions: {
            PrimaryButton(title: "Open Settings", id: "photos.settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            SecondaryButton(title: "Continue Anyway", id: "photos.anyway") { flow.finish() }
        }
        .navigationBarBackButtonHidden()
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            // Back from Settings with Full Access: carry on by itself (L6).
            status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            if status == .authorized, flow.current == .limitedPhotos { flow.go(.estimate) }
        }
    }
}

// MARK: 6.5 Pairing link opened

/// Confirms a pairing link opened from the Camera app or another app (01·6.5). Switching servers
/// must be deliberate, because links can come from any app or web page.
struct PairConfirmView: View {
    @Bindable var settings: AppSettings
    let link: PairingLink
    var paired: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var working = false
    @State private var error: String?
    @State private var symbol = "server.rack"

    /// The name comes from the link, so it can't be trusted to tell servers apart.
    private var name: String { link.name ?? link.serverURL.host ?? "this server" }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    Image(systemName: symbol).font(.system(size: 40)).foregroundStyle(Theme.accent)
                        .accessibilityHidden(true)
                    Text(replacing == nil ? "Pair with \(name)?" : "Switch to \(name)?")
                        .font(.system(.title2, design: .serif, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    Text(link.serverURL.host.map { "\($0):\(link.serverURL.port ?? 8787)" } ?? link.serverURL.absoluteString)
                        .font(.callout.monospaced()).foregroundStyle(Theme.secondaryLabel)
                    if let current = replacing {
                        InlineNotice(tone: .warning, title: "This iPhone is paired with \(current)",
                                     message: "Pairing replaces it: new items go to this server, and originals already on "
                                        + "\(current) stay there. Only pair with a server you set up.")
                            .accessibilityIdentifier("pair.replaces")
                    } else {
                        Text("Only pair with a server you set up.").foregroundStyle(Theme.secondaryLabel)
                    }
                    if let error { FieldError(text: error) }
                }
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            .background(Theme.card)
            .safeAreaBar(edge: .bottom) {
                VStack(spacing: 8) {
                    ConsequenceLine(text: "Pairs this iPhone with \(name). Nothing is uploaded until you choose; unpair "
                                    + "any time in Server.")
                    Button {
                        Task { await pair() }
                    } label: {
                        BusyLabel(title: replacing.map { "Replace \($0)" } ?? "Pair", busy: working)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent).controlSize(.large)
                    .tint(replacing == nil ? Theme.accent : Theme.red)
                    .allowsHitTesting(!working)
                    .accessibilityIdentifier("pair.confirm")
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }.accessibilityIdentifier("pair.cancel")
                }
            }
        }
        .presentationDetents(replacing == nil ? [.medium, .large] : [.large])
        .task {
            var client = ServerClient(baseURL: link.serverURL)
            client.timeout = 4
            if let options = try? await client.pairingOptions() {
                let server = SetupAdvisor.Server(id: name, os: options.platform?.os, kind: options.hardware?.kind)
                symbol = server.symbol
            }
        }
    }

    /// The server this link would replace, if the iPhone is paired with a different one.
    private var replacing: String? {
        guard let current = settings.serverURL, current != link.serverURL else { return nil }
        return settings.server?.name ?? current.host ?? current.absoluteString
    }

    private func pair() async {
        working = true
        defer { working = false }
        do {
            try await settings.pair(link)
            Announce.say("Paired with \(settings.server?.name ?? name).")
            dismiss()
            paired()
        } catch {
            self.error = PairingErrors.describe(error, address: link.serverURL.host ?? name)
        }
    }
}

extension PairingLink: @retroactive Identifiable {
    public var id: String { url.absoluteString }
}

private struct ComparedItem: Identifiable {
    let id: String
}
