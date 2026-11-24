// SPDX-License-Identifier: Apache-2.0
import Foundation

enum ReleaseFeatures {
    static let enabled = resolve(
        shipping: Bundle.main.object(forInfoDictionaryKey: "HomespunReleaseFeatures") as? String == "YES",
        arguments: ProcessInfo.processInfo.arguments, environment: ProcessInfo.processInfo.environment)

    static var automaticMode: Bool { enabled }
    static var widgets: Bool { enabled }
    static var watch: Bool { enabled }
    static var cloudCopies: Bool { enabled }
    static var premium: Bool { enabled }

    static func resolve(shipping: Bool, arguments: [String], environment: [String: String]) -> Bool {
        #if DEBUG
        if let index = arguments.firstIndex(of: "-releaseFeatures"), arguments.indices.contains(index + 1) {
            return arguments[index + 1] == "YES"
        }
        if let value = environment["HOMESPUN_RELEASE_FEATURES"] { return value == "1" }
        #endif
        return shipping
    }
}

/// Features of the one-time purchase, shared with the widget gallery and UI tests.
enum PremiumFeature: String, Identifiable, CaseIterable {
    case automatic, cloudCopies, widgets
    var id: String { rawValue }

    var isAvailable: Bool {
        switch self {
        case .automatic: ReleaseFeatures.automaticMode
        case .cloudCopies: ReleaseFeatures.cloudCopies
        case .widgets: ReleaseFeatures.widgets
        }
    }
    static var available: [Self] { allCases.filter(\.isAvailable) }
    static var backupFeatures: [Self] { available.filter { $0 != .widgets } }

    static var purchaseDescription: String {
        ReleaseFeatures.cloudCopies
            ? "Automatic Mode, OneDrive Cloud Copies, widgets and Apple Watch"
            : "Automatic Mode, widgets and Apple Watch"
    }

    var name: String {
        switch self {
        case .automatic: "Automatic Mode"
        case .cloudCopies: "Cloud Copies"
        case .widgets: "Widgets"
        }
    }

    var symbol: String {
        switch self {
        case .automatic: "bolt.fill"
        case .cloudCopies: "icloud.and.arrow.up"
        case .widgets: "square.grid.2x2"
        }
    }
}
