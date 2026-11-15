// SPDX-License-Identifier: Apache-2.0
import SwiftUI

@main
struct HomespunApp: App {
    init() {
        AppModel.registerBackgroundRun()
        LongRun.register()
        Journey.configureTips()
    }

    var body: some Scene {
        WindowGroup { RootView(model: .shared) }
    }
}
