// SPDX-License-Identifier: Apache-2.0
import Foundation
import HomespunCore
import UserNotifications

@MainActor
enum BackupReadyAlerts {
    static func post(context: BackupBindingContext, ledger: CompactLedger, photos: any PhotoSource,
                     current: @MainActor () -> Bool) async throws -> Bool {
        guard current() else { return false }
        let center = UNUserNotificationCenter.current()
        let authorization = await center.notificationSettings().authorizationStatus
        guard [.authorized, .provisional, .ephemeral].contains(authorization) else { return false }
        let entries = try await ledger.snapshot().filter {
            $0.value.origin == context.binding.origin && $0.value.verifiedCompact
        }
        let originals = photos.existing(Array(entries.keys), includeHidden: false)
        let copies = photos.existing(entries.values.map(\.compactIdentifier), includeHidden: true)
        let count = entries.count { originals.contains($0.key) && copies.contains($0.value.compactIdentifier) }
        guard current(), !Task.isCancelled else { return false }
        guard count > 0 else { return true }
        let content = UNMutableNotificationContent()
        content.title = "Ready to free up space"
        content.body = "\(count) compact \(count == 1 ? "copy is" : "copies are") saved and verified. Review them before removing any originals."
        content.userInfo = ["homespun.route": "free-up"]
        let origin = context.binding.origin
        let key = Fingerprint.sha256(of: Data((origin.serverID + ":" + origin.historyEpoch).utf8))
        try await center.add(.init(identifier: "homespun.ready." + key, content: content, trigger: nil))
        return true
    }
}

final class BackupAlertDelegate: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared = BackupAlertDelegate()

    nonisolated static func install() { UNUserNotificationCenter.current().delegate = shared }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              response.notification.request.content.userInfo["homespun.route"] as? String == "free-up" else { return }
        await MainActor.run { AppModel.shared.router.pending = .freeUp }
    }
}
