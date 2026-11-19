// SPDX-License-Identifier: Apache-2.0
import SwiftUI

enum MediaPresentation: Sendable, Equatable {
    case interactive, poster
}

private struct MediaPresentationKey: EnvironmentKey {
    static let defaultValue = MediaPresentation.interactive
}

extension EnvironmentValues {
    var mediaPresentation: MediaPresentation {
        get { self[MediaPresentationKey.self] }
        set { self[MediaPresentationKey.self] = newValue }
    }
}
