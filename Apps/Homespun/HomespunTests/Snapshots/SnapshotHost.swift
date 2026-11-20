// SPDX-License-Identifier: Apache-2.0
import SwiftUI
import UIKit
@testable import Homespun

@MainActor
enum SnapshotHost {
    static func capture<Content: View>(_ view: Content, variant: SnapshotVariant, clock: AppClock,
                                      defaults: UserDefaults? = nil,
                                      inspect: ((UIViewController) throws -> Void)? = nil) async throws -> CGImage {
        let device = try SnapshotDevice.measured(variant.device)
        var root = AnyView(view.environment(\.locale, clock.locale)
            .environment(\.calendar, clock.calendar).environment(\.timeZone, clock.timeZone)
            .environment(\.appClock, clock).environment(\.colorScheme, variant.colorScheme)
            .environment(\.dynamicTypeSize, variant.dynamicType).environment(\.displayScale, 3)
            .environment(\.layoutDirection, .leftToRight).environment(\.showsTips, false)
            .environment(\.mediaPresentation, .poster)
            .environment(\.horizontalSizeClass, device.horizontal == .regular ? .regular : .compact)
            .environment(\.verticalSizeClass, device.vertical == .regular ? .regular : .compact)
            .transaction { $0.disablesAnimations = true; $0.animation = nil })
        if let defaults { root = AnyView(root.defaultAppStorage(defaults)) }
        let controller = autoreleasepool {
            let controller = UIHostingController(rootView: root)
            controller.view.backgroundColor = .clear
            return controller
        }
        return try await capture(controller, device: device, appearance: variant.userInterfaceStyle,
                                 category: variant.category, inspect: inspect)
    }

    static func capture(_ controller: UIViewController, device: SnapshotDevice, appearance: UIUserInterfaceStyle = .light,
                        category: UIContentSizeCategory = .large,
                        inspect: ((UIViewController) throws -> Void)? = nil) async throws -> CGImage {
        try await SnapshotCanvas.capture(controller, device: device, appearance: appearance, category: category, inspect: inspect)
    }
}

extension UIView {
    func descendants<T: UIView>(of type: T.Type) -> [T] {
        let matches = (self as? T).map { [$0] } ?? []
        return matches + subviews.flatMap { $0.descendants(of: type) }
    }

    func descendant<T: UIView>(of type: T.Type) -> T? {
        if let match = self as? T { return match }
        return subviews.lazy.compactMap { $0.descendant(of: type) }.first
    }

    func descendant(identifier: String) -> UIView? {
        if accessibilityIdentifier == identifier { return self }
        return subviews.lazy.compactMap { $0.descendant(identifier: identifier) }.first
    }
}
