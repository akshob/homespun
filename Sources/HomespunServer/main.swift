// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import HomespunServerKit

let usage = """
    usage: homespun-server [serve | pair | devices | revoke <device-id>]

      serve            Run the server (default).
      pair             Print a one-time code (valid 10 minutes) to pair the Homespun app.
      devices          List paired devices.
      revoke <id>      Stop a device from using the server.

    Environment: HOMESPUN_DATA (required), HOMESPUN_HOST (default 127.0.0.1; use 0.0.0.0 for
    your home network), HOMESPUN_PORT (default 8787), HOMESPUN_NAME, and for Immich mode
    HOMESPUN_IMMICH_URL with HOMESPUN_IMMICH_API_KEY_FILE.
    """

let arguments = Array(CommandLine.arguments.dropFirst())
do {
    let configuration = try ServerConfiguration.fromEnvironment()
    let server = try HomespunServer(configuration: configuration)
    switch arguments.first ?? "serve" {
    case "serve":
        print("Homespun Server \(ServerConfiguration.version) (\(configuration.mode.rawValue) mode) on "
              + "\(configuration.host):\(configuration.port), data in \(configuration.dataDirectory.path)")
        try await server.application().runService()
    case "pair":
        let code = try await server.newPairingCode()
        print("Pairing code: \(code)  (valid for 10 minutes, one use)")
        print("In the Homespun app, enter this server's address (port \(configuration.port)) and the code.")
    case "devices":
        for device in try await server.catalog.devices() {
            print("\(device.id)  \(device.name)  paired \(device.createdAt)  last seen \(device.lastSeenAt ?? "never")"
                  + (device.revokedAt.map { "  REVOKED \($0)" } ?? ""))
        }
    case "revoke" where arguments.count == 2:
        print(try await server.catalog.revoke(deviceID: arguments[1]) ? "Revoked." : "No such active device.")
    default:
        print(usage)
        exit(2)
    }
} catch {
    FileHandle.standardError.write(Data("homespun-server: \(error)\n\(usage)\n".utf8))
    exit(1)
}
