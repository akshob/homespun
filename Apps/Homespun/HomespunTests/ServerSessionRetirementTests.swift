// SPDX-License-Identifier: Apache-2.0
import Foundation
import HomespunCore
import XCTest
@testable import Homespun

final class ServerSessionRetirementTests: XCTestCase {
    private final class Invalidations: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func record() { lock.withLock { value += 1 } }
    }

    func testResetRejectsRetainedPinnedClientBeforeStartingANewTask() async throws {
        let pool = ServerSessions()
        let url = try XCTUnwrap(URL(string: "https://retired-session.invalid"))
        let key = ServerKeyFingerprint(spki: Data("retired session fixture".utf8))
        let pair = pool.session(for: url, trust: .pinned([key]))
        let client = ServerClient(baseURL: url, token: "must-not-be-sent", trust: .pinned([key]),
                                  session: pair.0, delegate: pair.1)
        pool.reset(url)

        do {
            _ = try await client.info()
            XCTFail("A retired client started another request")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cancelled)
        }
    }

    func testRetirementWaitsForAdmittedOperationsAndRejectsNewOnes() async throws {
        let invalidations = Invalidations()
        let lifetime = ServerSessionLifetime(invalidate: { _ in invalidations.record() })
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let started = AsyncStream<Void>.makeStream()
        let finish = AsyncStream<Void>.makeStream()
        let work = Task {
            try await lifetime.withOperation(session: session) {
                started.continuation.yield(())
                var iterator = finish.stream.makeAsyncIterator()
                _ = await iterator.next()
                return 42
            }
        }
        var entered = started.stream.makeAsyncIterator()
        _ = await entered.next()
        lifetime.retire(session: session)
        XCTAssertEqual(invalidations.count, 0)
        do {
            try await lifetime.withOperation(session: session) {
                XCTFail("An operation entered a retired session")
            }
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cancelled)
        }
        finish.continuation.yield(())
        let result = try await work.value
        XCTAssertEqual(result, 42)
        XCTAssertEqual(invalidations.count, 1)
        lifetime.retire(session: session)
        XCTAssertEqual(invalidations.count, 1)
    }
}
