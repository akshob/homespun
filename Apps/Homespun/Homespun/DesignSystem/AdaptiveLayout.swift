// SPDX-License-Identifier: Apache-2.0
import SwiftUI

/// The Library grid's columns. On a phone (and iPhone Duo's cover) the person's choice: 2 (large),
/// 4 (medium, the default) or 6 (small). Wider, as many columns as fit cells of about the same size
/// across the whole width: the open iPhone Duo is one screen, so the grid runs across it like
/// Photos' (5 columns held tall, 6 wide, at the default size).
enum GridColumns {
    static func count(width: CGFloat, density: Int, accessibility: Bool) -> Int {
        let count: Int
        if width < 500 {
            count = density
        } else {
            let cell: CGFloat = switch density {
            case ..<3: 190
            case 3...4: 125
            default: 80
            }
            count = max(density, Int((width + 2) / (cell + 2)))
        }
        return accessibility ? max(2, count / 2) : count
    }
}

enum SidebarNavigation {
    static func selecting<Route>(_ route: Route?, in path: [Route],
                                 retaining: (Route) -> Bool) -> [Route] {
        if let route { return [route] }
        // The disappearing sidebar can deselect its row while the compact stack takes over.
        // That is not Back or an explicit choice to abandon an editor.
        return path.contains(where: retaining) ? path : []
    }
}

/// A tab's navigation (Activity, Server). On a compact width (an iPhone, iPhone Duo's cover) one
/// stack. On a regular width (iPhone Duo open) the shape of Settings: the list as a sidebar and what
/// it opens beside it, never an empty page (`defaultRoute`), deeper screens pushed in that column;
/// held tall, the detail across the width with the list behind the sidebar button. Unfolding keeps the
/// place; folding goes back to the list (a stack rebuilt around a page that was open beside the list
/// lost its Back button).
struct SplitNavigation<Route: Hashable, Root: View, Destination: View, Empty: View>: View {
    @Binding var path: [Route]
    /// What the detail shows when nothing has been opened (the newest run, Server Check).
    var defaultRoute: Route?
    /// Editors can retain the existing route while ordinary detail pages still fold to the list.
    var retainsOnFold: (Route) -> Bool = { _ in false }
    /// An editor's confirmation belongs to its navigation host, not to the destination being transferred.
    var confirmation: (Route) -> AnyView? = { _ in nil }
    /// The list, given the sidebar's selection (none in a stack, where its links push).
    @ViewBuilder var root: (Binding<Route?>?) -> Root
    @ViewBuilder var destination: (Route) -> Destination
    /// The detail when there's nothing to show yet (no default either).
    @ViewBuilder var empty: Empty
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// Held tall, the list is over the detail only after the sidebar button; choosing closes it.
    @State private var listShown = false

    /// The split view was showing: the next stack starts at the list (only after folding, never on a phone).
    @State private var unfolded = false

    var body: some View {
        Group {
            if sizeClass == .regular {
                split.onAppear { unfolded = true }
            } else {
                NavigationStack(path: $path) {
                    root(nil).navigationDestination(for: Route.self) { destination($0) }
                }
                .toolbar { confirmationToolbar(for: path.last, host: "compact") }
                .onAppear { folded() }
            }
        }
        .onChange(of: sizeClass) { folded() }
    }

    private func folded() {
        guard unfolded, sizeClass != .regular else { return }
        unfolded = false
        if !path.contains(where: retainsOnFold) { path = [] }
    }

    /// The sidebar's selection is the detail column's first screen; choosing another starts it afresh.
    private var selection: Binding<Route?> {
        Binding(get: { path.first ?? defaultRoute }, set: { new in
            path = SidebarNavigation.selecting(new, in: path, retaining: retainsOnFold)
            listShown = false
        })
    }

    /// Only the host's currently visible route supplies an action; Back or another route removes it.
    @ToolbarContentBuilder private func confirmationToolbar(for route: Route?, host: String) -> some ToolbarContent {
        if let route, let action = confirmation(route) {
            ToolbarItem(id: "editor.confirmation." + host, placement: .confirmationAction) { action }
        }
    }

    /// Wide: the list beside the detail. Tall: the detail alone unless the list was asked for.
    private func columns(tall: Bool) -> Binding<NavigationSplitViewVisibility> {
        Binding(get: { tall && !listShown ? .detailOnly : .all },
                set: { visibility in if tall { listShown = visibility != .detailOnly } })
    }

    /// Tall or wide from the size now, never a stored one: unfolding passes through the cover's tall size.
    private var split: some View {
        GeometryReader { proxy in
            let tall = proxy.size.height > proxy.size.width
            splitView(tall: tall).onChange(of: tall) { listShown = false }
        }
    }

    private func splitView(tall: Bool) -> some View {
        NavigationSplitView(columnVisibility: columns(tall: tall)) {
            root(selection)
                .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 400)
                .environment(\.sidebarSelection, (path.first ?? defaultRoute).map(AnyHashable.init))
        } detail: {
            NavigationStack(path: Binding(get: { Array(path.dropFirst()) },
                                          set: { rest in path = Array(path.prefix(1)) + rest })) {
                Group {
                    if let route = path.first ?? defaultRoute { destination(route) } else { empty }
                }
                .navigationDestination(for: Route.self) { destination($0) }
            }
            .toolbar { confirmationToolbar(for: path.last ?? defaultRoute, host: "detail") }
            .id(path.first ?? defaultRoute)
        }
        .onAppear { listShown = false }
    }
}

extension EnvironmentValues {
    /// The route open beside a split view's sidebar (nil in a stack), for its row's highlight.
    @Entry var sidebarSelection: AnyHashable?
}

extension View {
    /// A sidebar row that opens `route`: highlighted while it's the one open beside the list, like
    /// Settings (the card background the lists use hides the system's own highlight).
    func sidebarRow<Route: Hashable>(_ route: Route) -> some View {
        modifier(SidebarRow(route: AnyHashable(route)))
    }
}

private struct SidebarRow: ViewModifier {
    let route: AnyHashable
    @Environment(\.sidebarSelection) private var selection

    func body(content: Content) -> some View {
        let selected = selection == route
        content
            .listRowBackground(selected ? Theme.accent.opacity(0.16) : Theme.card)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
