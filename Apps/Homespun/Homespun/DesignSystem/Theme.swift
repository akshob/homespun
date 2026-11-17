// SPDX-License-Identifier: Apache-2.0
import SwiftUI
import UIKit

/// Homespun's look (DESIGN §8): the website's warm cream and rust, light and dark, with darker
/// accents when Increase Contrast is on. Content stays solid; only bars, the tab bar and the primary
/// action use Liquid Glass.
enum Theme {
    static let background = Color(light: 0xFBF8F3, dark: 0x1C1A18)
    static let card = Color(light: 0xFFFFFF, dark: 0x262320)
    static let separator = Color(light: 0xE6DED3, dark: 0x3A3530)
    static let label = Color(light: 0x2B2622, dark: 0xEFE9E2)
    static let secondaryLabel = Color(light: 0x6D645C, dark: 0xB3A99F, lightContrast: 0x544C45)
    /// Only for disabled items, placeholders and chevrons: never essential text.
    static let tertiaryLabel = Color(light: 0xA39A91, dark: 0x7D746B)
    static let accent = Color(light: 0x9A4F2B, dark: 0xE39A6F, lightContrast: 0x7E3F21, darkContrast: 0xF0B48E)
    static let onAccent = Color(light: 0xFFFFFF, dark: 0x1C1A18)
    static let accentSoft = Color(light: 0xF3E5DA, dark: 0x3B2A1F)
    static let fill = Color(light: 0xF0E9E0, dark: 0x2F2B27)

    /// Status text: OK, warning, problem, information.
    static let teal = Color(light: 0x2F7D6B, dark: 0x5FB8A2)
    static let amber = Color(light: 0xA85D0B, dark: 0xF0A54A)
    static let red = Color(light: 0xC0392B, dark: 0xFF6B5E)
    static let blue = Color(light: 0x2F6FB3, dark: 0x7FB0FF)

    /// Badge glyphs sit on photos on a white halo, so they don't change with the appearance.
    enum BadgeColor {
        static let teal = Color(hex: 0x2F7D6B)
        static let amber = Color(hex: 0xA85D0B)
        static let red = Color(hex: 0xC0392B)
        static let grey = Color(hex: 0x8A8279)
        static let accent = Color(hex: 0x9A4F2B)
    }
}

/// The four tones for inline notices about lasting conditions. Shape and colour change together,
/// so meaning never depends on colour alone. There are no toasts.
enum FeedbackTone {
    case warning, error, success, info

    var background: Color {
        switch self {
        case .warning: Color(light: 0xFBEEE0, dark: 0x3A2A16)
        case .error: Color(light: 0xFBE4E1, dark: 0x3D1F1C)
        case .success: Color(light: 0xE3F2E8, dark: 0x1C3329)
        case .info: Color(light: 0xE8F1FB, dark: 0x1D2B3D)
        }
    }

    var stroke: Color {
        switch self {
        case .warning: Color(light: 0xF1D2AD, dark: 0x5A4020)
        case .error: Color(light: 0xF2C4BE, dark: 0x5C2D28)
        case .success: Color(light: 0xBFDCC9, dark: 0x2C4D3E)
        case .info: Color(light: 0xC5D9EF, dark: 0x2E4360)
        }
    }

    var symbol: String {
        switch self {
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        case .success: "checkmark.circle.fill"
        case .info: "info.circle"
        }
    }

    var glyph: Color {
        switch self {
        case .warning: Theme.amber
        case .error: Theme.red
        case .success: Theme.teal
        case .info: Theme.blue
        }
    }
}

/// An inline notice for a lasting condition (can't reach the server, the iPhone is almost full),
/// with optional actions. Text stays `label` / `secondaryLabel`; only the symbol takes the tone.
struct InlineNotice<Actions: View>: View {
    let tone: FeedbackTone
    let title: String
    var message: String?
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: tone.symbol).foregroundStyle(tone.glyph).font(.body.weight(.semibold))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.label)
                if let message { Text(message).font(.subheadline).foregroundStyle(Theme.secondaryLabel) }
                actions()
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(tone.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(tone.stroke))
        .accessibilityElement(children: Actions.self == EmptyView.self ? .combine : .contain)
    }
}

extension InlineNotice where Actions == EmptyView {
    init(tone: FeedbackTone, title: String, message: String? = nil) {
        self.init(tone: tone, title: title, message: message) { EmptyView() }
    }
}

/// A button title that keeps its name while busy: a spinner appears beside it, and VoiceOver hears
/// "Working" as its value (the old pattern replaced the title with a spinner, so it lost its name).
struct BusyLabel: View {
    let title: String
    var systemImage: String?
    var busy: Bool

    var body: some View {
        HStack(spacing: 8) {
            if busy { ProgressView().controlSize(.small) }
            if let systemImage, !busy { Label(title, systemImage: systemImage) } else { Text(title) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(busy ? "Working" : "")
    }
}

/// Spoken once when a long task starts or ends, never on every tick.
enum Announce {
    @MainActor static func say(_ text: String) {
        AccessibilityNotification.Announcement(text).post()
    }
}

extension View {
    /// Setup page titles: New York, semibold (Display in DESIGN §8.2).
    func displayTitle() -> some View {
        font(.system(.largeTitle, design: .serif, weight: .semibold)).foregroundStyle(Theme.label)
    }

    /// Big numbers ("4.2 GB"): rounded, with digits that don't jump.
    func bigNumber() -> some View {
        font(.system(.largeTitle, design: .rounded, weight: .semibold)).monospacedDigit()
    }

    /// The one prominent action on a page: rust Liquid Glass capsule, full width.
    func primaryAction() -> some View {
        buttonStyle(.glassProminent).controlSize(.large).tint(Theme.accent)
    }

    /// A card on warm paper: solid, never glass.
    func card(padding: CGFloat = 16) -> some View {
        self.padding(padding).background(Theme.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

extension Color {
    /// A colour from hex (0xRRGGBB), the same in light and dark.
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }

    /// A colour that follows light and dark mode, and Increase Contrast when given.
    init(light: UInt32, dark: UInt32, lightContrast: UInt32? = nil, darkContrast: UInt32? = nil) {
        self.init(uiColor: UIColor { traits in
            let high = traits.accessibilityContrast == .high
            let value = traits.userInterfaceStyle == .dark ? (high ? darkContrast ?? dark : dark)
                : (high ? lightContrast ?? light : light)
            return UIColor(red: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                           blue: CGFloat(value & 0xFF) / 255, alpha: 1)
        })
    }
}
