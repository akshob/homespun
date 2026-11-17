// SPDX-License-Identifier: Apache-2.0
import CoreImage.CIFilterBuiltins
import HomespunCore
import SwiftUI

/// Who is paired with the server (DESIGN 04·3.1): this iPhone first, the others removable.
struct DevicesView: View {
    let settings: AppSettings
    /// Opens this iPhone's name (and folder) to change it.
    var rename: (() -> Void)?
    var addDevice: () -> Void
    @State private var devices: [ServerAPI.DeviceInfo]?
    @State private var error: String?
    @State private var removing: ServerAPI.DeviceInfo?

    private var server: String { settings.server?.name ?? "the server" }

    var body: some View {
        List {
            if let devices {
                Section {
                    ForEach(devices.sorted { $0.isThisDevice && !$1.isThisDevice }) { device in
                        Group {
                            if device.isThisDevice, let rename {
                                Button(action: rename) {
                                    HStack {
                                        DeviceRow(device: device, isElement: false)
                                        Spacer(minLength: 0)
                                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                                            .foregroundStyle(Theme.tertiaryLabel).accessibilityHidden(true)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                // One element: the row's words, as a button that renames it.
                                .accessibilityElement(children: .combine)
                                .accessibilityIdentifier("devices.this")
                                .accessibilityHint("Renames this iPhone and its folder on \(server).")
                            } else {
                                DeviceRow(device: device)
                            }
                        }
                            .swipeActions {
                                if !device.isThisDevice {
                                    Button("Remove", role: .destructive) { removing = device }
                                }
                            }
                            .accessibilityAction(named: "Remove") { if !device.isThisDevice { removing = device } }
                    }
                } footer: {
                    Text("Tap this iPhone to rename it. Swipe to remove another device; it can pair again with a new code.")
                }
                .listRowBackground(Theme.card)
            } else if let error {
                Section {
                    InlineNotice(tone: .error, title: "Couldn't load the devices", message: error) {
                        Button("Try Again") { Task { await load() } }.tint(Theme.accent)
                    }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            } else {
                Section { ProgressView().frame(maxWidth: .infinity) }.listRowBackground(Theme.card)
            }
            Section {
                Button(action: addDevice) {
                    HStack(spacing: 14) {
                        Image(systemName: "plus").frame(width: 28).accessibilityHidden(true)
                        Text("Add Another Device")
                        Spacer()
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.tertiaryLabel).accessibilityHidden(true)
                    }
                    .foregroundStyle(Theme.accent)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings.addDevice")
            }
            .listRowBackground(Theme.card)
        }
        .homespunList()
        .navigationTitle("Devices")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .alert("Remove \(removing?.name ?? "this device")?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) { if let removing { Task { await remove(removing) } } }
        } message: {
            Text("It stops backing up to \(server). Its originals stay on \(server). It can pair again with a new code.")
        }
    }

    private func load() async {
        guard let client = settings.client else { return }
        do {
            devices = try await client.devices()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func remove(_ device: ServerAPI.DeviceInfo) async {
        guard let client = settings.client else { return }
        do {
            try await client.removeDevice(device.id)
            devices?.removeAll { $0.id == device.id }
            Announce.say("Removed \(device.name).")
        } catch {
            self.error = error.localizedDescription
            devices = nil
        }
    }
}

private struct DeviceRow: View {
    let device: ServerAPI.DeviceInfo
    /// False inside a button, which is the element then.
    var isElement = true

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: device.name.localizedCaseInsensitiveContains("ipad") ? "ipad" : "iphone")
                .font(.title3).foregroundStyle(Theme.accent).frame(width: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name).foregroundStyle(Theme.label)
                Text(detail).font(.subheadline).foregroundStyle(Theme.secondaryLabel)
            }
        }
        .padding(.vertical, 2)
        .modifier(DeviceRowElement(isElement: isElement, identifier: device.isThisDevice ? "devices.this" : "devices.other"))
    }

    /// "This iPhone · paired Nov 6" or "Paired Oct 2 · last seen yesterday".
    private var detail: String {
        var parts: [String] = []
        if device.isThisDevice { parts.append("This iPhone") }
        if let paired = device.pairedAt {
            let date = paired.formatted(.dateTime.month(.abbreviated).day())
            parts.append(device.isThisDevice ? "paired \(date)" : "Paired \(date)")
        }
        if !device.isThisDevice, let seen = device.lastSeenAt {
            parts.append("last seen \(seen.formatted(.relative(presentation: .named)))")
        }
        return parts.isEmpty ? "Paired" : parts.joined(separator: " · ")
    }
}

/// A one-time code and QR code that pair another iPhone or iPad with this server (04·3.2). The
/// time left counts down; when it runs out the QR dims and New Code becomes the main button.
struct AddDeviceView: View {
    let settings: AppSettings
    @State private var link: PairingLink?
    @State private var expires: Date?
    @State private var error: String?
    @State private var loading = false
    @State private var announced = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let left = expires.map { max(0, $0.timeIntervalSince(context.date)) } ?? 0
            let expired = link != nil && left <= 0
            List {
                if let link {
                    Section {
                        VStack(spacing: 14) {
                            if let image = Self.qrCode(link.url.absoluteString) {
                                Image(uiImage: image).interpolation(.none).resizable().scaledToFit()
                                    .padding(16)
                                    .frame(maxWidth: 240)
                                    .background(.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.separator))
                                    .opacity(expired ? 0.25 : 1)
                                    .accessibilityLabel("Pairing QR code for \(settings.server?.name ?? "the server")")
                            }
                            Text("On the other iPhone or iPad, open the Camera and point it here.")
                                .font(.subheadline).foregroundStyle(Theme.secondaryLabel).multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .listRowBackground(Color.clear)
                    Section {
                        LabeledContent("Address", value: link.serverURL.host.map { "\($0):\(link.serverURL.port ?? 8787)" } ?? "")
                        LabeledContent("Code", value: link.code)
                            .accessibilityValue(link.code.map { String($0) }.joined(separator: " "))
                            .accessibilityIdentifier("addDevice.code")
                    } header: {
                        Text("Or enter these in Homespun there")
                    } footer: {
                        Text(expired ? "This code has expired. New Code makes another." : Self.footer(left))
                    }
                    .listRowBackground(Theme.card)
                    Section {
                        newCodeButton(prominent: expired)
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                } else if let error {
                    Section {
                        InlineNotice(tone: .error, title: "Couldn't make a code", message: error)
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    Section { newCodeButton(prominent: true) }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                } else {
                    Section { ProgressView().frame(maxWidth: .infinity) }.listRowBackground(Color.clear)
                }
            }
            .onChange(of: left <= 60 && left > 0) { _, soon in
                if soon, !announced {
                    announced = true
                    Announce.say("The pairing code works for 1 more minute.")
                }
            }
        }
        .homespunList()
        .navigationTitle("Add Device")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    @ViewBuilder private func newCodeButton(prominent: Bool) -> some View {
        let button = Button { Task { await load() } } label: {
            BusyLabel(title: "New Code", systemImage: "arrow.clockwise", busy: loading).frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .disabled(loading)
        .accessibilityIdentifier("addDevice.newCode")
        if prominent {
            button.buttonStyle(.glassProminent).tint(Theme.accent)
        } else {
            button.buttonStyle(.bordered).tint(Theme.accent)
        }
    }

    /// "This code works once, for 9 more minutes." (seconds under a minute).
    static func footer(_ left: TimeInterval) -> String {
        let time = left >= 60 ? "\(Int((left / 60).rounded(.up))) more minutes" : "\(Int(left)) more seconds"
        return "This code works once, for \(time). New Code replaces it."
    }

    private func load() async {
        guard let client = settings.client, let url = settings.serverURL else { return }
        loading = true
        defer { loading = false }
        do {
            let code = try await client.newPairingCode()
            link = PairingLink(serverURL: url, code: code.code, name: settings.server?.name)
            expires = Date().addingTimeInterval(TimeInterval(code.expiresIn))
            announced = false
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    static func qrCode(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let image = filter.outputImage,
              let cgImage = CIContext().createCGImage(image, from: image.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

private struct DeviceRowElement: ViewModifier {
    let isElement: Bool
    let identifier: String

    func body(content: Content) -> some View {
        if isElement {
            content.accessibilityElement(children: .combine).accessibilityIdentifier(identifier)
        } else {
            content
        }
    }
}

/// This iPhone's name on the server, which is also the name of its originals folder there: renaming
/// it renames the folder (the server moves it, with everything in it).
struct DeviceNameView: View {
    let settings: AppSettings
    var renamed: (ServerAPI.DeviceInfo) -> Void = { _ in }
    @State private var device: ServerAPI.DeviceInfo?
    @State private var name = ""
    @State private var working = false
    @State private var error: String?
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    private var server: String { settings.server?.name ?? "the server" }
    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool {
        guard let device, !working else { return false }
        return !trimmed.isEmpty && trimmed.count <= ServerAPI.RenameDeviceRequest.maximumLength && trimmed != device.name
    }

    var body: some View {
        List {
            Section {
                TextField("Name", text: $name, prompt: Text("Akshob’s iPhone"))
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit { if canSave { Task { await save() } } }
                    .disabled(device == nil || working)
                    .accessibilityIdentifier("device.name")
                if let error {
                    Text(error).font(.subheadline).foregroundStyle(Theme.red).accessibilityIdentifier("device.name.error")
                }
            } footer: {
                if let folder = device?.folder {
                    Text("This iPhone’s originals are in the folder “\(folder)” on \(server). Renaming this iPhone renames "
                         + "that folder too; everything in it stays as it is.")
                } else if device == nil, error == nil {
                    ProgressView()
                }
            }
            .listRowBackground(Theme.card)
        }
        .homespunList()
        .navigationTitle("Name")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(role: .confirm) { Task { await save() } } label: {
                    if working { ProgressView() } else { Label("Save", systemImage: "checkmark") }
                }
                .disabled(!canSave)
                .accessibilityIdentifier("device.name.save")
            }
        }
        .task { await load() }
    }

    private func load() async {
        guard let client = settings.client else { return }
        do {
            let this = try await client.devices().first(where: \.isThisDevice)
            device = this
            name = this?.name ?? ""
            focused = true
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save() async {
        guard let client = settings.client, let device else { return }
        working = true
        error = nil
        defer { working = false }
        do {
            let updated = try await client.renameDevice(device.id, to: trimmed)
            renamed(updated)
            Announce.say("Renamed to \(updated.name).")
            dismiss()
        } catch let failure as ServerClient.Failure where failure.status == 404 || failure.status == 405 {
            error = "Update Homespun Server on \(server) to rename this iPhone."
        } catch {
            self.error = error.localizedDescription
        }
    }
}
