// SPDX-License-Identifier: Apache-2.0
#if canImport(AVFoundation)
import AVFoundation
import CoreMedia
import Foundation

extension LivePhotoMotionCompressor {
    /// Observation points for package and hosted app tests; not part of the compressor's public API.
    @_spi(Testing) public struct MotionObserver: Sendable {
        public var willReadSample: @Sendable (AVMediaType) -> Void
        public var didReadSample: @Sendable (AVMediaType) -> Void
        public var didAppend: @Sendable (AVMediaType) -> Void
        public var didDecodeFrame: @Sendable () -> Void
        public var lateCallback: @Sendable (AVMediaType) -> Void
        public var didJoinLanes: @Sendable () -> Void
        public var didCancelReader: @Sendable () -> Void
        public var didJoin: @Sendable (AVAssetReader.Status, AVAssetWriter.Status) -> Void

        public init(willReadSample: @escaping @Sendable (AVMediaType) -> Void = { _ in },
                    didReadSample: @escaping @Sendable (AVMediaType) -> Void = { _ in },
                    didAppend: @escaping @Sendable (AVMediaType) -> Void = { _ in },
                    didDecodeFrame: @escaping @Sendable () -> Void = {},
                    lateCallback: @escaping @Sendable (AVMediaType) -> Void = { _ in },
                    didJoinLanes: @escaping @Sendable () -> Void = {},
                    didCancelReader: @escaping @Sendable () -> Void = {},
                    didJoin: @escaping @Sendable (AVAssetReader.Status, AVAssetWriter.Status) -> Void = { _, _ in }) {
            self.willReadSample = willReadSample
            self.didReadSample = didReadSample
            self.didAppend = didAppend
            self.didDecodeFrame = didDecodeFrame
            self.lateCallback = lateCallback
            self.didJoinLanes = didJoinLanes
            self.didCancelReader = didCancelReader
            self.didJoin = didJoin
        }
    }
}

extension AVSupport {
    typealias MotionObserver = LivePhotoMotionCompressor.MotionObserver

    static func transferMotion(reader: AVAssetReader, writer: AVAssetWriter,
                               pairs: [(AVAssetReaderOutput, AVAssetWriterInput)],
                               observer: MotionObserver) async throws {
        let transfer = MotionTransfer(reader: reader, writer: writer, pairs: pairs, observer: observer)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { transfer.start($0) }
            try Task.checkCancellation()
        } onCancel: {
            transfer.cancel()
        }
    }

    /// The lifecycle queue owns start/finish/stop and the continuation. Only the stop reason
    /// crosses queues, under its lock. Each SamplePump lane owns its own finished fence.
    private final class MotionTransfer: @unchecked Sendable {
        private let reader: AVAssetReader
        private let writer: AVAssetWriter
        private let pump: SamplePump
        private let observer: MotionObserver
        private let queue = DispatchQueue(label: "photos.homespun.motion-transfer")
        private let lock = NSLock()
        private var cancelled = false
        private var failure: VideoCompressionError?
        private var continuation: CheckedContinuation<Void, Error>?
        private var pumping = false
        private var finishing = false
        private var completing = false
        private var readerObservation: NSKeyValueObservation?
        private var writerObservation: NSKeyValueObservation?

        init(reader: AVAssetReader, writer: AVAssetWriter,
             pairs: [(AVAssetReaderOutput, AVAssetWriterInput)], observer: MotionObserver) {
            self.reader = reader
            self.writer = writer
            pump = SamplePump(pairs)
            self.observer = observer
        }

        private var stopped: Bool { lock.withLock { cancelled || failure != nil } }

        func cancel() {
            lock.withLock { cancelled = true }
            queue.async { self.stop() }
        }

        private func fail(_ message: String) {
            lock.withLock {
                if failure == nil { failure = .encodingFailed(message) }
            }
            queue.async { self.stop() }
        }

        func start(_ continuation: CheckedContinuation<Void, Error>) {
            queue.async {
                self.continuation = continuation
                guard !self.stopped else { self.stop(); return }
                self.readerObservation = self.reader.observe(\.status) { [weak self] reader, _ in
                    if reader.status == .failed {
                        self?.fail("reader: \(String(describing: reader.error))")
                    }
                }
                self.writerObservation = self.writer.observe(\.status) { [weak self] writer, _ in
                    if writer.status == .failed {
                        self?.fail("writer: \(String(describing: writer.error))")
                    }
                }
                guard self.reader.startReading() else {
                    self.fail("reader: \(String(describing: self.reader.error))")
                    self.stop()
                    return
                }
                guard !self.stopped else { self.stop(); return }
                guard self.writer.startWriting() else {
                    self.fail("writer: \(String(describing: self.writer.error))")
                    self.stop()
                    return
                }
                self.writer.startSession(atSourceTime: .zero)
                self.pumping = true
                self.pump.start(control: .init(stopped: { [weak self] in self?.stopped ?? true }, failed: { [weak self] in
                    guard let self else { return }
                    self.fail("append: \(String(describing: self.writer.error))")
                }, willReadSample: self.observer.willReadSample, didReadSample: self.observer.didReadSample,
                   didAppend: self.observer.didAppend, lateCallback: self.observer.lateCallback),
                                notifyQueue: self.queue) {
                    self.lanesFinished()
                }
                if self.stopped { self.stop() }
            }
        }

        private func stop() {
            guard continuation != nil, !completing else { return }
            // Lanes mark their inputs finished and return from their last read before either
            // reader or writer is cancelled. Keep the reader alive until that join.
            if pumping {
                pump.stop()
                return
            }
            reader.cancelReading()
            observer.didCancelReader()
            writer.cancelWriting()
            if !finishing { complete() }
        }

        private func lanesFinished() {
            pumping = false
            observer.didJoinLanes()
            if reader.status == .failed { fail("reader: \(String(describing: reader.error))") }
            guard !stopped else { stop(); return }
            finishing = true
            writer.finishWriting {
                self.queue.async {
                    self.finishing = false
                    if self.writer.status != .completed {
                        self.fail("writer: \(String(describing: self.writer.error))")
                    }
                    if self.stopped { self.stop() }
                    else { self.complete() }
                }
            }
        }

        private func complete() {
            guard !completing else { return }
            completing = true
            readerObservation = nil
            writerObservation = nil
            // The writer is terminal. Fence callbacks already queued by AVFoundation too.
            // Any later callback sees its lane closed and cannot read or append.
            pump.fence(queue: queue) {
                self.observer.didJoin(self.reader.status, self.writer.status)
                let error: (any Error)? = self.lock.withLock {
                    if self.cancelled { return CancellationError() }
                    return self.failure
                }
                let continuation = self.continuation
                self.continuation = nil
                if let error { continuation?.resume(throwing: error) }
                else { continuation?.resume() }
            }
        }
    }
}
#endif
