// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import HomespunCore
import Hummingbird
import Logging

/// Separate optional infrastructure, never started by Homespun Server or by the iPhone app.
public enum WakeRelayCommand {
    public static func run(environment: [String: String] = ProcessInfo.processInfo.environment,
                           arguments: [String] = CommandLine.arguments) async -> Int32 {
        if arguments.dropFirst().contains("--help") {
            print("""
                homespun-notify
                Optional opaque APNs wake relay. Requires a public HTTPS frontend to its loopback listener.
                Required: HOMESPUN_RELAY_DATA, HOMESPUN_RELAY_TLS_FRONTEND=YES,
                HOMESPUN_APNS_KEY_FILE (private .p8 file), HOMESPUN_APNS_KEY_ID, HOMESPUN_APNS_TEAM_ID.
                Optional: HOMESPUN_RELAY_PORT (8789), HOMESPUN_RELAY_MAX_ROUTES (10000),
                HOMESPUN_APNS_ENVIRONMENT (production or sandbox), HOMESPUN_APNS_TOPIC (photos.homespun.app).
                No deployment is performed by this command's installation.
                """)
            return 0
        }
        let logger = Logger(label: "homespun-notify")
        do {
            guard environment["HOMESPUN_RELAY_TLS_FRONTEND"] == "YES",
                  let data = environment["HOMESPUN_RELAY_DATA"], data.hasPrefix("/"),
                  let keyPath = environment["HOMESPUN_APNS_KEY_FILE"], keyPath.hasPrefix("/"),
                  let keyID = environment["HOMESPUN_APNS_KEY_ID"], let teamID = environment["HOMESPUN_APNS_TEAM_ID"],
                  let port = Int(environment["HOMESPUN_RELAY_PORT"] ?? "8789"), (1...65_535).contains(port),
                  let capacity = Int(environment["HOMESPUN_RELAY_MAX_ROUTES"] ?? "10000"),
                  let pushEnvironment = WakeRelayAPI.Environment(rawValue: environment["HOMESPUN_APNS_ENVIRONMENT"] ?? "production") else {
                throw APNsWakeFailure.configuration
            }
            let keyURL = URL(fileURLWithPath: keyPath)
            let keyAttributes = try keyURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            let permissions = try FileManager.default.attributesOfItem(atPath: keyPath)[.posixPermissions] as? NSNumber
            guard keyAttributes.isRegularFile == true, keyAttributes.isSymbolicLink != true,
                  let permissions, permissions.intValue & 0o077 == 0 else { throw APNsWakeFailure.configuration }
            let key = try String(contentsOf: keyURL, encoding: .utf8)
            let store = try WakeRelayStore(directory: URL(fileURLWithPath: data, isDirectory: true),
                policy: .init(maximumRoutes: capacity, minimumInterval: 20 * 60, pendingLifetime: 86_400,
                              activeLifetime: 90 * 86_400, leaseDuration: 60))
            let provider = try APNsWakeProvider(keyPEM: key, keyID: keyID, teamID: teamID,
                topic: environment["HOMESPUN_APNS_TOPIC"] ?? "photos.homespun.app")
            let relay = WakeRelay(store: store, environment: pushEnvironment)
            let application = Application(router: relay.router(),
                configuration: .init(address: .hostname("127.0.0.1", port: port), serverName: "homespun-notify"),
                services: [WakeRelayWorker(store: store, provider: provider, logger: logger)], logger: logger)
            do { try await application.runService() }
            catch {
                logger.error("Wake relay stopped with an error.")
                try await provider.shutdown()
                return 1
            }
            try await provider.shutdown()
            return 0
        } catch {
            logger.error("Wake relay configuration or storage is unavailable. Check its private configuration; no key is logged.")
            return 1
        }
    }
}
