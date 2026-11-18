// SPDX-License-Identifier: Apache-2.0
import SwiftUI

@main
struct HomespunApp: App {
    init() {
        PerfMonitor.mainStarted = CACurrentMediaTime()
        AppModel.registerBackgroundRun()
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
        if let model = demo.model {
            RootView(model: model)
                // The demo's view settings (grid size, …) are its own, and its taps don't change the app's tips.
                .defaultAppStorage(model.settings.defaults)
                .environment(\.showsTips, false)
                .id(ObjectIdentifier(model))
        } else {
            RootView(model: .shared)
        }
    }
}
