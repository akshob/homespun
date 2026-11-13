// SPDX-License-Identifier: Apache-2.0
import StoreKit
import SwiftUI

/// What Premium adds, with the one-time purchase and Restore purchases.
struct PremiumView: View {
    let premium: Premium
    @State private var working = false
    @State private var message: String?

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Homespun Premium", systemImage: "sparkles").font(.title2.bold())
                    Text("One purchase, yours to keep. Backing up, compact copies, and freeing up space stay free.")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            Section {
                feature("bolt.badge.clock", "Automatic mode",
                        "New photos are backed up and compacted on their own, usually overnight while charging. "
                        + "Homespun tells you when there's space to free up.")
                feature("icloud.and.arrow.up", "Cloud copies",
                        "Your server also copies each original to OneDrive and other services, as an extra backup.")
            }
            Section {
                if premium.purchased {
                    Label("Unlocked. Thank you!", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                        .accessibilityIdentifier("premium.unlocked")
                } else if premium.ownBuild {
                    Label("Unlocked in this build of the app", systemImage: "hammer").foregroundStyle(.green)
                        .accessibilityIdentifier("premium.unlocked")
                } else {
                    Button {
                        Task { await buy() }
                    } label: {
                        HStack {
                            Text("Unlock Premium")
                            Spacer()
                            if working { ProgressView() } else { Text(premium.product?.displayPrice ?? "") }
                        }
                    }
                    .disabled(working || premium.product == nil)
                    .accessibilityIdentifier("premium.buy")
                    Button("Restore purchases") { Task { await restore() } }
                        .disabled(working)
                        .accessibilityIdentifier("premium.restore")
                }
                if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
            } footer: {
                if !premium.isUnlocked {
                    Text("A one-time purchase. Family Sharing includes your family.")
                }
            }
        }
        .navigationTitle("Premium")
        .task { await premium.load() }
    }

    private func feature(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.title3).foregroundStyle(.tint).frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func buy() async {
        working = true
        defer { working = false }
        do {
            switch try await premium.purchase() {
            case .purchased: message = nil
            case .pending: message = "Waiting for approval (Ask to Buy). Premium unlocks when it's approved."
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
