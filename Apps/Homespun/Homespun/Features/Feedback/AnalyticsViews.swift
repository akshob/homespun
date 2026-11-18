// SPDX-License-Identifier: Apache-2.0
import SwiftUI

/// What sharing analytics means, in the words used on the setup page and in Settings.
enum AnalyticsPromises {
    struct Promise: Identifiable {
        var id: String { symbol }
        let symbol: String
        let title: String
        let detail: String
    }

    static let all = [
        Promise(symbol: "chart.bar", title: "Rounded counts",
                detail: "How setup went, how big backups are, and which features get used."),
        Promise(symbol: "stethoscope", title: "Crash and speed reports",
                detail: "What iOS reports when Homespun crashes, hangs, or starts slowly."),
        Promise(symbol: "eye.slash", title: "Never your photos",
                detail: "No photos, file names, places, or server names. No account, nothing that identifies you."),
    ]
}

/// Setup: asked once, after pairing and before Photos access.
struct AnalyticsPage: View {
    let flow: SetupFlow

    var body: some View {
        SetupScaffold(symbol: "heart.text.square", title: "Help improve Homespun",
                      subtitle: "Share anonymous analytics with Homespun's developer.") {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(AnalyticsPromises.all) { promise in
                    PromiseRow(symbol: promise.symbol, title: promise.title, detail: promise.detail)
                }
            }
            .padding(.top, 8)
        } actions: {
            ConsequenceLine(text: "Change it any time in Server › Share Analytics.")
            PrimaryButton(title: "Share Analytics", id: "analytics.share") { flow.afterAnalytics(sharing: true) }
            SecondaryButton(title: "Don't Share", id: "analytics.dontShare") { flow.afterAnalytics(sharing: false) }
        }
    }
}

/// Server › This iPhone › Share Analytics.
struct AnalyticsSettingsView: View {
    /// The demo shows the choice but leaves it as the person made it (the demo records nothing).
    var demo = false
    @State private var telemetry = Telemetry.shared
    @State private var confirmingDelete = false
    @State private var deleting = false
    @State private var deleted = false
    @State private var error: String?

    var body: some View {
        List {
            if demo {
                Section {
                    InlineNotice(tone: .info, title: "The demo records nothing",
                                 message: "This choice is your own Homespun's, so it can't be changed in the demo.")
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            Section {
                Toggle("Share Analytics", isOn: Binding(get: { telemetry.isSharing },
                                                        set: { telemetry.setSharing($0); deleted = false }))
                    .tint(Theme.accent)
                    .disabled(demo)
                    .accessibilityIdentifier("analytics.toggle")
            } footer: {
                Text("Anonymous analytics help the developer see what works and fix what doesn't.")
            }
            .listRowBackground(Theme.card)
            Section("What's shared") {
                ForEach(AnalyticsPromises.all) { promise in
                    ActivityRow(symbol: promise.symbol, title: promise.title, detail: promise.detail)
                }
            }
            .listRowBackground(Theme.card)
            Section {
                Button(role: .destructive) { confirmingDelete = true } label: {
                    HStack {
                        Text("Delete Shared Data")
                        if deleting { Spacer(); ProgressView() }
                    }
                }
                .disabled(demo || deleting || !(telemetry.hasSharedData || telemetry.isSharing))
                .accessibilityIdentifier("analytics.delete")
                if deleted {
                    Label("Deleted", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.teal)
                        .accessibilityIdentifier("analytics.deleted")
                }
                if let error { FieldError(text: error) }
            } footer: {
                Text("Deletes everything this iPhone shared, including problem reports. Crash and speed reports also need "
                     + "Share With App Developers in Settings › Privacy & Security › Analytics & Improvements.")
            }
            .listRowBackground(Theme.card)
        }
        .homespunList()
        .navigationTitle("Share Analytics")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete what this iPhone shared?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Shared Data", role: .destructive) {
                Task {
                    deleting = true
                    error = nil
                    defer { deleting = false }
                    do {
                        try await telemetry.deleteSharedData()
                        deleted = true
                    } catch {
                        self.error = "Couldn't delete it now. Check the connection and try again."
                    }
                }
            }
        } message: {
            Text("Analytics, crash reports, and problem reports from this iPhone are deleted from the developer's service.")
        }
    }
}
