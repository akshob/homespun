// SPDX-License-Identifier: Apache-2.0
import XCTest

final class SnapshotProbeUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor func testDeviceTraits() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let output = environment["HOMESPUN_TRAIT_RESULTS"] else {
            throw XCTSkip("Run with ci/lane.sh probe or the nightly trait check.")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-traitProbe"]
        app.launch()
        defer { app.terminate() }
        let folder = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if environment["HOMESPUN_DEVICE_TYPE"] == "iPhone-Duo" {
            let file = try XCTUnwrap(environment["DUO_POSE_FILE"])
            let initial = app.frame.width < 600 ? "folded" : app.frame.width > app.frame.height ? "landscape" : "portrait"
            defer { try? pose(initial, file: file) }
            if initial != "folded" {
                app.terminate()
                try pose("folded", file: file)
                app.launch()
            }
            try capture("duoCover", app: app, folder: folder, wide: false, maximumWidth: 600)
            app.terminate()
            try pose("portrait", file: file)
            app.launch()
            try capture("duoInnerPortrait", app: app, folder: folder, wide: false, minimumWidth: 600)
            app.terminate()
            try pose("landscape", file: file)
            app.launch()
            try capture("duoInnerLandscape", app: app, folder: folder, wide: true, minimumWidth: 600)
        } else {
            XCUIDevice.shared.orientation = .portrait
            defer { XCUIDevice.shared.orientation = .portrait }
            try capture("iphone", app: app, folder: folder, wide: false)
            XCUIDevice.shared.orientation = .landscapeLeft
            try capture("iphoneLandscape", app: app, folder: folder, wide: true)
        }
    }

    @MainActor private func capture(_ name: String, app: XCUIApplication, folder: URL, wide: Bool,
                                    minimumWidth: Double = 0, maximumWidth: Double = .infinity) throws {
        let element = app.staticTexts["snapshot.traits"]
        XCTAssertTrue(element.waitForExistence(timeout: 20), "No trait probe label")
        let deadline = Date().addingTimeInterval(30)
        var previous = ""
        while Date() < deadline {
            let text = element.label
            if let data = text.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let size = object["sizePoints"] as? [Double], size.count == 2,
               size[0] > minimumWidth, size[0] < maximumWidth,
               (size[0] > size[1]) == wide, text == previous {
                let pretty = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
                try pretty.write(to: folder.appendingPathComponent(name + ".json"), options: .atomic)
                let attachment = XCTAttachment(data: pretty, uniformTypeIdentifier: "public.json")
                attachment.name = name
                attachment.lifetime = .keepAlways
                add(attachment)
                print("TRAITS \(name) \(text)")
                warnIfChanged(name, observed: object)
                return
            }
            previous = text
            Thread.sleep(forTimeInterval: 0.3)
        }
        XCTFail("Traits did not settle for \(name): \(element.label)")
    }

    @MainActor private func pose(_ value: String, file: String) throws {
        let url = URL(fileURLWithPath: file)
        try Data(value.utf8).write(to: url, options: .atomic)
        let deadline = Date().addingTimeInterval(240)
        while FileManager.default.fileExists(atPath: file), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file), "Pose request was not acknowledged: \(value)")
    }

    private func warnIfChanged(_ name: String, observed: [String: Any]) {
        guard let folder = ProcessInfo.processInfo.environment["HOMESPUN_SNAPSHOT_DIR"],
              let data = try? Data(contentsOf: URL(fileURLWithPath: folder).appendingPathComponent("TRAITS.json")),
              let all = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]],
              let expected = all[name] else { return }
        let keys = ["sizePoints", "safeArea", "displayScale", "nativeScale",
                    "horizontalSizeClass", "verticalSizeClass", "contentSizeCategory"]
        let old = expected.filter { keys.contains($0.key) } as NSDictionary
        let new = observed.filter { keys.contains($0.key) } as NSDictionary
        if !old.isEqual(new) {
            print("warning: Simulator traits changed for \(name); review TRAITS.json and re-record snapshots.")
        }
    }
}
