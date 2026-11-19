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
    @State private var layout = AccessoryLayout()
    @State private var height: CGFloat = 0

    func body(content: Content) -> some View {
        let _ = RenderProbe.count("render.accessory")
        let status = AccessoryLadder.pick(model.library.accessoryInputs)
        let visible = status != nil && !model.library.isSelecting
        content
            .environment(\.statusAccessoryInset, visible ? height + 8 : 0)
            .onChange(of: visible) { _, visible in if !visible { layout = AccessoryLayout() } }
            .overlay {
                GeometryReader { proxy in
                    let bounds = CGRect(origin: .zero, size: proxy.size).inset(by: layout.insets)
                    ZStack(alignment: .topLeading) {
                        if visible {
                            AccessoryInsets { layout = $0 }.allowsHitTesting(false)
                        }
                        if visible, bounds.width > 0, bounds.height > 100 {
                            VStack(spacing: 0) {
                                Spacer(minLength: 0)
                                StatusAccessory(status: status, serverName: model.library.serverName,
                                                width: min(640, max(0, bounds.width - 24)), open: open)
                                    // The combined accessibility and hit region must use the folded width too.
                                    .id([proxy.size.width, proxy.size.height])
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

private struct AccessoryLayout: Equatable {
    var size = CGSize.zero
    var insets = UIEdgeInsets.zero
}

private struct AccessoryInsets: UIViewRepresentable {
    let changed: (AccessoryLayout) -> Void

    func makeUIView(context: Context) -> AccessoryInsetsView {
        let view = AccessoryInsetsView()
        view.changed = changed
        return view
    }

    func updateUIView(_ view: AccessoryInsetsView, context: Context) {
        view.changed = changed
        view.sample()
    }

    static func dismantleUIView(_ view: AccessoryInsetsView, coordinator: ()) { view.stop() }
}

/// Follows the system's bar or Duo strip without contributing a safe area of its own.
@MainActor private final class AccessoryInsetsView: UIView {
    var changed: (AccessoryLayout) -> Void = { _ in }
    private var link: CADisplayLink?
    private var reported: AccessoryLayout?

    override func layoutSubviews() {
        super.layoutSubviews()
        sample()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        sample()
    }

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
    }

    @objc func sample() {
        guard let window else { return }
        // Folding can replace the hosting window. Read its live containers, not a cached rectangle.
        let windows = (window.windowScene?.windows ?? [window]).filter { !$0.isHidden }
            .sorted { $0.isKeyWindow && !$1.isKeyWindow }
        guard let tabs = windows.lazy.compactMap({ self.findTabs($0.rootViewController) }).first,
              let selected = tabs.selectedViewController, selected.viewIfLoaded?.window != nil else { return }
        let display = windows.first(where: \.isKeyWindow) ?? window
        let size = display.bounds.size
        var edges = display.safeAreaInsets
        func includeInsets(_ insets: UIEdgeInsets) {
            edges.top = max(edges.top, insets.top)
            edges.left = max(edges.left, insets.left)
            edges.bottom = max(edges.bottom, insets.bottom)
            edges.right = max(edges.right, insets.right)
        }
        func include(_ controller: UIViewController) {
            if let view = controller.viewIfLoaded, view.window != nil,
               view.bounds.width <= size.width + 1, view.bounds.height <= size.height + 1,
               view.bounds.height > size.height / 2,
               view.bounds.width - view.safeAreaInsets.left - view.safeAreaInsets.right > 100,
               view.bounds.height - view.safeAreaInsets.top - view.safeAreaInsets.bottom > 100 {
                includeInsets(view.safeAreaInsets)
            }
            let scroll = controller.contentScrollView(for: .bottom) ?? (controller.viewIfLoaded as? UIScrollView)
            if let scroll, scroll.window != nil, scroll.bounds.width <= size.width + 1, scroll.bounds.height <= size.height + 1 {
                let adjusted = scroll.adjustedContentInset, own = scroll.contentInset
                let automatic = UIEdgeInsets(top: adjusted.top - own.top, left: adjusted.left - own.left,
                                             bottom: adjusted.bottom - own.bottom, right: adjusted.right - own.right)
                if scroll.bounds.width - automatic.left - automatic.right > 100,
                   scroll.bounds.height - automatic.top - automatic.bottom > 100 {
                    includeInsets(automatic)
                }
            }
            for child in controller.children { include(child) }
        }
        include(selected)
        let bar = tabs.tabBar
        if !bar.isHidden, bar.alpha > 0.01, bar.window === display, bar.frame.intersects(tabs.view.bounds) {
            if bar.bounds.width > bar.bounds.height {
                edges.bottom = max(edges.bottom, bar.bounds.height)
            } else if bar.frame.midX > display.bounds.midX {
                edges.right = max(edges.right, bar.bounds.width)
            } else {
                edges.left = max(edges.left, bar.bounds.width)
            }
        }
        let result = AccessoryLayout(size: size, insets: edges)
        guard result != reported else { return }
        reported = result
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil else { return }
            self.changed(result)
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
