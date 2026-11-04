import Foundation
import Hummingbird
import RoundtripCore

struct Health: ResponseEncodable {
    let status: String
    let version: String
    let profile: CompressionProfile
}

let environment = ProcessInfo.processInfo.environment
let host = environment["ROUNDTRIP_HOST"] ?? "127.0.0.1"
let port = Int(environment["ROUNDTRIP_PORT"] ?? "") ?? 8787

let router = Router()
router.get("/api/v1/health") { _, _ in
    Health(status: "ok", version: "0.1.0", profile: .standard)
}

let app = Application(router: router, configuration: .init(address: .hostname(host, port: port),
                                                           serverName: "roundtrip"))
try await app.runService()
