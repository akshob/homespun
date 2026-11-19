// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import HomespunCore

public struct ImmichConfiguration: Sendable {
    public var url: URL
    public var apiKey: String

    public init(url: URL, apiKey: String) {
        self.url = url
        self.apiKey = apiKey
    }
}

public struct ServerConfiguration: Sendable {
    public static let version = "0.2.0"

    /// Holds the catalog, compact copies, and work files (and originals, unless `originalsDirectory` is set).
    public var dataDirectory: URL
    /// Where originals go (`HOMESPUN_ORIGINALS`), each phone in its own folder; default `<data>/originals`.
    /// A folder chosen later from the app wins over this.
    public var originalsDirectory: URL?
    public var host: String
    public var port: Int
    public var name: String
    public var profile: CompressionProfile
    /// When set, originals are read from Immich instead of being uploaded.
    public var immich: ImmichConfiguration?
    /// The address the app should use (`HOMESPUN_PUBLIC_URL`), when the detected one is wrong.
    public var publicURL: String?
    /// A Microsoft app registration for the OneDrive connector (`HOMESPUN_ONEDRIVE_CLIENT_ID`).
    public var onedriveClientID: String?
    /// Largest body accepted by one upload request.
    public var maximumChunkBytes = 64 << 20

    public init(dataDirectory: URL, host: String = "127.0.0.1", port: Int = 8787, name: String = "Homespun",
                profile: CompressionProfile = .standard, immich: ImmichConfiguration? = nil) {
        self.dataDirectory = dataDirectory
        self.host = host
        self.port = port
        self.name = name
        self.profile = profile
        self.immich = immich
    }

    public var mode: ServerAPI.StorageMode { immich == nil ? .files : .immich }

    public enum Failure: Error, CustomStringConvertible {
        case missing(String), invalid(String)
        public var description: String {
            switch self {
            case .missing(let name): "\(name) is not set"
            case .invalid(let message): message
            }
        }
    }

    /// `HOMESPUN_DATA` (required), `HOMESPUN_HOST`, `HOMESPUN_PORT`, `HOMESPUN_NAME`, and for Immich
    /// mode `HOMESPUN_IMMICH_URL` with `HOMESPUN_IMMICH_API_KEY_FILE` (a file holding only the key).
    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) throws
        -> ServerConfiguration {
        guard let data = environment["HOMESPUN_DATA"], !data.isEmpty else { throw Failure.missing("HOMESPUN_DATA") }
        guard data.hasPrefix("/") else { throw Failure.invalid("HOMESPUN_DATA must be an absolute path") }
        var configuration = ServerConfiguration(dataDirectory: URL(fileURLWithPath: data, isDirectory: true))
        if let host = environment["HOMESPUN_HOST"] { configuration.host = host }
        if let port = environment["HOMESPUN_PORT"] {
            guard let number = Int(port), (1...65535).contains(number) else { throw Failure.invalid("bad HOMESPUN_PORT") }
            configuration.port = number
        }
        configuration.name = environment["HOMESPUN_NAME"] ?? ProcessInfo.processInfo.hostName
        if let originals = environment["HOMESPUN_ORIGINALS"], !originals.isEmpty {
            guard originals.hasPrefix("/") else { throw Failure.invalid("HOMESPUN_ORIGINALS must be an absolute path") }
            configuration.originalsDirectory = URL(fileURLWithPath: originals, isDirectory: true)
        }
        configuration.onedriveClientID = environment["HOMESPUN_ONEDRIVE_CLIENT_ID"].flatMap { $0.isEmpty ? nil : $0 }
        if let publicURL = environment["HOMESPUN_PUBLIC_URL"], !publicURL.isEmpty {
            guard PairingLink.serverURL(from: publicURL) != nil else { throw Failure.invalid("bad HOMESPUN_PUBLIC_URL") }
            configuration.publicURL = publicURL
        }
        if let url = environment["HOMESPUN_IMMICH_URL"] {
            guard let parsed = URL(string: url), ["http", "https"].contains(parsed.scheme ?? "") else {
                throw Failure.invalid("HOMESPUN_IMMICH_URL must be an http(s) URL")
            }
            guard let keyFile = environment["HOMESPUN_IMMICH_API_KEY_FILE"] else {
                throw Failure.missing("HOMESPUN_IMMICH_API_KEY_FILE")
            }
            let key = try String(contentsOfFile: keyFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !key.contains(where: \.isWhitespace) else {
                throw Failure.invalid("HOMESPUN_IMMICH_API_KEY_FILE must contain only the API key")
            }
            configuration.immich = ImmichConfiguration(url: parsed, apiKey: key)
        }
        return configuration
    }
}

/// Server-controlled paths under the data directory. Client input never becomes a path
/// except through `sanitized(_:)`.
struct Storage: Sendable {
    let root: URL

    public struct UnsafeLocation: Error, CustomStringConvertible { public var description: String }

    var catalog: URL { root.appendingPathComponent("homespun.db") }
    /// The default originals folder.
    var originals: URL { root.appendingPathComponent("originals", isDirectory: true) }
    var staging: URL { root.appendingPathComponent("staging", isDirectory: true) }
    var compactRoot: URL { root.appendingPathComponent("compact", isDirectory: true) }
    var cacheRoot: URL { root.appendingPathComponent("cache", isDirectory: true) }

    func prepare() throws {
        // Updating or re-cloning source code deletes what isn't part of it, originals included.
        // On macOS, folder names usually ignore case: ~/homespun and ~/Homespun are one folder.
        try Self.checkNotSourceCode(root)
        // Never make the folder a missing disk would have had: on a Mac, /Volumes/Homespun made
        // while the Homespun volume isn't mounted lands on the startup disk instead.
        if !FileManager.default.fileExists(atPath: root.path) {
            guard FileManager.default.fileExists(atPath: root.deletingLastPathComponent().path) else {
                throw UnsafeLocation(description: "\(root.deletingLastPathComponent().path) doesn't exist (is the disk connected?).")
            }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        }
        for directory in [staging, compactRoot, cacheRoot] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    /// Updating or re-cloning source code deletes what isn't part of it, originals included.
    static func checkNotSourceCode(_ folder: URL) throws {
        for marker in [".git", "Package.swift"]
        where FileManager.default.fileExists(atPath: folder.appendingPathComponent(marker).path) {
            throw UnsafeLocation(description:
                "\(folder.path) holds source code (it has \(marker)), so originals there could be deleted. "
                + "Keep them in another folder, for example ~/Pictures/Homespun. (On a Mac, ~/homespun and "
                + "~/Homespun are the same folder.)")
        }
    }

    /// Makes the originals folder if it can be made safely (its parent exists); returns whether it's there.
    static func prepareOriginals(_ folder: URL) throws -> Bool {
        try checkNotSourceCode(folder)
        if FileManager.default.fileExists(atPath: folder.path) { return true }
        guard FileManager.default.fileExists(atPath: folder.deletingLastPathComponent().path) else { return false }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        return true
    }

    func partial(_ assetID: String, _ role: Role) -> URL {
        staging.appendingPathComponent("\(assetID)-\(role.rawValue).partial")
    }

    func compact(_ assetID: String) -> URL { compactRoot.appendingPathComponent(assetID, isDirectory: true) }
    func cache(_ assetID: String) -> URL { cacheRoot.appendingPathComponent(assetID, isDirectory: true) }

    /// A phone's folder in the originals folder: its name as typed (letters in any language, spaces,
    /// apostrophes), without what would make it a path or trouble a NAS share (separators, `:*?"<>|`,
    /// control characters, a leading dot, trailing dots or spaces), at most 64 characters. Empty if
    /// nothing is left. Names that were already safe stay the same.
    static func folderName(_ name: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters).union(.illegalCharacters)
        var cleaned = String(String.UnicodeScalarView(
            name.precomposedStringWithCanonicalMapping.unicodeScalars.filter { !forbidden.contains($0) }))
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        if cleaned.count > ServerAPI.RenameDeviceRequest.maximumLength {
            cleaned = String(cleaned.prefix(ServerAPI.RenameDeviceRequest.maximumLength))
        }
        while let last = cleaned.last, last == "." || last.isWhitespace { cleaned.removeLast() }
        return cleaned
    }

    /// A safe single path component: no separators, no leading dot, limited characters and length.
    static func sanitized(_ filename: String) -> String {
        let base = filename.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        var cleaned = String(base.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII || "._- ".unicodeScalars.contains(scalar)
                ? Character(scalar) : "_"
        })
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        if cleaned.count > 120 {
            let ext = (cleaned as NSString).pathExtension
            cleaned = String(cleaned.prefix(110)) + (ext.isEmpty || ext.count > 8 ? "" : ".\(ext)")
        }
        return cleaned.isEmpty ? "file" : cleaned
    }
}

enum Pairing {
    /// Unambiguous characters (no 0/O, 1/I/L, U).
    static let alphabet = Array("23456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// An 8-character code shown as `XXXX-XXXX`.
    static func newCode() -> String {
        var generator = SystemRandomNumberGenerator()
        let characters = (0..<8).map { _ in alphabet.randomElement(using: &generator)! }
        return String(characters[0..<4]) + "-" + String(characters[4..<8])
    }

    static func normalized(_ code: String) -> String {
        String(code.uppercased().filter { alphabet.contains($0) })
    }

    static func hash(_ secret: String) -> String { Fingerprint.sha256(of: Data(secret.utf8)) }

    /// A bearer token with 256 random bits.
    static func newToken() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: 0...255, using: &generator) }
        return "hs1_" + Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum Validation {
    static func isSHA256(_ value: String) -> Bool { value.count == 64 && value.allSatisfy(\.isHexDigit) }
    static func isSHA1(_ value: String) -> Bool { value.count == 40 && value.allSatisfy(\.isHexDigit) }
}
