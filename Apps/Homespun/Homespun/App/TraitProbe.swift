// SPDX-License-Identifier: Apache-2.0
#if DEBUG
import SwiftUI
import UIKit

struct TraitProbeScreen: UIViewRepresentable {
    func makeUIView(context: Context) -> TraitProbeView { TraitProbeView() }
    func updateUIView(_ view: TraitProbeView, context: Context) { view.capture() }
}

final class TraitProbeView: UIView {
    init() {
        super.init(frame: .zero)
        backgroundColor = .systemBackground
        isAccessibilityElement = true
        accessibilityIdentifier = "snapshot.traits"
        accessibilityTraits = .staticText
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        capture()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        capture()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        capture()
    }

    func capture() {
        guard let window, let scene = window.windowScene, window.bounds.width > 0 else { return }
        let screen = scene.screen
        let insets = window.safeAreaInsets
        let record = TraitProbeRecord(
            sizePoints: [Double(window.bounds.width), Double(window.bounds.height)],
            safeArea: ["top": Double(insets.top), "left": Double(insets.left),
                       "bottom": Double(insets.bottom), "right": Double(insets.right)],
            displayScale: Double(traitCollection.displayScale),
            nativeScale: Double(screen.nativeScale),
            nativePixels: [Double(screen.nativeBounds.width), Double(screen.nativeBounds.height)],
            horizontalSizeClass: name(traitCollection.horizontalSizeClass),
            verticalSizeClass: name(traitCollection.verticalSizeClass),
            contentSizeCategory: traitCollection.preferredContentSizeCategory.rawValue,
            xcodeBuild: Bundle.main.object(forInfoDictionaryKey: "DTXcodeBuild") as? String ?? "unknown",
            runtimeBuild: ProcessInfo.processInfo.environment["SIMULATOR_RUNTIME_BUILD_VERSION"]
                ?? ProcessInfo.processInfo.operatingSystemVersionString,
            model: ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "unknown")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(record), let value = String(data: data, encoding: .utf8),
           accessibilityLabel != value {
            accessibilityLabel = value
        }
    }

    private func name(_ value: UIUserInterfaceSizeClass) -> String {
        switch value {
        case .compact: "compact"
        case .regular: "regular"
        default: "unspecified"
        }
    }
}

private struct TraitProbeRecord: Encodable {
    let sizePoints: [Double]
    let safeArea: [String: Double]
    let displayScale: Double
    let nativeScale: Double
    let nativePixels: [Double]
    let horizontalSizeClass: String
    let verticalSizeClass: String
    let contentSizeCategory: String
    let xcodeBuild: String
    let runtimeBuild: String
    let model: String
}
#endif
