// SPDX-License-Identifier: Apache-2.0
import SwiftUI
import Testing
import UIKit
@testable import Homespun

private struct CompareSnapshotCase: Sendable, CustomTestStringConvertible {
    enum Layout: Sendable { case single, split, beside, stacked }
    var variant: SnapshotVariant
    var video = false
    var fraction = 0.5
    var layout: Layout
    var testDescription: String { "\(video ? "video" : "photo").split\(Int(fraction * 100)).\(variant.name)" }

    static var all: [Self] {
        [
            Self(variant: .init(device: .iphone), layout: .split),
            Self(variant: .init(device: .iphone), fraction: 0.25, layout: .split),
            Self(variant: .init(device: .iphone, appearance: .dark), layout: .split),
            Self(variant: .init(device: .iphoneLandscape), layout: .split),
            Self(variant: .init(device: .duoCover), layout: .split),
            Self(variant: .init(device: .duoInnerPortrait), layout: .stacked),
            Self(variant: .init(device: .duoInnerLandscape), layout: .beside),
            Self(variant: .init(device: .duoInnerLandscape, appearance: .dark), layout: .beside),
            Self(variant: .init(device: .duoInnerLandscapeStrip), layout: .beside),
            Self(variant: .init(device: .iphone), video: true, layout: .single),
            Self(variant: .init(device: .iphoneLandscape), video: true, layout: .single),
            Self(variant: .init(device: .duoInnerPortrait), video: true, layout: .stacked),
            Self(variant: .init(device: .duoInnerLandscape), video: true, layout: .beside),
        ]
    }
}

extension SnapshotTests {
    @Suite @MainActor
    struct Compare {
        @Test(arguments: CompareSnapshotCase.all)
        fileprivate func render(_ sample: CompareSnapshotCase) async throws {
            let started = ProcessInfo.processInfo.systemUptime
            let world = try await SnapshotWorld()
            defer { world.close() }
            let comparison = try await world.comparison(FixtureCatalog.compact(sample.video ? 75 : 72))
            defer { comparison.close() }
            let view = NavigationStack {
                CompareView(model: world.model, compactIdentifier: FixtureCatalog.compact(sample.video ? 75 : 72),
                            split: sample.fraction, comparison: comparison)
            }
            let image = try await SnapshotHost.capture(view, variant: sample.variant, clock: SnapshotWorld.clock,
                                                       defaults: world.defaults) { controller in
                guard comparison.status == .ready, comparison.hasOriginal, comparison.hasCompact else {
                    throw SnapshotFailure("Compare has not loaded both fixture images")
                }
                guard controller.view.descendants(of: PlayerSurface.self).isEmpty else {
                    throw SnapshotFailure("Poster comparisons must not create player layers")
                }
                switch sample.layout {
                case .beside, .stacked:
                    let frames = try SnapshotComparisonFrames.read(in: controller.view)
                    let beside = frames.first.maxX <= frames.second.minX + 0.1
                        && abs(frames.first.midY - frames.second.midY) < 0.1
                    let stacked = frames.first.maxY <= frames.second.minY + 0.1
                        && abs(frames.first.midX - frames.second.midX) < 0.1
                    guard sample.layout == .beside ? beside : stacked else {
                        throw SnapshotFailure("Compare panes moved: \(frames)")
                    }
                case .split, .single:
                    guard let canvas = controller.view.descendant(identifier: "compare.image"),
                          canvas.bounds.width > 100, canvas.bounds.height > 100 else {
                        throw SnapshotFailure("Compare canvas is missing")
                    }
                }
            }
            try world.stub.validate()
            try SnapshotReferences.shared.check(image, suite: "Compare", name: sample.testDescription,
                                                 elapsed: ProcessInfo.processInfo.systemUptime - started)
        }
    }
}

@MainActor
enum SnapshotComparisonFrames {
    static func read(in root: UIView) throws -> (first: CGRect, second: CGRect) {
        func frame(_ identifier: String) throws -> CGRect {
            guard let image = root.descendant(identifier: identifier) as? UIImageView, image.image != nil else {
                throw SnapshotFailure("Comparison image has not loaded: \(identifier)")
            }
            var ancestor = image.superview
            while let view = ancestor {
                if view is ZoomScrollView { return view.convert(view.bounds, to: root) }
                ancestor = view.superview
            }
            throw SnapshotFailure("Comparison lost its real zoom viewport")
        }
        return try (frame("compare.image.original"), frame("compare.image.compact"))
    }
}
