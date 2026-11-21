// SPDX-License-Identifier: Apache-2.0
import Foundation
import HomespunCore
import os
import Security

struct ServerPins: Codable, Equatable, Sendable {
    var v = 1
    var pins: [ServerKeyFingerprint]
    var since = Date()
    var source: String
    var previous: ServerKeyFingerprint?
    var changedAt: Date?
    var serviceName: String?
    var trust: ServerTrust { pins.isEmpty ? .system : .pinned(Set(pins)) }
}

/// The server's device token, kept in the Keychain (this device only, after first unlock), and in
/// memory once read: screens ask whether the iPhone is paired as they draw, and a Keychain read
/// each time cost the main thread on every redraw.
enum Keychain {
    private static let service = "photos.homespun.server-token"
    private static let pinsService = "photos.homespun.server-pins"
    private static let cache = OSAllocatedUnfairLock<[String: String]>(initialState: [:])
    private static let pinsCache = OSAllocatedUnfairLock<[String: ServerPins]>(initialState: [:])
    private static let installationService = "photos.homespun.installation"
    private static let installationCache = OSAllocatedUnfairLock<DeviceInstallation?>(initialState: nil)

    static func removeLegacyReviewCode(
        defaults: UserDefaults = .standard,
        delete: ([CFString: Any]) -> OSStatus = { SecItemDelete($0 as CFDictionary) }
    ) {
        let completed = "didRemoveLegacyReviewCode"
        guard !defaults.bool(forKey: completed) else { return }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "photos.homespun.demo-review-code",
            kSecAttrAccount: "review",
            kSecAttrSynchronizable: false,
        ]
        let status = delete(query)
        // Retry at a later launch if the Keychain is unavailable, without touching pairing items.
        if status == errSecSuccess || status == errSecItemNotFound {
            defaults.set(true, forKey: completed)
        }
    }

    static func installation() throws -> DeviceInstallation {
        try installationCache.withLock { cached in
            if let cached { return cached }
            let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: installationService,
                kSecAttrAccount: "device", kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne,
                kSecAttrSynchronizable: false]
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            let value: DeviceInstallation
            if status == errSecItemNotFound {
                value = DeviceInstallation(id: UUID().uuidString.lowercased())
                try write(JSONEncoder().encode(value), service: installationService, server: "device")
            } else {
                guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
                guard let data = result as? Data, let saved = try? JSONDecoder().decode(DeviceInstallation.self, from: data),
                      UUID(uuidString: saved.id) != nil else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(errSecDecode)) }
                value = saved
            }
            cached = value
            return value
        }
    }

    static func confirmInstallationName(_ name: String) throws {
        var value = try installation()
        guard !name.isEmpty, value.name != name else { return }
        value.name = name
        try write(JSONEncoder().encode(value), service: installationService, server: "device")
        let confirmed = value
        installationCache.withLock { $0 = confirmed }
    }

    static func token(for server: String) -> String? {
        if let cached = cache.withLock({ $0[server] }) { return cached }
        let token = read(server)
        if let token { cache.withLock { $0[server] = token } }
        return token
    }

    static func accounts() -> [String] {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                      kSecReturnAttributes: true, kSecMatchLimit: kSecMatchLimitAll]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    static func recognises(_ fingerprint: ServerKeyFingerprint) -> Bool {
        accounts().contains { pins(for: $0)?.pins.contains(fingerprint) == true }
    }

    private static func read(_ server: String) -> String? {
        var result: AnyObject?
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                      kSecAttrAccount: server, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setToken(_ token: String, for server: String) throws {
        try write(Data(token.utf8), service: service, server: server)
        cache.withLock { $0[server] = token }
    }

    private static func write(_ data: Data, service: String, server: String) throws {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: server,
                                      kSecAttrSynchronizable: false]
        let attributes: [CFString: Any] = [kSecValueData: data,
                                          kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, value in value } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    static func pins(for server: String) -> ServerPins? {
        if let cached = pinsCache.withLock({ $0[server] }) { return cached }
        var result: AnyObject?
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: pinsService,
                                      kSecAttrAccount: server, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let pins = try? JSONDecoder().decode(ServerPins.self, from: data), pins.v == 1 else { return nil }
        pinsCache.withLock { $0[server] = pins }
        return pins
    }

    static func hasPinRecord(for server: String) -> Bool {
        if pinsCache.withLock({ $0[server] != nil }) { return true }
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: pinsService,
                                      kSecAttrAccount: server, kSecMatchLimit: kSecMatchLimitOne]
        // An unreadable or newer record is not an unpinned legacy pairing.
        return SecItemCopyMatching(query as CFDictionary, nil) != errSecItemNotFound
    }

    static func setPins(_ pins: ServerPins, for server: String) throws {
        try write(JSONEncoder().encode(pins), service: pinsService, server: server)
        pinsCache.withLock { $0[server] = pins }
    }

    static func removePins(for server: String) {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: pinsService, kSecAttrAccount: server]
        SecItemDelete(query as CFDictionary)
        pinsCache.withLock { $0[server] = nil }
    }

    static func removeToken(for server: String) {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: server]
        SecItemDelete(query as CFDictionary)
        cache.withLock { $0[server] = nil }
    }
}

/// Where pairing tokens are kept: the Keychain for the person's own server (`KeychainTokens`); the
/// demo keeps its pretend server's token with its own settings.
protocol TokenStore: Sendable {
    func token(for server: String) -> String?
    func setToken(_ token: String, for server: String) throws
    func removeToken(for server: String)
    func pins(for server: String) -> ServerPins?
    func setPins(_ pins: ServerPins, for server: String) throws
    func removePins(for server: String)
    func hasPinRecord(for server: String) -> Bool
}

extension TokenStore {
    func hasPinRecord(for server: String) -> Bool { pins(for: server) != nil }
}

struct KeychainTokens: TokenStore {
    func token(for server: String) -> String? { Keychain.token(for: server) }
    func setToken(_ token: String, for server: String) throws { try Keychain.setToken(token, for: server) }
    func removeToken(for server: String) { Keychain.removeToken(for: server) }
    func pins(for server: String) -> ServerPins? { Keychain.pins(for: server) }
    func setPins(_ pins: ServerPins, for server: String) throws { try Keychain.setPins(pins, for: server) }
    func removePins(for server: String) { Keychain.removePins(for: server) }
    func hasPinRecord(for server: String) -> Bool { Keychain.hasPinRecord(for: server) }
}
