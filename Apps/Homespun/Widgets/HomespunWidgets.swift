// SPDX-License-Identifier: Apache-2.0
import SwiftUI
import WidgetKit

/// The widget extension, on the iPhone (HomespunWidgets) and on Apple Watch (HomespunWatchWidgets).
@main
struct HomespunWidgets: WidgetBundle {
    var body: some Widget {
        StatusWidget()
    }
}
