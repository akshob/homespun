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
    let catalog: Catalog
    /// Where originals go (it may be on another disk than the data folder).
    var originalsFolder: URL? = nil
    var identity: TLSIdentityBox? = nil
    var environment = ProcessInfo.processInfo.environment
    var platform = HostPlatform.current()
    /// Linux control group of this process; a systemd service runs in `.../homespun.service`.
    var controlGroup = (try? String(contentsOfFile: "/proc/self/cgroup", encoding: .utf8)) ?? ""
    var hardware = HostPlatform.hardware
    /// In a container, Bonjour goes through the host's D-Bus, mounted at this path.
    var systemBus = "/var/run/dbus/system_bus_socket"
    static var executable: String { HostPlatform.serverCommand }

    func report() async -> ServerSetup.Report {
        var checks = [encryption(), photos(), videos(), livePhotos(), discovery(), storageSpace(), service()]
        let (immich, connected) = await self.immich()
        checks.append(immich)
        if connected, let copies = await immichCopies() { checks.append(copies) }
        return ServerSetup.Report(platform: platform, checks: checks)
    }

    func encryption() -> Check {
        guard let current = identity?.current ?? (try? TLSStore.load(data: configuration.dataDirectory)) else {
            return Check(id: "encryption", title: "Encryption", status: .problem, detail: "Can't read the server's encryption key.")
        }
        if current.notAfter.timeIntervalSinceNow < 30 * 86400, let error = identity?.renewalError {
            return Check(id: "encryption", title: "Encryption", status: .problem,
                         detail: "The certificate couldn't be renewed: \(error)")
        }
        return Check(id: "encryption", title: "Encryption", status: .ok,
                     detail: "Connections are encrypted. Server key \(current.fingerprint.display); certificate renews itself "
                        + "(valid until \(current.notAfter.formatted(date: .abbreviated, time: .omitted))).")
    }

    private func install(_ packages: [String]) -> [String] {
        guard let manager = platform.packageManager else { return [] }
        return [manager.install(packages)]
    }

    func photos() -> Check {
        if let backend = PlatformMedia.photoBackend {
            return Check(id: "photos", title: "Photos", status: .ok, detail: "Compressed with \(backend).")
        }
        // libvips is found at build time, so installing it needs a rebuild, installed again.
        let executable = Self.executable
        let checkout = executable.hasSuffix("/.build/release/homespun-server")
            ? String(executable.dropLast("/.build/release/homespun-server".count)) : "~/homespun"
        return Check(id: "photos", title: "Photos", status: .problem,
                     detail: "This server was built without libvips, so photos can't be compressed.",
                     fix: install([platform.packageManager?.vipsDevelopment ?? "libvips"])
                        + ["cd \(checkout) && swift build -c release --product homespun-server",
                           "\(checkout)/.build/release/homespun-server install-service --data \(configuration.dataDirectory.path)"])
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
        if hardware.kind == .container, !FileManager.default.fileExists(atPath: systemBus) {
            return Check(id: "discovery", title: "Home network", status: .warning,
                         detail: "The app can't find this server by itself. Give the container the volume "
                            + "/var/run/dbus:/var/run/dbus:ro and host networking, as in compose.yaml.")
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
        let path = (originalsFolder ?? configuration.dataDirectory).path
        guard FileManager.default.fileExists(atPath: path) else {
            return Check(id: "storage", title: "Storage", status: .problem,
                         detail: "The originals folder \(path) isn't there. Is its disk connected?")
        }
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
        if hardware.kind == .container {
            return Check(id: "service", title: "Starts automatically", status: .ok,
                         detail: "Runs in a container, which Docker starts with the NAS (restart: unless-stopped).")
        }
        return runsAsService
            ? Check(id: "service", title: "Starts automatically", status: .ok,
                    detail: platform.os == .macOS ? "Runs as a LaunchAgent." : "Runs as a systemd service.")
            : Check(id: "service", title: "Starts automatically", status: .warning,
                    detail: "The server is running in a terminal and stops when it closes.",
                    fix: ["\(Self.executable) install-service --data \(configuration.dataDirectory.path)"])
    }

    func immich() async -> (Check, connected: Bool) {
        guard await immichState.current != nil else {
            return (Check(id: "immich", title: "Immich", status: .info,
                          detail: "Not connected. Originals are kept on this server."), false)
        }
        let settings = await immichState.settings()
        return settings.connected
            ? (Check(id: "immich", title: "Immich", status: settings.message == nil ? .ok : .warning,
                     detail: settings.message ?? "Originals are read from Immich at \(settings.url ?? "")."), true)
            : (Check(id: "immich", title: "Immich", status: .problem, detail: settings.message ?? "Immich is not reachable."),
               false)
    }

    static let copiesToCheck = 40

    /// Whether the Immich app uploaded Homespun's compact copies (the Homespun album isn't
    /// excluded from its backup), looking up the newest copies by SHA-1. Nil if there are no
    /// copies yet or Immich can't be asked.
    func immichCopies() async -> Check? {
        guard let client = await immichState.client,
              let copies = try? await catalog.recentMadeCopies(limit: Self.copiesToCheck), !copies.isEmpty else { return nil }
        var hashes: [String] = []
        for copy in copies {
            if let sha1 = copy.sha1 {
                hashes.append(sha1)
            } else if let path = copy.path, let url = storage.resolve(path),
                      let sha1 = try? await detached({ try Fingerprint.digests(of: url).sha1 }) {
                try? await catalog.setMadeCopySHA1(copy.sha256, sha1)
                hashes.append(sha1)
            }
        }
        guard !hashes.isEmpty else { return nil }
        let found: Int
        do {
            found = try await withThrowingTaskGroup(of: Bool.self) { group in
                var found = 0, next = 0
                func add() {
                    let sha1 = hashes[next]
                    next += 1
                    group.addTask { !(try await client.assets(sha1Hex: sha1)).isEmpty }
                }
                while next < min(8, hashes.count) { add() }
                while let inImmich = try await group.next() {
                    if inImmich { found += 1 }
                    if next < hashes.count { add() }
                }
                return found
            }
        } catch {
            return nil
        }
        let title = "Compact copies in Immich"
        guard found > 0 else {
            return Check(id: "immich_copies", title: title, status: .ok,
                         detail: "None of the latest \(hashes.count) compact copies were uploaded to Immich.")
        }
        return Check(id: "immich_copies", title: title, status: .warning,
                     detail: "\(found) of the latest \(hashes.count) compact copies were uploaded to Immich, so it shows them "
                        + "next to their originals. In the Immich app's backup settings, exclude the Homespun album. Then "
                        + "delete those copies in Immich (Homespun can't: its key only reads).")
    }
}
