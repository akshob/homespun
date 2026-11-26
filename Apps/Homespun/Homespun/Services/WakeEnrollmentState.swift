// SPDX-License-Identifier: Apache-2.0
import Foundation
import Security

struct WakeEnrollmentRecord: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    var id: UUID
    var relayURL: URL
    var bindingID: UUID
    var managementToken: String
    var senderToken: String
    var generationID: UUID?
    var tokenHash: String?
    var linked = false
    var refreshedAt: Date?
    var description: String { "WakeEnrollmentRecord(redacted)" }
    var debugDescription: String { description }
}

struct WakeEnrollmentState: Codable, Equatable, Sendable {
    var enabled = false
    var epoch = UUID()
    var active: WakeEnrollmentRecord?
    var retiring: [WakeEnrollmentRecord] = []
}

@MainActor protocol WakeEnrollmentStoring: AnyObject {
    func load() throws -> WakeEnrollmentState
    func save(_ state: WakeEnrollmentState) throws
}

@MainActor final class KeychainWakeEnrollmentStore: WakeEnrollmentStoring {
    private let service = "photos.homespun.wake"
    private var query: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: "enrollment",
         kSecAttrSynchronizable: false]
    }

    func load() throws -> WakeEnrollmentState {
        var query = query
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return WakeEnrollmentState() }
        guard status == errSecSuccess, let data = result as? Data else { throw WakeEnrollmentFailure.storage }
        do { return try JSONDecoder().decode(WakeEnrollmentState.self, from: data) }
        catch { throw WakeEnrollmentFailure.storage }
    }

    func save(_ state: WakeEnrollmentState) throws {
        let data = try JSONEncoder().encode(state)
        let attributes: [CFString: Any] = [kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item.merge(attributes) { _, value in value }
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw WakeEnrollmentFailure.storage }
    }
}
