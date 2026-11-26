// SPDX-License-Identifier: Apache-2.0
import os
import Testing
@testable import Homespun

@Test func waitingForRemoteEncodingNeverInventsContinuedProcessingProgress() {
    for step in ["Queued on server", "Compressing on server"] {
        #expect(LongRun.fraction(step: step, seconds: 3_600) == LongRun.fraction(step: step, seconds: 0))
        #expect(LongRun.fraction(step: step, seconds: 3_600) < LongRun.fraction(step: "Downloading compact copy", seconds: 0))
    }
}

@Test func continuedProcessingExpirationCannotBeCompletedAgainAsSuccess() {
    let results = OSAllocatedUnfairLock(initialState: [Bool]())
    let completion = LongRun.Completion { success in results.withLock { $0.append(success) } }
    #expect(completion.finish(success: false))
    #expect(!completion.finish(success: true))
    #expect(completion.result == false)
    #expect(results.withLock { $0 } == [false])
}

@Test func continuedProcessingConcurrentCompletionIsExactlyOnce() async {
    let results = OSAllocatedUnfairLock(initialState: [Bool]())
    let completion = LongRun.Completion { success in results.withLock { $0.append(success) } }
    await withTaskGroup(of: Void.self) { group in
        for index in 0..<100 {
            group.addTask { completion.finish(success: index.isMultiple(of: 2)) }
        }
    }
    #expect(results.withLock { $0.count } == 1)
    #expect(completion.result == results.withLock { $0.first })
}
