// SPDX-License-Identifier: Apache-2.0
import SwiftUI
import Testing
@testable import Homespun

private struct SetupSnapshotCase: Sendable, CustomTestStringConvertible {
    enum Page: String, CaseIterable, Sendable {
        case welcome, localNetwork, looking, found, otherWays, address, ready, analytics, photos, estimate, welcomeBack, preparing
        @MainActor var flowPage: SetupFlow.Page {
            switch self {
            case .welcome: .welcome
            case .localNetwork: .localNetwork
            case .looking: .looking
            case .found: .found
            case .otherWays: .otherWays
            case .address: .address
            case .ready: .ready
            case .analytics: .analytics
            case .photos: .photos
            case .estimate: .estimate
            case .welcomeBack: .welcomeBack
            case .preparing: .welcome
            }
        }
    }
    var page: Page
    var variant: SnapshotVariant
    var testDescription: String { "\(page.rawValue).\(variant.name)" }
    static var all: [Self] {
        var cases = Page.allCases.map { Self(page: $0, variant: .init(device: .iphone)) }
        for device in [SnapshotDevice.Kind.duoCover, .duoInnerPortrait] {
            cases += [Page.welcome, .localNetwork, .found, .address, .estimate, .preparing].map {
                Self(page: $0, variant: .init(device: device))
            }
        }
        cases += [Page.welcome, .ready].map { Self(page: $0, variant: .init(device: .iphone, appearance: .dark)) }
        cases += [Page.welcome, .photos, .address, .estimate].map {
            Self(page: $0, variant: .init(device: .iphone, typeSize: .accessibilityExtraLarge))
        }
        return cases
    }
}

extension SnapshotTests {
    @Suite @MainActor
    struct Setup {
        @Test(arguments: SetupSnapshotCase.all)
        fileprivate func render(_ sample: SetupSnapshotCase) async throws {
            let started = ProcessInfo.processInfo.systemUptime
            let world = try await SnapshotWorld()
            defer { world.close() }
            let flow = world.setup(sample.page.flowPage)
            defer { flow.stop() }
            let view: AnyView
            if sample.page == .preparing {
                view = AnyView(DemoPreparationContent(failure: nil, progress: .init(done: 42, total: 72, fraction: 42.0 / 72),
                                                       cancelTitle: "Cancel", retry: {}, cancel: {}))
            } else {
                view = AnyView(OnboardingView(settings: world.settings, library: world.library, flow: flow))
            }
            let image = try await SnapshotHost.capture(view, variant: sample.variant, clock: SnapshotWorld.clock,
                                                       defaults: world.defaults)
            try world.stub.validate()
            try SnapshotReferences.shared.check(image, suite: "Setup", name: sample.testDescription,
                                                 elapsed: ProcessInfo.processInfo.systemUptime - started)
        }
    }
}
