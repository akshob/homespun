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
        .task { await premium.load() }
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
                    NavigationLink { ConnectorsView(settings: model.settings) } label: {
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
            switch try await premium.purchase() {
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

/// A Premium feature tapped while locked.
enum PremiumFeature: String, Identifiable {
    case automatic, cloudCopies
    var id: String { rawValue }
}

/// Explains the one feature tapped, in a medium sheet (05·1.2).
struct PremiumFeatureSheet: View {
    let feature: PremiumFeature
    let premium: Premium
    var seeAll: () -> Void
    @State private var working = false
    @State private var message: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    Image(systemName: feature == .automatic ? "bolt.fill" : "icloud.and.arrow.up")
                        .font(.system(size: 36)).foregroundStyle(Theme.accent).accessibilityHidden(true)
                    Text(feature == .automatic ? "Automatic mode is part of Premium" : "Cloud copies are part of Premium")
                        .font(.title2.weight(.semibold)).foregroundStyle(Theme.label).multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    Text(feature == .automatic
                         ? "New photos back up on their own, usually overnight while charging. Homespun tells you when "
                            + "there's space to free up."
                         : "Your server also copies each original to OneDrive, as an extra backup. Freeing up space "
                            + "still depends only on your server's own copy.")
                        .font(.subheadline).foregroundStyle(Theme.secondaryLabel).multilineTextAlignment(.center)
                    Button { Task { await buy() } } label: {
                        BusyLabel(title: premium.product.map { "Unlock · \($0.displayPrice)" } ?? "Unlock", busy: working)
                            .frame(maxWidth: .infinity)
                    }
                    .primaryAction()
                    .disabled(working || premium.product == nil)
                    .padding(.top, 6)
                    .accessibilityIdentifier("premium.feature.buy")
                    Button("See Everything in Premium", action: seeAll)
                        .tint(Theme.accent)
                        .accessibilityIdentifier("premium.seeAll")
                    if let message { Text(message).font(.footnote).foregroundStyle(Theme.secondaryLabel) }
                }
                .padding(.horizontal, 24)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Label("Close", systemImage: "xmark") }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task { await premium.load() }
    }

    private func buy() async {
        working = true
        defer { working = false }
        do {
            switch try await premium.purchase() {
            case .purchased: dismiss()
            case .pending: message = "Waiting for approval. Premium unlocks when it's approved."
            case .cancelled: break
            }
        } catch {
            message = error.localizedDescription
        }
    }
}
