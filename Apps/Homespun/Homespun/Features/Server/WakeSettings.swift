// SPDX-License-Identifier: Apache-2.0
import SwiftUI

struct WakeSettingsView: View {
    let enrollment: WakeEnrollment
    var demo = false
    @State private var error: String?

    var body: some View {
        List {
            Section {
                if demo {
                    Text("The demo never enrolls for remote notifications.")
                        .accessibilityIdentifier("wake.demo")
                } else if let enabled = enrollment.enabled {
                    Toggle("Background Wakeups", isOn: Binding(get: { enabled }, set: change))
                        .disabled(!enrollment.available && !enabled)
                        .accessibilityIdentifier("wake.enabled")
                    if enrollment.busy { ProgressView("Updating private wake enrollment…") }
                } else {
                    Text("Checking the private wake setting…")
                }
            } footer: {
                Text("Optional. Your server can send an opaque hint through Homespun's relay and Apple so iOS may let "
                     + "Homespun check for completed copies. Delivery is not guaranteed. Backups still reconcile when "
                     + "iOS next lets the app run.")
            }
            Section {
                Text("The relay receives this iPhone's push token and an opaque route, never media, hashes, file names, "
                     + "server addresses or progress. Your home server gets only a scoped send credential. This is "
                     + "separate from permission to show local space-ready alerts.")
                if !enrollment.available, !demo {
                    Text("The optional relay is not configured in this build. No enrollment will be started.")
                        .foregroundStyle(Theme.secondaryLabel)
                }
                if enrollment.cleanupPending {
                    Text("An earlier enrollment still needs private cleanup. Homespun retains its deletion handle and retries.")
                        .accessibilityIdentifier("wake.cleanup")
                }
                if let problem = error ?? enrollment.problem {
                    Text(problem).foregroundStyle(Theme.secondaryLabel).accessibilityIdentifier("wake.problem")
                }
            }
        }
        .homespunList()
        .navigationTitle("Background Wakeups")
        .task {
            guard !demo else { return }
            do { try enrollment.load() }
            catch { self.error = error.localizedDescription }
        }
    }

    private func change(_ value: Bool) {
        guard !demo else { return }
        Task { @MainActor in
            do {
                try await enrollment.setEnabled(value)
                WakeSystem.updateRegistration(for: enrollment)
                error = nil
            } catch {
                if !value { WakeSystem.updateRegistration(for: enrollment) }
                self.error = error.localizedDescription
            }
        }
    }
}
