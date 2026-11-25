// SPDX-License-Identifier: Apache-2.0
#if canImport(AVFoundation)
import AVFoundation
import CoreMedia
import Foundation

extension AVSupport {
    /// Internal observation points let tests hold real in-flight work at deterministic barriers.
    struct MotionObserver: Sendable {
        var didAppend: @Sendable (AVMediaType) -> Void = { _ in }
        var didDecodeFrame: @Sendable () -> Void = {}
        var didJoin: @Sendable (AVAssetReader.Status, AVAssetWriter.Status) -> Void = { _, _ in }
    }

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
                }, didAppend: self.observer.didAppend)) {
                    self.queue.async { self.lanesFinished() }
                }
                if self.stopped { self.stop() }
            }
        }

        private func stop() {
            guard continuation != nil, !completing else { return }
            // Interrupt an in-flight read before asking every lane to close. The writer is
            // stopped only after all appends/markAsFinished calls have returned.
            reader.cancelReading()
            if pumping {
                pump.stop()
                return
            }
            writer.cancelWriting()
            if !finishing { complete() }
        }

        private func lanesFinished() {
            pumping = false
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
            pump.fence {
                self.queue.async {
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
}
#endif
