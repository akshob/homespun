// SPDX-License-Identifier: Apache-2.0
import SwiftUI

struct IdentityProblemView: View {
    let settings: AppSettings
    var pairAgain: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingUnpair = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(settings.connectionProblem ?? "Check your server's identity", systemImage: "lock.trianglebadge.exclamationmark")
                        .font(.headline)
                    Text("Homespun stopped sending anything to this server because it couldn't confirm the security key "
                         + "with this iPhone's pairing. This can happen after reinstalling without the data folder, "
                         + "or if another device is pretending to be your server.")
                    if let fingerprint = settings.pins?.pins.first {
                        LabeledContent("Expected key", value: fingerprint.display)
                    }
                    if let fingerprint = settings.identityObserved {
                        LabeledContent("Server now shows", value: fingerprint.display)
                    }
                    Text("On the server, homespun-server certificate shows its key. Update Homespun Server to 0.2 or later "
                         + "if it doesn't support encrypted connections.")
                }
                Section {
                    Button("Pair Again") {
                        dismiss()
                        Task { try? await Task.sleep(for: .milliseconds(350)); pairAgain() }
                    }
                    Button("Check Again") { Task { await settings.reverifyIdentity(); await settings.refreshServerInfo() } }
                    Button("Unpair", role: .destructive) { confirmingUnpair = true }
                }
            }
            .navigationTitle("Can't confirm this is your server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Unpair from this server?", isPresented: $confirmingUnpair, titleVisibility: .visible) {
                Button("Unpair", role: .destructive) { settings.unpair(); dismiss() }
            }
        }
    }
}
