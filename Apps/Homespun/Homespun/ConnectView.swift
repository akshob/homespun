// SPDX-License-Identifier: Apache-2.0
import HomespunCore
import SwiftUI

// Finding the home computer (DESIGN 01·1.4, 8.1, 6.1), the recommendation among the servers found
// (1.5, 2.5, 6.6), and the other ways to connect (6.2, 6.3, 6.4).

// MARK: 1.4 Looking · 8.1 Still looking · 6.1 Can't look

struct LookingPage: View {
    let flow: SetupFlow
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var announced = Set<String>()

    private var discovery: ServerDiscovery { flow.discovery }

    var body: some View {
        Group {
            if discovery.blocked {
                blocked
            } else if (flow.stillLooking || flow.advanced), discovery.ready.isEmpty {
                slow
            } else {
                looking
            }
        }
        .task { flow.look() }
        .onChange(of: discovery.ready.map(\.name)) {
            // Each server is announced once, as it answers.
            for found in discovery.ready where !announced.contains(found.name) {
                announced.insert(found.name)
                let server = found.advisorServer
                Announce.say("Found \(server.name), \(server.kindName), Homespun running")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            // Back from Settings with Local Network on: look again by itself (L6).
            if discovery.blocked, flow.current == .looking { flow.lookAgain() }
        }
    }

    private var looking: some View {
        SetupScaffold(title: "Looking on your Wi‑Fi…", subtitle: "Usually a few seconds.", centered: true) {
            VStack(alignment: .leading, spacing: 8) {
                if !discovery.servers.isEmpty {
                    SetupSectionHeader(text: "Found so far")
                    SetupCard {
                        ForEach(discovery.servers) { found in
                            FoundRow(found: found)
                        }
                    }
                }
                Text("Only computers running Homespun Server appear here.")
                    .font(.footnote).foregroundStyle(Theme.secondaryLabel).padding(.horizontal, 16)
                    .frame(maxWidth: .infinity, alignment: discovery.servers.isEmpty ? .center : .leading)
            }
            .padding(.top, 12)
            .animation(reduceMotion ? nil : .default, value: discovery.servers.map(\.name))
        } actions: {
            // Back here after the recommendation: it stays, and the list keeps updating.
            if flow.advanced, !discovery.ready.isEmpty {
                PrimaryButton(title: "Continue", id: "looking.continue") { flow.go(.found) }
                SecondaryButton(title: "Set Up a Server Instead", id: "setup.server") { flow.go(.question) }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { Rings(still: reduceMotion).frame(height: 190).padding(.top, 8) }
    }

    private var slow: some View {
        SetupScaffold(symbol: "wifi", title: "Still looking…",
                      subtitle: "A computer running Homespun Server usually answers within a few seconds.",
                      centered: true) {
            VStack(alignment: .leading, spacing: 8) {
                SetupSectionHeader(text: "If you've set one up")
                SetupCard {
                    SetupRow(symbol: "wifi", title: "Is this iPhone on the same Wi‑Fi?",
                             detail: "Guest networks can't see other devices.")
                    SetupRow(symbol: "bolt.fill", title: "Is the computer on and awake?")
                }
                Text("Haven't set one up yet? In a few seconds, Homespun asks what you have.")
                    .font(.footnote).foregroundStyle(Theme.secondaryLabel).padding(.horizontal, 16)
            }
            .padding(.top, 12)
        } actions: {
            Button { flow.go(.question) } label: {
                Text("Set Up a Server Instead").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered).controlSize(.large).tint(Theme.accent)
            .accessibilityIdentifier("setup.server")
            SecondaryButton(title: "Connect Another Way", id: "setup.otherWays") { flow.go(.otherWays) }
        }
    }

    private var blocked: some View {
        SetupScaffold(symbol: "wifi.exclamationmark", title: "Homespun can't look on your network",
                      subtitle: "Local Network is off for Homespun, so it can't find your server. Turn it on in Settings, "
                        + "or connect another way.") {
            SetupCard { SetupRow(title: "Settings › Apps › Homespun › Local Network") }
        } actions: {
            PrimaryButton(title: "Open Settings", id: "network.settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            SecondaryButton(title: "Connect Another Way", id: "setup.otherWays") { flow.go(.otherWays) }
        }
    }

    /// Rings around the Wi‑Fi symbol; still with Reduce Motion.
    private struct Rings: View {
        let still: Bool
        @State private var pulse = false

        var body: some View {
            ZStack {
                ForEach(0..<3) { ring in
                    Circle()
                        .stroke(Theme.accent.opacity(0.35 - Double(ring) * 0.1), lineWidth: 1.5)
                        .frame(width: CGFloat(64 + ring * 48), height: CGFloat(64 + ring * 48))
                        .scaleEffect(pulse && !still ? 1.06 : 1)
                        .opacity(pulse && !still ? 0.6 : 1)
                        .animation(still ? nil : .easeInOut(duration: 1.2).repeatForever().delay(Double(ring) * 0.2),
                                   value: pulse)
                }
                Image(systemName: "wifi").font(.title).foregroundStyle(Theme.accent)
            }
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
            .onAppear { pulse = true }
        }
    }
}

/// A server found so far: its name, kind and version, with a check once it has answered.
private struct FoundRow: View {
    let found: ServerDiscovery.Found

    var body: some View {
        let server = found.advisorServer
        HStack(spacing: 14) {
            Image(systemName: server.symbol).font(.title3).foregroundStyle(Theme.accent).frame(width: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name).font(.body).foregroundStyle(Theme.label)
                Text(found.unreachable ? "Not answering" : found.isReady ? server.summary : "Asking…")
                    .font(.footnote).foregroundStyle(Theme.secondaryLabel)
            }
            Spacer()
            if found.isReady {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.teal).font(.title3)
                    .accessibilityHidden(true)
            } else if !found.unreachable {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("discovered.\(found.name)")
    }
}

// MARK: 1.5 Recommendation · 2.5 One server found · 6.6 Several Macs

struct FoundPage: View {
    let flow: SetupFlow
    @State private var chosen: String?

    var body: some View {
        Group {
            if let advice = flow.foundAdvice {
                if advice.layout == .chooseMac { chooseMac(advice) } else { recommend(advice) }
            } else {
                SetupScaffold(title: "No servers answer now") {
                    Text("The server that answered has gone quiet. Look again, or connect another way.")
                        .foregroundStyle(Theme.secondaryLabel)
                } actions: {
                    PrimaryButton(title: "Look Again", id: "setup.lookAgain") { flow.lookAgain() }
                    SecondaryButton(title: "Connect Another Way", id: "setup.otherWays") { flow.go(.otherWays) }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Look Again", systemImage: "arrow.clockwise") { flow.lookAgain() }
                    .accessibilityIdentifier("setup.refresh")
            }
        }
        .task { flow.discovery.start() }
        .onAppear { if let advice = flow.foundAdvice { Announce.say(advice.title) } }
    }

    private func use(_ server: SetupAdvisor.Server, immich: Bool = false) {
        guard let target = flow.target(for: server.id) else { return }
        flow.usesImmich = immich || flow.answers.contains(.immich)
        flow.go(.pair(target))
    }

    private func recommend(_ advice: SetupAdvisor.FoundAdvice) -> some View {
        let best = advice.recommended
        return SetupScaffold(title: advice.title) {
            RecommendationCard(symbol: best.symbol, name: best.name, summary: best.summary,
                               reasons: advice.reasons,
                               consequence: best.needsUpdate ? nil
                                : "Pairs this iPhone with \(best.name). Nothing is uploaded until you choose.",
                               action: best.needsUpdate ? "Update \(best.name)" : "Use \(best.name)",
                               id: "found.use") { use(best) }
            if !advice.others.isEmpty {
                SetupSectionHeader(text: "Also running Homespun")
                ForEach(advice.others) { other in
                    SetupCard {
                        SetupLinkRow(symbol: other.symbol, title: other.title, detail: other.detail,
                                     id: "found.\(other.id)") {
                            if case .server(let id) = other.target, let server = advice.ranked.first(where: { $0.id == id }) {
                                use(server)
                            }
                        }
                    }
                }
            } else {
                SetupSectionHeader(text: "Other options")
            }
            SetupCard {
                SetupLinkRow(symbol: "plus", title: "Set Up a Different Computer",
                             detail: advice.layout == .onlyOne ? advice.differentDetail : nil, id: "setup.different") {
                    flow.go(.question)
                }
            }
            SetupCard {
                SetupLinkRow(symbol: "qrcode", title: "Connect Another Way", id: "setup.otherWays") { flow.go(.otherWays) }
            }
            if !best.needsUpdate {
                SetupCard {
                    SetupLinkRow(symbol: "camera.macro", title: "I Already Use Immich", id: "setup.immich") {
                        use(best, immich: true)
                    }
                }
            }
        } actions: {
            EmptyView()
        }
    }

    private func chooseMac(_ advice: SetupAdvisor.FoundAdvice) -> some View {
        let selected = advice.ranked.first { $0.id == chosen } ?? advice.recommended
        return SetupScaffold(title: advice.title) {
            SetupCard {
                ForEach(advice.ranked) { server in
                    Button { chosen = server.id } label: {
                        HStack(spacing: 14) {
                            Image(systemName: server.symbol).font(.title3).foregroundStyle(Theme.accent).frame(width: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(server.name).foregroundStyle(Theme.label)
                                Text(server.summary).font(.footnote).foregroundStyle(Theme.secondaryLabel)
                            }
                            Spacer()
                            Image(systemName: server.id == selected.id ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(server.id == selected.id ? Theme.accent : Theme.tertiaryLabel)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(server.id == selected.id ? [.isButton, .isSelected] : .isButton)
                    .accessibilityIdentifier("found.choose.\(server.id)")
                }
            }
            Text("A Mac that stays on at home works best. Laptops work while they're awake and at home.")
                .font(.footnote).foregroundStyle(Theme.secondaryLabel).padding(.horizontal, 16)
            SetupCard {
                SetupLinkRow(symbol: "plus", title: "Set Up a Different Computer", id: "setup.different") {
                    flow.go(.question)
                }
                SetupLinkRow(symbol: "qrcode", title: "Connect Another Way", id: "setup.otherWays") { flow.go(.otherWays) }
            }
        } actions: {
            ConsequenceLine(text: "Pairs this iPhone with \(selected.name). Nothing is uploaded until you choose.")
            PrimaryButton(title: "Use \(selected.name)", id: "found.use") { use(selected) }
        }
    }
}

// MARK: 6.2 Other ways to connect

struct OtherWaysPage: View {
    let flow: SetupFlow
    @State private var scanning = false
    @State private var error: String?

    var body: some View {
        SetupScaffold(title: "Connect another way") {
            SetupCard {
                if PairingScanner.isSupported {
                    SetupLinkRow(symbol: "qrcode.viewfinder", title: "Scan QR Code",
                                 detail: "From \"homespun-server pair\" on the server.", id: "other.scan") { scanning = true }
                }
                HStack(spacing: 0) {
                    SetupRow(symbol: "link", title: "Paste Pairing Link", detail: "homespun://pair?…")
                    PasteButton(payloadType: String.self) { strings in
                        let link = strings.lazy.compactMap(PairingLink.init(text:)).first
                        Task { @MainActor in
                            if let link { flow.link = link } else {
                                error = "That isn't a Homespun pairing link. It starts with homespun://pair."
                            }
                        }
                    }
                    .labelStyle(.titleOnly)
                    .buttonBorderShape(.capsule)
                    .tint(Theme.accent)
                    .padding(.trailing, 16)
                    .accessibilityIdentifier("connect.paste")
                }
                SetupLinkRow(symbol: "keyboard", title: "Enter Address and Code", detail: "For example 192.168.1.20:8787",
                             id: "other.address") { flow.go(.address) }
            }
            if let error { FieldError(text: error).padding(.horizontal, 16) }
            Text("All three need a code from the server. On a Mac you can also click Allow instead.")
                .font(.footnote).foregroundStyle(Theme.secondaryLabel).padding(.horizontal, 16)
            SetupCard {
                SetupLinkRow(symbol: "plus", title: "Set Up a Server", detail: "Tell Homespun what you have at home.",
                             id: "setup.server") { flow.go(.question) }
            }
        } actions: {
            EmptyView()
        }
        .sheet(isPresented: $scanning) {
            ScanPage { link in
                scanning = false
                // After the scanner's sheet has gone, so the confirmation can be presented.
                Task {
                    try? await Task.sleep(for: .milliseconds(700))
                    flow.link = link
                }
            }
        }
    }
}

// MARK: 6.4 Address and code

struct AddressPage: View {
    let flow: SetupFlow
    /// Kept when pairing fails and across relaunches (L6).
    @SceneStorage("setup.address") private var address = ""
    @SceneStorage("setup.code") private var code = ""
    @State private var addressError: String?
    @State private var codeError: String?
    @State private var working = false
    @FocusState private var focus: Field?

    enum Field { case address, code }

    var body: some View {
        SetupScaffold(title: "Enter address and code") {
            SetupField(label: "Server address", error: addressError != nil, focused: focus == .address) {
                TextField("Server address", text: $address, prompt: Text(verbatim: "192.168.1.20:8787"))
                    .monospaced()
                    .focused($focus, equals: .address)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    .submitLabel(.next)
                    .onSubmit { focus = .code }
                    .accessibilityIdentifier("server.address")
            }
            if let addressError { FieldError(text: addressError).padding(.horizontal, 16) }
            SetupField(label: "Pairing code", error: codeError != nil, focused: focus == .code) {
                TextField("Pairing code", text: $code, prompt: Text(verbatim: "XXXX-XXXX"))
                    .monospaced()
                    .focused($focus, equals: .code)
                    .textInputAutocapitalization(.characters).autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit { Task { await pair() } }
                    .accessibilityHint("\(SetupAdvisor.codeCount(code)) of 8 characters")
                    .accessibilityIdentifier("pair.code")
            }
            if let codeError {
                FieldError(text: codeError).padding(.horizontal, 16)
            } else {
                Text("Run \"homespun-server pair\" on the server for a code. Codes work once, for 10 minutes.")
                    .font(.footnote).foregroundStyle(Theme.secondaryLabel).padding(.horizontal, 16)
            }
        } actions: {
            ConsequenceLine(text: "Pairs this iPhone with that server. Nothing is uploaded until you choose.")
            PrimaryButton(title: "Pair", busy: working, id: "pair.submit") { Task { await pair() } }
                .disabled(address.isEmpty || SetupAdvisor.codeCount(code) < SetupAdvisor.codeLength)
        }
        .onChange(of: code) { _, new in
            let formatted = SetupAdvisor.formatCode(new)
            if formatted != new { code = formatted }
            codeError = nil
        }
        .onChange(of: address) { _, _ in addressError = nil }
        .onAppear { focus = address.isEmpty ? .address : .code }
    }

    private func pair() async {
        guard !working else { return }
        guard let url = PairingLink.serverURL(from: address) else {
            addressError = "Enter the server's address, for example 192.168.1.20:8787."
            return
        }
        guard SetupAdvisor.codeCount(code) == SetupAdvisor.codeLength else {
            codeError = "Enter all 8 characters of the code."
            return
        }
        working = true
        defer { working = false }
        do {
            try await flow.settings.pair(PairingLink(serverURL: url, code: code))
            Announce.say("Paired with \(flow.serverName).")
            code = ""
            flow.paired(.typed)
        } catch {
            if PairingErrors.isUnreachable(error) {
                addressError = "Can't reach \(address). Is this iPhone on the same network?"
                Announce.say(addressError ?? "")
            } else {
                codeError = PairingErrors.describe(error, address: address)
                Announce.say(codeError ?? "")
            }
        }
    }
}

// MARK: The Server tab's Connect

/// Pairs the app with a server from the Server tab: the same pages as setup, in a sheet, ending
/// once paired and checked.
struct ConnectView: View {
    @Bindable var settings: AppSettings
    var onPaired: () -> Void
    @State private var start: SetupFlow.Page?

    var body: some View {
        SetupScaffold(symbol: "house", title: "Connect your home computer",
                      subtitle: "Homespun keeps your originals on your own computer at home.") {
            SetupCard {
                SetupLinkRow(symbol: "wifi", title: "Find My Home Computer",
                             detail: "Looks for Homespun Server on this Wi‑Fi.", id: "connect.find") { start = .looking }
                SetupLinkRow(symbol: "qrcode", title: "Connect Another Way",
                             detail: "A QR code, a pairing link, or an address and code.", id: "connect.other") {
                    start = .otherWays
                }
                SetupLinkRow(symbol: "plus", title: "Set Up a Server", detail: "Tell Homespun what you have at home.",
                             id: "connect.setup") { start = .question }
            }
        }
        .sheet(item: $start) { page in
            OnboardingView(settings: settings, start: page, pairOnly: true, onPaired: onPaired)
        }
    }
}

extension SetupFlow.Page: Identifiable {
    var id: Self { self }
}
