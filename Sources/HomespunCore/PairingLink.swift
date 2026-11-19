// SPDX-License-Identifier: Apache-2.0
import Foundation

/// The link `homespun-server pair` prints (and shows as a QR code):
/// `homespun://pair?server=192.168.1.20:8787&code=K7Q4-M9XT&name=Linux%20Box`.
/// Scanning it with the Camera app, or pasting it, opens Homespun and pairs.
/// An optional `fp` authenticates the server's key and requires HTTPS.
public struct PairingLink: Equatable, Sendable {
    public static let scheme = "homespun"

    public var serverURL: URL
    public var code: String
    public var name: String?
    public var fingerprint: ServerKeyFingerprint?

    public init(serverURL: URL, code: String, name: String? = nil, fingerprint: ServerKeyFingerprint? = nil) {
        self.serverURL = serverURL
        self.code = code
        self.name = name
        self.fingerprint = fingerprint
    }

    /// Accepts "host", "host:port", or a full URL; Homespun always uses HTTPS.
    public static func serverURL(from text: String) -> URL? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let bare = !value.contains("://")
        if bare { value = "https://" + value }
        guard var components = URLComponents(string: value), let host = components.host, !host.isEmpty,
              ["http", "https"].contains(components.scheme ?? "") else { return nil }
        if components.port == nil, bare || components.scheme == "http" { components.port = 8787 }
        components.scheme = "https"
        components.path = ""
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        return components.url
    }

    public init?(_ url: URL) {
        guard url.scheme?.lowercased() == Self.scheme, url.host?.lowercased() == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let server = items.first(where: { $0.name == "server" })?.value.flatMap(Self.serverURL(from:)),
              let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else { return nil }
        let fingerprints = items.filter { $0.name == "fp" }
        guard fingerprints.count <= 1 else { return nil }
        let fingerprint = fingerprints.first?.value.flatMap(ServerKeyFingerprint.init(base64url:))
        guard fingerprints.isEmpty || fingerprint != nil else { return nil }
        var secureServer = server
        if fingerprint != nil {
            guard var components = URLComponents(url: server, resolvingAgainstBaseURL: false) else { return nil }
            components.scheme = "https"
            guard let url = components.url else { return nil }
            secureServer = url
        }
        self.init(serverURL: secureServer, code: code, name: items.first(where: { $0.name == "name" })?.value,
                  fingerprint: fingerprint)
    }

    /// Finds a pairing link in pasted text.
    public init?(text: String) {
        guard let range = text.range(of: #"homespun://pair\?\S+"#, options: .regularExpression),
              let url = URL(string: String(text[range])) else { return nil }
        self.init(url)
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "pair"
        // Plain http with a port is written as host:port, which keeps the QR code small.
        let host = serverURL.host ?? ""
        let address = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        let server = (serverURL.scheme == "http" || fingerprint != nil) && serverURL.port != nil
            ? "\(address):\(serverURL.port!)" : serverURL.absoluteString
        components.queryItems = [URLQueryItem(name: "server", value: server), URLQueryItem(name: "code", value: code)]
            + (fingerprint.map { [URLQueryItem(name: "fp", value: $0.base64url)] } ?? [])
            + (name.map { [URLQueryItem(name: "name", value: $0)] } ?? [])
        return components.url!
    }
}
