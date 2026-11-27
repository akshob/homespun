// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import HomespunCore

@Test func serverInfoBackupAPIIsOptionalAndUsesSnakeCase() throws {
    let old = ServerAPI.ServerInfo(name: "polonium", version: "0.2.0", mode: .files, profile: .standard)
    let oldJSON = try ServerAPI.encoder.encode(old)
    #expect(try ServerAPI.decoder.decode(ServerAPI.ServerInfo.self, from: oldJSON).backupAPI == nil)
    var updated = old
    updated.backupAPI = 2
    let data = try ServerAPI.encoder.encode(updated)
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["backup_api"] as? Int == 2)
    #expect(try ServerAPI.decoder.decode(ServerAPI.ServerInfo.self, from: data) == updated)
    // 1.0 decoders ignored new keys.
    struct OldInfo: Decodable { var name: String; var version: String }
    #expect(try ServerAPI.decoder.decode(OldInfo.self, from: data).name == old.name)
}
