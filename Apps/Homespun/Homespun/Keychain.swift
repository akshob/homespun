// SPDX-License-Identifier: Apache-2.0
import Foundation
import Security

/// The server's device token, kept in the Keychain (this device only, after first unlock).
enum Keychain {
    private static let service = "photos.homespun.server-token"

    static func token(for server: String) -> String? {
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
    }

    static func removeToken(for server: String) {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: server]
        SecItemDelete(query as CFDictionary)
    }
}
