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
    @State private var scanning = false
    @State private var pairing = false
    @State private var error: String?
    @State private var target: ServerPairView.Target?
    @State private var paired = false

    var body: some View {
        List {
            Section {
                Text("Tap the computer that keeps your originals. A Mac asks you to click Allow on its screen; "
                     + "a Linux server gives you a code.")
            }

            Section {
                ForEach(discovery.servers) { found in
                    Button {
                        if let url = found.url { target = .init(url: url, name: found.name) }
                    } label: {
                        HStack {
                            Label(found.name, systemImage: "server.rack")
                            Spacer()
                            if let url = found.url { Text(url.host ?? "").font(.caption).foregroundStyle(.secondary) }
                            else { ProgressView().controlSize(.small) }
                        }
                    }
                    .disabled(found.url == nil)
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
            }

            Section {
                TextField("Address, e.g. 192.168.1.20:8787", text: $address)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    .accessibilityIdentifier("server.address")
                    .onSubmit(continueWithAddress)
                Button("Continue", action: continueWithAddress)
                    .disabled(address.isEmpty)
                    .accessibilityIdentifier("server.continue")
            } header: {
                Text("Or enter its address")
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
        .sheet(item: $target, onDismiss: {
            // After the pairing sheet has gone, so the next screen isn't presented under it.
            if paired {
                paired = false
                onPaired()
            }
        }) { target in
            ServerPairView(settings: settings, target: target) {
                paired = true
                self.target = nil
            }
        }
        .onAppear { discovery.start() }
        .onDisappear { discovery.stop() }
    }

    private func continueWithAddress() {
        guard let url = PairingLink.serverURL(from: address) else {
            error = "Enter the server's address, for example 192.168.1.20:8787."
            return
        }
        error = nil
        target = .init(url: url, name: nil)
    }

    private func pair(_ link: PairingLink) async {
        pairing = true
        defer { pairing = false }
        do {
            try await settings.pair(link)
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
