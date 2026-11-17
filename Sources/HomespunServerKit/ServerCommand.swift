// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// The `homespun-server` command line. A server binary with extra connectors calls
/// `ServerCommand.run(connectors:)` from its own `main`.
public enum ServerCommand {
    static let usage = """
        usage: homespun-server [serve | pair | install-service | devices | revoke <device-id> | import <manifest>] [options]

          serve              Run the server (default).
          pair               Show a QR code and link to pair the Homespun app (one use, 10 minutes;
                             --minutes N keeps it longer, up to a day, e.g. for a test run).
          install-service    Copy the server to ~/.local/bin and start it now and whenever this
                             computer starts (systemd user service on Linux, LaunchAgent on macOS).
          devices            List paired devices.
          revoke <id>        Stop a device from using the server.
          import <manifest>  Record originals already kept elsewhere, and the compact copies made from
                             them before Homespun, so the app recognises those copies. The originals
                             are only read, never changed. One JSON object per line (see the README).
                             --copy copies them into the originals folder, under --folder NAME
                             (default "Camera Roll"), instead of leaving them where they are.
                             --dry-run only checks the files; --jobs N reads N files at a time
                             (default 4).

        Options (or environment variables):
          --data DIR         Where the catalog, compact copies, and work files live (HOMESPUN_DATA).
          --originals DIR    Where originals go, a folder per phone (HOMESPUN_ORIGINALS); default
                             DIR/originals in the data folder. Once set, change it from the app,
                             which moves every original there.
          --port N           Port, default 8787 (HOMESPUN_PORT).
          --name NAME        Name shown in the app, default this computer's name (HOMESPUN_NAME).
          HOMESPUN_HOST      Address to listen on; default 127.0.0.1, install-service uses 0.0.0.0.
          HOMESPUN_PUBLIC_URL  Address the app should use, if the detected one is wrong.

        Connect Immich from the app (Settings > Server), or set HOMESPUN_IMMICH_URL and
        HOMESPUN_IMMICH_API_KEY_FILE.
        """

    /// How long a code from `pair` lasts: 10 minutes, or `--minutes N` (1 to 1440).
    static func pairingMinutes(_ options: [String]) -> Int? {
        guard let index = options.firstIndex(of: "--minutes") else { return 10 }
        guard index + 1 < options.count, let minutes = Int(options[index + 1]), (1...1440).contains(minutes) else { return nil }
        return minutes
    }

    /// Runs the command and returns its exit status.
    public static func run(connectors: [any Connector] = [], commandLine: [String] = CommandLine.arguments) async -> Int32 {
        var arguments = Array(commandLine.dropFirst())
        var environment = ProcessInfo.processInfo.environment
        let flags = ["--data": "HOMESPUN_DATA", "--originals": "HOMESPUN_ORIGINALS", "--port": "HOMESPUN_PORT",
                     "--name": "HOMESPUN_NAME"]
        var index = 0
        while index < arguments.count {
            if let key = flags[arguments[index]], index + 1 < arguments.count {
                var value = arguments[index + 1]
                if key == "HOMESPUN_DATA" || key == "HOMESPUN_ORIGINALS" {
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
            environment = Self.applying(saved: saved, to: environment)
        }

        do {
            var configuration = try ServerConfiguration.fromEnvironment(environment)
            let command = arguments.first ?? "serve"
            if command == "install-service", environment["HOMESPUN_HOST"] == nil { configuration.host = "0.0.0.0" }
            let server = try await HomespunServer(configuration: configuration, connectors: connectors)
            switch command {
            case "serve":
                print("Homespun Server \(ServerConfiguration.version) on \(configuration.host):\(configuration.port), "
                      + "data in \(configuration.dataDirectory.path)")
                try await server.run()
            case "pair":
                guard let minutes = pairingMinutes(Array(arguments.dropFirst())) else {
                    FileHandle.standardError.write(Data("pair: --minutes takes a number from 1 to 1440.\n".utf8))
                    return 2
                }
                let code = try await server.newPairingCode(lifetime: TimeInterval(minutes * 60))
                print(server.pairingInstructions(code: code, minutes: minutes))
            case "install-service":
                let executable = URL(fileURLWithPath: Bundle.main.executablePath ?? commandLine[0])
                    .resolvingSymlinksInPath().path
                print(try server.installService(executable: executable))
                let saved = [("HOMESPUN_DATA", configuration.dataDirectory.path),
                             ("HOMESPUN_ORIGINALS", configuration.originalsDirectory?.path), ("HOMESPUN_HOST", configuration.host),
                             ("HOMESPUN_PORT", String(configuration.port)), ("HOMESPUN_NAME", configuration.name),
                             ("HOMESPUN_PUBLIC_URL", configuration.publicURL),
                             ("HOMESPUN_ONEDRIVE_CLIENT_ID", configuration.onedriveClientID)]
                    .compactMap { key, value in value.map { "\(key)=\($0)" } }.joined(separator: "\n") + "\n"
                try FileManager.default.createDirectory(at: settingsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                try saved.write(to: settingsFile, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settingsFile.path)
                #if os(macOS)
                print("\nNext, open Homespun on your iPhone, pick \"\(configuration.name)\", and click Allow on this Mac."
                      + "\n(Or show a pairing code: ~/.local/bin/homespun-server pair)")
                #else
                print("\nNext, pair the app:  ~/.local/bin/homespun-server pair")
                #endif
            case "devices":
                for device in try await server.catalog.devices() {
                    print("\(device.id)  \(device.name)  paired \(device.createdAt)  last seen \(device.lastSeenAt ?? "never")"
                          + (device.revokedAt.map { "  REVOKED \($0)" } ?? ""))
                }
            case "import":
                var rest = Array(arguments.dropFirst()), jobs = 4
                let dryRun = rest.contains("--dry-run"), copy = rest.contains("--copy")
                rest.removeAll { $0 == "--dry-run" || $0 == "--copy" }
                var folder = "Camera Roll"
                if let index = rest.firstIndex(of: "--folder") {
                    guard index + 1 < rest.count, !rest[index + 1].isEmpty else {
                        print(usage)
                        return 2
                    }
                    folder = rest[index + 1]
                    rest.removeSubrange(index...(index + 1))
                }
                if let index = rest.firstIndex(of: "--jobs") {
                    guard index + 1 < rest.count, let count = Int(rest[index + 1]), (1...16).contains(count) else {
                        print(usage)
                        return 2
                    }
                    jobs = count
                    rest.removeSubrange(index...(index + 1))
                }
                guard rest.count == 1 else {
                    print(usage)
                    return 2
                }
                let manifest = URL(fileURLWithPath: (rest[0] as NSString).expandingTildeInPath)
                if copy, !dryRun, try await server.catalog.setting(OriginalsMover.setting) != nil {
                    print("The originals folder is being moved; run the import again when that's done.")
                    return 1
                }
                let into = await server.originals.root.appendingPathComponent(Storage.sanitized(folder)).path
                print(dryRun ? "Checking \(manifest.path) (nothing is recorded)…"
                      : copy ? "Importing \(manifest.path), copying the originals into \(into)…"
                      : "Importing \(manifest.path), leaving the originals where they are…")
                let summary = try await LibraryImport(catalog: server.catalog, dryRun: dryRun, jobs: jobs,
                                                      copyInto: copy ? server.originals : nil, folder: folder)
                    .run(manifest: manifest) { line in
                        // Unbuffered, so progress shows up as it happens even in a log file.
                        FileHandle.standardOutput.write(Data((line + "\n").utf8))
                    }
                print(LibraryImport.progress(summary, of: summary.items, dryRun: dryRun))
                if summary.problems > 0 {
                    print("Fix the problems above and run the same command again; finished items are skipped.")
                } else if !dryRun {
                    print("Done. On your iPhone, open Homespun and find compact copies made elsewhere (Server tab).")
                }
                return summary.problems > 0 ? 1 : 0
            case "revoke" where arguments.count == 2:
                print(try await server.catalog.revoke(deviceID: arguments[1]) ? "Revoked." : "No such active device.")
            default:
                print(usage)
                return 2
            }
        } catch {
            let help = error is ServerConfiguration.Failure ? "\n\(usage)\n" : ""
            FileHandle.standardError.write(Data("homespun-server: \(error)\n\(help)".utf8))
            return 1
        }
        return 0
    }

    /// The installed server's saved settings fill in what this run didn't say, but only when this run
    /// is about that server: no data folder given, or the same one. A run with its own data folder
    /// (a second server, a test) must never inherit the installed server's originals folder or port.
    static func applying(saved: String, to environment: [String: String]) -> [String: String] {
        var settings: [String: String] = [:]
        for line in saved.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2, parts[0].hasPrefix("HOMESPUN_") { settings[parts[0]] = parts[1] }
        }
        if let wanted = environment["HOMESPUN_DATA"], let installed = settings["HOMESPUN_DATA"],
           URL(fileURLWithPath: wanted).standardizedFileURL.path != URL(fileURLWithPath: installed).standardizedFileURL.path {
            return environment
        }
        return environment.merging(settings) { given, _ in given }
    }
}