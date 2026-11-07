// SPDX-License-Identifier: Apache-2.0
import HomespunCore
import SwiftUI

/// Pairs the app with a server: one found on the network, a scanned or pasted pairing link,
/// or a typed address and code. Also leads to the setup guide.
struct ConnectView: View {
    @Bindable var settings: AppSettings
    var onPaired: () -> Void
    @State private var discovery = ServerDiscovery()
    @State private var address = ""
    @State private var code = ""
    @State private var scanning = false
    @State private var pairing = false
    @State private var error: String?
    @FocusState private var codeFocused: Bool

    var body: some View {
        List {
            Section {
                Text("On the computer that keeps your originals, run this. It shows a QR code: scan it with this "
                     + "iPhone's Camera app, or use one of the options below.")
                CommandRow(command: ServerSetup.serverCommand + " pair")
            }

            Section {
                ForEach(discovery.servers) { found in
                    Button {
                        if let url = found.url { address = url.host.map { "\($0):\(url.port ?? 8787)" } ?? "" }
                        codeFocused = true
                    } label: {
                        HStack {
                            Label(found.name, systemImage: "server.rack")
                            Spacer()
                            if let url = found.url { Text(url.host ?? "").font(.caption).foregroundStyle(.secondary) }
                            else { ProgressView().controlSize(.small) }
                        }
                    }
                    .accessibilityIdentifier("discovered.\(found.name)")
                }
                if discovery.servers.isEmpty {
                    if discovery.blocked {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Homespun can't look for servers", systemImage: "wifi.exclamationmark")
                            Text("Turn on Local Network for Homespun in Settings, or pair with a link or the address below.")
                                .font(.callout).foregroundStyle(.secondary)
                            Button("Open Settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                            }
                        }
                    } else {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Looking for servers on your network…").foregroundStyle(.secondary)
                        }
                        if discovery.foundNothing {
                            Text("None found yet. Check that the server is running and on the same network as this "
                                 + "iPhone. A Linux server also needs avahi-utils for this (its server check says so). "
                                 + "You can always pair with the link or the address and code instead.")
                                .font(.callout).foregroundStyle(.secondary)
                                .accessibilityIdentifier("discovery.none")
                        }
                    }
                }
            } header: {
                Text("On your network")
            } footer: {
                Text("Tap a server, then enter the code `homespun-server pair` shows.")
            }

            Section("Pair with a link") {
                if PairingScanner.isAvailable {
                    Button { scanning = true } label: { Label("Scan the QR code", systemImage: "qrcode.viewfinder") }
                }
                PasteButton(payloadType: String.self) { strings in
                    let link = strings.lazy.compactMap(PairingLink.init(text:)).first
                    Task { @MainActor in
                        if let link { await pair(link) } else { error = "That isn't a Homespun pairing link." }
                    }
                }
                .accessibilityIdentifier("connect.paste")
            }

            Section("Or enter the address and code") {
                TextField("Address, e.g. 192.168.1.20:8787", text: $address)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    .accessibilityIdentifier("server.address")
                TextField("Pairing code", text: $code)
                    .textInputAutocapitalization(.characters).autocorrectionDisabled()
                    .focused($codeFocused)
                    .accessibilityIdentifier("server.code")
                Button {
                    Task { await pair() }
                } label: {
                    if pairing { ProgressView() } else { Text("Pair") }
                }
                .disabled(address.isEmpty || code.isEmpty || pairing)
                .accessibilityIdentifier("server.pair")
            }

            if let error {
                Section { Text(error).foregroundStyle(.red).accessibilityIdentifier("server.error") }
            }

            Section {
                NavigationLink {
                    SetupGuideView()
                } label: {
                    Label("Don't have a server yet? Set one up", systemImage: "wrench.and.screwdriver")
                }
                .accessibilityIdentifier("connect.setup")
            }
        }
        .navigationTitle("Connect your server")
        .sheet(isPresented: $scanning) {
            PairingScanner { link in
                scanning = false
                Task { await pair(link) }
            }
            .ignoresSafeArea()
        }
        .onAppear { discovery.start() }
        .onDisappear { discovery.stop() }
    }

    private func pair(_ link: PairingLink? = nil) async {
        pairing = true
        defer { pairing = false }
        do {
            if let link { try await settings.pair(link) } else { try await settings.pair(address: address, code: code) }
            error = nil
            onPaired()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// A command to run on the server, with a copy button.
struct CommandRow: View {
    let command: String
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top) {
            Text(command)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                UIPasteboard.general.string = command
                copied = true
                Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Copy command")
        }
    }
}

/// Install steps for the computer that will be the server, by operating system.
struct SetupGuideView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var os: ServerSetup.OperatingSystem = .macOS
    @State private var packageManager: ServerSetup.PackageManager = .apt

    private var steps: [ServerSetup.Step] { ServerSetup.installSteps(for: os, packageManager: packageManager) }
    private var allCommands: String {
        steps.enumerated().map { index, step in
            "# \(index + 1). \(step.title)\n" + step.commands.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    var body: some View {
        List {
            Section {
                Picker("Server", selection: $os) {
                    Text("Mac").tag(ServerSetup.OperatingSystem.macOS)
                    Text("Linux").tag(ServerSetup.OperatingSystem.linux)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("setup.os")
                if os == .linux {
                    Picker("Distribution", selection: $packageManager) {
                        Text("Ubuntu, Debian").tag(ServerSetup.PackageManager.apt)
                        Text("Fedora, RHEL").tag(ServerSetup.PackageManager.dnf)
                        Text("Arch").tag(ServerSetup.PackageManager.pacman)
                        Text("openSUSE").tag(ServerSetup.PackageManager.zypper)
                    }
                }
            } footer: {
                Text(os == .macOS
                     ? "A Mac that stays on, like a Mac mini, works well. It also compresses Live Photos itself."
                     : "Any always-on Linux computer with room for your originals works.")
            }

            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                Section {
                    Text(step.detail).font(.callout).foregroundStyle(.secondary)
                    ForEach(step.commands, id: \.self) { CommandRow(command: $0) }
                } header: {
                    Text("\(index + 1). \(step.title)")
                }
            }

            Section {
                ShareLink(item: allCommands, subject: Text("Homespun Server setup")) {
                    Label("Send these steps to your computer", systemImage: "square.and.arrow.up")
                }
                Button {
                    dismiss()
                } label: {
                    Label("I've done this — find my server", systemImage: "checkmark.circle")
                }
                .accessibilityIdentifier("setup.done")
            } footer: {
                Text("After the last step, scan the QR code it shows, or go back and pick your server from the list. "
                     + "Homespun then checks the server and tells you if anything still needs installing.")
            }
        }
        .navigationTitle("Set up a server")
    }
}
