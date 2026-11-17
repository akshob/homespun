// SPDX-License-Identifier: Apache-2.0
import StoreKit
import SwiftUI

/// What Premium adds, with the one-time purchase and Restore Purchases (DESIGN 05·1.1, 1.4). The
/// price comes from StoreKit; nothing free is ever locked.
struct PremiumView: View {
    let premium: Premium
    /// For the links after unlocking (Turn On Automatic Mode, Set Up Cloud Copies).
    var model: AppModel?
    @State private var working = false
    @State private var message: String?
    @State private var justUnlocked = false
    @Environment(\.dismiss) private var dismiss

    private var server: String { model?.library.serverName ?? "Your server" }

    var body: some View {
        ScrollView {
            if justUnlocked { unlocked } else { features }
        }
        .background(Theme.background)
        .safeAreaBar(edge: .bottom) { bottomBar }
        .navigationBarTitleDisplayMode(.inline)
        .task {
            Telemetry.shared.record(.premium("shown"))
            await premium.load()
        }
    }

    private var features: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Image(systemName: "sparkles").font(.system(size: 44)).foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
                Text("Homespun Premium").displayTitle().multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text("One purchase. Yours to keep.").font(.title3).foregroundStyle(Theme.secondaryLabel)
            }
            .padding(.top, 12)
            VStack(alignment: .leading, spacing: 14) {
                feature("bolt.fill", "Automatic mode",
                        "New photos are backed up and compacted on their own, usually overnight while charging. You "
                            + "still choose when to free up space.")
                Divider().overlay(Theme.separator)
                feature("icloud.and.arrow.up", "Cloud copies",
                        "\(server) also copies each original to OneDrive (Google Photos and others later), as an extra "
                            + "backup.")
            }
            .card()
            feature("checkmark.circle", "Always free",
                    "Backing up, compact copies, freeing up space, quality settings and every safety check.",
                    tint: Theme.teal)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
            if premium.purchased {
                InlineNotice(tone: .success, title: "Unlocked. Thank you!")
                    .accessibilityIdentifier("premium.unlocked")
            } else if premium.ownBuild {
                InlineNotice(tone: .success, title: "Unlocked in this build of the app")
                    .accessibilityIdentifier("premium.unlocked")
            } else if premium.beta {
                InlineNotice(tone: .success, title: "Unlocked while you test with TestFlight")
                    .accessibilityIdentifier("premium.unlocked")
            }
            if let message {
                InlineNotice(tone: .info, title: message).accessibilityIdentifier("premium.message")
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
    }

    /// After buying here: straight on to the features (05·1.4).
    private var unlocked: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 48)).foregroundStyle(Theme.teal)
                .accessibilityHidden(true)
            Text("Premium unlocked").displayTitle().accessibilityAddTraits(.isHeader)
            Text("Thank you. Both features are ready when you are.").foregroundStyle(Theme.secondaryLabel)
            if let model {
                VStack(spacing: 0) {
                    NavigationLink { AutomaticModeView(model: model) } label: {
                        ServerRow(title: "Turn On Automatic Mode", symbol: "bolt.fill", value: nil, chevron: true)
                    }
                    Divider().overlay(Theme.separator).padding(.leading, 42)
                    NavigationLink { ConnectorsView(settings: model.settings, premium: premium) } label: {
                        ServerRow(title: "Set Up Cloud Copies", symbol: "icloud.and.arrow.up", value: nil, chevron: true)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                .card(padding: 12)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var bottomBar: some View {
        VStack(spacing: 10) {
            if justUnlocked {
                Button { dismiss() } label: { Text("Done").frame(maxWidth: .infinity) }.primaryAction()
            } else if !premium.isUnlocked {
                let unavailable = !premium.loading && premium.product == nil
                if unavailable {
                    Text("The App Store isn't available right now.").font(.footnote).foregroundStyle(Theme.secondaryLabel)
                }
                Button { Task { await buy() } } label: {
                    BusyLabel(title: premium.product.map { "Unlock Premium · \($0.displayPrice)" } ?? "Unlock Premium",
                              busy: working)
                        .frame(maxWidth: .infinity)
                }
                .primaryAction()
                .disabled(working || premium.product == nil)
                .accessibilityIdentifier("premium.buy")
                Button("Restore Purchases") { Task { await restore() } }
                    .tint(Theme.accent)
                    .disabled(working)
                    .accessibilityIdentifier("premium.restore")
                Text("One-time purchase · Family Sharing included").font(.footnote).foregroundStyle(Theme.secondaryLabel)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    private func feature(_ icon: String, _ title: String, _ text: String, tint: Color = Theme.accent) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.title3).foregroundStyle(tint).frame(width: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline).foregroundStyle(Theme.label)
                Text(text).font(.subheadline).foregroundStyle(Theme.secondaryLabel)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func buy() async {
        working = true
        defer { working = false }
        do {
            let outcome = try await premium.purchase()
            Telemetry.shared.record(.premium("purchase", outcome: String(describing: outcome)))
            switch outcome {
            case .purchased:
                message = nil
                justUnlocked = true
                Announce.say("Premium unlocked.")
            case .pending: message = "Waiting for approval. Premium unlocks when it's approved."
            case .cancelled: break
            }
        } catch {
            message = error.localizedDescription
        }
    }

    private func restore() async {
        working = true
        defer { working = false }
        do {
            try await premium.restore()
            message = premium.purchased ? nil : "This Apple Account hasn't bought Premium."
        } catch {
            message = error.localizedDescription
        }
    }
}

/// A feature the one-time purchase unlocks (both of them, whichever is turned on first).
enum PremiumFeature: String, Identifiable {
    case automatic, cloudCopies
    var id: String { rawValue }

    var name: String { self == .automatic ? "Automatic Mode" : "Cloud Copies" }
    var symbol: String { self == .automatic ? "bolt.fill" : "icloud.and.arrow.up" }
}

/// Turning on automatic mode or cloud copies before the purchase (DESIGN 05·1.2): what it does, the
/// price, and Restore Purchase. One purchase unlocks both. `unlocked` runs once it's unlocked, so
/// the presenter carries on with what the person started after the sheet has closed.
struct UnlockSheet: View {
    let feature: PremiumFeature
    let premium: Premium
    var server = "Your server"
    var unlocked: () -> Void
    @State private var working = false
    @State private var message: String?
    @State private var finished = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    Image(systemName: feature.symbol).font(.system(size: 32)).foregroundStyle(Theme.accent)
                        .accessibilityHidden(true)
                    Text("Turn On \(feature.name)")
                        .font(.title2.weight(.semibold)).foregroundStyle(Theme.label).multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    Text(feature == .automatic
                         ? "New photos and videos back up on their own, usually overnight while this iPhone charges. "
                            + "Homespun tells you when there's space to free up; you still choose when."
                         : "\(server) also copies each original to OneDrive, as an extra backup. Freeing up space "
                            + "still depends only on \(server)'s own copy.")
                        .font(.subheadline).foregroundStyle(Theme.secondaryLabel).multilineTextAlignment(.center)
                    Text("A one-time purchase unlocks Automatic Mode and Cloud Copies, on all your devices with this "
                         + "Apple Account.")
                        .font(.subheadline).foregroundStyle(Theme.label).multilineTextAlignment(.center)
                        .accessibilityIdentifier("unlock.both")
                    if !premium.loading && premium.product == nil {
                        Text("The App Store isn't available right now.").font(.footnote)
                            .foregroundStyle(Theme.secondaryLabel)
                    }
                    Button { Task { await buy() } } label: {
                        BusyLabel(title: premium.product.map { "Unlock for \($0.displayPrice)" } ?? "Unlock", busy: working)
                            .frame(maxWidth: .infinity)
                    }
                    .primaryAction()
                    .disabled(working || premium.product == nil)
                    .padding(.top, 6)
                    .accessibilityIdentifier("unlock.buy")
                    Button("Restore Purchase") { Task { await restore() } }
                        .tint(Theme.accent)
                        .disabled(working)
                        .accessibilityIdentifier("unlock.restore")
                    if let message {
                        Text(message).font(.footnote).foregroundStyle(Theme.secondaryLabel).multilineTextAlignment(.center)
                            .accessibilityIdentifier("unlock.message")
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Label("Close", systemImage: "xmark") }
                        .accessibilityIdentifier("unlock.close")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task {
            Telemetry.shared.record(.premium("shown.\(feature.rawValue)"))
            await premium.load()
        }
        // Bought, restored, approved (Ask to Buy) or found owned while open: carry on.
        .onChange(of: premium.isUnlocked) { _, isUnlocked in
            if isUnlocked { finish() }
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        unlocked()
        dismiss()
    }

    private func buy() async {
        working = true
        defer { working = false }
        do {
            let outcome = try await premium.purchase()
            Telemetry.shared.record(.premium("purchase", outcome: String(describing: outcome)))
            switch outcome {
            case .purchased:
                Announce.say("Unlocked.")
                finish()
            case .pending: message = "Waiting for approval. Once it's approved, turn it on again."
            case .cancelled: break
            }
        } catch {
            message = error.localizedDescription
        }
    }

    private func restore() async {
        working = true
        defer { working = false }
        do {
            try await premium.restore()
            if premium.isUnlocked { finish() } else { message = "This Apple Account hasn't bought it yet." }
        } catch {
            message = error.localizedDescription
        }
    }
}
