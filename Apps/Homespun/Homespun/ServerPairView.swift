// SPDX-License-Identifier: Apache-2.0
import HomespunCore
import SwiftUI

/// Pairs with one server (DESIGN 01·1.6, 8.2, 2.3, 2.4 by approval; 2.1, 8.4 with a code; 6.7 when
/// it's too old). A Mac with someone logged in shows a window to click Allow, with the same number
/// as this iPhone and a visible countdown; any server takes the code its `pair` command shows.
struct PairPage: View {
    let flow: SetupFlow
    let target: SetupFlow.PairTarget

    enum Approval: Equatable {
        case asking
        case waiting(match: String, deadline: Date)
        /// Deny was clicked; the server waits before it can ask again.
        case denied(until: Date)
        case expired
        case failed(String)
    }

    @State private var options: ServerAPI.PairingOptions?
    @State private var loadError: String?
    @State private var needsUpdate = false
    @State private var useCode = false
    @State private var approval: Approval = .asking
    @State private var ticket: ServerAPI.ApprovalTicket?
    @State private var attempt = 0
    @State private var code = ""
    @State private var pairing = false
    @State private var codeError: String?
    @State private var warnedSoon = false
    @State private var scanning = false
    @FocusState private var codeFocused: Bool

    private var name: String { options?.serverName ?? target.displayName }
    private var how: SetupFlow.Pairing { target.waitedFor ? .waited : target.discovered ? .discovered : .typed }

    var body: some View {
        Group {
            if needsUpdate {
                update
            } else if let loadError {
                unreachable(loadError)
            } else if let options {
                if options.canApprove, !useCode { approvalPage } else { codePage(options) }
            } else {
                SetupScaffold(title: "Contacting \(name)…", subtitle: target.address) {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 24)
                }
            }
        }
        .task(id: attempt) { await run() }
        .onDisappear(perform: withdraw)
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

    // MARK: 1.6 Allow on the Mac · 8.2 closes soon · 2.3 denied · 2.4 no answer

    @ViewBuilder private var approvalPage: some View {
        switch approval {
        case .asking, .waiting:
            allow
        case .denied(let until):
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let left = Int(until.timeIntervalSince(context.date).rounded(.up))
                SetupScaffold(symbol: "hand.raised", title: "\(name) didn't allow this iPhone",
                              subtitle: "Someone clicked Deny on \(name). If that was a mistake, ask again.") {
                    EmptyView()
                } actions: {
                    ConsequenceLine(text: "\(name) waits 20 seconds after a Deny before it can ask again.")
                    askAgain(left: left)
                    useCodeButton
                }
            }
        case .expired:
            SetupScaffold(symbol: "clock", title: "No one answered on \(name)",
                          subtitle: "The window on \(name) closed. Is someone at the Mac? If it runs without a screen, "
                            + "use a pairing code.") {
                EmptyView()
            } actions: {
                askAgain(left: 0)
                useCodeButton
            }
        case .failed(let message):
            SetupScaffold(symbol: "exclamationmark.triangle", title: "Couldn't ask \(name)", subtitle: message) {
                EmptyView()
            } actions: {
                askAgain(left: 0)
                useCodeButton
            }
        }
    }

    private var allow: some View {
        SetupScaffold(art: AnyView(MacDialogArt(match: match, server: name)), title: "Click Allow on \(name)") {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let left = secondsLeft(at: context.date)
                VStack(alignment: .leading, spacing: 20) {
                    if let left, left <= 15 {
                        Text("The window on \(name) closes in \(SetupAdvisor.clock(left)). Is someone at the Mac?")
                            .font(.body).foregroundStyle(Theme.amber)
                            .accessibilityIdentifier("pair.closingSoon")
                    } else {
                        Text("A window opened on \(name)'s screen. Check that it shows the same number.")
                            .font(.body).foregroundStyle(Theme.secondaryLabel)
                    }
                    if let match {
                        Text(match.map(String.init).joined(separator: " "))
                            .font(.system(size: 56, weight: .medium, design: .rounded)).monospacedDigit()
                            .foregroundStyle(Theme.label)
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel(match.map(String.init).joined(separator: ", "))
                            .accessibilityIdentifier("pair.match")
                    }
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        if let left, left > 15 {
                            Text("Waiting for \(name) · closes in \(SetupAdvisor.clock(left))").monospacedDigit()
                        } else {
                            Text(match == nil ? "Asking \(name)…" : "Waiting for \(name)")
                        }
                    }
                    .font(.subheadline).foregroundStyle(Theme.secondaryLabel)
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(match == nil ? "Asking \(name)" : "Waiting for \(name)")
                }
                .onChange(of: left.map { $0 <= 15 }) { _, soon in
                    // Announced at the start (below) and once at 15 s left, never every second (L12).
                    if soon == true, !warnedSoon {
                        warnedSoon = true
                        Announce.say("The window on \(name) closes in 15 seconds.")
                    }
                }
            }
        } actions: {
            useCodeButton
        }
    }

    private var match: String? {
        if case .waiting(let match, _) = approval { return match }
        return nil
    }

    private func secondsLeft(at date: Date) -> Int? {
        guard case .waiting(_, let deadline) = approval else { return nil }
        return max(0, Int(deadline.timeIntervalSince(date).rounded(.up)))
    }

    /// Keeps its name while counting down: "Ask Again in 0:18", then "Ask Again" (L12).
    private func askAgain(left: Int) -> some View {
        let waiting = left > 0
        return Button { attempt += 1 } label: {
            Text(waiting ? "Ask Again in \(SetupAdvisor.clock(left))" : "Ask Again").monospacedDigit()
                .frame(maxWidth: .infinity)
        }
        .primaryAction()
        .disabled(waiting)
        .accessibilityLabel("Ask Again")
        .accessibilityValue(waiting ? "available in \(SetupAdvisor.spokenClock(left))" : "")
        .accessibilityIdentifier("pair.askAgain")
    }

    private var useCodeButton: some View {
        SecondaryButton(title: "Use a Pairing Code Instead", id: "pair.useCode") {
            withdraw()
            useCode = true
        }
    }

    // MARK: 2.1 Pair with a code · 8.4 That code didn't work

    private func codePage(_ options: ServerAPI.PairingOptions) -> some View {
        SetupScaffold(title: "Get a code from \(name)", subtitle: "On \(name), run this. It shows a code and a QR code.") {
            CommandBox(command: options.pairCommand)
                .accessibilityIdentifier("pair.command")
            SetupField(label: "Pairing code", error: codeError != nil, focused: codeFocused) {
                TextField("Pairing code", text: $code, prompt: Text(verbatim: "XXXX-XXXX"))
                    .monospaced()
                    .focused($codeFocused)
                    .textInputAutocapitalization(.characters).autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit { Task { await pairWithCode() } }
                    .accessibilityHint("\(SetupAdvisor.codeCount(code)) of 8 characters")
                    .accessibilityIdentifier("pair.code")
            }
            if let codeError {
                FieldError(text: codeError).padding(.horizontal, 16).accessibilityIdentifier("pair.error")
            } else if pairing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Pairing with \(name)…")
                }
                .font(.footnote).foregroundStyle(Theme.secondaryLabel).padding(.horizontal, 16)
            } else {
                Text("Codes work once, for 10 minutes after you run the command.")
                    .font(.footnote).foregroundStyle(Theme.secondaryLabel).padding(.horizontal, 16)
            }
            if PairingScanner.isSupported {
                SecondaryButton(title: "Scan the QR Code Instead", systemImage: "qrcode.viewfinder", id: "pair.scan") {
                    scanning = true
                }
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear { codeFocused = true }
        .onChange(of: code) { old, new in
            let formatted = SetupAdvisor.formatCode(new)
            if formatted != new { code = formatted; return }
            if old != new { codeError = nil }
            // Pairs by itself once all 8 characters are there; no Pair button.
            if SetupAdvisor.codeCount(formatted) == SetupAdvisor.codeLength { Task { await pairWithCode() } }
        }
    }

    // MARK: 6.7 Server needs an update

    private var update: some View {
        SetupScaffold(symbol: "arrow.down.circle", title: "Update Homespun Server on \(name)",
                      subtitle: "\(name) runs an older Homespun Server. This app needs a newer one.") {
            CommandBox(command: "cd ~/homespun && git pull && swift build -c release --product homespun-server")
            Text("Then restart Homespun Server on \(name), and check again.")
                .font(.footnote).foregroundStyle(Theme.secondaryLabel)
        } actions: {
            PrimaryButton(title: "Check Again", id: "pair.checkAgain") {
                needsUpdate = false
                options = nil
                attempt += 1
            }
            SecondaryButton(title: "Use Another Server", id: "pair.another") {
                if !flow.path.isEmpty { flow.path.removeLast() }
            }
        }
    }

    private func unreachable(_ message: String) -> some View {
        SetupScaffold(symbol: "wifi.exclamationmark", title: "Can't reach \(name)", subtitle: message) {
            EmptyView()
        } actions: {
            PrimaryButton(title: "Try Again", id: "pair.retry") {
                loadError = nil
                attempt += 1
            }
            SecondaryButton(title: "Connect Another Way", id: "setup.otherWays") { flow.go(.otherWays) }
        }
    }

    // MARK: Actions

    private func run() async {
        if options == nil {
            if let known = flow.options(for: target) {
                options = known
            } else {
                var client = ServerClient(baseURL: target.url)
                client.timeout = 8
                do {
                    options = try await client.pairingOptions()
                } catch let failure as ServerClient.Failure where failure.status == 404 {
                    needsUpdate = true
                    return
                } catch {
                    loadError = "\(target.address) doesn't answer. Is this iPhone on the same network?"
                    return
                }
            }
        }
        if options?.canApprove == true, !useCode { await askForApproval() }
    }

    private func askForApproval() async {
        withdraw()
        approval = .asking
        warnedSoon = false
        let ticket: ServerAPI.ApprovalTicket
        do {
            ticket = try await ServerClient(baseURL: target.url).requestApproval(deviceName: UIDevice.current.name)
        } catch {
            approval = .failed(error.localizedDescription)
            return
        }
        self.ticket = ticket
        approval = .waiting(match: ticket.match, deadline: Date().addingTimeInterval(TimeInterval(ticket.expiresIn)))
        Announce.say("Click Allow on \(name). The number is \(ticket.match.map(String.init).joined(separator: " ")). "
                     + "The window closes in \(SetupAdvisor.spokenClock(ticket.expiresIn)).")
        let poller = ServerClient(baseURL: target.url, token: ticket.secret)
        let deadline = Date().addingTimeInterval(TimeInterval(ticket.expiresIn) + 15)
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, self.ticket == ticket else { return }
            if Date() > deadline {
                // The server stopped answering (asleep, off the Wi‑Fi): the window has closed by now.
                withdraw()
                approval = .expired
                Announce.say("No one answered on \(name).")
                return
            }
            let status: ServerAPI.ApprovalStatus
            do {
                status = try await poller.approvalStatus(ticket.id)
            } catch let failure as ServerClient.Failure where failure.status == 404 {
                self.ticket = nil
                approval = .expired
                return
            } catch {
                continue // A dropped poll (Wi-Fi blip) is retried.
            }
            guard status.state != .waiting else { continue }
            self.ticket = nil
            switch status.state {
            case .approved:
                guard let pairing = status.pairing else { return }
                do {
                    try flow.settings.finishPairing(serverURL: target.url, response: pairing)
                    Announce.say("Paired with \(name).")
                    flow.paired(how)
                } catch {
                    approval = .failed(error.localizedDescription)
                }
            case .denied:
                approval = .denied(until: Date().addingTimeInterval(20))
                Announce.say("\(name) didn't allow this iPhone. Ask Again is available in 20 seconds.")
            case .expired, .waiting:
                approval = .expired
                Announce.say("No one answered on \(name).")
            }
            return
        }
    }

    /// Closes the window on the server if it is still asking.
    private func withdraw() {
        guard let ticket else { return }
        self.ticket = nil
        let client = ServerClient(baseURL: target.url, token: ticket.secret)
        Task { await client.cancelApproval(ticket.id) }
    }

    private func pairWithCode() async {
        guard !pairing, SetupAdvisor.codeCount(code) == SetupAdvisor.codeLength else { return }
        pairing = true
        defer { pairing = false }
        do {
            try await flow.settings.pair(PairingLink(serverURL: target.url, code: code))
            withdraw()
            Announce.say("Paired with \(name).")
            flow.paired(how)
        } catch {
            codeError = PairingErrors.describe(error, address: target.address)
            Announce.say(codeError ?? "")
        }
    }
}

/// A drawing of the Mac's Allow window, with the same number.
private struct MacDialogArt: View {
    let match: String?
    let server: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(Color(hex: 0xFF5F57)).frame(width: 10, height: 10)
                Circle().fill(Color(hex: 0xFEBC2E)).frame(width: 10, height: 10)
                Circle().fill(Color(hex: 0x28C840)).frame(width: 10, height: 10)
                Spacer()
            }
            .padding(10)
            .background(Theme.separator)
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "server.rack").font(.title2).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Allow “\(UIDevice.current.name)” to use Homespun Server?").font(.footnote)
                    Text(match ?? "····").font(.title2.monospacedDigit())
                    HStack {
                        Spacer()
                        Text("Deny").font(.footnote).padding(.horizontal, 14).padding(.vertical, 5)
                            .background(Theme.card, in: Capsule())
                        Text("Allow").font(.footnote).foregroundStyle(.white).padding(.horizontal, 14).padding(.vertical, 5)
                            .background(Theme.blue, in: Capsule())
                    }
                }
            }
            .padding(16)
        }
        .foregroundStyle(Theme.label)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.separator))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .accessibilityHidden(true)
    }
}

/// What a failed pairing means, in words that say how to fix it (PC-E1, PC-E2).
enum PairingErrors {
    static let wrongCode = "That code didn't work. Codes work once, for 10 minutes after you run the command. "
        + "Run it again for a new one."

    static func isUnreachable(_ error: Error) -> Bool {
        error is URLError || (error as NSError).domain == NSURLErrorDomain
    }

    static func describe(_ error: Error, address: String) -> String {
        if isUnreachable(error) { return "Can't reach \(address). Is this iPhone on the same network?" }
        if let failure = error as? ServerClient.Failure, [400, 401, 403, 410].contains(failure.status) { return wrongCode }
        return error.localizedDescription
    }
}
