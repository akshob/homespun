// SPDX-License-Identifier: Apache-2.0
import SwiftUI
import Testing
@testable import Homespun

private struct FreeUpSnapshotCase: Sendable, CustomTestStringConvertible {
    enum Scene: String, Sendable { case review, trial, keepOriginal }
    var scene: Scene = .review
    var variant: SnapshotVariant
    var testDescription: String { "\(scene.rawValue).\(variant.name)" }

    static var all: [Self] {
        var cases = [SnapshotDevice.Kind.iphone, .duoCover, .duoInnerPortrait, .duoInnerLandscape].map {
            Self(variant: .init(device: $0))
        }
        cases += [SnapshotDevice.Kind.iphone, .duoCover].flatMap {
            [Self(scene: .trial, variant: .init(device: $0)), Self(scene: .keepOriginal, variant: .init(device: $0))]
        }
        cases += [SnapshotDevice.Kind.iphone, .duoInnerLandscape].map {
            Self(variant: .init(device: $0, appearance: .dark))
        }
        return cases
    }
}

extension SnapshotTests {
    @Suite @MainActor
    struct FreeUp {
        @Test(arguments: FreeUpSnapshotCase.all)
        fileprivate func render(_ sample: FreeUpSnapshotCase) async throws {
            let started = ProcessInfo.processInfo.systemUptime
            let world = try await SnapshotWorld()
            defer { world.close() }
            if sample.scene == .trial { world.settings.trialConfirmed = false }
            let comparison = try await world.comparison(FixtureCatalog.compact(72))
            defer { comparison.close() }
            let pair = FreeUpPair(original: FixtureCatalog.original(72), compact: FixtureCatalog.compact(72))
            let view = FreeUpSpaceScreen(model: world.model, scope: nil,
                                         comparing: sample.scene == .keepOriginal ? pair : nil, comparison: comparison)
            let image = try await SnapshotHost.capture(view, variant: sample.variant, clock: SnapshotWorld.clock,
                                                       defaults: world.defaults) { controller in
                let device = sample.variant.device
                if sample.scene == .keepOriginal {
                    guard comparison.status == .ready, controller.view.descendant(identifier: "compare.image") != nil else {
                        throw SnapshotFailure("Keep Original did not open its real Compare destination")
                    }
                } else if device == .duoInnerPortrait || device == .duoInnerLandscape {
                    guard comparison.status == .ready else { throw SnapshotFailure("Free Up comparison has not loaded") }
                    let frames = try SnapshotComparisonFrames.read(in: controller.view)
                    let stage = frames.first.union(frames.second)
                    if device == .duoInnerLandscape {
                        guard stage.minX >= 300 else {
                            throw SnapshotFailure("Wide Free Up comparison is no longer beside the review: \(stage)")
                        }
                    } else {
                        guard stage.minX < 100, stage.maxY < controller.view.bounds.height - 180 else {
                            throw SnapshotFailure("Tall Free Up comparison is no longer above the brief review: \(stage)")
                        }
                    }
                }
            }
            try world.stub.validate()
            try SnapshotReferences.shared.check(image, suite: "FreeUp", name: sample.testDescription,
                                                 elapsed: ProcessInfo.processInfo.systemUptime - started)
        }
    }
}
