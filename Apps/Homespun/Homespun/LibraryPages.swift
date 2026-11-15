// SPDX-License-Identifier: Apache-2.0
import Photos
import SwiftUI

/// What the right page of the open book shows (DUO §9.2). Closed, the same things are pushed or
/// shown as sheets.
enum LibraryRoute: Hashable {
    case overview
    case item(String)
    case selection
    case review(Set<String>?)
}

/// The Library's right page: the Overview, the item you tapped, the selection, or Free Up Space.
struct LibraryRightPage: View {
    let model: AppModel
    @Binding var route: LibraryRoute
    let selected: Set<String>
    var backUp: ([String]) -> Void
    var showAll: (LibraryState.Filter) -> Void
    var openItem: (String) -> Void

    private var controller: LibraryController { model.library }

    var body: some View {
        Group {
            switch route {
            case .overview: overview
            case .item(let id): ItemPage(model: model, id: id, freeUp: { route = .review($0) }, open: openItem)
            case .selection: selection
            case .review(let scope):
                FreeUpSpacePanel(controller: controller, scope: scope) {
                    controller.dismissRemoval()
                    route = .overview
                }
            }
        }
        .background(Theme.background)
        .accessibilityIdentifier("library.page")
    }

    // MARK: Overview

    private var overview: some View {
        let state = controller.library.state
        let notBackedUp = state.cells.filter(\.canCompact).map(\.id)
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Overview").font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                serverCard
                if model.job.isRunning { runningCard }
                if controller.ready.count > 0 {
                    card(icon: "circle.lefthalf.filled", tint: Theme.amber,
                         title: "\(controller.ready.count.formatted()) ready to free up",
                         detail: "\(LibraryController.bytes(controller.ready.bytes)) on this iPhone") {
                        Button("Free Up Space") { route = .review(nil) }.primaryAction()
                            .accessibilityIdentifier("overview.free")
                    }
                }
                if !notBackedUp.isEmpty, model.settings.isPaired {
                    card(icon: "circle.dashed", tint: Theme.secondaryLabel,
                         title: "\(notBackedUp.count.formatted()) not backed up",
                         detail: "Only on this iPhone") {
                        HStack {
                            Button("Back Up All…") { backUp(notBackedUp) }.buttonStyle(.glass)
                                .disabled(controller.backUpBlockedReason != nil)
                            Button("Show Them") { showAll(.notBackedUp) }.buttonStyle(.borderless)
                        }
                    }
                }
                let attention = state.count(.needsAttention)
                if attention > 0 {
                    card(icon: "exclamationmark.triangle.fill", tint: Theme.red,
                         title: "\(attention) need\(attention == 1 ? "s" : "") attention", detail: "See Activity for why.") {
                        Button("Show Them") { showAll(.needsAttention) }.buttonStyle(.borderless)
                    }
                }
                if controller.ready.count == 0, notBackedUp.isEmpty, model.settings.isPaired, !model.job.isRunning {
                    ContentUnavailableView("Everything's backed up", systemImage: "checkmark.circle.fill",
                                           description: Text("Originals are at home on \(controller.serverName)."))
                }
            }
            .padding(20)
        }
    }

    private var serverCard: some View {
        let settings = model.settings
        let status: (String, Color) = switch settings.serverStatus {
        case .reachable: ("Connected", Theme.teal)
        case .unreachable: ("Can't reach it", Theme.amber)
        default: ("Checking…", Theme.secondaryLabel)
        }
        return HStack(spacing: 12) {
            Image(systemName: "server.rack").font(.title2).foregroundStyle(Theme.accent).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(settings.isPaired ? controller.serverName : "No server yet").font(.headline)
                if settings.isPaired {
                    Label(status.0, systemImage: "circle.fill").font(.subheadline).foregroundStyle(status.1)
                        .labelStyle(DotLabelStyle())
                } else {
                    Text("Set up your home computer to back up originals.").font(.subheadline)
                        .foregroundStyle(Theme.secondaryLabel)
                }
            }
            Spacer(minLength: 0)
        }
        .card()
        .accessibilityElement(children: .combine)
    }

    private var runningCard: some View {
        let job = model.job
        let open = job.items.filter { $0.state == .waiting || $0.isWorking }.count
        let done = job.items.count - open
        return VStack(alignment: .leading, spacing: 8) {
            Text("Backing up \(min(done + 1, job.items.count)) of \(job.items.count)").font(.headline)
            ProgressView(value: Double(done), total: Double(max(1, job.items.count))).tint(Theme.accent)
            if let current = job.items.first(where: \.isWorking) {
                Text(current.name).font(.subheadline).foregroundStyle(Theme.secondaryLabel).lineLimit(1)
            }
        }
        .card()
        .accessibilityElement(children: .combine)
    }

    // MARK: Selection

    private var selection: some View {
        let cells = controller.library.state.cells.filter { selected.contains($0.id) }
        let backUpIDs = cells.filter(\.canCompact).map(\.id)
        let freeable = Set(cells.filter(\.canFree).compactMap(\.original))
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(selected.isEmpty ? "Select Items" : "\(selected.count) Selected").font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                if selected.isEmpty {
                    Text("Tap photos and videos on the left, or drag across them.").foregroundStyle(Theme.secondaryLabel)
                }
                ThumbnailStrip(identifiers: Array(selected.prefix(12)), manager: controller.library.thumbnails)
                if !backUpIDs.isEmpty {
                    card(icon: "arrow.up.circle", tint: Theme.accent, title: "Back up \(backUpIDs.count)",
                         detail: "Originals go to \(controller.serverName); compact copies come back to Photos.") {
                        EmptyView()
                    }
                }
                if !freeable.isEmpty {
                    card(icon: "circle.lefthalf.filled", tint: Theme.amber, title: "\(freeable.count) ready to free up",
                         detail: "Their originals are safe at home.") {
                        Button("Free Up Space") { route = .review(freeable) }.buttonStyle(.glass)
                    }
                }
            }
            .padding(20)
        }
    }

    private func card<Actions: View>(icon: String, tint: Color, title: String, detail: String,
                                     @ViewBuilder actions: () -> Actions) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon).font(.title3).foregroundStyle(tint).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(detail).font(.subheadline).foregroundStyle(Theme.secondaryLabel)
                }
            }
            actions()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

/// The item you tapped, on the right page: the photo, its state, and its one action.
struct ItemPage: View {
    let model: AppModel
    let id: String
    var freeUp: (Set<String>?) -> Void
    var open: (String) -> Void

    private var cell: LibraryState.Cell? { model.library.library.state.cells.first { $0.id == id } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Thumbnail(identifier: id, manager: model.library.library.thumbnails, side: 330)
                    .frame(maxWidth: .infinity)
                    .onTapGesture { open(id) }
                    .accessibilityLabel("Open full screen")
                    .accessibilityAddTraits(.isButton)
                if let asset = PhotoLibrary.asset(id), let date = asset.creationDate {
                    Text(date.formatted(date: .long, time: .shortened)).font(.headline)
                }
                if let cell {
                    HStack(spacing: 8) {
                        BadgeView(badge: cell.badge)
                        Text(cell.badge.spoken(server: model.library.serverName)).font(.subheadline)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("item.state")
                    Text(cell.badge.explanation).font(.subheadline).foregroundStyle(Theme.secondaryLabel)
                    if cell.canFree, let original = cell.original {
                        Button("Free Up Space") { freeUp([original]) }.primaryAction()
                    } else if cell.canCompact, model.settings.isPaired {
                        Button("Back Up") { model.library.backUp([id]) }.primaryAction()
                            .disabled(model.library.backUpBlockedReason != nil)
                    }
                }
                Button("Open Full Screen", systemImage: "arrow.up.left.and.arrow.down.right") { open(id) }
                    .buttonStyle(.borderless)
            }
            .padding(20)
        }
    }
}

/// A status dot and text, tight together.
struct DotLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.system(size: 7))
            configuration.title
        }
    }
}
