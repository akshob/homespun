// SPDX-License-Identifier: Apache-2.0
import SwiftUI
import UIKit
@testable import Homespun

@MainActor
enum SnapshotHost {
    static func capture<Content: View>(_ view: Content, variant: SnapshotVariant, clock: AppClock,
                                      defaults: UserDefaults? = nil,
                                      inspect: ((UIViewController) throws -> Void)? = nil) async throws -> CGImage {
        var root = AnyView(view.environment(\.locale, clock.locale)
            .environment(\.calendar, clock.calendar).environment(\.timeZone, clock.timeZone)
            .environment(\.appClock, clock).environment(\.colorScheme, variant.colorScheme)
            .environment(\.dynamicTypeSize, variant.dynamicType).environment(\.displayScale, 3)
            .environment(\.layoutDirection, .leftToRight).environment(\.showsTips, false)
            .transaction { $0.disablesAnimations = true; $0.animation = nil })
        if let defaults { root = AnyView(root.defaultAppStorage(defaults)) }
        let controller = UIHostingController(rootView: root)
        controller.view.backgroundColor = .clear
        return try await capture(controller, device: SnapshotDevice.measured(variant.device),
                                 appearance: variant.userInterfaceStyle, category: variant.category, inspect: inspect)
    }

    static func capture(_ controller: UIViewController, device: SnapshotDevice, appearance: UIUserInterfaceStyle = .light,
                        category: UIContentSizeCategory = .large,
                        inspect: ((UIViewController) throws -> Void)? = nil) async throws -> CGImage {
        try await SnapshotCanvas.capture(controller, device: device, appearance: appearance, category: category, inspect: inspect)
    }
}
