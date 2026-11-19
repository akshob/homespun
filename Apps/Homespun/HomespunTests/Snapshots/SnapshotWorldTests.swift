// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import Homespun

@MainActor
struct SnapshotWorldTests {
    @Test func isolatedWorldsNeverFallThroughToTheNetwork() async throws {
        let first = try await SnapshotWorld(), second = try await SnapshotWorld()
        defer { first.close(); second.close() }
        let client = try #require(first.settings.client)
        let info = try await client.info()
        #expect(info == StubServer.info)
        #expect(!first.settings.isDemo)
        #expect(first.settings.pins == StubServer.pins)
        #expect(try first.settings.pairingIdentity().name == "Sample iPhone")
        #expect(first.library.library.state.cell(FixtureCatalog.original(83))?.badge == .failed)
        let request = URLRequest(url: StubServer.baseURL.appendingPathComponent("not-stubbed"))
        await #expect(throws: (any Error).self) { try await first.stub.session.data(for: request) }
        #expect(throws: SnapshotFailure.self) { try first.stub.validate() }
        try second.stub.validate()
    }
}
