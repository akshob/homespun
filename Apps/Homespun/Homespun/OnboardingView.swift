// SPDX-License-Identifier: Apache-2.0
import HomespunCore
import Photos
import SwiftUI

/// The first-run flow: what Homespun does, connecting a server (and checking it), and Photos access.
struct OnboardingView: View {
    enum Step: Hashable { case connect, check, photos }

    @Bindable var settings: AppSettings
    @State private var path: [Step] = []

    var body: some View {
        NavigationStack(path: $path) {
            WelcomeView { path.append(settings.isPaired ? .check : .connect) }
                .navigationDestination(for: Step.self) { step in
                    switch step {
                    case .connect:
                        ConnectView(settings: settings) { path.append(.check) }
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) {
                                    Button("Skip") { path.append(.photos) }.accessibilityIdentifier("onboarding.skip")
                                }
                            }
                    case .check:
                        ServerCheckView(settings: settings) { path.append(.photos) }
                    case .photos:
                        PhotosAccessView { settings.onboardingComplete = true }
                    }
                }
        }
        .sheet(item: $settings.pendingLink) { link in
            PairConfirmView(settings: settings, link: link) {
                if path.last != .check { path.append(.check) }
            }
        }
    }
}

struct WelcomeView: View {
    var start: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "photo.stack.fill").font(.system(size: 56)).foregroundStyle(.tint)
                    Text("Homespun").font(.largeTitle.bold())
                    Text("Originals at home. Compact copies on your iPhone.").font(.title3).foregroundStyle(.secondary)
                }
                Feature(icon: "server.rack", title: "Originals stay full quality",
                        text: "They're kept on your own computer, a Mac or Linux server, or found in your Immich library.")
                Feature(icon: "photo.on.rectangle.angled", title: "Compact copies in Photos",
                        text: "About a fifth of the size, with the same date, place, favorites, and Live Photo motion.")
                Feature(icon: "checkmark.shield", title: "Nothing is lost",
                        text: "An original leaves this iPhone only after your server proves it has an identical copy, "
                            + "and iOS always asks you first.")
            }
            .padding(24)
        }
        .safeAreaInset(edge: .bottom) {
            Button(action: start) {
                Text("Get started").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(24)
            .background(.bar)
            .accessibilityIdentifier("onboarding.start")
        }
    }

    private struct Feature: View {
        let icon: String, title: String, text: String

        var body: some View {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: icon).font(.title2).foregroundStyle(.tint).frame(width: 36)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(text).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Explains why Homespun needs full Photos access, then asks.
struct PhotosAccessView: View {
    var done: () -> Void
    @State private var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "photo.on.rectangle").font(.system(size: 48)).foregroundStyle(.tint)
                Text("Allow access to your photos").font(.title.bold())
                Text("Homespun reads the originals you choose, saves compact copies to a Homespun album, and removes "
                     + "originals only when you ask. To do that, it needs Full Access.")
                    .foregroundStyle(.secondary)
                switch status {
                case .limited:
                    Text("With limited access, Homespun can't read originals or save copies. Choose Full Access in Settings.")
                        .foregroundStyle(.orange)
                case .denied, .restricted:
                    Text("Access is off. You can turn it on in Settings.").foregroundStyle(.orange)
                default:
                    EmptyView()
                }
            }
            .padding(24)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 12) {
                switch status {
                case .notDetermined:
                    Button {
                        Task {
                            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
                            if status == .authorized { done() }
                        }
                    } label: { Text("Allow access").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .accessibilityIdentifier("photos.allow")
                case .authorized:
                    Button(action: done) { Text("Done").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .accessibilityIdentifier("photos.done")
                default:
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    } label: { Text("Open Settings").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    Button("Continue without access", action: done)
                }
            }
            .padding(24)
            .background(.bar)
        }
        .navigationTitle("")
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        }
    }
}

/// Confirms a pairing link opened from the Camera app or another app.
struct PairConfirmView: View {
    @Bindable var settings: AppSettings
    let link: PairingLink
    var paired: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "server.rack").font(.system(size: 48)).foregroundStyle(.tint)
                // The name comes from the link, so it can't be trusted to tell servers apart.
                Text(replacing == nil ? "Pair with \(link.name ?? "this server")?" : "Switch to a different server?")
                    .font(.title2.bold()).multilineTextAlignment(.center)
                Text(link.serverURL.host.map { "\($0):\(link.serverURL.port ?? 8787)" } ?? link.serverURL.absoluteString)
                    .font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                if let current = replacing {
                    // Links can come from any app or web page; switching servers must be deliberate.
                    Label {
                        Text("This iPhone is paired with \(current). Pairing replaces it: new items go to this server, "
                             + "and originals already on \(current) stay there. Only pair with a server you set up.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    .font(.callout)
                    .accessibilityIdentifier("pair.replaces")
                }
                if let error { Text(error).foregroundStyle(.red).multilineTextAlignment(.center) }
                Spacer()
                Button {
                    Task { await pair() }
                } label: {
                    if working {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text(replacing.map { "Replace \($0)" } ?? "Pair").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .tint(replacing == nil ? nil : .red)
                .disabled(working)
                .accessibilityIdentifier("pair.confirm")
            }
            .padding(24)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents(replacing == nil ? [.medium] : [.large])
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
            dismiss()
            paired()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

extension PairingLink: @retroactive Identifiable {
    public var id: String { url.absoluteString }
}
