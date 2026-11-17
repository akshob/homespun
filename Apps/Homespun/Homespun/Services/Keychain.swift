// SPDX-License-Identifier: Apache-2.0
import Foundation
import os
import Security

/// The server's device token, kept in the Keychain (this device only, after first unlock), and in
/// memory once read: screens ask whether the iPhone is paired as they draw, and a Keychain read
/// each time cost the main thread on every redraw.
enum Keychain {
    private static let service = "photos.homespun.server-token"
    private static let cache = OSAllocatedUnfairLock<[String: String]>(initialState: [:])

    static func token(for server: String) -> String? {
        if let cached = cache.withLock({ $0[server] }) { return cached }
        let token = read(server)
        if let token { cache.withLock { $0[server] = token } }
        return token
    }

    private static func read(_ server: String) -> String? {
        var result: AnyObject?
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                      kSecAttrAccount: server, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setToken(_ token: String, for server: String) throws {
        removeToken(for: server)
        let item: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: server,
                                     kSecValueData: Data(token.utf8),
                                     kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        cache.withLock { $0[server] = token }
    }

    static func removeToken(for server: String) {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: server]
        SecItemDelete(query as CFDictionary)
        cache.withLock { $0[server] = nil }
    }
}
