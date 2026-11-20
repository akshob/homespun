// SPDX-License-Identifier: Apache-2.0
import SwiftUI
import UIKit

/// Shared by the viewer and its zoom source, including the item reached after paging.
@MainActor @Observable
final class ItemViewerState {
    var ids: [String]
    var shown: String
    var zoomed = false
    var details: String?
    @ObservationIgnored weak var host: UIViewController?
    @ObservationIgnored var onShow: (String) -> Void = { _ in }

    init(ids: [String], start: String, details: Bool) {
        self.ids = ids
        shown = start
        self.details = details ? start : nil
    }

    func close() {
        guard let host else { return }
        host.presentingViewController?.dismiss(animated: true) {
            (host as? ItemViewerController)?.finishedDismissal()
        }
    }
}

@MainActor
final class ItemViewerController: UIHostingController<ItemViewerScreen> {
    let state: ItemViewerState
    var closing: () -> Void = {}
    var closed: () -> Void = {}
    var resumed: () -> Void = {}
    private var finished = false

    init(model: AppModel, state: ItemViewerState, showsTips: Bool) {
        self.state = state
        super.init(rootView: ItemViewerScreen(model: model, state: state, showsTips: showsTips))
        state.host = self
        // Full-screen removal changes the presenter's insets before it returns to the window.
        modalPresentationStyle = .overFullScreen
        modalPresentationCapturesStatusBarAppearance = true
        view.backgroundColor = .black
        view.accessibilityViewIsModal = true
    }

    @available(*, unavailable)
    required dynamic init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        resumed()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isBeingDismissed { closing() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isBeingDismissed || presentingViewController == nil else { return }
        finishedDismissal()
    }

    func finishedDismissal() {
        guard !finished else { return }
        finished = true
        ItemViewerPresence.shared.closed(self)
        closed()
    }
}

/// App-wide presentations dismiss the viewer before changing tabs or presenting their own UI.
@MainActor @Observable
final class ItemViewerPresence {
    static let shared = ItemViewerPresence()
    private(set) weak var current: ItemViewerController?
    @ObservationIgnored private var dismissing = false
    @ObservationIgnored private var completions: [() -> Void] = []
    var isOpen: Bool { current != nil }

    func opened(_ viewer: ItemViewerController) { current = viewer }

    func closed(_ viewer: ItemViewerController) {
        if current === viewer { current = nil }
    }

    func close(animated: Bool, then: @escaping () -> Void = {}) {
        if dismissing {
            completions.append(then)
            return
        }
        guard let viewer = current, let presenter = viewer.presentingViewController else { return then() }
        dismissing = true
        completions.append(then)
        presenter.dismiss(animated: animated) {
            viewer.finishedDismissal()
            self.dismissing = false
            let completions = self.completions
            self.completions = []
            for completion in completions { completion() }
        }
    }
}

struct ItemViewerScreen: View {
    let model: AppModel
    let state: ItemViewerState
    let showsTips: Bool
    @State private var freeUp: FreeUpRequest?
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        ItemViewerNavigation(model: model, state: state) {
            freeUp = FreeUpRequest(scope: $0, wide: sizeClass == .regular)
        }
        .inspector(isPresented: Binding(get: { state.details != nil }, set: { if !$0 { state.details = nil } })) {
            if let id = state.details {
                ItemDetailsPanel(model: model, id: id) { state.details = nil }
                    .inspectorColumnWidth(min: 280, ideal: 320, max: 400)
            }
        }
        .modifier(FreeUpPresentation(model: model, request: $freeUp))
        .environment(\.showsTips, showsTips)
        .defaultAppStorage(model.settings.defaults)
        .tint(Theme.accent)
        // The performance report must remain reachable while the app behind is covered.
        .overlay(alignment: .topLeading) { PerfMonitorLabel() }
    }

}

struct ItemViewerNavigation: View {
    let model: AppModel
    let state: ItemViewerState
    var freeUp: (Set<String>?) -> Void

    var body: some View {
        NavigationStack { ItemViewer(model: model, state: state, freeUp: freeUp) }
    }
}
