// SPDX-License-Identifier: Apache-2.0
import CoreGraphics
import Foundation

enum SnapshotMode: String {
    case verify, record
    case recordMissing = "record-missing"
}

enum SnapshotEnvironment {
    private final class BundleMarker: NSObject {}

    static var references: URL {
        if let path = ProcessInfo.processInfo.environment["HOMESPUN_SNAPSHOT_DIR"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("__Snapshots__", isDirectory: true)
    }

    static var results: URL {
        if let path = ProcessInfo.processInfo.environment["HOMESPUN_SNAPSHOT_RESULTS"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return references.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("ci-results/snapshots", isDirectory: true)
    }

    static var isCI: Bool {
        ["true", "1"].contains(ProcessInfo.processInfo.environment["HOMESPUN_SNAPSHOT_CI"] ?? "")
    }

    static var mode: String { ProcessInfo.processInfo.environment["HOMESPUN_SNAPSHOTS"] ?? "verify" }

    static var pin: [String: String] {
        let environment = ProcessInfo.processInfo.environment
        return [
            "renderer": "2",
            "xcodeBuild": Bundle(for: BundleMarker.self).object(forInfoDictionaryKey: "DTXcodeBuild") as? String
                ?? environment["HOMESPUN_XCODE_BUILD"]
                ?? Bundle.main.object(forInfoDictionaryKey: "DTXcodeBuild") as? String ?? "unknown",
            "runtimeBuild": environment["SIMULATOR_RUNTIME_BUILD_VERSION"]
                ?? ProcessInfo.processInfo.operatingSystemVersionString,
            "hostModel": environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "unknown",
            "hostDevice": environment["HOMESPUN_SNAPSHOT_HOST"] ?? "iPhone-18-Pro",
            "locale": Locale.current.identifier,
        ]
    }

    static func readPin(at references: URL) -> [String: String]? {
        guard let text = try? String(contentsOf: references.appendingPathComponent("ENVIRONMENT.txt"), encoding: .utf8) else {
            return nil
        }
        var result: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { result[parts[0]] = parts[1] }
        }
        return result
    }

    static var shouldRun: Bool {
        isCI || mode != "verify" || readPin(at: references) == pin
    }
}

struct SnapshotMetric: Codable {
    var suite: String
    var name: String
    var result: String
    var changedFraction: Double?
    var maximumDeltaE: Double?
    var deltaEThreshold: Double = 2.3
    var elapsedSeconds: Double
    var referenceBytes: Int?
}

@MainActor
final class SnapshotReferences {
    static let shared = SnapshotReferences()
    static let budget: Double = 180

    struct Options {
        var references = SnapshotEnvironment.references
        var results = SnapshotEnvironment.results
        var mode = SnapshotEnvironment.mode
        var isCI = SnapshotEnvironment.isCI
        var pin = SnapshotEnvironment.pin
    }

    private let options: Options
    private var prepared = false
    private var metrics: [SnapshotMetric] = []

    init(options: Options = Options()) { self.options = options }

    func check(_ input: CGImage, suite: String, name: String, elapsed: Double,
               tolerance: SnapshotDiff.Tolerance = .init()) throws {
        let started = ProcessInfo.processInfo.systemUptime
        try prepare()
        guard !suite.isEmpty, !name.isEmpty, !suite.contains("/"), !name.contains("/"),
              suite != "..", name != ".." else { throw SnapshotFailure("Invalid snapshot name") }
        let mode = SnapshotMode(rawValue: options.mode)!
        let directory = options.references.appendingPathComponent(suite, isDirectory: true)
        let referenceURL = directory.appendingPathComponent(name + ".png")
        let actual = try SnapshotImage.sRGB(input)
        let exists = FileManager.default.fileExists(atPath: referenceURL.path)
        var metric = SnapshotMetric(suite: suite, name: name, result: "passed", elapsedSeconds: 0)
        metric.deltaEThreshold = Double(tolerance.deltaE)
        var failure: String?
        if mode == .record || (mode == .recordMissing && !exists) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try SnapshotImage.png(actual)
            try data.write(to: referenceURL, options: .atomic)
            metric.result = "recorded"
            metric.referenceBytes = data.count
        } else if !exists {
            metric.result = "missing"
            let placeholder = try SnapshotImage.solid(width: actual.width, height: actual.height,
                                                      color: CGColor(gray: 0.8, alpha: 1))
            try writeFailure(suite: suite, name: name, reference: placeholder, actual: actual, difference: actual)
            failure = "Missing reference \(suite)/\(name); record snapshots in CI"
        } else {
            let reference = try SnapshotImage.sRGB(SnapshotImage.read(referenceURL))
            let diff = try SnapshotDiff.compare(actual, to: reference, tolerance: tolerance)
            metric.changedFraction = diff.changedFraction
            metric.maximumDeltaE = diff.maximumDeltaE
            metric.referenceBytes = (try? referenceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            if !diff.passed {
                metric.result = diff.sizeMatches ? "different" : "size"
                try writeFailure(suite: suite, name: name, reference: reference, actual: actual,
                                 difference: diff.difference ?? actual)
                if let fraction = diff.changedFraction, let maximum = diff.maximumDeltaE {
                    failure = String(format: "%@/%@ differs: %.4f%% of pixels over ΔE %.1f; maximum ΔE %.2f",
                                     suite, name, fraction * 100, tolerance.deltaE, maximum)
                } else {
                    failure = "\(suite)/\(name) snapshot size differs"
                }
            }
        }
        metric.elapsedSeconds = elapsed + ProcessInfo.processInfo.systemUptime - started
        metrics.append(metric)
        let total = metrics.reduce(0) { $0 + $1.elapsedSeconds }
        if total > Self.budget {
            failure = String(format: "Snapshot suite exceeded its %.0f s budget (%.1f s)", Self.budget, total)
            metrics[metrics.count - 1].result = "budget"
        }
        try report()
        if let failure { throw SnapshotFailure(failure) }
    }

    private func prepare() throws {
        guard !prepared else { return }
        guard let mode = SnapshotMode(rawValue: options.mode) else {
            throw SnapshotFailure("Unknown snapshot mode: \(options.mode)")
        }
        if mode != .verify, !options.isCI { throw SnapshotFailure("Record snapshot references only in CI") }
        if mode == .record {
            guard options.pin["xcodeBuild"] != "unknown", options.pin["hostModel"] != "unknown" else {
                throw SnapshotFailure("Missing Xcode/simulator metadata for snapshot recording")
            }
            try FileManager.default.createDirectory(at: options.references, withIntermediateDirectories: true)
            let text = options.pin.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n") + "\n"
            try text.write(to: options.references.appendingPathComponent("ENVIRONMENT.txt"), atomically: true, encoding: .utf8)
        } else if SnapshotEnvironment.readPin(at: options.references) != options.pin {
            throw SnapshotFailure("Snapshot environment changed or is missing; re-record snapshots for this Xcode/runtime")
        }
        prepared = true
    }

    private func writeFailure(suite: String, name: String, reference: CGImage, actual: CGImage, difference: CGImage) throws {
        let directory = options.results.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (suffix, image) in [("reference", reference), ("actual", actual), ("diff", difference)] {
            try SnapshotImage.png(image).write(to: directory.appendingPathComponent("\(name).\(suffix).png"), options: .atomic)
        }
    }

    private func report() throws {
        try FileManager.default.createDirectory(at: options.results, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(metrics).write(to: options.results.appendingPathComponent("report.json"), options: .atomic)
    }
}
