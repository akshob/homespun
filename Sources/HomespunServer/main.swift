// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import HomespunServerKit

let usage = """
    usage: homespun-server [serve | pair | install-service | devices | revoke <device-id>] [options]

      serve              Run the server (default).
      pair               Show a QR code and link to pair the Homespun app (one use, 10 minutes).
      install-service    Start the server now and whenever this computer starts
                         (systemd user service on Linux, LaunchAgent on macOS).
      devices            List paired devices.
      revoke <id>        Stop a device from using the server.

    Options (or environment variables):
      --data DIR         Where originals, compact copies, and the catalog live (HOMESPUN_DATA).
      --port N           Port, default 8787 (HOMESPUN_PORT).
      --name NAME        Name shown in the app, default this computer's name (HOMESPUN_NAME).
      HOMESPUN_HOST      Address to listen on; default 127.0.0.1, install-service uses 0.0.0.0.
      HOMESPUN_PUBLIC_URL  Address the app should use, if the detected one is wrong.

    Connect Immich from the app (Settings > Server), or set HOMESPUN_IMMICH_URL and
    HOMESPUN_IMMICH_API_KEY_FILE.
    """

var arguments = Array(CommandLine.arguments.dropFirst())
var environment = ProcessInfo.processInfo.environment
let flags = ["--data": "HOMESPUN_DATA", "--port": "HOMESPUN_PORT", "--name": "HOMESPUN_NAME"]
var index = 0
while index < arguments.count {
    if let key = flags[arguments[index]], index + 1 < arguments.count {
        var value = arguments[index + 1]
        if key == "HOMESPUN_DATA" {
            value = (value as NSString).expandingTildeInPath
            if !value.hasPrefix("/") { value = FileManager.default.currentDirectoryPath + "/" + value }
        }
        environment[key] = value
        arguments.removeSubrange(index...(index + 1))
    } else {
        index += 1
    }
}

// Settings saved by install-service, so `pair` and `devices` find the running server's data.
let settingsFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/homespun/server.env")
if let saved = try? String(contentsOf: settingsFile, encoding: .utf8) {
    for line in saved.split(separator: "\n") {
        let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
        if parts.count == 2, parts[0].hasPrefix("HOMESPUN_"), environment[parts[0]] == nil { environment[parts[0]] = parts[1] }
    }
}

do {
    var configuration = try ServerConfiguration.fromEnvironment(environment)
    let command = arguments.first ?? "serve"
    if command == "install-service", environment["HOMESPUN_HOST"] == nil { configuration.host = "0.0.0.0" }
    let server = try await HomespunServer(configuration: configuration)
    switch command {
    case "serve":
        print("Homespun Server \(ServerConfiguration.version) on \(configuration.host):\(configuration.port), "
              + "data in \(configuration.dataDirectory.path)")
        try await server.application().runService()
    case "pair":
        print(server.pairingInstructions(code: try await server.newPairingCode()))
    case "install-service":
        let executable = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
            .resolvingSymlinksInPath().path
        print(try server.installService(executable: executable))
        let saved = [("HOMESPUN_DATA", configuration.dataDirectory.path), ("HOMESPUN_HOST", configuration.host),
                     ("HOMESPUN_PORT", String(configuration.port)), ("HOMESPUN_NAME", configuration.name),
                     ("HOMESPUN_PUBLIC_URL", configuration.publicURL)]
            .compactMap { key, value in value.map { "\(key)=\($0)" } }.joined(separator: "\n") + "\n"
        try FileManager.default.createDirectory(at: settingsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try saved.write(to: settingsFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settingsFile.path)
        print("\nNext, pair the app:  \(executable) pair")
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
    FileHandle.standardError.write(Data("homespun-server: \(error)\n\n\(usage)\n".utf8))
    exit(1)
}
