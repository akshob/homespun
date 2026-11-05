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
    public static let version = "0.1.0"

    /// Holds the catalog, originals (files mode), compact copies, and work files.
    public var dataDirectory: URL
    public var host: String
    public var port: Int
    public var name: String
    public var profile: CompressionProfile
    /// When set, originals are read from Immich instead of being uploaded.
    public var immich: ImmichConfiguration?
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

    var catalog: URL { root.appendingPathComponent("homespun.db") }
    var originals: URL { root.appendingPathComponent("originals", isDirectory: true) }
    var staging: URL { root.appendingPathComponent("staging", isDirectory: true) }
    var compactRoot: URL { root.appendingPathComponent("compact", isDirectory: true) }
    var cacheRoot: URL { root.appendingPathComponent("cache", isDirectory: true) }

    func prepare() throws {
        for directory in [root, originals, staging, compactRoot, cacheRoot] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    func partial(_ assetID: String, _ role: Role) -> URL {
        staging.appendingPathComponent("\(assetID)-\(role.rawValue).partial")
    }

    func compact(_ assetID: String) -> URL { compactRoot.appendingPathComponent(assetID, isDirectory: true) }
    func cache(_ assetID: String) -> URL { cacheRoot.appendingPathComponent(assetID, isDirectory: true) }

    /// `originals/YYYY/MM/<name>`, adding part of the SHA-256 if another file already has the name.
    func originalDestination(filename: String, sha256: String, captureDate: Date?) -> URL {
        let parts = captureDate.map { Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: $0) }
        let folder = parts.map { String(format: "%04d/%02d", $0.year ?? 0, $0.month ?? 0) } ?? "undated"
        let directory = originals.appendingPathComponent(folder, isDirectory: true)
        let name = Self.sanitized(filename)
        var candidate = directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: candidate.path) {
            let stem = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
            candidate = directory.appendingPathComponent("\(stem)_\(sha256.prefix(12))" + (ext.isEmpty ? "" : ".\(ext)"))
        }
        return candidate
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
