// SPDX-License-Identifier: Apache-2.0
import SwiftUI
import UIKit

extension EnvironmentValues {
    @Entry var statusAccessoryInset: CGFloat = 0
}

/// A floating accessory, not a tab-bar accessory: adding one must not change the tabs' geometry.
struct StatusAccessoryModifier: ViewModifier {
    let model: AppModel
    let open: (StatusAccessory.Action) -> Void
    @State private var bounds = CGRect.zero
    @State private var height: CGFloat = 0

    func body(content: Content) -> some View {
        let status = AccessoryLadder.pick(model.library.accessoryInputs)
        let visible = status != nil && !model.library.isSelecting
        content
            .environment(\.statusAccessoryInset, visible ? height + 8 : 0)
            .onChange(of: visible) { _, visible in if !visible { bounds = .zero } }
            .overlay {
                GeometryReader { _ in
                    ZStack(alignment: .topLeading) {
                        if visible {
                            AccessoryBounds { bounds = $0 }.allowsHitTesting(false)
                        }
                        if visible, bounds.width > 0 {
                            VStack(spacing: 0) {
                                Spacer(minLength: 0)
                                StatusAccessory(status: status, serverName: model.library.serverName, open: open)
                                    .padding(.vertical, 10)
                                    .frame(width: min(640, max(0, bounds.width - 24)))
                                    .glassEffect(.regular, in: .rect(cornerRadius: 24))
                                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
                            }
                            .frame(width: bounds.width, height: bounds.height)
                            .offset(x: bounds.minX, y: bounds.minY - 8)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .ignoresSafeArea()
            }
    }
}

struct StatusAccessoryScrollInset: ViewModifier {
    @Environment(\.statusAccessoryInset) private var inset

    func body(content: Content) -> some View {
        content.contentMargins(.bottom, inset, for: .scrollContent)
    }
}

private struct AccessoryBounds: UIViewRepresentable {
    let changed: (CGRect) -> Void

    func makeUIView(context: Context) -> AccessoryBoundsView {
        let view = AccessoryBoundsView()
        view.changed = changed
        return view
    }

    func updateUIView(_ view: AccessoryBoundsView, context: Context) { view.changed = changed }

    static func dismantleUIView(_ view: AccessoryBoundsView, coordinator: ()) { view.stop() }
}

/// Follows the system's bar or Duo strip without contributing a safe area of its own.
@MainActor private final class AccessoryBoundsView: UIView {
    var changed: (CGRect) -> Void = { _ in }
    private weak var tabs: UITabBarController?
    private var link: CADisplayLink?
    private var reported = CGRect.null

    override func didMoveToWindow() {
        super.didMoveToWindow()
        stop()
        guard window != nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(sample))
        link.add(to: .main, forMode: .common)
        self.link = link
        sample()
    }

    func stop() {
        link?.invalidate()
        link = nil
        tabs = nil
    }

    @objc private func sample() {
        guard let window else { return }
        if tabs == nil { tabs = findTabs(window.rootViewController) }
        guard let selected = tabs?.selectedViewController, selected.viewIfLoaded?.window === window else { return }
        let whole = convert(window.bounds, from: window)
        var usable = whole.inset(by: window.safeAreaInsets)
        func include(_ controller: UIViewController) {
            if let view = controller.viewIfLoaded, view.window === window {
                let frame = view.convert(view.bounds, to: self)
                if abs(frame.width - whole.width) < 1, abs(frame.height - whole.height) < 1 {
                    usable = usable.intersection(view.convert(view.safeAreaLayoutGuide.layoutFrame, to: self))
                }
            }
            for child in controller.children { include(child) }
        }
        include(selected)
        guard !usable.isNull, usable.height > 100, usable != reported else { return }
        reported = usable
        let frame = usable
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil else { return }
            self.changed(frame)
        }
    }

    private func findTabs(_ controller: UIViewController?) -> UITabBarController? {
        guard let controller else { return nil }
        if let tabs = controller as? UITabBarController { return tabs }
        for child in controller.children {
            if let tabs = findTabs(child) { return tabs }
        }
        return nil
    }
}
