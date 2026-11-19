// SPDX-License-Identifier: Apache-2.0
import Foundation

struct DeviceInstallation: Codable, Equatable, Sendable {
    var id: String
    var name: String?
}

protocol InstallationStore: Sendable {
    func load() throws -> DeviceInstallation
    func confirm(name: String) throws
}

struct KeychainInstallation: InstallationStore {
    func load() throws -> DeviceInstallation { try Keychain.installation() }
    func confirm(name: String) throws { try Keychain.confirmInstallationName(name) }
}

struct DefaultsInstallation: InstallationStore, @unchecked Sendable {
    let defaults: UserDefaults

    func load() throws -> DeviceInstallation {
        if let data = defaults.data(forKey: "demo.installation"),
           let value = try? JSONDecoder().decode(DeviceInstallation.self, from: data) { return value }
        let value = DeviceInstallation(id: UUID().uuidString.lowercased())
        defaults.set(try JSONEncoder().encode(value), forKey: "demo.installation")
        return value
    }

    func confirm(name: String) throws {
        var value = try load()
        guard value.name != name else { return }
        value.name = name
        defaults.set(try JSONEncoder().encode(value), forKey: "demo.installation")
    }
}
