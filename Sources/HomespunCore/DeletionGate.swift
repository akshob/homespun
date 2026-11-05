// SPDX-License-Identifier: Apache-2.0
/// Decides whether the app may ask iOS to delete an original. Deletion is allowed only
/// when the server's stored copy matches the device original byte-for-byte (SHA-256)
/// and every compact resource was imported and verified. Re-evaluate at deletion time.
public struct DeletionGate: Sendable {
    public enum Decision: Equatable, Sendable {
        case allowed
        case blocked(String)
    }

    public init() {}

    public func evaluate(deviceOriginalSHA256: String, serverOriginalSHA256: String?,
                         serverOriginalSize: Int?, deviceOriginalSize: Int,
                         compactImported: Bool) -> Decision {
        guard deviceOriginalSize > 0 else { return .blocked("zero-byte original") }
        guard let serverSHA = serverOriginalSHA256, let serverSize = serverOriginalSize else {
            return .blocked("server has no verified copy")
        }
        guard serverSize == deviceOriginalSize else { return .blocked("size mismatch") }
        guard serverSHA.lowercased() == deviceOriginalSHA256.lowercased() else {
            return .blocked("hash mismatch")
        }
        guard compactImported else { return .blocked("compact copy not imported yet") }
        return .allowed
    }

    /// One file of an asset: its PhotoKit role, size, and SHA-256.
    public struct Resource: Equatable, Sendable {
        public var role: String
        public var sha256: String
        public var size: Int

        public init(role: String, sha256: String, size: Int) {
            self.role = role
            self.sha256 = sha256
            self.size = size
        }
    }

    /// Multi-resource form: every resource read from the device just now must match a copy
    /// the server verified just now (same role, size, and SHA-256), and the compact copy must
    /// be in the library. Live Photos and edited items have several resources.
    public func evaluate(deviceResources: [Resource], serverVerified: [Resource], compactImported: Bool) -> Decision {
        guard !deviceResources.isEmpty else { return .blocked("no resources were read from the device") }
        for resource in deviceResources {
            let decision = evaluate(
                deviceOriginalSHA256: resource.sha256,
                serverOriginalSHA256: serverVerified.first { $0.role == resource.role }?.sha256,
                serverOriginalSize: serverVerified.first { $0.role == resource.role }?.size,
                deviceOriginalSize: resource.size, compactImported: compactImported)
            if case .blocked(let reason) = decision { return .blocked("\(resource.role): \(reason)") }
        }
        return .allowed
    }
}
