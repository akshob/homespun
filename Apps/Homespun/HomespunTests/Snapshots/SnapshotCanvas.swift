// SPDX-License-Identifier: Apache-2.0
import UIKit

@MainActor
enum SnapshotCanvas {
    private static var capturing = false

    static func capture(_ controller: UIViewController, device: SnapshotDevice, appearance: UIUserInterfaceStyle = .light,
                        category: UIContentSizeCategory = .large,
                        inspect: ((UIViewController) throws -> Void)? = nil) async throws -> CGImage {
        // Main-actor tasks can interleave while a render waits for layout.
        while capturing { try await Task.sleep(for: .milliseconds(25)) }
        capturing = true
        defer { capturing = false }
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else {
            throw SnapshotFailure("Snapshots require the hosted app's foreground UIWindowScene")
        }
        let previous = scene.windows.first(where: \.isKeyWindow)
        let animations = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(false)
        let window = SnapshotWindow(scene: scene, size: device.size)
        let container = UIViewController()
        container.traitOverrides.horizontalSizeClass = device.horizontal
        container.traitOverrides.verticalSizeClass = device.vertical
        container.traitOverrides.displayScale = device.layoutScale
        container.traitOverrides.preferredContentSizeCategory = category
        container.traitOverrides.userInterfaceStyle = appearance
        container.additionalSafeAreaInsets = device.safeArea
        container.view.backgroundColor = .systemBackground
        window.frame = CGRect(origin: .zero, size: device.size)
        window.rootViewController = container
        container.view.frame = window.bounds
        container.addChild(controller)
        controller.view.frame = container.view.bounds
        container.view.addSubview(controller.view)
        controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controller.didMove(toParent: container)
        defer {
            controller.willMove(toParent: nil)
            controller.view.removeFromSuperview()
            controller.removeFromParent()
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
            UIView.setAnimationsEnabled(animations)
        }

        func layout() {
            window.frame = CGRect(origin: .zero, size: device.size)
            container.view.frame = window.bounds
            controller.view.frame = container.view.bounds
            window.layoutIfNeeded()
            container.view.layoutIfNeeded()
            controller.view.layoutIfNeeded()
            // Cancel the host phone's system insets before applying this measured configuration.
            let actual = container.view.safeAreaInsets
            let extra = container.additionalSafeAreaInsets
            let adjusted = UIEdgeInsets(
                top: extra.top + device.safeArea.top - actual.top,
                left: extra.left + device.safeArea.left - actual.left,
                bottom: extra.bottom + device.safeArea.bottom - actual.bottom,
                right: extra.right + device.safeArea.right - actual.right)
            if adjusted != extra { container.additionalSafeAreaInsets = adjusted }
            container.view.layoutIfNeeded()
            controller.view.layoutIfNeeded()
        }

        func render() throws -> CGImage {
            layout()
            func pauseIndicators(_ view: UIView) {
                if view is UIActivityIndicatorView {
                    // This runs a layer animation even when UIView animations are disabled.
                    view.layer.speed = 0
                    view.layer.timeOffset = 0
                }
                for child in view.subviews { pauseIndicators(child) }
            }
            pauseIndicators(container.view)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 2
            format.preferredRange = .standard
            format.opaque = true
            var drawn = false
            let image = UIGraphicsImageRenderer(size: device.size, format: format).image { _ in
                drawn = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            guard drawn else { throw SnapshotFailure("Snapshot hierarchy did not finish drawing") }
            guard let cgImage = image.cgImage else { throw SnapshotFailure("Snapshot produced no bitmap") }
            return try SnapshotImage.sRGB(cgImage)
        }

        layout()
        window.makeKeyAndVisible()
        let initial = try render()
        var bytes = initial.dataProvider?.data
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        var layoutFailure: Error?
        var frames = 1
        while ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(50))
            let next = try render()
            frames += 1
            let nextBytes = next.dataProvider?.data
            if let bytes, let nextBytes, CFEqual(bytes, nextBytes) {
                let actual = controller.view.safeAreaInsets
                do {
                    guard abs(actual.top - device.safeArea.top) < 0.01,
                          abs(actual.left - device.safeArea.left) < 0.01,
                          abs(actual.bottom - device.safeArea.bottom) < 0.01,
                          abs(actual.right - device.safeArea.right) < 0.01 else {
                        throw SnapshotFailure("Snapshot safe areas differ: wanted \(device.safeArea), got \(actual)")
                    }
                    try inspect?(controller)
                    return next
                } catch {
                    layoutFailure = error
                }
            }
            bytes = nextBytes
        }
        throw layoutFailure ?? SnapshotFailure("Snapshot did not settle within two seconds (\(frames) frames)")
    }
}

@MainActor
private final class SnapshotWindow: UIWindow {
    private let canvas: CGRect

    init(scene: UIWindowScene, size: CGSize) {
        canvas = CGRect(origin: .zero, size: size)
        super.init(windowScene: scene)
        super.frame = canvas
        super.bounds = canvas
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var frame: CGRect {
        get { super.frame }
        set { if super.frame != canvas { super.frame = canvas } }
    }

    override var bounds: CGRect {
        get { super.bounds }
        set { if super.bounds != canvas { super.bounds = canvas } }
    }
}
