// SPDX-License-Identifier: Apache-2.0
import SwiftUI
import Testing
import UIKit
@testable import Homespun

@Suite @MainActor
struct SnapshotInfrastructureTests {
    @Test func perceptualThresholdsCatchSparseStrongChangesWithoutRejectingTinyNoise() throws {
        let white = try SnapshotImage.solid(width: 128, height: 128, color: CGColor(gray: 1, alpha: 1))
        let context = try SnapshotImage.context(width: 128, height: 128)
        context.draw(white, in: CGRect(x: 0, y: 0, width: 128, height: 128))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        let sparse = try #require(context.makeImage())
        let difference = try SnapshotDiff.compare(sparse, to: white)
        #expect(!difference.passed)
        #expect(try #require(difference.changedFraction) < 0.0005)
        #expect(try #require(difference.maximumDeltaE) > 90)
        #expect(difference.difference != nil)
        #expect(try SnapshotDiff.compare(sparse, to: white, tolerance: .init(maximum: 101)).passed)

        let noise = try SnapshotImage.solid(width: 128, height: 128,
                                            color: CGColor(gray: 254.0 / 255, alpha: 1))
        #expect(try SnapshotDiff.compare(noise, to: white).passed)
        let dark = try SnapshotImage.solid(width: 128, height: 128, color: CGColor(gray: 0, alpha: 1))
        #expect(try !SnapshotDiff.compare(dark, to: white, tolerance: .init(maximum: 101)).passed)
    }

    @Test func comparisonNeverResizesAReferenceToHideLayoutChanges() throws {
        let small = try SnapshotImage.solid(width: 2, height: 2, color: CGColor(gray: 1, alpha: 1))
        let large = try SnapshotImage.solid(width: 3, height: 2, color: CGColor(gray: 1, alpha: 1))
        let result = try SnapshotDiff.compare(large, to: small)
        #expect(!result.passed && !result.sizeMatches)
        #expect(result.difference?.width == 3)
    }

    @Test func recordingIsCIOnlyAndVerificationKeepsReferencesReadOnly() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        var options = options(in: folder)
        let colored = try SnapshotImage.solid(width: 4, height: 4,
                                             color: CGColor(red: 0.8, green: 0.3, blue: 0.5, alpha: 1))
        let black = try SnapshotImage.solid(width: 4, height: 4, color: CGColor(gray: 0, alpha: 1))
        options.isCI = false
        #expect(throws: SnapshotFailure.self) {
            try SnapshotReferences(options: options).check(colored, suite: "Fixture", name: "sample", elapsed: 0)
        }
        #expect(!FileManager.default.fileExists(atPath: options.references.path))
        options.isCI = true
        try SnapshotReferences(options: options).check(colored, suite: "Fixture", name: "sample", elapsed: 0)
        let reference = options.references.appendingPathComponent("Fixture/sample.png")
        let original = try Data(contentsOf: reference)
        options.mode = "verify"
        let verifier = SnapshotReferences(options: options)
        try verifier.check(colored, suite: "Fixture", name: "sample", elapsed: 0)
        #expect(throws: SnapshotFailure.self) {
            try verifier.check(black, suite: "Fixture", name: "sample", elapsed: 0)
        }
        #expect(try Data(contentsOf: reference) == original)
        for suffix in ["reference", "actual", "diff"] {
            #expect(FileManager.default.fileExists(atPath:
                options.results.appendingPathComponent("Fixture/sample.\(suffix).png").path))
        }
        let report = try JSONDecoder().decode([SnapshotMetric].self,
                                              from: Data(contentsOf: options.results.appendingPathComponent("report.json")))
        #expect(report.last?.result == "different")
        #expect(try #require(report.last?.maximumDeltaE) > 15)
        options.pin["runtimeBuild"] = "different"
        #expect(throws: SnapshotFailure.self) {
            try SnapshotReferences(options: options).check(colored, suite: "Fixture", name: "sample", elapsed: 0)
        }
    }

    @Test func recordMissingDoesNotReplaceExistingReferences() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        var options = options(in: folder)
        let white = try SnapshotImage.solid(width: 2, height: 2, color: CGColor(gray: 1, alpha: 1))
        let black = try SnapshotImage.solid(width: 2, height: 2, color: CGColor(gray: 0, alpha: 1))
        try SnapshotReferences(options: options).check(white, suite: "Fixture", name: "existing", elapsed: 0)
        let reference = options.references.appendingPathComponent("Fixture/existing.png")
        let original = try Data(contentsOf: reference)
        options.mode = "record-missing"
        let recorder = SnapshotReferences(options: options)
        try recorder.check(black, suite: "Fixture", name: "new", elapsed: 0)
        #expect(throws: SnapshotFailure.self) {
            try recorder.check(black, suite: "Fixture", name: "existing", elapsed: 0)
        }
        #expect(try Data(contentsOf: reference) == original)
        #expect(FileManager.default.fileExists(atPath: options.references.appendingPathComponent("Fixture/new.png").path))
    }

    @Test func sceneCanvasUsesMeasuredInsetsAndThreeTimesLayoutButTwoTimesRaster() async throws {
        @MainActor final class Geometry {
            var insets = EdgeInsets()
        }
        for size in [CGSize(width: 320, height: 640), CGSize(width: 951, height: 669)] {
            let insets = UIEdgeInsets(top: 20, left: 13, bottom: 31, right: size.width > 800 ? 84 : 7)
            let device = SnapshotDevice(size: size, safeArea: insets, horizontal: .regular, vertical: .regular,
                                        layoutScale: 3, nativeScale: 3)
            let geometry = Geometry()
            let content = ZStack { Color.green; ProgressView().tint(.black) }
                .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: {
                geometry.insets = $0
            }
            let controller = UIHostingController(rootView: content)
            let image = try await SnapshotCanvas.capture(controller, device: device) { controller in
                #expect(controller.view.safeAreaInsets == insets)
                #expect(controller.traitCollection.displayScale == 3)
                #expect(geometry.insets.top == insets.top && geometry.insets.leading == insets.left)
                #expect(geometry.insets.bottom == insets.bottom && geometry.insets.trailing == insets.right)
            }
            #expect(image.width == Int(size.width * 2) && image.height == Int(size.height * 2))
            if size.width > 800 {
                let data = try #require(image.dataProvider?.data)
                let pixels = try #require(CFDataGetBytePtr(data))
                let offset = (200 * image.width + 1600) * 4
                #expect(Int(pixels[offset + 1]) > Int(pixels[offset]) + 20)
                #expect(Int(pixels[offset + 1]) > Int(pixels[offset + 2]) + 20)
            }
        }
    }

    @Test func fixtureClockPinsLedgerTimesAndMonthFormattingWithoutChangingDefaults() async throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let date = Date(timeIntervalSince1970: 1_781_517_600)
        let ledger = CompactLedger(url: folder.appendingPathComponent("fixed/ledger.json"), now: { date })
        try await ledger.record(original: "ready", compact: "copy", originalBytes: 100, compactBytes: 20)
        try await ledger.recordBackedUp(original: "waiting", serverAssetID: "asset", originalBytes: 100)
        try await ledger.keepOriginals([("kept", "asset-2", 100)])
        #expect(await ledger.entry(for: "ready")?.savedAt == date)
        #expect(await ledger.backedUpSnapshot()["waiting"]?.backedUpAt == date)
        #expect(await ledger.backedUpSnapshot()["kept"]?.backedUpAt == date)

        let live = CompactLedger(url: folder.appendingPathComponent("live/ledger.json"))
        let before = Date()
        try await live.record(original: "one", compact: "two", originalBytes: 100, compactBytes: 20)
        let saved = try #require(await live.entry(for: "one")?.savedAt)
        #expect(saved >= before && saved <= Date())

        let zone = try #require(TimeZone(secondsFromGMT: 0))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let english = AppClock(now: { date }, locale: Locale(identifier: "en_US"), calendar: calendar, timeZone: zone)
        var french = english
        french.locale = Locale(identifier: "fr_FR")
        #expect(GridController.title(2026 * 12 + 5, clock: english) == "June 2026")
        #expect(GridController.title(2026 * 12 + 5, clock: french) == "juin 2026")
    }

    @Test func nestedSetupNavigationDrawsItsScrollContentRatherThanOnlyTheBottomBar() async throws {
        let world = try await SnapshotWorld()
        defer { world.close() }
        let flow = world.setup(.address)
        defer { flow.stop() }
        let view = OnboardingView(settings: world.settings, library: world.library, flow: flow)
            .environment(\.colorScheme, .light).environment(\.appClock, SnapshotWorld.clock)
            .transaction { $0.disablesAnimations = true; $0.animation = nil }
        let device = SnapshotDevice(size: CGSize(width: 320, height: 640),
                                    safeArea: UIEdgeInsets(top: 20, left: 0, bottom: 20, right: 0),
                                    horizontal: .compact, vertical: .regular, layoutScale: 3, nativeScale: 3)
        let image = try await SnapshotCanvas.capture(UIHostingController(rootView: view), device: device)
        let data = try #require(image.dataProvider?.data)
        let pixels = try #require(CFDataGetBytePtr(data))
        let offset = (200 * image.width + 10) * 4
        #expect(pixels[offset] > 200 && pixels[offset + 1] > 200 && pixels[offset + 2] > 200)
    }

    private func scratch() throws -> URL {
        let url = SnapshotEnvironment.results.deletingLastPathComponent()
            .appendingPathComponent("snapshot-state/contract-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func options(in folder: URL) -> SnapshotReferences.Options {
        var options = SnapshotReferences.Options()
        options.references = folder.appendingPathComponent("references", isDirectory: true)
        options.results = folder.appendingPathComponent("results", isDirectory: true)
        options.mode = "record"
        options.isCI = true
        options.pin = ["xcodeBuild": "fixture", "runtimeBuild": "fixture", "hostModel": "fixture", "renderer": "1"]
        return options
    }
}
