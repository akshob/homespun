// SPDX-License-Identifier: Apache-2.0
import Foundation
import SwiftUI

struct AppClock: Sendable {
    var now: @Sendable () -> Date = { Date() }
    var locale: Locale = .autoupdatingCurrent
    var calendar: Calendar = .autoupdatingCurrent
    var timeZone: TimeZone = .autoupdatingCurrent

    static let live = AppClock()
}

private struct AppClockKey: EnvironmentKey {
    static let defaultValue = AppClock.live
}

extension EnvironmentValues {
    var appClock: AppClock {
        get { self[AppClockKey.self] }
        set { self[AppClockKey.self] = newValue }
    }
}
