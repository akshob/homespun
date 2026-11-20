// SPDX-License-Identifier: Apache-2.0
import SwiftUI
import Testing
import UIKit
@testable import Homespun

private struct ViewerSnapshotCase: Sendable, CustomTestStringConvertible {
    enum State: String, Sendable { case ready, notBackedUp, atHome, failed, kept, video }
    var state: State = .ready
    var variant: SnapshotVariant
    var details = false
    var zoomed = false
    var testDescription: String {
        "\(state.rawValue).\(details ? "details" : zoomed ? "zoomed" : "viewer").\(variant.name)"
    }
    var id: String {
        switch state {
        case .ready: FixtureCatalog.compact(72)
        case .notBackedUp: FixtureCatalog.original(93)
        case .atHome: FixtureCatalog.compact(FixtureCatalog.freed)
        case .failed: FixtureCatalog.original(83)
        case .kept: FixtureCatalog.original(84)
        case .video: FixtureCatalog.compact(75)
        }
    }
    static var all: [Self] {
        var cases = SnapshotVariant.standard.map { Self(variant: $0) }
        for state in [State.notBackedUp, .atHome, .failed, .kept] {
            cases.append(Self(state: state, variant: .init(device: .iphone)))
        }
        for device in [SnapshotDevice.Kind.iphone, .duoInnerLandscape] {
            cases.append(Self(state: .video, variant: .init(device: device)))
        }
        cases.append(Self(variant: .init(device: .iphone), zoomed: true))
        cases += [SnapshotDevice.Kind.iphone, .duoCover, .duoInnerPortrait, .duoInnerLandscape].map {
            Self(variant: .init(device: $0), details: true)
        }
        cases += [State.failed, .kept].map { Self(state: $0, variant: .init(device: .iphone), details: true) }
        cases += [Self(variant: .init(device: .iphone, typeSize: .accessibilityExtraLarge)),
                  Self(variant: .init(device: .iphone, typeSize: .accessibilityExtraLarge), details: true)]
        return cases
    }
}

extension SnapshotTests {
    @Suite @MainActor
    struct Viewer {
        @Test(arguments: ViewerSnapshotCase.all)
        fileprivate func render(_ sample: ViewerSnapshotCase) async throws {
            let started = ProcessInfo.processInfo.systemUptime
            let world = try await SnapshotWorld()
            defer { world.close() }
            let state = ItemViewerState(ids: [sample.id], start: sample.id, details: false)
            state.zoomed = sample.zoomed
            let viewer = ItemViewerNavigation(model: world.model, state: state, freeUp: { _ in })
                .tint(Theme.accent)
            let cell = try #require(world.library.library.state.cell(sample.id))
            let details = sample.details ? await ItemDetails.load(model: world.model, cell: cell) : nil
            let wide = sample.variant.device == .duoInnerPortrait || sample.variant.device == .duoInnerLandscape
            let view: AnyView
            if sample.details, wide {
                view = AnyView(HStack(spacing: 0) {
                    viewer
                    Divider()
                    ItemDetailsPanel(model: world.model, id: sample.id, close: {}, details: details).frame(width: 400)
                })
            } else if sample.details {
                view = AnyView(ItemDetailsPanel(model: world.model, id: sample.id, close: {}, details: details))
            } else {
                view = AnyView(viewer)
            }
            let renderingStarted = ProcessInfo.processInfo.systemUptime
            let image = try await SnapshotHost.capture(view, variant: sample.variant, clock: SnapshotWorld.clock,
                                                       defaults: world.defaults) { controller in
                let root = controller.view.window ?? controller.view!
                if !sample.details || wide {
                    guard let photo = root.descendant(of: PhotoContent.self) else {
                        throw SnapshotFailure("Viewer page has not appeared")
                    }
                    if photo.image == nil, let poster = world.catalog.items[sample.id]?.poster {
                        photo.image = poster
                        photo.tellLoaded()
                        throw SnapshotFailure("Waiting for the supplied synthetic poster to draw")
                    }
                }
                guard root.descendants(of: PlayerSurface.self).isEmpty else {
                    throw SnapshotFailure("Poster viewer created a player layer")
                }
                if sample.zoomed {
                    guard state.zoomed else { throw SnapshotFailure("Viewer did not acknowledge the zoom") }
                }
                if sample.details, wide { try Self.checkDetailsBesideViewer(root, relativeTo: controller.view) }
            }
            let rendered = ProcessInfo.processInfo.systemUptime
            defer {
                print("SNAPSHOT_PHASE \(sample.testDescription) setup=\(renderingStarted - started) "
                      + "render=\(rendered - renderingStarted) reference=\(ProcessInfo.processInfo.systemUptime - rendered)")
            }
            try world.stub.validate()
            try SnapshotReferences.shared.check(image, suite: "Viewer", name: sample.testDescription,
                                                 elapsed: ProcessInfo.processInfo.systemUptime - started)
        }
        private static func checkDetailsBesideViewer(_ root: UIView, relativeTo view: UIView) throws {
            let collections = root.descendants(of: UICollectionView.self)
            guard let pager = collections.first(where: { $0.collectionViewLayout is PagerLayout }),
                  let details = collections.first(where: { !($0.collectionViewLayout is PagerLayout) }) else {
                throw SnapshotFailure("Open Duo Details did not create its real list beside the pager")
            }
            var viewport = pager.bounds
            viewport.size.width -= ItemPagerController.gap
            let photoFrame = pager.convert(viewport, to: view)
            let detailsFrame = details.convert(details.bounds, to: view).intersection(view.safeAreaLayoutGuide.layoutFrame)
            guard photoFrame.width > 200, detailsFrame.width >= 260, detailsFrame.width <= 420,
                  photoFrame.maxX <= detailsFrame.minX + 1,
                  abs(photoFrame.midY - detailsFrame.midY) < view.bounds.height / 3 else {
                throw SnapshotFailure("Details no longer sits beside the viewer: \(photoFrame), \(detailsFrame)")
            }
        }

    }
}
