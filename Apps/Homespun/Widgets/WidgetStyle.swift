// SPDX-License-Identifier: Apache-2.0
import SwiftUI

/// The app's warm cream and rust (DESIGN §8), for the widgets and the watch app.
enum WidgetPalette {
    static let background = Color(light: 0xFBF8F3, dark: 0x1C1A18)
    static let accent = Color(light: 0x9A4F2B, dark: 0xE39A6F)
    static let teal = Color(light: 0x2F7D6B, dark: 0x5FB8A2)
    static let amber = Color(light: 0xA85D0B, dark: 0xF0A54A)
    static let stackBackground = Color(light: 0xF3E5DA, dark: 0x3B2A1F)
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        #if os(iOS)
        self.init(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
        #else
        // The watch is always dark.
        self.init(red: Double((dark >> 16) & 0xFF) / 255, green: Double((dark >> 8) & 0xFF) / 255,
                  blue: Double(dark & 0xFF) / 255)
        #endif
    }
}

/// Symbols for the four facts, the same everywhere.
enum FactSymbol {
    static let ready = "circle.lefthalf.filled"
    static let backup = "arrow.up.circle"
    static let server = "server.rack"
    static let unreachable = "wifi.exclamationmark"
    static let automatic = "bolt.fill"
    static let locked = "lock.fill"
    static let phone = "iphone"
}

/// "Updated 10 min ago", kept current by the system between timeline entries.
struct UpdatedText: View {
    let date: Date

    var body: some View {
        Text("Updated \(TimeDataSource<Date>.currentDate, format: .reference(to: date, allowedFields: [.day, .hour, .minute], maxFieldCount: 1))")
    }
}
