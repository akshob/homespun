// SPDX-License-Identifier: Apache-2.0
import HomespunCore
import SwiftUI

/// Pairs with one server. A Mac asks the person at its screen to click Allow; any server also
/// takes the code its `pair` command shows.
struct ServerPairView: View {
    struct Target: Identifiable, Hashable {
        var url: URL
        var name: String?
        var id: String { url.absoluteString }
    }

    enum Approval: Equatable {
        case asking, waiting(match: String), denied, expired, failed(String)
    }

    @Bindable var settings: AppSettings
    let target: Target
    /// Called once paired; the caller dismisses this view.
    var onPaired: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var options: ServerAPI.PairingOptions?
    @State private var loadError: String?
    @State private var approval: Approval = .asking
    @State private var ticket: ServerAPI.ApprovalTicket?
    @State private var attempt = 0
    @State private var code = ""
    @State private var pairing = false
    @State private var error: String?

    private var name: String { options?.serverName ?? target.name ?? target.url.host ?? "the server" }
    private var address: String {
        target.url.host.map { "\($0):\(target.url.port ?? 8787)" } ?? target.url.absoluteString
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent {
                        Text(address).font(.system(.callout, design: .monospaced))
                    } label: {
                        Label(name, systemImage: "server.rack")
                    }
                }
                if let options {
                    if options.canApprove { approvalSection }
                    codeSection(options)
                } else if let loadError {
                    Section {
                        Text(loadError).foregroundStyle(.red)
                        Button("Try again") { attempt += 1 }
                    }
                } else {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Contacting \(name)…").foregroundStyle(.secondary)
                        }
                    }
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red).accessibilityIdentifier("pair.error") }
                }
            }
            .navigationTitle(name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .task(id: attempt) { await run() }
        .onDisappear(perform: withdraw)
    }

    @ViewBuilder private var approvalSection: some View {
        Section {
            switch approval {
            case .asking:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Asking \(name)…").foregroundStyle(.secondary)
                }
            case .waiting(let match):
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Click Allow on \(name)'s screen").font(.headline)
                    }
                    Text("Check that it shows this number:").foregroundStyle(.secondary)
                    Text(match)
                        .font(.system(size: 44, weight: .semibold, design: .rounded)).monospacedDigit()
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("pair.match")
                }
            case .denied:
                Label("\(name) didn't allow this iPhone.", systemImage: "hand.raised")
                Button("Ask again") { attempt += 1 }
            case .expired:
                Label("No one answered on \(name).", systemImage: "clock")
                Button("Ask again") { attempt += 1 }
            case .failed(let message):
                Text(message).foregroundStyle(.red)
                Button("Ask again") { attempt += 1 }
            }
        } header: {
            Text("Allow on the Mac")
        } footer: {
            Text("Only click Allow if both screens show the same number.")
        }
    }

    private func codeSection(_ options: ServerAPI.PairingOptions) -> some View {
        Section {
            Text("On \(name), run this. It shows a code, and a QR code you can scan with the Camera app instead.")
            CommandRow(command: options.pairCommand)
                .accessibilityIdentifier("pair.command")
            TextField("Pairing code", text: $code)
                .textInputAutocapitalization(.characters).autocorrectionDisabled()
                .accessibilityIdentifier("pair.code")
            Button {
                Task { await pairWithCode() }
            } label: {
                if pairing { ProgressView() } else { Text("Pair") }
            }
            .disabled(code.isEmpty || pairing)
            .accessibilityIdentifier("pair.submit")
        } header: {
            Text(options.canApprove ? "Or use a pairing code" : "Pair with a code")
        }
    }

    // MARK: Actions

    private func run() async {
        if options == nil {
            loadError = nil
            var client = ServerClient(baseURL: target.url)
            client.timeout = 8
            do {
                options = try await client.pairingOptions()
            } catch {
                loadError = "Couldn't reach \(name) at \(address). \(error.localizedDescription)"
                return
            }
        }
        if options?.canApprove == true { await askForApproval() }
    }

    private func askForApproval() async {
        withdraw()
        approval = .asking
        let ticket: ServerAPI.ApprovalTicket
        do {
            ticket = try await ServerClient(baseURL: target.url).requestApproval(deviceName: UIDevice.current.name)
        } catch {
            approval = .failed(error.localizedDescription)
            return
        }
        self.ticket = ticket
        approval = .waiting(match: ticket.match)
        let poller = ServerClient(baseURL: target.url, token: ticket.secret)
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, self.ticket == ticket else { return }
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
                    try settings.finishPairing(serverURL: target.url, response: pairing)
                    onPaired()
                } catch {
                    approval = .failed(error.localizedDescription)
                }
            case .denied: approval = .denied
            case .expired, .waiting: approval = .expired
            }
            return
        }
    }

    /// Closes the dialog on the server if it is still asking.
    private func withdraw() {
        guard let ticket else { return }
        self.ticket = nil
        let client = ServerClient(baseURL: target.url, token: ticket.secret)
        Task { await client.cancelApproval(ticket.id) }
    }

    private func pairWithCode() async {
        pairing = true
        defer { pairing = false }
        do {
            try await settings.pair(PairingLink(serverURL: target.url, code: code))
            error = nil
            withdraw()
            onPaired()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
