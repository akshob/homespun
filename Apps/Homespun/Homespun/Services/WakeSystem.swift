// SPDX-License-Identifier: Apache-2.0
import Foundation
import HomespunCore
import UIKit

@MainActor enum WakeSystem {
    static let enrollment: WakeEnrollment = {
        let configured = Bundle.main.object(forInfoDictionaryKey: "HomespunWakeRelayURL") as? String
        let url = configured.flatMap { $0.isEmpty ? nil : URL(string: $0) }
        #if DEBUG
        let environment = WakeRelayAPI.Environment.sandbox
        #else
        let environment = WakeRelayAPI.Environment.production
        #endif
        return WakeEnrollment(relayURL: url, environment: environment, storage: KeychainWakeEnrollmentStore())
    }()

    static func updateRegistration() {
        updateRegistration(for: enrollment)
    }

    static func updateRegistration(for enrollment: WakeEnrollment) {
        if enrollment.shouldRegisterForPush { UIApplication.shared.registerForRemoteNotifications() }
        else { UIApplication.shared.unregisterForRemoteNotifications() }
    }

    static func resume() async throws {
        try await enrollment.resume()
        updateRegistration()
    }
}

@MainActor final class WakeAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in
            do { try await WakeSystem.enrollment.receivedDeviceToken(deviceToken) }
            catch { WakeSystem.enrollment.enrollmentFailed() }
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        WakeSystem.enrollment.registrationFailed()
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        guard let aps = userInfo["aps"] as? [String: Any], aps["content-available"] as? Int == 1 else { return .noData }
        do { return try await WakeSystem.enrollment.receiveHint() ? .newData : .noData }
        catch { return .failed }
    }
}
