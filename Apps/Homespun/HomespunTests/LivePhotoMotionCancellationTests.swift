// SPDX-License-Identifier: Apache-2.0
import AVFoundation
import Foundation
@_spi(Testing) import HomespunMedia
import HomespunTestSupport
import Testing

@Suite(.serialized) struct LivePhotoMotionCancellationTests {
    private final class CancellationProbe: @unchecked Sendable {
        private let mediaType: AVMediaType
        private let index: Int
        private let lock = NSLock()
        private let gate = DispatchSemaphore(value: 0)
        private var arrival: CheckedContinuation<Bool, Never>?
        private var blocked = false
        private var finished = false
        private var reads: [String: Int] = [:]
        private var inFlight = 0
        private var inFlightAtCancelReader: [Int] = []
        private var lateCallbacks: [String: Int] = [:]
        private var joined: (AVAssetReader.Status, AVAssetWriter.Status)?

        init(mediaType: AVMediaType, index: Int) {
            self.mediaType = mediaType
            self.index = index
        }

        var snapshot: (finished: Bool, inFlight: Int, inFlightAtCancelReader: [Int],
                       lateCallbacks: [String: Int], joined: (AVAssetReader.Status, AVAssetWriter.Status)?) {
            lock.withLock { (finished, inFlight, inFlightAtCancelReader, lateCallbacks, joined) }
        }

        func willReadSample(_ mediaType: AVMediaType) {
            let pause = lock.withLock {
                inFlight += 1
                let index = reads[mediaType.rawValue, default: 0]
                reads[mediaType.rawValue] = index + 1
                guard !blocked, mediaType == self.mediaType, index == self.index else { return false }
                blocked = true
                arrival?.resume(returning: true)
                arrival = nil
                return true
            }
            if pause { gate.wait() }
        }

        func didReadSample() { lock.withLock { inFlight -= 1 } }
        func didCancelReader() { lock.withLock { inFlightAtCancelReader.append(inFlight) } }

        func lateCallback(_ mediaType: AVMediaType) {
            lock.withLock { lateCallbacks[mediaType.rawValue, default: 0] += 1 }
            // Keep a regressed requester from starving the simulator's test executor.
            Thread.sleep(forTimeInterval: 0.001)
        }

        func didJoin(_ reader: AVAssetReader.Status, _ writer: AVAssetWriter.Status) {
            lock.withLock { joined = (reader, writer) }
        }

        func didFinish() {
            lock.withLock {
                finished = true
                arrival?.resume(returning: false)
                arrival = nil
            }
        }

        func waitUntilBlockedOrFinished() async -> Bool {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    if blocked { continuation.resume(returning: true) }
                    else if finished { continuation.resume(returning: false) }
                    else { arrival = continuation }
                }
            }
        }

        func release() { gate.signal() }
    }

    @Test func cancelPointsNeverSpinOrCancelDuringARead() async throws {
        let directory = try Synthetic.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("in.mov")
        try await Synthetic.video(at: input, .init(width: 640, height: 480, frames: 45,
            bitrate: 12_000_000, audioChannels: 1, liveIdentifier: UUID().uuidString))
        let tracks = try await AVURLAsset(url: input).load(.tracks)
        try #require([AVMediaType.video, .audio, .metadata].allSatisfy { type in
            tracks.filter { $0.mediaType == type }.count == 1
        })
        let points: [(AVMediaType, Int)] = [(.video, 0), (.video, 3), (.audio, 0), (.audio, 2), (.metadata, 0)]
        for (mediaType, index) in points {
            let point = "\(mediaType.rawValue) sample \(index)"
            let output = directory.appendingPathComponent("out-\(mediaType.rawValue)-\(index).mov")
            let probe = CancellationProbe(mediaType: mediaType, index: index)
            let observer = LivePhotoMotionCompressor.MotionObserver(
                willReadSample: { probe.willReadSample($0) },
                didReadSample: { _ in probe.didReadSample() },
                lateCallback: { probe.lateCallback($0) },
                didCancelReader: { probe.didCancelReader() },
                didJoin: { probe.didJoin($0, $1) })
            let task = Task {
                defer { probe.didFinish() }
                return try await LivePhotoMotionCompressor().compress(input: input, output: output, observer: observer)
            }
            defer { probe.release() }
            guard await probe.waitUntilBlockedOrFinished() else {
                _ = try await task.value
                Issue.record("Motion completed without reaching \(point)")
                return
            }
            #expect(probe.snapshot.inFlight > 0, "\(point)")
            task.cancel()
            #expect(!probe.snapshot.finished, "Cancellation returned while \(point) was held")
            probe.release()
            await #expect(throws: CancellationError.self) { _ = try await task.value }
            let snapshot = probe.snapshot
            #expect(snapshot.inFlightAtCancelReader == [0] && snapshot.inFlight == 0, "\(point)")
            #expect(snapshot.lateCallbacks.values.allSatisfy { $0 <= 1 },
                    "\(point): late requester callbacks \(snapshot.lateCallbacks)")
            let joined = try #require(snapshot.joined)
            #expect(joined.0 == .cancelled && joined.1 == .cancelled, "\(point)")
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == ["in.mov"], "\(point)")
        }
    }
}
