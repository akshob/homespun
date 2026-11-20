// SPDX-License-Identifier: Apache-2.0
import Foundation
import SwiftUI
import UIKit

struct SnapshotDevice {
    enum Kind: String, CaseIterable, Sendable {
        case iphone, iphoneLandscape, duoCover, duoInnerPortrait, duoInnerLandscape, duoInnerLandscapeStrip
    }

    let size: CGSize
    let safeArea: UIEdgeInsets
    let horizontal: UIUserInterfaceSizeClass
    let vertical: UIUserInterfaceSizeClass
    let layoutScale: CGFloat
    let nativeScale: CGFloat

    private struct Measurement: Decodable {
        let sizePoints: [CGFloat]
        let safeArea: [String: CGFloat]
        let displayScale: CGFloat
        let nativeScale: CGFloat
        let horizontalSizeClass: String
        let verticalSizeClass: String
    }

    static func measured(_ kind: Kind) throws -> SnapshotDevice {
        let url = SnapshotEnvironment.references.appendingPathComponent("TRAITS.json")
        guard let data = try? Data(contentsOf: url) else {
            throw SnapshotFailure("Missing TRAITS.json; run the pinned simulator probe first")
        }
        let measurements = try JSONDecoder().decode([String: Measurement].self, from: data)
        let key = kind == .duoInnerLandscapeStrip ? Kind.duoInnerLandscape.rawValue : kind.rawValue
        guard let value = measurements[key], value.sizePoints.count == 2, value.displayScale == 3 else {
            throw SnapshotFailure("Missing or unsupported measured device: \(key)")
        }
        func sizeClass(_ name: String) throws -> UIUserInterfaceSizeClass {
            switch name {
            case "compact": .compact
            case "regular": .regular
            default: throw SnapshotFailure("Unsupported size class in \(key): \(name)")
            }
        }
        return SnapshotDevice(
            size: CGSize(width: value.sizePoints[0], height: value.sizePoints[1]),
            safeArea: UIEdgeInsets(top: value.safeArea["top"] ?? 0, left: value.safeArea["left"] ?? 0,
                                  bottom: value.safeArea["bottom"] ?? 0,
                                  right: (value.safeArea["right"] ?? 0) + (kind == .duoInnerLandscapeStrip ? 84 : 0)),
            horizontal: try sizeClass(value.horizontalSizeClass), vertical: try sizeClass(value.verticalSizeClass),
            layoutScale: value.displayScale, nativeScale: value.nativeScale)
    }
}

struct SnapshotVariant: Hashable, Sendable {
    enum Appearance: String, Sendable { case light, dark }
    enum TypeSize: String, Sendable { case large, accessibilityExtraLarge }

    var device: SnapshotDevice.Kind
    var appearance: Appearance = .light
    var typeSize: TypeSize = .large

    var name: String { "\(device.rawValue).\(appearance.rawValue).\(typeSize.rawValue)" }
    var userInterfaceStyle: UIUserInterfaceStyle { appearance == .light ? .light : .dark }
    var colorScheme: ColorScheme { appearance == .light ? .light : .dark }
    var category: UIContentSizeCategory { typeSize == .large ? .large : .accessibilityExtraLarge }
    var dynamicType: DynamicTypeSize { typeSize == .large ? .large : .accessibility3 }

    static let light = SnapshotDevice.Kind.allCases.map { SnapshotVariant(device: $0) }
    static let standard = light + [
        SnapshotVariant(device: .iphone, appearance: .dark),
        SnapshotVariant(device: .duoInnerLandscape, appearance: .dark),
    ]
}
