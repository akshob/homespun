// SPDX-License-Identifier: Apache-2.0
import SwiftUI

/// The Server tab: the paired server, its folders, devices, automatic mode and Premium.
struct ServerTab: View {
    let model: AppModel

    var body: some View {
        SettingsView(settings: model.settings, premium: model.premium, automatic: model.automatic,
                     copyFinder: model.copyFinder, ledger: model.job.ledger, showsDone: false)
    }
}
