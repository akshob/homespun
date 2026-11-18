// SPDX-License-Identifier: Apache-2.0
import SwiftUI

/// Homespun on Apple Watch: one screen with what the iPhone last said (the watch can't reach the
/// server itself), and the widgets for watch faces and the Smart Stack.
@main
struct HomespunWatchApp: App {
    init() {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "-watchDemo"), index + 1 < args.count {
            let now = Date()
            var demo = StatusSnapshot.sample(now: now)
            demo.updatedAt = now.addingTimeInterval(args[index + 1] == "stale" ? -7 * 3600 : -5 * 60)
            if args.contains("-watchDemoLater") {
                if let url = StatusStore.url { try? FileManager.default.removeItem(at: url) }
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(3))
                    WatchStatus.shared.apply(demo)
                }
            } else {
                StatusStore.write(demo)
            }
        }
        #endif
        PhoneLink.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            WatchStatusView(status: .shared)
        }
        // The iPhone sent something while the app wasn't running: keep it before the watch suspends it.
        .backgroundTask(.watchConnectivity) {
            await PhoneLink.shared.receivePending()
        }
    }
}
