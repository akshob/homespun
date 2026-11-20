// SPDX-License-Identifier: Apache-2.0
import SwiftUI
import Testing
@testable import Homespun

private struct AccessorySnapshotCase: Sendable, CustomTestStringConvertible {
    enum Scene: String, CaseIterable, Sendable { case backingUp, ready, unreachable, finished, done, overlay }
    var scene: Scene
    var variant: SnapshotVariant
    var testDescription: String { "\(scene.rawValue).\(variant.name)" }
    @MainActor var state: AccessoryLadder.State? {
        switch scene {
        case .backingUp: .backingUp(done: 12, total: 48, current: "Uploading the original")
        case .ready, .overlay: .ready(count: 5, bytes: 62_000_000)
        case .unreachable: .unreachable(StubServer.info.name)
        case .finished: .finished(count: 5, bytes: 62_000_000, originals: [])
        case .done: nil
        }
    }
    static var all: [Self] {
        var cases = Scene.allCases.flatMap { scene in
            [SnapshotDevice.Kind.iphone, .duoCover].map { Self(scene: scene, variant: .init(device: $0)) }
        }
        cases += [Self(scene: .ready, variant: .init(device: .iphone, appearance: .dark)),
                  Self(scene: .ready, variant: .init(device: .iphone, typeSize: .accessibilityExtraLarge))]
        return cases
    }
}

extension SnapshotTests {
    @Suite @MainActor
    struct Accessory {
        @Test(arguments: AccessorySnapshotCase.all)
        fileprivate func render(_ sample: AccessorySnapshotCase) async throws {
            let started = ProcessInfo.processInfo.systemUptime
            let world = try await SnapshotWorld()
            defer { world.close() }
            let view: AnyView
            if sample.scene == .overlay {
                view = AnyView(MainTabView(model: world.model))
            } else {
                let device = try SnapshotDevice.measured(sample.variant.device)
                let width = min(640, device.size.width - device.safeArea.left - device.safeArea.right - 24)
                view = AnyView(Theme.background.ignoresSafeArea().overlay {
                    StatusAccessorySurface(status: sample.state, serverName: world.library.serverName,
                                           width: width, open: { _ in })
                })
            }
            let image = try await SnapshotHost.capture(view, variant: sample.variant, clock: SnapshotWorld.clock,
                                                       defaults: world.defaults)
            try world.stub.validate()
            try SnapshotReferences.shared.check(image, suite: "Accessory", name: sample.testDescription,
                                                 elapsed: ProcessInfo.processInfo.systemUptime - started)
        }
    }
}
