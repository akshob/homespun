// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import HomespunCore
import HomespunMedia

/// The server's self-check for the app: what works, what is missing, and the command that
/// fixes it on this server's operating system.
struct SetupChecks {
    typealias Check = ServerSetup.Check

    let configuration: ServerConfiguration
    let storage: Storage
    let immichState: ImmichState
    var environment = ProcessInfo.processInfo.environment
    var platform = HostPlatform.current()
    /// Linux control group of this process; a systemd service runs in `.../homespun.service`.
    var controlGroup = (try? String(contentsOfFile: "/proc/self/cgroup", encoding: .utf8)) ?? ""
    static var executable: String { Bundle.main.executablePath ?? "homespun-server" }

    func report() async -> ServerSetup.Report {
        var checks = [photos(), videos(), livePhotos(), discovery(), storageSpace(), service()]
        checks.append(await immich())
        return ServerSetup.Report(platform: platform, checks: checks)
    }

    private func install(_ packages: [String]) -> [String] {
        guard let manager = platform.packageManager else { return [] }
        return [manager.install(packages)]
    }

    func photos() -> Check {
        if let backend = PlatformMedia.photoBackend {
            return Check(id: "photos", title: "Photos", status: .ok, detail: "Compressed with \(backend).")
        }
        // libvips is found at build time, so installing it needs a rebuild and a restart.
        let executable = Self.executable
        let checkout = executable.hasSuffix("/.build/release/homespun-server")
            ? String(executable.dropLast("/.build/release/homespun-server".count)) : "~/homespun"
        return Check(id: "photos", title: "Photos", status: .problem,
                     detail: "This server was built without libvips, so photos can't be compressed.",
                     fix: install([platform.packageManager?.vipsDevelopment ?? "libvips"])
                        + ["cd \(checkout) && swift build -c release --product homespun-server",
                           runsAsService ? "systemctl --user restart homespun" : "# Then start homespun-server again."])
    }

    func videos() -> Check {
        let encoders = Tools.output("ffmpeg", ["-hide_banner", "-encoders"])
        if encoders?.contains("libx265") == true {
            return Check(id: "videos", title: "Videos", status: .ok, detail: "Compressed with x265 (ffmpeg).")
        }
        let fix = install(["ffmpeg"]) + (platform.packageManager == .dnf ? ["# Use RPM Fusion's ffmpeg; Fedora's own lacks x265."] : [])
        if platform.os == .macOS {
            return Check(id: "videos", title: "Videos", status: .warning,
                         detail: "Using Apple's encoder; videos come out 2-3 times larger than with ffmpeg's x265.", fix: fix)
        }
        return Check(id: "videos", title: "Videos", status: .problem,
                     detail: encoders == nil ? "ffmpeg is not installed, so videos can't be compressed."
                                             : "This ffmpeg has no x265 encoder.", fix: fix)
    }

    func livePhotos() -> Check {
        platform.os == .macOS
            ? Check(id: "live_photos", title: "Live Photos", status: .ok, detail: "Motion is compressed on this Mac.")
            : Check(id: "live_photos", title: "Live Photos", status: .info,
                    detail: "Motion is compressed on the iPhone; only Apple's AVFoundation keeps it paired with the photo.")
    }

    func discovery() -> Check {
        if ["127.0.0.1", "::1", "localhost"].contains(configuration.host) {
            return Check(id: "discovery", title: "Home network", status: .warning,
                         detail: "The server listens only on this computer.",
                         fix: ["\(Self.executable) install-service --data \(configuration.dataDirectory.path)"])
        }
        if ServiceAdvertiser.tool != nil {
            return Check(id: "discovery", title: "Home network", status: .ok,
                         detail: "The app can find \"\(configuration.name)\" on your network.")
        }
        let package = switch platform.packageManager {
        case .dnf: "avahi-tools"
        case .pacman: "avahi"
        default: "avahi-utils"
        }
        return Check(id: "discovery", title: "Home network", status: .warning,
                     detail: "Install Bonjour tools so the app can find this server by itself.", fix: install([package]))
    }

    func storageSpace() -> Check {
        let path = configuration.dataDirectory.path
        guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: path),
              let free = (attributes[.systemFreeSize] as? NSNumber)?.int64Value else {
            return Check(id: "storage", title: "Storage", status: .problem, detail: "Can't read \(path).")
        }
        let text = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
        let writable = FileManager.default.isWritableFile(atPath: path)
        if !writable { return Check(id: "storage", title: "Storage", status: .problem, detail: "Can't write to \(path).") }
        return Check(id: "storage", title: "Storage", status: free < 5_000_000_000 ? .warning : .ok,
                     detail: "\(text) free in \(path).")
    }

    var runsAsService: Bool {
        controlGroup.contains("/homespun.service") || environment["XPC_SERVICE_NAME"] == ServiceInstaller.label
    }

    func service() -> Check {
        runsAsService
            ? Check(id: "service", title: "Starts automatically", status: .ok,
                    detail: platform.os == .macOS ? "Runs as a LaunchAgent." : "Runs as a systemd service.")
            : Check(id: "service", title: "Starts automatically", status: .warning,
                    detail: "The server is running in a terminal and stops when it closes.",
                    fix: ["\(Self.executable) install-service --data \(configuration.dataDirectory.path)"])
    }

    func immich() async -> Check {
        guard await immichState.current != nil else {
            return Check(id: "immich", title: "Immich", status: .info,
                         detail: "Not connected. Originals are kept on this server.")
        }
        let settings = await immichState.settings()
        return settings.connected
            ? Check(id: "immich", title: "Immich", status: settings.message == nil ? .ok : .warning,
                    detail: settings.message ?? "Originals are read from Immich at \(settings.url ?? "").")
            : Check(id: "immich", title: "Immich", status: .problem, detail: settings.message ?? "Immich is not reachable.")
    }
}
