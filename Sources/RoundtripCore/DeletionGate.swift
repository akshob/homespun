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
}
