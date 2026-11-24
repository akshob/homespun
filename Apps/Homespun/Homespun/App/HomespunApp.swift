// SPDX-License-Identifier: Apache-2.0
import SwiftUI

@main
struct HomespunApp: App {
    @UIApplicationDelegateAdaptor(WakeAppDelegate.self) private var wakeDelegate
    init() {
        PerfMonitor.mainStarted = CACurrentMediaTime()
        Task.detached(priority: .utility) { Keychain.removeLegacyReviewCode() }
        AppModel.registerBackgroundRun()
        BackupAlertDelegate.install()
        Journey.configureTips()
        MetricsReceiver.shared.start()
        _ = SessionMarker.shared
        // A demo left on when the app last closed carries on (its launches aren't recorded).
        _ = DemoMode.shared
        Telemetry.shared.record(.appLaunch())
    }

    var body: some Scene {
        WindowGroup { AppRoot(demo: .shared) }
    }
}

/// The person's own app, or the demo while it's on (Try the Demo), each with its own model.
private struct AppRoot: View {
    let demo: DemoMode

    var body: some View {
        ZStack {
            if let model = demo.model {
                RootView(model: model)
                    // The demo's view settings (grid size, …) are its own, and its taps don't change the app's tips.
                    .defaultAppStorage(model.settings.defaults)
                    .environment(\.showsTips, false)
                    .id(ObjectIdentifier(model))
            } else if demo.origin == .launch {
                Theme.background.ignoresSafeArea()
            } else {
                RootView(model: .shared)
                    .accessibilityHidden(demo.preparation != nil)
                    .allowsHitTesting(demo.preparation == nil)
            }
            // Both start points are in the root window. A future sheet needs its own full-screen cover.
            if demo.preparation != nil {
                DemoPreparingView(demo: demo).transition(.opacity).zIndex(1)
            }
        }
        .animation(.default, value: demo.preparation == nil)
    }
}
