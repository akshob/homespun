// SPDX-License-Identifier: Apache-2.0
import Foundation

/// The link `homespun-server pair` prints (and shows as a QR code):
/// `homespun://pair?server=192.168.1.20:8787&code=K7Q4-M9XT&name=Linux%20Box`.
/// Scanning it with the Camera app, or pasting it, opens Homespun and pairs.
public struct PairingLink: Equatable, Sendable {
    public static let scheme = "homespun"

    public var serverURL: URL
    public var code: String
    public var name: String?

    public init(serverURL: URL, code: String, name: String? = nil) {
        self.serverURL = serverURL
        self.code = code
        self.name = name
    }

    /// Accepts "host", "host:port", or a full http(s) URL; plain addresses use http and port 8787.
    public static func serverURL(from text: String) -> URL? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.contains("://") { value = "http://" + value }
        guard var components = URLComponents(string: value), let host = components.host, !host.isEmpty,
              ["http", "https"].contains(components.scheme ?? "") else { return nil }
        if components.port == nil, components.scheme == "http" { components.port = 8787 }
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
        self.init(serverURL: server, code: code, name: items.first(where: { $0.name == "name" })?.value)
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
        let server = serverURL.scheme == "http" && serverURL.port != nil
            ? "\(serverURL.host ?? ""):\(serverURL.port!)" : serverURL.absoluteString
        components.queryItems = [URLQueryItem(name: "server", value: server), URLQueryItem(name: "code", value: code)]
            + (name.map { [URLQueryItem(name: "name", value: $0)] } ?? [])
        return components.url!
    }
}
