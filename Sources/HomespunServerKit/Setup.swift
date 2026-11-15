// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import HomespunCore
import Logging
import QRCodeGenerator
import ServiceLifecycle
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

enum HostPlatform {
    static func current() -> ServerSetup.Platform {
        #if os(macOS)
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return .init(os: .macOS, name: "macOS \(version.majorVersion).\(version.minorVersion)", packageManager: .homebrew)
        #else
        return .linux(osRelease: (try? String(contentsOfFile: "/etc/os-release", encoding: .utf8)) ?? "")
        #endif
    }
}

extension HostPlatform {
    /// The kind of computer this is, read once. `HOMESPUN_HARDWARE_KIND` (desktop, laptop, server,
    /// container) and `HOMESPUN_HARDWARE` (a model name, e.g. "Synology DS923+") override it, for a
    /// Docker image to say which NAS it runs on.
    static let hardware: ServerAPI.Hardware = detectHardware(environment: ProcessInfo.processInfo.environment)

    static func detectHardware(environment: [String: String]) -> ServerAPI.Hardware {
        let override = environment["HOMESPUN_HARDWARE"].flatMap { $0.isEmpty ? nil : $0 }
        if let kind = environment["HOMESPUN_HARDWARE_KIND"].flatMap(ServerAPI.Hardware.Kind.init(rawValue:)) {
            return .init(kind: kind, model: override)
        }
        #if os(macOS)
        let model = macModelName()
        return .init(kind: model?.hasPrefix("MacBook") == true ? .laptop : .desktop, model: override ?? model)
        #else
        let files = FileManager.default
        let cgroup = (try? String(contentsOfFile: "/proc/1/cgroup", encoding: .utf8)) ?? ""
        if files.fileExists(atPath: "/.dockerenv") || files.fileExists(atPath: "/run/.containerenv")
            || ["docker", "containerd", "kubepods", "libpod"].contains(where: cgroup.contains) {
            return .init(kind: .container, model: override)
        }
        func dmi(_ name: String) -> String? {
            let value = (try? String(contentsOfFile: "/sys/class/dmi/id/\(name)", encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let value, !value.isEmpty, !value.lowercased().contains("to be filled"),
                  !value.lowercased().contains("default string"), value.lowercased() != "system product name" else { return nil }
            return value
        }
        // SMBIOS chassis types: 8, 9, 10, 14, 31, 32 are portable; 17, 23, 28, 29 are servers.
        let chassis = Int(dmi("chassis_type") ?? "") ?? 0
        let kind: ServerAPI.Hardware.Kind = [8, 9, 10, 14, 31, 32].contains(chassis) ? .laptop
            : [17, 23, 28, 29].contains(chassis) ? .server : .desktop
        let model = override ?? [dmi("sys_vendor"), dmi("product_name")].compactMap { $0 }.joined(separator: " ")
        return .init(kind: kind, model: model.isEmpty ? nil : model)
        #endif
    }

    #if os(macOS)
    /// "Mac mini", "MacBook Air", …, from the system profiler (model identifiers like Mac14,3 say little).
    private static func macModelName() -> String? {
        guard let text = Tools.output("system_profiler", ["SPHardwareDataType", "-json"]),
              let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let items = json["SPHardwareDataType"] as? [[String: Any]] else { return nil }
        return items.first?["machine_name"] as? String
    }
    #endif

    /// This program's path for commands shown to people, with the home folder as `~`, or
    /// `HOMESPUN_COMMAND` (the Docker image sets `docker exec homespun homespun-server`).
    static var serverCommand: String { serverCommand(environment: ProcessInfo.processInfo.environment) }

    static func serverCommand(environment: [String: String]) -> String {
        if let command = environment["HOMESPUN_COMMAND"], !command.isEmpty { return command }
        let path = Bundle.main.executablePath ?? "homespun-server"
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

/// Finds command-line tools without running a shell. Includes Homebrew's folders, which a
/// LaunchAgent's PATH may lack.
enum Tools {
    static func path(_ name: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        return directories.lazy.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Runs a tool and returns its standard output, or nil if it is missing or fails.
    static func output(_ name: String, _ arguments: [String]) -> String? {
        guard let path = path(name) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}

enum Network {
    struct Interface: Equatable { var name: String; var address: String }

    /// IPv4 addresses of this machine's network interfaces.
    static func interfaces() -> [Interface] {
        var result: [Interface] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return [] }
        defer { freeifaddrs(list) }
        var cursor = list
        while let entry = cursor?.pointee {
            defer { cursor = entry.ifa_next }
            guard let address = entry.ifa_addr, Int32(address.pointee.sa_family) == AF_INET else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            #if canImport(Darwin)
            let length = socklen_t(address.pointee.sa_len)
            #else
            let length = socklen_t(MemoryLayout<sockaddr_in>.size)
            #endif
            guard getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let numeric = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            result.append(Interface(name: String(cString: entry.ifa_name), address: numeric))
        }
        return result
    }

    /// The address a phone on the home network most likely reaches: a private IPv4 address on
    /// a wired or Wi-Fi interface, not loopback, VPN, or container bridges.
    static func preferredAddress(_ interfaces: [Interface]) -> String? {
        let virtual = ["lo", "lxdbr", "docker", "br-", "veth", "virbr", "tun", "tap", "wg", "utun", "tailscale", "zt",
                       "awdl", "llw", "bridge", "vmnet", "podman", "cni", "flannel", "cali"]
        func isPrivate(_ address: String) -> Bool {
            let parts = address.split(separator: ".").compactMap { Int($0) }
            guard parts.count == 4 else { return false }
            return parts[0] == 10 || (parts[0] == 192 && parts[1] == 168) || (parts[0] == 172 && (16...31).contains(parts[1]))
        }
        let candidates = interfaces.filter { interface in
            isPrivate(interface.address) && !virtual.contains { interface.name.hasPrefix($0) }
        }
        let physical = ["en", "eth", "wl", "eno", "enp", "wlp", "wlan"]
        return (candidates.first { interface in physical.contains { interface.name.hasPrefix($0) } } ?? candidates.first)?.address
    }

    /// The URL the app should use: `HOMESPUN_PUBLIC_URL`, the bound address, or the LAN address.
    static func publicURL(configuration: ServerConfiguration) -> URL? {
        if let explicit = configuration.publicURL, let url = PairingLink.serverURL(from: explicit) { return url }
        let host = ["0.0.0.0", "::", ""].contains(configuration.host) ? preferredAddress(interfaces()) : configuration.host
        return host.flatMap { PairingLink.serverURL(from: "\($0):\(configuration.port)") }
    }
}

enum TerminalQR {
    /// A QR code drawn with half-block characters, black on white so it scans on dark terminals.
    static func render(_ text: String) throws -> String {
        let code = try QRCode.encode(text: text, ecl: .medium)
        let quiet = 2, size = code.size + quiet * 2
        func dark(_ x: Int, _ y: Int) -> Bool {
            let (qx, qy) = (x - quiet, y - quiet)
            return qx >= 0 && qy >= 0 && qx < code.size && qy < code.size && code.getModule(x: qx, y: qy)
        }
        var lines: [String] = []
        for y in stride(from: 0, to: size, by: 2) {
            var line = "\u{1B}[30;47m"
            for x in 0..<size {
                switch (dark(x, y), dark(x, y + 1)) {
                case (true, true): line += "█"
                case (true, false): line += "▀"
                case (false, true): line += "▄"
                case (false, false): line += " "
                }
            }
            lines.append(line + "\u{1B}[0m")
        }
        return lines.joined(separator: "\n")
    }
}

/// Starts automatically with the computer: a systemd user unit on Linux, a LaunchAgent on macOS.
enum ServiceInstaller {
    static let label = "photos.homespun.server"

    /// Where `install-service` puts the server, so rebuilding the source doesn't change the
    /// running server and every instruction names the same command.
    static func installedExecutable(home: URL) -> URL {
        home.appendingPathComponent(".local/bin/homespun-server")
    }

    /// Copies the server into place (atomically, so a running copy keeps working).
    static func install(_ executable: String, home: URL) throws -> URL {
        let target = installedExecutable(home: home)
        let source = URL(fileURLWithPath: executable).resolvingSymlinksInPath()
        guard source.path != target.resolvingSymlinksInPath().path else { return target }
        let files = FileManager.default
        try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = target.appendingPathExtension("new")
        try? files.removeItem(at: temporary)
        try files.copyItem(at: source, to: temporary)
        try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporary.path)
        guard rename(temporary.path, target.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        return target
    }

    struct Plan: Equatable {
        var path: URL
        var contents: String
        /// Run first and allowed to fail (for example, stopping a service that isn't loaded).
        var prepare: [[String]] = []
        var commands: [[String]]
    }

    static func plan(executable: String, environment: [String: String], os: ServerSetup.OperatingSystem,
                     home: URL, userID: UInt32, user: String) -> Plan {
        let keys = environment.keys.sorted()
        switch os {
        case .linux:
            let lines = keys.map { "Environment=\"\($0)=\(environment[$0]!.replacingOccurrences(of: "\"", with: "\\\""))\"" }
            let unit = """
                [Unit]
                Description=Homespun Server
                After=network-online.target
                Wants=network-online.target

                [Service]
                ExecStart=\(executable) serve
                \(lines.joined(separator: "\n"))
                Restart=on-failure
                RestartSec=5

                [Install]
                WantedBy=default.target

                """
            return Plan(path: home.appendingPathComponent(".config/systemd/user/homespun.service"), contents: unit,
                        commands: [["systemctl", "--user", "daemon-reload"],
                                   ["systemctl", "--user", "enable", "--now", "homespun.service"],
                                   ["systemctl", "--user", "restart", "homespun.service"],
                                   // Keeps the server running when you are not logged in.
                                   ["loginctl", "enable-linger", user]])
        case .macOS:
            func escape(_ value: String) -> String {
                value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                    .replacingOccurrences(of: ">", with: "&gt;")
            }
            let variables = keys.map { "        <key>\(escape($0))</key><string>\(escape(environment[$0]!))</string>" }
            let log = escape((environment["HOMESPUN_DATA"] ?? home.path) + "/server.log")
            let plist = """
                <?xml version="1.0" encoding="UTF-8"?>
                <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                <plist version="1.0">
                <dict>
                    <key>Label</key><string>\(label)</string>
                    <key>ProgramArguments</key>
                    <array><string>\(escape(executable))</string><string>serve</string></array>
                    <key>EnvironmentVariables</key>
                    <dict>
                \(variables.joined(separator: "\n"))
                    </dict>
                    <key>RunAtLoad</key><true/>
                    <key>KeepAlive</key><true/>
                    <key>StandardOutPath</key><string>\(log)</string>
                    <key>StandardErrorPath</key><string>\(log)</string>
                </dict>
                </plist>

                """
            let path = home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
            return Plan(path: path, contents: plist, prepare: [["launchctl", "bootout", "gui/\(userID)/\(label)"]],
                        commands: [["launchctl", "bootstrap", "gui/\(userID)", path.path]])
        }
    }
}

/// Advertises `_homespun._tcp` on the home network so the app can find the server, using the
/// system's Bonjour tools: `dns-sd` on macOS, `avahi-publish` (avahi-utils) on Linux.
final class ServiceAdvertiser: Service, Sendable {
    static let type = "_homespun._tcp"
    let name: String
    let port: Int
    let logger: Logger

    init(name: String, port: Int, logger: Logger) {
        self.name = name
        self.port = port
        self.logger = logger
    }

    static var tool: String? {
        #if os(macOS)
        Tools.path("dns-sd")
        #else
        Tools.path("avahi-publish")
        #endif
    }

    func arguments() -> [String] {
        #if os(macOS)
        ["-R", name, Self.type, "local", String(port), "api=\(ServerAPI.version)"]
        #else
        ["-s", name, Self.type, String(port), "api=\(ServerAPI.version)"]
        #endif
    }

    func run() async throws {
        // A service that returns early stops the whole server, so this runs until shutdown. It
        // looks for the tool again now and then, in case it is installed while the server runs.
        await cancelWhenGracefulShutdown {
            var missing = false
            while !Task.isCancelled {
                guard let tool = Self.tool else {
                    if !missing {
                        self.logger.notice("Bonjour advertising is off: install avahi-utils so the app can find this server.")
                        missing = true
                    }
                    try? await Task.sleep(for: .seconds(15))
                    continue
                }
                if missing {
                    self.logger.notice("Bonjour advertising is on.")
                    missing = false
                }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: tool)
                process.arguments = self.arguments()
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                do { try process.run() } catch {
                    self.logger.warning("Bonjour advertising failed to start: \(error)")
                    try? await Task.sleep(for: .seconds(60))
                    continue
                }
                // SIGKILL, because on Linux Foundation starts the child with this process's signals
                // blocked, SIGTERM included. The Bonjour daemon withdraws the name when it goes.
                let pid = process.processIdentifier
                await withTaskCancellationHandler {
                    while process.isRunning && !Task.isCancelled { try? await Task.sleep(for: .seconds(1)) }
                } onCancel: {
                    kill(pid, SIGKILL)
                }
                if process.isRunning {
                    kill(pid, SIGKILL)
                    process.waitUntilExit()
                }
                if !Task.isCancelled {
                    self.logger.warning("Bonjour advertising stopped (\(tool) exited with \(process.terminationStatus)); retrying")
                    try? await Task.sleep(for: .seconds(30))
                }
            }
        }
    }
}
