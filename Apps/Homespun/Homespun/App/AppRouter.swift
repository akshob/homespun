// SPDX-License-Identifier: Apache-2.0
import Observation

/// Where a link from a widget (`AppLink`) asked to go, until the main screen gets there.
@MainActor @Observable
final class AppRouter {
    /// Opened by the main screen once it's showing (after setup, if setup was still going).
    var pending: AppLink?
    /// A page of the Server tab to open when it appears (Automatic Mode, Premium).
    var serverRoute: ServerTab.Route?
}
