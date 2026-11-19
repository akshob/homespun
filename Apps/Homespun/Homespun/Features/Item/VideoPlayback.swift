// SPDX-License-Identifier: Apache-2.0
import AVFoundation
import Photos
import SwiftUI
import UIKit

/// A player's picture, without AVKit's controls competing with paging or linked zoom.
final class PlayerSurface: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    private var ready: NSKeyValueObservation?
    var onReady: ((Bool) -> Void)?

    var player: AVPlayer? {
        get { playerLayer.player }
        set {
            guard playerLayer.player !== newValue else { return }
            playerLayer.player = newValue
            onReady?(playerLayer.isReadyForDisplay)
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        playerLayer.videoGravity = .resizeAspect
        ready = playerLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                onReady?(playerLayer.isReadyForDisplay)
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

enum VideoTime {
    static func text(_ seconds: Double) -> String {
        let seconds = seconds.isFinite ? max(0, seconds.rounded(.down)) : 0
        let duration = Duration.seconds(seconds)
        return seconds >= 3600 ? duration.formatted(.time(pattern: .hourMinuteSecond))
            : duration.formatted(.time(pattern: .minuteSecond))
    }
}

/// Only one exact seek in flight. A moving slider replaces the destination, not the seek.
@MainActor
final class PlayerSeek {
    let player: AVPlayer
    private(set) var isSeeking = false
    private var target: Double?
    private var finished: (() -> Void)?
    private var generation = 0

    init(_ player: AVPlayer) { self.player = player }

    func seek(to seconds: Double, finished: (() -> Void)? = nil) {
        target = seconds
        self.finished = finished
        chase()
    }

    func reset() {
        generation += 1
        target = nil
        finished = nil
        isSeeking = false
        player.currentItem?.cancelPendingSeeks()
    }

    private func chase() {
        guard !isSeeking, let target else { return }
        isSeeking = true
        let generation = generation
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) {
            [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                isSeeking = false
                if self.target != target {
                    chase()
                } else {
                    self.target = nil
                    let done = self.finished
                    self.finished = nil
                    done?()
                }
            }
        }
    }
}

/// One player per viewer, reused as the person turns video pages. Only the scrubber reads `time`.
@MainActor @Observable
final class VideoPlayback {
    enum Status: Equatable {
        case idle, loading, ready, failed(String)
    }

    private(set) var id: String?
    private(set) var status = Status.idle {
        didSet { if oldValue != status { stateChanged?() } }
    }
    private(set) var isPlaying = false {
        didSet { if oldValue != isPlaying { stateChanged?() } }
    }
    private(set) var duration = 0.0
    private(set) var time = 0.0
    // SwiftUI may construct a fresh State value before keeping the old one. Only a video shown needs a player.
    @ObservationIgnored private(set) lazy var player = makePlayer()
    @ObservationIgnored var stateChanged: (() -> Void)?
    @ObservationIgnored weak var stateOwner: AnyObject?
    @ObservationIgnored private lazy var seeker = PlayerSeek(player)
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var clock: Any?
    @ObservationIgnored private var observedPlayer: AVPlayer?
    @ObservationIgnored private var control: NSKeyValueObservation?
    @ObservationIgnored private var itemStatus: NSKeyValueObservation?
    @ObservationIgnored private var ended: NSObjectProtocol?
    @ObservationIgnored private var scrubbing = false
    @ObservationIgnored private var resumeAfterScrub = false
    @ObservationIgnored private var wantsPlay = false

    private func makePlayer() -> AVPlayer {
        let player = AVPlayer()
        observedPlayer = player
        player.actionAtItemEnd = .pause
        clock = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.id != nil, !self.scrubbing, !self.seeker.isSeeking else { return }
                let seconds = self.player.currentTime().seconds
                if seconds.isFinite { self.time = min(max(0, seconds), self.duration) }
            }
        }
        control = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                isPlaying = id != nil && player.timeControlStatus != .paused
            }
        }
        return player
    }

    isolated deinit {
        loading?.cancel()
        observedPlayer?.pause()
        if let clock { observedPlayer?.removeTimeObserver(clock) }
        if let ended { NotificationCenter.default.removeObserver(ended) }
        control?.invalidate()
        itemStatus?.invalidate()
    }

    func load(_ asset: any LibraryItem, id: String, autoplay: Bool) {
        guard self.id != id else { return }
        reset()
        self.id = id
        duration = asset.duration
        status = .loading
        wantsPlay = autoplay
        loading = Task { [weak self] in
            let result = await asset.playerItem()
            guard let self, self.id == id, !Task.isCancelled else { return }
            switch result {
            case .success(let item): install(item)
            case .failure(let error): status = .failed(error.localizedDescription)
            }
        }
    }

    func load(item: AVPlayerItem, id: String, duration: Double, autoplay: Bool) {
        guard self.id != id else { return }
        reset()
        self.id = id
        self.duration = duration
        status = .loading
        wantsPlay = autoplay
        install(item)
    }

    private func install(_ item: AVPlayerItem) {
        player.replaceCurrentItem(with: item)
        itemStatus = item.observe(\.status, options: [.initial, .new]) { [weak self, weak item] _, _ in
            Task { @MainActor [weak self, weak item] in
                guard let self, let item, player.currentItem === item else { return }
                switch item.status {
                case .readyToPlay:
                    status = .ready
                    if wantsPlay { play() }
                case .failed:
                    pause()
                    status = .failed(item.error?.localizedDescription ?? "This video can't be played here.")
                default: break
                }
            }
        }
        ended = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) {
            [weak self, weak item] _ in
            MainActor.assumeIsolated {
                guard let self, let item, self.player.currentItem === item else { return }
                self.wantsPlay = false
                self.isPlaying = false
                self.time = self.duration
            }
        }
    }

    func unload(id: String) {
        guard self.id == id else { return }
        reset()
    }

    private func reset() {
        loading?.cancel()
        loading = nil
        pause()
        seeker.reset()
        itemStatus?.invalidate()
        itemStatus = nil
        if let ended { NotificationCenter.default.removeObserver(ended) }
        ended = nil
        player.replaceCurrentItem(with: nil)
        id = nil
        scrubbing = false
        duration = 0
        time = 0
        status = .idle
    }

    func play() {
        guard status == .ready else { return }
        wantsPlay = true
        if duration > 0, time >= duration - 0.05 {
            time = 0
            seeker.seek(to: 0) { [weak self] in
                guard let self, wantsPlay else { return }
                player.play()
            }
        } else {
            player.play()
        }
    }

    func pause() {
        wantsPlay = false
        resumeAfterScrub = false
        observedPlayer?.pause()
        isPlaying = false
    }

    func toggle() { isPlaying ? pause() : play() }

    func beginScrub() {
        let playing = isPlaying
        pause()
        resumeAfterScrub = playing
        scrubbing = true
    }

    func scrub(to seconds: Double) {
        guard status == .ready, seconds.isFinite else { return }
        time = min(max(0, seconds), duration)
        seeker.seek(to: time)
    }

    func endScrub() {
        let resume = resumeAfterScrub
        scrubbing = false
        wantsPlay = resume
        seeker.seek(to: time) { [weak self] in
            guard let self, wantsPlay else { return }
            play()
        }
    }
}

struct VideoScrubber: View {
    let playback: VideoPlayback
    var durationOverride: Double?

    var body: some View {
        let duration = durationOverride ?? playback.duration
        HStack(spacing: 10) {
            Text(VideoTime.text(playback.time)).accessibilityHidden(true)
            Slider(value: Binding(get: { playback.time }, set: { playback.scrub(to: $0) }),
                   in: 0...max(duration, 0.1), onEditingChanged: {
                $0 ? playback.beginScrub() : playback.endScrub()
            })
            .disabled(durationOverride == nil && playback.status != .ready)
            .accessibilityLabel("Position")
            .accessibilityValue("\(VideoTime.text(playback.time)) of \(VideoTime.text(duration))")
            .accessibilityIdentifier("item.position")
            Text("−" + VideoTime.text(duration - playback.time)).accessibilityHidden(true)
        }
        .font(.footnote.monospacedDigit())
        .foregroundStyle(.white)
        .tint(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(in: .capsule)
    }
}
