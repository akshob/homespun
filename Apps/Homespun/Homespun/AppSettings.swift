// SPDX-License-Identifier: Apache-2.0
import Foundation
import HomespunCore
import Observation
import SwiftUI
import UIKit

/// Where compact copies are made, and the paired server.
@MainActor @Observable
final class AppSettings {
    private let defaults: UserDefaults
    private(set) var serverURL: URL?
    private(set) var server: ServerAPI.ServerInfo?
    var useServer: Bool { didSet { defaults.set(useServer, forKey: "useServer") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        serverURL = defaults.url(forKey: "serverURL")
        server = defaults.data(forKey: "serverInfo").flatMap { try? ServerAPI.decoder.decode(ServerAPI.ServerInfo.self, from: $0) }
        useServer = defaults.bool(forKey: "useServer")
        if client == nil { useServer = false }
    }

    var client: ServerClient? {
        guard let serverURL, let token = Keychain.token(for: serverURL.absoluteString) else { return nil }
        return ServerClient(baseURL: serverURL, token: token)
    }

    var isPaired: Bool { client != nil && server != nil }
    var usesServer: Bool { useServer && isPaired }

    func compactor(ledger: CompactLedger) -> any Compacting {
        if usesServer, let client, let server {
            return ServerCompactor(client: client, mode: server.mode, profile: server.profile, ledger: ledger)
        }
        return OnDeviceCompactor(ledger: ledger)
    }

    func remover(ledger: CompactLedger) -> OriginalRemover? {
        guard let client, let server else { return nil }
        return OriginalRemover(client: client, mode: server.mode, ledger: ledger)
    }

    func pair(address: String, code: String) async throws {
        guard let url = ServerClient.normalizedURL(address) else {
            throw ServerClient.Failure(status: 0, message: "Enter the server's address, for example 192.168.1.20:8787.")
        }
        let response = try await ServerClient(baseURL: url).pair(code: code, deviceName: UIDevice.current.name)
        try Keychain.setToken(response.token, for: url.absoluteString)
        serverURL = url
        server = response.server
        defaults.set(url, forKey: "serverURL")
        defaults.set(try ServerAPI.encoder.encode(response.server), forKey: "serverInfo")
        useServer = true
    }

    /// Picks up server changes (for example a switch to Immich mode) before processing.
    func refreshServerInfo() async {
        guard let client, let info = try? await client.info() else { return }
        server = info
        defaults.set(try? ServerAPI.encoder.encode(info), forKey: "serverInfo")
    }

    func unpair() {
        if let serverURL { Keychain.removeToken(for: serverURL.absoluteString) }
        serverURL = nil
        server = nil
        useServer = false
        defaults.removeObject(forKey: "serverURL")
        defaults.removeObject(forKey: "serverInfo")
    }
}

struct SettingsView: View {
    @Bindable var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var code = ""
    @State private var pairing = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Make compact copies", selection: $settings.useServer) {
                        Text("On this iPhone").tag(false)
                        Text("On my server").tag(true)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .disabled(!settings.isPaired)
                    .accessibilityIdentifier("mode.picker")
                } header: {
                    Text("Make compact copies")
                } footer: {
                    Text(settings.isPaired
                         ? "With a server, originals are kept there and can be removed from this iPhone once verified."
                         : "Pair a Homespun Server to keep originals at home.")
                }

                if let server = settings.server, settings.isPaired {
                    Section("Server") {
                        LabeledContent("Name", value: server.name)
                        LabeledContent("Originals", value: server.mode == .immich ? "In Immich" : "On the server")
                        LabeledContent("Address", value: settings.serverURL?.absoluteString ?? "")
                        Button("Unpair", role: .destructive) { settings.unpair() }
                    }
                } else {
                    Section {
                        TextField("Address, e.g. 192.168.1.20:8787", text: $address)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                            .accessibilityIdentifier("server.address")
                        TextField("Pairing code", text: $code)
                            .textInputAutocapitalization(.characters).autocorrectionDisabled()
                            .accessibilityIdentifier("server.code")
                        Button {
                            Task { await pair() }
                        } label: {
                            if pairing { ProgressView() } else { Text("Pair") }
                        }
                        .disabled(address.isEmpty || code.isEmpty || pairing)
                        .accessibilityIdentifier("server.pair")
                        if let error { Text(error).foregroundStyle(.red).font(.callout).accessibilityIdentifier("server.error") }
                    } header: {
                        Text("Pair a server")
                    } footer: {
                        Text("On the server, run `homespun-server pair` to get a code. It works once and expires in 10 minutes.")
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func pair() async {
        pairing = true
        defer { pairing = false }
        do {
            try await settings.pair(address: address, code: code)
            error = nil
            code = ""
        } catch {
            self.error = error.localizedDescription
        }
    }
}
