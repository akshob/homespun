// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import HomespunCore
import Hummingbird
import HummingbirdTesting
import Testing
@testable import HomespunServerKit

extension Catalog {
    func installationState(_ id: String) throws -> (hash: String?, assets: Int, events: [String]) {
        let hash = try database.query("SELECT install_id FROM devices WHERE id = ?", [.text(id)]).first?["install_id"]?.string
        let assets = try database.query("SELECT count(*) AS n FROM assets WHERE device_id = ?", [.text(id)]).first?["n"]?.int ?? 0
        let events = try database.query("SELECT type FROM events WHERE device_id = ? ORDER BY id", [.text(id)])
            .compactMap { $0["type"]?.string }
        return (hash, assets, events)
    }
}

@Test func rePairingAnActiveInstallationPreservesItsRecordNameFolderAndAssets() async throws {
    let fixture = try await Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let installation = UUID().uuidString
    try await Application(router: fixture.server.testRouter()).test(.router) { client in
        func pair(_ id: String, _ name: String) async throws -> ServerAPI.PairResponse {
            let code = try await fixture.server.newPairingCode()
            return try await client.call("/api/v1/pair", .post,
                json: ServerAPI.PairRequest(code: code, deviceName: name, installID: id)).decode(ServerAPI.PairResponse.self)
        }
        let first = try await pair(installation, "iPhone")
        _ = try await client.call("/api/v1/devices/\(first.deviceID)", .patch, token: first.token,
                                   json: ServerAPI.RenameDeviceRequest(name: "Family Phone"))
        let before = try #require(try await fixture.server.catalog.devices().first { $0.id == first.deviceID })
        let bytes = Data("synthetic original".utf8), hash = Fingerprint.sha256(of: bytes)
        _ = try await client.call("/api/v1/assets", .post, token: first.token,
            json: ServerAPI.RegisterAssetRequest(kind: .photo, captureDate: nil, resources: [
                .init(role: .photo, filename: "original.bin", size: bytes.count, sha256: hash)
            ], compact: false))
        #expect(try await client.call("/api/v1/assets/\(hash)/resources/photo?offset=0", .put,
                                      token: first.token, body: bytes).status == .ok)
        let stateBefore = try await fixture.server.catalog.installationState(first.deviceID)
        let again = try await pair(installation.lowercased(), "iPhone")
        #expect(again.deviceID == first.deviceID && again.token != first.token)
        #expect(again.server.deviceName == "Family Phone")
        let after = try #require(try await fixture.server.catalog.devices().first { $0.id == first.deviceID })
        #expect(after.name == before.name && after.folder == before.folder && after.createdAt == before.createdAt)
        let stateAfter = try await fixture.server.catalog.installationState(first.deviceID)
        #expect(stateAfter.hash == Pairing.hash(UUID(uuidString: installation)!.uuidString.lowercased()))
        #expect(stateAfter.hash != installation && stateAfter.assets == 1 && stateAfter.assets == stateBefore.assets)
        #expect(stateAfter.events.contains("device_paired_again"))
        #expect(try await client.call("/api/v1/info", token: first.token).status == .unauthorized)
        #expect(try await client.call("/api/v1/assets/\(hash)", token: again.token).status == .ok)

        let another = try await pair(UUID().uuidString, "iPhone")
        #expect(another.deviceID != first.deviceID)
        _ = try await fixture.server.catalog.revoke(deviceID: first.deviceID)
        let revoked = try await pair(installation, "Family Phone")
        #expect(revoked.deviceID != first.deviceID, "Explicit revocation must not be undone by an install ID")
    }
}

@Test func ownerApprovedInstallationsReuseOnlyAnActiveMatchingRecord() async throws {
    let fixture = try await Fixture(approver: FakeApprover())
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let installation = UUID().uuidString.lowercased(), hash = Pairing.hash(installation)
    let first = try await fixture.server.catalog.claimApprovedDevice(
        .init(id: UUID().uuidString, name: "Family Phone", createdAt: "", lastSeenAt: nil, revokedAt: nil),
        tokenHash: Pairing.hash("first approved token"), installHash: hash)
    try await Application(router: fixture.server.testRouter()).test(.router) { client in
        let nonce = PairingCrypto.nonce()
        #expect(try await client.call("/api/v1/pair/requests", .post, json: ServerAPI.ApprovalRequest(
            deviceName: "iPhone", commitment: PairingCrypto.encode(PairingCrypto.commitment(nonce: nonce)),
            installID: installation)).status == .badRequest)
        let ticket = try await client.call("/api/v1/pair/requests", .post, json: ServerAPI.ApprovalRequest(
            deviceName: "iPhone", commitment: PairingCrypto.encode(PairingCrypto.commitment(nonce: nonce))))
            .decode(ServerAPI.ApprovalTicket.self)
        _ = try await client.call("/api/v1/pair/requests/\(ticket.id)/reveal", .post, token: ticket.secret,
                                  json: ServerAPI.ApprovalReveal(nonce: PairingCrypto.encode(nonce)))
        var paired: ServerAPI.PairResponse?
        for _ in 0..<100 {
            let status = try await client.call("/api/v1/pair/requests/\(ticket.id)", token: ticket.secret)
                .decode(ServerAPI.ApprovalStatus.self)
            #expect(status.pairing == nil)
            if status.state == .approved {
                paired = try await client.call("/api/v1/pair/requests/\(ticket.id)/complete", .post, token: ticket.secret,
                    json: ServerAPI.ApprovalCompletion(installID: installation)).decode(ServerAPI.PairResponse.self)
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let again = try #require(paired)
        #expect(again.deviceID == first.id && again.server.deviceName == first.name)
        let record = try #require(try await fixture.server.catalog.devices().first { $0.id == first.id })
        #expect(record.folder == first.folder)
        #expect(try await client.call("/api/v1/info", token: again.token).status == .ok)
    }
    #expect(try await fixture.server.catalog.device(tokenHash: Pairing.hash("first approved token")) == nil)
    #expect(try await fixture.server.catalog.installationState(first.id).events.contains("device_paired_again"))
}

@Test func installationMigrationLeavesLegacyDevicesUnmatched() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("old.db").path
    let old = try SQLiteDatabase(path: path)
    for migration in Catalog.migrations.dropLast() { try old.executeScript(migration) }
    try old.execute("PRAGMA user_version = \(Catalog.migrations.count - 1)")
    try old.execute("INSERT INTO devices (id, name, token_hash, created_at, folder) VALUES (?, ?, ?, ?, ?)",
                    [.text("legacy-device"), .text("Family Phone"), .text(Pairing.hash("legacy token")),
                     .text(Timestamp.string()), .text("Family Phone")])
    let catalog = try Catalog(path: path)
    #expect(try await catalog.installationState("legacy-device").hash == nil)
    let created = try await catalog.claimApprovedDevice(
        .init(id: UUID().uuidString, name: "Family Phone", createdAt: "", lastSeenAt: nil, revokedAt: nil),
        tokenHash: Pairing.hash("new token"), installHash: Pairing.hash(UUID().uuidString.lowercased()))
    #expect(created.id != "legacy-device")
    #expect(try await catalog.devices().count == 2)
    #expect(try await catalog.device(tokenHash: Pairing.hash("legacy token"))?.id == "legacy-device")
}
