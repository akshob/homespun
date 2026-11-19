// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import Homespun

@MainActor
struct SnapshotWorldTests {
    @Test func videoPostersLoadBothCopiesWithoutCreatingPlayers() async throws {
        let world = try await SnapshotWorld()
        defer { world.close() }
        let compare = try await world.comparison(FixtureCatalog.compact(75))
        defer { compare.close() }
        #expect(compare.status == .ready)
        #expect(compare.isVideo && compare.original != nil && compare.compact != nil)
        #expect(compare.originalPlayer == nil && compare.compactPlayer == nil)
    }

    @Test func aFreedOriginalComesFromTheCannedServerIntoTheWorldsOwnFolder() async throws {
        let world = try await SnapshotWorld()
        defer { world.close() }
        let compare = try await world.comparison(FixtureCatalog.compact(FixtureCatalog.freed))
        defer { compare.close() }
        #expect(compare.source == .server(assetID: StubServer.asset(FixtureCatalog.freed)))
        #expect(compare.status == .ready && compare.original != nil && compare.compact != nil)
        try world.stub.validate()
    }

    @Test func isolatedWorldsNeverFallThroughToTheNetwork() async throws {
        let first = try await SnapshotWorld(), second = try await SnapshotWorld()
        defer { first.close(); second.close() }
        let client = try #require(first.settings.client)
        let info = try await client.info()
        #expect(info == StubServer.info)
        #expect(!first.settings.isDemo)
        #expect(first.settings.serverCheckedAt == SnapshotWorld.now)
        #expect(first.settings.pins == StubServer.pins)
        #expect(try first.settings.pairingIdentity().name == "Sample iPhone")
        #expect(first.library.library.state.cell(FixtureCatalog.original(83))?.badge == .failed)
        let request = URLRequest(url: StubServer.baseURL.appendingPathComponent("not-stubbed"))
        await #expect(throws: (any Error).self) { try await first.stub.session.data(for: request) }
        #expect(throws: SnapshotFailure.self) { try first.stub.validate() }
        try second.stub.validate()
    }
}
