// SPDX-License-Identifier: Apache-2.0
import SwiftUI
import Testing
import UIKit
@testable import Homespun

private struct GridSnapshotCase: Sendable, CustomTestStringConvertible {
    enum Scene: String, Sendable { case badges, selected, videos, empty }
    var scene: Scene = .badges
    var variant: SnapshotVariant
    var density = 4
    var columns: Int
    var testDescription: String { "\(scene.rawValue).\(density).\(variant.name)" }

    static var all: [Self] {
        let columns: [SnapshotDevice.Kind: Int] = [
            .iphone: 4, .iphoneLandscape: 5, .duoCover: 4, .duoInnerPortrait: 5,
            .duoInnerLandscape: 6, .duoInnerLandscapeStrip: 6,
        ]
        var cases = SnapshotVariant.standard.map { Self(variant: $0, columns: columns[$0.device]!) }
        for (device, large, small) in [(SnapshotDevice.Kind.iphone, 2, 6), (.duoCover, 2, 6), (.duoInnerPortrait, 3, 8)] {
            cases += [Self(variant: .init(device: device), density: 2, columns: large),
                      Self(variant: .init(device: device), density: 6, columns: small)]
        }
        for scene in [Scene.selected, .videos, .empty] {
            cases += [SnapshotDevice.Kind.iphone, .duoCover, .duoInnerPortrait, .duoInnerLandscape].map {
                Self(scene: scene, variant: .init(device: $0), columns: columns[$0]!)
            }
        }
        return cases
    }
}

extension SnapshotTests {
    @Suite @MainActor
    struct Grid {
        @Test(arguments: GridSnapshotCase.all)
        fileprivate func render(_ sample: GridSnapshotCase) async throws {
            let started = ProcessInfo.processInfo.systemUptime
            let world = try await SnapshotWorld(count: sample.scene == .empty ? 0 : 96)
            defer { world.close() }
            let image: CGImage
            if sample.scene == .empty {
                image = try await SnapshotHost.capture(LibraryView(model: world.model, freeUp: { _ in }),
                                                       variant: sample.variant, clock: SnapshotWorld.clock,
                                                       defaults: world.defaults) { controller in
                    guard let grid = controller.view.descendant(of: UICollectionView.self),
                          grid.numberOfSections == 0 else {
                        throw SnapshotFailure("Empty Library did not finish loading")
                    }
                }
            } else {
                let library = world.library.library
                let media = sample.scene == .videos ? await library.identifiers(.videos) : nil
                let data = GridData(state: library.state, filter: .all, media: media, months: library.monthsSnapshot)
                let counts = SectionCounts()
                counts.update(data)
                let selection = GridSelection()
                selection.active = sample.scene == .selected
                if selection.active { selection.ids = data.selectable }
                let input = GridInput(
                    data: data, dataVersion: 1, stateVersion: library.state.version, selecting: selection.active,
                    selectionVersion: selection.version, countsVersion: counts.version, filter: .all, paired: true,
                    serverName: world.library.serverName, density: sample.density, newest: 0,
                    notice: AnyView(EmptyView()), noticeKey: "")
                let actions = GridActions(tapped: { _ in }, menu: { _, _ in nil }, dragSelect: { _ in },
                                          dragEnded: {}, resize: { _ in })
                let controller = GridController(library: library, selection: selection, counts: counts, zoom: GridZoom(),
                                                input: input, actions: actions, clock: SnapshotWorld.clock)
                image = try await SnapshotHost.capture(controller, device: SnapshotDevice.measured(sample.variant.device),
                                                       appearance: sample.variant.userInterfaceStyle,
                                                       category: sample.variant.category) { controller in
                    try Self.checkGeometry(controller, columns: sample.columns)
                }
            }
            try world.stub.validate()
            try SnapshotReferences.shared.check(image, suite: "Grid", name: sample.testDescription,
                                                 elapsed: ProcessInfo.processInfo.systemUptime - started)
        }

        private static func checkGeometry(_ controller: UIViewController, columns: Int) throws {
            guard let collection = controller.view as? UICollectionView,
                  let layout = collection.collectionViewLayout as? Homespun.GridLayout else {
                throw SnapshotFailure("Missing real GridController layout")
            }
            let geometry = layout.geometry
            let expectedWidth = collection.bounds.width - collection.adjustedContentInset.left - collection.adjustedContentInset.right
            guard collection.traitCollection.displayScale == 3, geometry.metrics.scale == 3,
                  geometry.columns == columns, abs(geometry.metrics.width - expectedWidth) < 0.01,
                  geometry.count >= columns else {
                throw SnapshotFailure("Grid geometry changed: \(geometry.columns) columns at \(geometry.metrics.width) pt; "
                                      + "expected \(columns) at \(expectedWidth) pt, layout scale 3")
            }
            let month = geometry.months - 1
            let range = geometry.monthRange(month)
            let first = range.lowerBound, count = min(columns, range.count)
            let frames = (first..<(first + count)).map { geometry.frame(ofItem: $0) }
            guard frames.first?.minX == 0,
                  count < columns || abs(frames.last!.maxX - expectedWidth) < 0.01 else {
                throw SnapshotFailure("Grid no longer reaches both content edges")
            }
            for pair in zip(frames, frames.dropFirst()) {
                guard abs(pair.1.minX - pair.0.maxX - 2) < 0.01 else {
                    throw SnapshotFailure("Grid spacing changed")
                }
            }
            for frame in frames {
                guard abs(frame.minX * 3 - (frame.minX * 3).rounded()) < 0.01,
                      abs(frame.maxX * 3 - (frame.maxX * 3).rounded()) < 0.01 else {
                    throw SnapshotFailure("Grid edges no longer fall on real layout pixels")
                }
            }
        }
    }
}

extension UIView {
    func descendant<T: UIView>(of type: T.Type) -> T? {
        if let match = self as? T { return match }
        return subviews.lazy.compactMap { $0.descendant(of: type) }.first
    }
}
