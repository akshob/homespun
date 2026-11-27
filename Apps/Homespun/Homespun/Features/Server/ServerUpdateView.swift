// SPDX-License-Identifier: Apache-2.0
import SwiftUI

struct ServerUpdateNotice: View {
    let controller: LibraryController

    var body: some View {
        if controller.settings.needsBackupUpdate, !controller.settings.updateNoticeDismissed {
            InlineNotice(tone: .info, title: controller.settings.updateTitle, message: controller.updateMessage) {
                Button("How to Update") { controller.settings.showingServerUpdate = true }
                Button("Check Again") { Task { await controller.refresh() } }
                Button("Dismiss", systemImage: "xmark") { controller.settings.updateNoticeDismissed = true }
                    .labelStyle(.iconOnly)
            }
            .accessibilityIdentifier("server.updateNotice")
        }
    }
}

struct ServerUpdatePresentation: ViewModifier {
    @Bindable var settings: AppSettings

    func body(content: Content) -> some View {
        content
            .alert("\(settings.server?.name ?? "Your server") needs an update", isPresented: $settings.showingBackUpUpdate) {
                Button("How to Update") { settings.showingServerUpdate = true }
                Button("OK", role: .cancel) {}
            } message: {
                Text("This version of Homespun backs up with Homespun Server 1.1 or later. Your existing backups aren't affected.")
            }
            .sheet(isPresented: $settings.showingServerUpdate) {
                ServerUpdateView(name: settings.server?.name ?? "your server")
            }
    }
}

private struct ServerUpdateView: View {
    let name: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Mac or Linux") {
                    Text("In the folder where you installed it, run git pull, rebuild, and rerun homespun-server install-service with the same data folder.")
                }
                Section("Docker or NAS") {
                    Text("Pull ghcr.io/akshob/homespun-server:latest and recreate the container with the same folders.")
                }
                Section {
                    Text("Your originals, settings and this iPhone's pairing stay as they are.")
                }
            }
            .navigationTitle("Update \(name)")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
