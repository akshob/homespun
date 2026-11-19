// SPDX-License-Identifier: Apache-2.0
import Foundation

enum AppFeatures {
    /// Hidden until Homespun Server ships a Microsoft app ID.
    static let cloudCopies = false
}

/// Features of the one-time purchase, shared with the widget gallery and UI tests.
enum PremiumFeature: String, Identifiable, CaseIterable {
    case automatic, cloudCopies, widgets
    var id: String { rawValue }

    var isAvailable: Bool { self != .cloudCopies || AppFeatures.cloudCopies }
    static var available: [Self] { allCases.filter(\.isAvailable) }
    static var backupFeatures: [Self] { available.filter { $0 != .widgets } }

    static var purchaseDescription: String {
        AppFeatures.cloudCopies ? "Automatic Mode, Cloud Copies and widgets" : "Automatic Mode and widgets"
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
