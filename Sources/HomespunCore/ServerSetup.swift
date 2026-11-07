// SPDX-License-Identifier: Apache-2.0
import Foundation

/// What the app needs to know to guide server setup: the operating system and how to install
/// packages on it, install steps per platform, and the server's self-check.
public enum ServerSetup {
    public enum OperatingSystem: String, Codable, Sendable, CaseIterable {
        case macOS = "macos", linux
    }

    public enum PackageManager: String, Codable, Sendable, CaseIterable {
        case homebrew, apt, dnf, pacman, zypper

        /// Packages the server needs, in this package manager's names.
        public var packages: [String] {
            switch self {
            case .homebrew: ["ffmpeg"]
            case .apt: ["git", vipsDevelopment, "libsqlite3-dev", "ffmpeg", "avahi-utils"]
            case .dnf: ["git", vipsDevelopment, "sqlite-devel", "ffmpeg", "avahi-tools"]
            case .pacman: ["git", vipsDevelopment, "sqlite", "ffmpeg", "avahi"]
            case .zypper: ["git", vipsDevelopment, "sqlite3-devel", "ffmpeg", "avahi-utils"]
            }
        }

        /// libvips with its headers; the server finds it when it is built (Linux photos).
        public var vipsDevelopment: String {
            switch self {
            case .homebrew, .pacman: "libvips"
            case .apt: "libvips-dev"
            case .dnf: "vips-devel"
            case .zypper: "libvips-devel"
            }
        }

        public func install(_ packages: [String]) -> String {
            let list = packages.joined(separator: " ")
            return switch self {
            case .homebrew: "brew install \(list)"
            case .apt: "sudo apt install -y \(list)"
            case .dnf: "sudo dnf install -y \(list)"
            case .pacman: "sudo pacman -S --needed \(list)"
            case .zypper: "sudo zypper install -y \(list)"
            }
        }
    }

    public struct Platform: Codable, Equatable, Sendable {
        public var os: OperatingSystem
        /// For example "Ubuntu 24.04" or "macOS 27.2".
        public var name: String
        public var packageManager: PackageManager?

        public init(os: OperatingSystem, name: String, packageManager: PackageManager?) {
            self.os = os
            self.name = name
            self.packageManager = packageManager
        }

        /// Reads `/etc/os-release`-style text (ID and ID_LIKE) to pick the package manager.
        public static func linux(osRelease: String) -> Platform {
            var fields: [String: String] = [:]
            for line in osRelease.split(separator: "\n") {
                let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                fields[parts[0]] = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
            let ids = ([fields["ID"]] + (fields["ID_LIKE"]?.split(separator: " ").map(String.init) ?? [])).compactMap { $0 }
            let manager: PackageManager? = ids.lazy.compactMap { id -> PackageManager? in
                switch id {
                case "debian", "ubuntu", "raspbian", "linuxmint", "pop": .apt
                case "fedora", "rhel", "centos", "rocky", "almalinux": .dnf
                case "arch", "manjaro", "endeavouros": .pacman
                case "opensuse", "opensuse-leap", "opensuse-tumbleweed", "suse", "sles": .zypper
                default: nil
                }
            }.first
            return Platform(os: .linux, name: fields["PRETTY_NAME"] ?? fields["NAME"] ?? "Linux", packageManager: manager)
        }
    }

    // MARK: Self-check

    public enum CheckStatus: String, Codable, Sendable {
        case ok, warning, problem, info
    }

    public struct Check: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var status: CheckStatus
        public var detail: String
        /// Commands to run on the server to fix this, if any.
        public var fix: [String]

        public init(id: String, title: String, status: CheckStatus, detail: String, fix: [String] = []) {
            self.id = id
            self.title = title
            self.status = status
            self.detail = detail
            self.fix = fix
        }
    }

    /// `GET /api/v1/setup`.
    public struct Report: Codable, Equatable, Sendable {
        public var platform: Platform
        public var checks: [Check]
        public init(platform: Platform, checks: [Check]) {
            self.platform = platform
            self.checks = checks
        }
        public var ready: Bool { !checks.contains { $0.status == .problem } }
    }

    // MARK: Install guide

    public struct Step: Equatable, Sendable, Identifiable {
        public var id: String { title }
        public var title: String
        public var detail: String
        public var commands: [String]

        public init(title: String, detail: String, commands: [String] = []) {
            self.title = title
            self.detail = detail
            self.commands = commands
        }
    }

    public static let repository = "https://github.com/akshob/homespun.git"
    /// Where the install steps put the server.
    public static let serverCommand = "~/homespun/.build/release/homespun-server"

    /// Steps to build and start the server from source. (Packages come later, once the
    /// repository is public.)
    public static func installSteps(for os: OperatingSystem, packageManager: PackageManager? = nil) -> [Step] {
        let build = Step(
            title: "Download and build Homespun Server",
            detail: "This takes a few minutes. The repository is private for now, so sign in to GitHub first if asked.",
            commands: ["git clone \(repository) ~/homespun",
                       "cd ~/homespun && swift build -c release --product homespun-server"])
        let service = Step(
            title: "Choose where originals are kept, and start the server",
            detail: "Pick a folder on a disk with room for your originals. The server starts now and again whenever "
                + "the computer starts.",
            commands: ["\(serverCommand) install-service --data ~/Homespun"])
        let pair = Step(
            title: "Show the pairing code",
            detail: "Scan the QR code with this iPhone's camera, or come back here and choose \"Find my server\".",
            commands: ["\(serverCommand) pair"])
        switch os {
        case .macOS:
            return [
                Step(title: "Install Apple's developer tools",
                     detail: "They include Swift and git. Skip this if Xcode is installed.",
                     commands: ["xcode-select --install"]),
                Step(title: "Install Homebrew and ffmpeg",
                     detail: "ffmpeg makes the smallest videos. Skip the first command if you already have Homebrew.",
                     commands: [#"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#,
                                PackageManager.homebrew.install(PackageManager.homebrew.packages)]),
                build, service, pair,
            ]
        case .linux:
            let manager = packageManager ?? .apt
            return [
                Step(title: "Install the packages Homespun needs",
                     detail: "Photo and video tools, SQLite, and Bonjour so the app can find the server."
                        + (manager == .dnf ? " On Fedora, enable RPM Fusion first for an ffmpeg with x265." : ""),
                     commands: [manager.install(manager.packages)]),
                Step(title: "Install Swift",
                     detail: "Swift's installer, swiftly, sets up the compiler in your home folder.",
                     commands: ["curl -fsSLO https://download.swift.org/swiftly/linux/swiftly-$(uname -m).tar.gz",
                                "tar zxf swiftly-$(uname -m).tar.gz && ./swiftly init --quiet-shell-followup",
                                ". ~/.local/share/swiftly/env.sh"]),
                build, service, pair,
            ]
        }
    }
}
