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
        case confirming(match: String, deadline: Date)
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
    @State private var approvalTask: Task<Void, Never>?
    @State private var confirmedNumber: Bool?
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
        case .asking, .waiting, .confirming:
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
        SetupScaffold(art: AnyView(MacDialogArt(match: formattedMatch, server: name)),
                      title: confirming ? "Did the numbers match?" : "Click Allow on \(name)") {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let left = secondsLeft(at: context.date)
                VStack(alignment: .leading, spacing: 20) {
                    if confirming {
                        Text("The server approved this iPhone. Check the number you saw on its screen.")
                            .font(.body).foregroundStyle(Theme.secondaryLabel)
                    } else if let left, left <= 15 {
                        Text("The window on \(name) closes in \(SetupAdvisor.clock(left)). Is someone at the Mac?")
                            .font(.body).foregroundStyle(Theme.amber)
                            .accessibilityIdentifier("pair.closingSoon")
                    } else {
                        Text("A window opened on \(name)'s screen. Check that it shows the same number.")
                            .font(.body).foregroundStyle(Theme.secondaryLabel)
                    }
                    if flow.settings.isDemo {
                        Text("In the demo, no one needs to click: \(name) allows this iPhone by itself in a moment.")
                            .font(.footnote).foregroundStyle(Theme.secondaryLabel)
                            .accessibilityIdentifier("pair.demo")
                    }
                    if let match {
                        Text(formattedMatch ?? match)
                            .font(.system(size: 56, weight: .medium, design: .rounded)).monospacedDigit()
                            .lineLimit(1).minimumScaleFactor(0.7)
                            .foregroundStyle(Theme.label)
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel(match.map(String.init).joined(separator: ", "))
                            .accessibilityIdentifier("pair.match")
                    }
                    if confirming {
                        Text("Confirm only if this number matched the window you allowed on \(name). Your device identity hasn't been sent yet.")
                            .font(.subheadline).foregroundStyle(Theme.secondaryLabel)
                    } else { HStack(spacing: 8) {
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
                }
                .onChange(of: left.map { $0 <= 15 }) { _, soon in
                    // Announced at the start (below) and once at 15 s left, never every second (L12).
                    if soon == true, !warnedSoon, !confirming {
                        warnedSoon = true
                        Announce.say("The window on \(name) closes in 15 seconds.")
                    }
                }
            }
        } actions: {
            if confirming {
                PrimaryButton(title: "The Numbers Matched", id: "pair.confirmNumber") { confirmedNumber = true }
                SecondaryButton(title: "They Didn't Match", id: "pair.rejectNumber") { confirmedNumber = false }
            }
            useCodeButton
        }
    }

    private var match: String? {
        if case .waiting(let match, _) = approval { return match }
        if case .confirming(let match, _) = approval { return match }
        return nil
    }
    private var confirming: Bool { if case .confirming = approval { return true }; return false }

    private var formattedMatch: String? { match.map { String($0.prefix(3)) + " " + $0.suffix(3) } }

    private func secondsLeft(at date: Date) -> Int? {
        let deadline: Date
        switch approval {
        case .waiting(_, let value), .confirming(_, let value): deadline = value
        default: return nil
        }
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
            } else if flow.settings.isDemo {
                Text("In the demo, use DEMO-2468.")
                    .font(.footnote).foregroundStyle(Theme.secondaryLabel).padding(.horizontal, 16)
            } else {
                Text("Codes work once, for 10 minutes after you run the command, or 2 minutes after the first check.")
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
                var client = ServerClient(baseURL: target.url, trust: flow.settings.isDemo ? .demo : .capture(expected: nil))
                defer { if client.trust != .demo { client.session.finishTasksAndInvalidate() } }
                client.timeout = 8
                do {
                    options = try await client.pairingOptions()
                } catch let failure as ServerClient.Failure where failure.status == 404 {
                    needsUpdate = true
                    return
                } catch let error as URLError where error.code == .secureConnectionFailed {
                    needsUpdate = true
                    return
                } catch {
                    loadError = "\(target.address) doesn't answer. Is this iPhone on the same network?"
                    return
                }
            }
        }
        guard (options?.pairingVersion ?? 0) >= 2 else { needsUpdate = true; return }
        if options?.canApprove == true, !useCode { await askForApproval() }
    }

    private func askForApproval() async {
        withdraw()
        approval = .asking
        confirmedNumber = nil
        warnedSoon = false
        let task = Task {
            do {
                let paired = try await flow.settings.approvePairing(url: target.url, onNumber: { number, deadline in
                    approval = .waiting(match: number, deadline: deadline)
                    Announce.say("Click Allow on \(name). The number is \(number.map(String.init).joined(separator: " ")).")
                }, confirmNumber: { number in
                    if flow.settings.isDemo { return true }
                    let deadline = Date().addingTimeInterval(30)
                    approval = .confirming(match: number, deadline: deadline)
                    Announce.say("Did the numbers match on \(name)? Confirm before pairing.")
                    while Date() < deadline, !Task.isCancelled {
                        if let confirmedNumber { return confirmedNumber }
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    return false
                })
                try Task.checkCancellation()
                try flow.settings.finishPairing(paired, serviceName: target.serviceName ?? target.name)
                Announce.say("Paired with \(name).")
                flow.paired(how)
            } catch let failure as ServerPairing.ApprovalFailure {
                approval = failure.state == .denied ? .denied(until: Date().addingTimeInterval(20)) : .expired
            } catch where AppSettings.isCancellation(error) {
            } catch {
                approval = .failed(error.localizedDescription)
            }
        }
        approvalTask = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    /// Closes the window on the server if it is still asking.
    private func withdraw() {
        confirmedNumber = false
        approvalTask?.cancel()
        approvalTask = nil
    }

    private func pairWithCode() async {
        guard !pairing, SetupAdvisor.codeCount(code) == SetupAdvisor.codeLength else { return }
        pairing = true
        defer { pairing = false }
        do {
            try await flow.settings.pair(PairingLink(serverURL: target.url, code: code, name: target.serviceName ?? target.name))
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
                    Text("Allow this iPhone to use Homespun Server?").font(.footnote)
                    Text(match ?? "··· ···").font(.title2.monospacedDigit())
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
    static let wrongCode = "That code didn't work. Codes work once, for 10 minutes after you run the command "
        + "or 2 minutes after the first check. "
        + "Run it again for a new one."

    static func isUnreachable(_ error: Error) -> Bool {
        error is URLError || (error as NSError).domain == NSURLErrorDomain
    }

    static func describe(_ error: Error, address: String) -> String {
        if error is ServerClient.IdentityMismatch {
            return "This link is for a different server key. Run pair again on the server and scan the new code."
        }
        if let failure = error as? ServerClient.Failure, failure.status == 404 {
            return "Update Homespun Server to 0.2 or later for encrypted pairing."
        }
        if let urlError = error as? URLError {
            if urlError.code == .appTransportSecurityRequiresSecureConnection {
                return "Use the server's IP address, a .local name, or an HTTPS proxy with a publicly trusted certificate."
            }
            if [.secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
                .serverCertificateHasBadDate].contains(urlError.code) {
                return "Update Homespun Server to 0.2 or later for encrypted connections. If it is already updated, "
                    + "use its IP address or .local name, or a proxy with a publicly trusted certificate."
            }
        }
        if isUnreachable(error) { return "Can't reach \(address). Is this iPhone on the same network?" }
        if let failure = error as? ServerClient.Failure, [400, 401, 403, 410].contains(failure.status) { return wrongCode }
        return error.localizedDescription
    }
}
