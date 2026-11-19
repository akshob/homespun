// SPDX-License-Identifier: Apache-2.0
import AVFoundation
import SwiftUI

/// Two videos share a position, but only one supplies sound. Compact leads, including when a
/// downloaded original arrives later. Nothing synchronizes or changes sound in single-copy mode.
@MainActor @Observable
final class VideoPair {
    enum Side { case original, compact }

    private(set) var isPlaying = false
    private(set) var time = 0.0
    private(set) var duration = 0.0
    var heard = Side.compact { didSet { applySound() } }
    var active = false {
        didSet {
            applySound()
            if active { updateDuration() }
        }
    }

    @ObservationIgnored private var original: AVPlayer?
    @ObservationIgnored private var compact: AVPlayer?
    @ObservationIgnored private var originalSeek: PlayerSeek?
    @ObservationIgnored private var compactSeek: PlayerSeek?
    @ObservationIgnored private var clock: Any?
    @ObservationIgnored private var clockPlayer: AVPlayer?
    @ObservationIgnored private var control: NSKeyValueObservation?
    @ObservationIgnored private var ready: [NSKeyValueObservation] = []
    @ObservationIgnored private var ended: NSObjectProtocol?
    @ObservationIgnored private var scrubbing = false
    @ObservationIgnored private var wantsPlay = false
    @ObservationIgnored private var resumeAfterScrub = false
    @ObservationIgnored private var lastCheck = 0.0
    @ObservationIgnored private var lastCorrection = 0.0
    @ObservationIgnored private var seekGeneration = 0

    private var leader: AVPlayer? { compact ?? original }
    private var follower: AVPlayer? { compact == nil ? nil : original }
    private var players: [AVPlayer] { [original, compact].compactMap(\.self) }
    private var seekers: [PlayerSeek] { [originalSeek, compactSeek].compactMap(\.self) }

    func attach(original: AVPlayer?, compact: AVPlayer?) {
        guard self.original !== original || self.compact !== compact else { return }
        let position = leader?.currentTime().seconds ?? 0
        let playing = wantsPlay
        let oldPlayers = players
        removeObservers()
        seekers.forEach { $0.reset() }
        self.original = original
        self.compact = compact
        originalSeek = original.map(PlayerSeek.init)
        compactSeek = compact.map(PlayerSeek.init)
        for player in oldPlayers where !players.contains(where: { $0 === player }) {
            player.pause()
            player.isMuted = false
        }
        for player in players {
            player.automaticallyWaitsToMinimizeStalling = false
            player.allowsExternalPlayback = false
            player.actionAtItemEnd = .pause
        }
        applySound()
        observe()
        updateDuration()
        if active, position.isFinite {
            seek(to: position) { [weak self] in
                guard let self, playing, wantsPlay, active else { return }
                start()
            }
        }
    }

    private func observe() {
        guard let leader else { return }
        clockPlayer = leader
        clock = leader.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        control = leader.observe(\.timeControlStatus, options: [.new]) { [weak self, weak leader] _, _ in
            Task { @MainActor [weak self, weak leader] in
                guard let self, let leader, self.leader === leader, active, !scrubbing else { return }
                isPlaying = leader.timeControlStatus != .paused
            }
        }
        for player in players {
            guard let item = player.currentItem else { continue }
            ready.append(item.observe(\.status, options: [.initial, .new]) { [weak self, weak player] _, _ in
                Task { @MainActor [weak self, weak player] in
                    guard let self, let player else { return }
                    updateDuration()
                    guard active, wantsPlay, player.currentItem?.status == .readyToPlay else { return }
                    let position = self.leader?.currentTime().seconds ?? 0
                    if player === self.leader, players.allSatisfy({ $0.currentItem?.status == .readyToPlay }) {
                        start()
                    } else if player === follower, position.isFinite {
                        originalSeek?.seek(to: position) { [weak self, weak player] in
                            guard let self, active, wantsPlay else { return }
                            player?.play()
                        }
                    }
                }
            })
        }
        if let item = leader.currentItem {
            ended = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) {
                [weak self, weak leader] _ in
                MainActor.assumeIsolated {
                    guard let self, let leader, self.leader === leader, self.active else { return }
                    self.pause()
                    self.time = self.duration
                }
            }
        }
    }

    private func updateDuration() {
        let seconds = leader?.currentItem?.duration.seconds ?? 0
        if seconds.isFinite, seconds > 0 { duration = seconds }
    }

    private func applySound() {
        original?.isMuted = active && heard != .original
        compact?.isMuted = active && heard != .compact
    }

    private func tick() {
        guard active, !scrubbing, !seekers.contains(where: \.isSeeking), let leader else { return }
        let position = leader.currentTime().seconds
        guard position.isFinite else { return }
        time = max(0, position)
        updateDuration()
        let now = CACurrentMediaTime()
        guard isPlaying, now - lastCheck >= 0.5 else { return }
        lastCheck = now
        guard let follower, follower.timeControlStatus == .playing, now - lastCorrection >= 1 else { return }
        let other = follower.currentTime().seconds
        let end = follower.currentItem?.duration.seconds ?? .infinity
        // A slightly shorter copy holds its last frame instead of repeatedly seeking past its end.
        guard other.isFinite, position < end - 0.05, abs(other - position) > 0.08 else { return }
        lastCorrection = now
        originalSeek?.seek(to: position)
    }

    func play() {
        guard active, leader != nil else { return }
        wantsPlay = true
        if duration > 0, time >= duration - 0.05 {
            seek(to: 0) { [weak self] in
                guard let self, active, wantsPlay else { return }
                start()
            }
        } else {
            start()
        }
    }

    private func start() {
        guard let leader else { return }
        isPlaying = true
        if players.allSatisfy({ $0.currentItem?.status == .readyToPlay }) {
            let position = leader.currentTime()
            let host = CMTimeAdd(CMClockGetTime(CMClockGetHostTimeClock()), CMTime(seconds: 0.05, preferredTimescale: 600))
            for player in players { player.setRate(1, time: position, atHostTime: host) }
        } else {
            for player in players { player.play() }
        }
    }

    func pause() {
        wantsPlay = false
        resumeAfterScrub = false
        players.forEach { $0.pause() }
        isPlaying = false
        let position = leader?.currentTime().seconds ?? 0
        if position.isFinite {
            time = position
            originalSeek?.seek(to: position)
        }
    }

    func seek(to seconds: Double, finished: (() -> Void)? = nil) {
        guard seconds.isFinite else { return }
        time = min(max(0, seconds), duration > 0 ? duration : max(0, seconds))
        seekGeneration += 1
        let generation = seekGeneration
        var left = seekers.count
        guard left > 0 else { finished?(); return }
        for seeker in seekers {
            seeker.seek(to: time) { [weak self] in
                guard let self, generation == seekGeneration else { return }
                left -= 1
                if left == 0 { finished?() }
            }
        }
    }

    func beginScrub() {
        let playing = isPlaying
        pause()
        resumeAfterScrub = playing
        scrubbing = true
    }

    func scrub(to seconds: Double) { seek(to: seconds) }

    func endScrub() {
        scrubbing = false
        wantsPlay = resumeAfterScrub
        seek(to: time) { [weak self] in
            guard let self, active, wantsPlay else { return }
            start()
        }
    }

    func stop() {
        pause()
        active = false
        removeObservers()
        seekGeneration += 1
        seekers.forEach { $0.reset() }
        original = nil
        compact = nil
        originalSeek = nil
        compactSeek = nil
        time = 0
        duration = 0
    }

    private func removeObservers() {
        if let clock { clockPlayer?.removeTimeObserver(clock) }
        clock = nil
        clockPlayer = nil
        control?.invalidate()
        control = nil
        ready.forEach { $0.invalidate() }
        ready = []
        if let ended { NotificationCenter.default.removeObserver(ended) }
        ended = nil
    }

    isolated deinit {
        players.forEach { $0.pause() }
        removeObservers()
    }
}

struct CompareTransport: View {
    let pair: VideoPair
    var durationOverride: Double?

    var body: some View {
        let duration = durationOverride ?? pair.duration
        HStack(spacing: 10) {
            Button(pair.isPlaying ? "Pause both" : "Play both", systemImage: pair.isPlaying ? "pause.fill" : "play.fill") {
                pair.isPlaying ? pair.pause() : pair.play()
            }
            .labelStyle(.iconOnly)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityIdentifier("compare.play")
            Text(VideoTime.text(pair.time)).accessibilityHidden(true)
            Slider(value: Binding(get: { pair.time }, set: { pair.scrub(to: $0) }), in: 0...max(duration, 0.1),
                   onEditingChanged: { $0 ? pair.beginScrub() : pair.endScrub() })
                .accessibilityLabel("Position")
                .accessibilityValue("\(VideoTime.text(pair.time)) of \(VideoTime.text(duration))")
                .accessibilityIdentifier("compare.position")
            Text(VideoTime.text(duration)).accessibilityHidden(true)
            Button("Sound", systemImage: "speaker.wave.2") {
                pair.heard = pair.heard == .compact ? .original : .compact
            }
            .labelStyle(.iconOnly)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityValue(pair.heard == .compact ? "Compact copy" : "Original")
            .accessibilityIdentifier("compare.sound")
        }
        .font(.footnote.monospacedDigit())
        .padding(.horizontal, 16)
    }
}

struct LinkedZoomPlayer: UIViewRepresentable {
    var player: AVPlayer?
    var size: CGSize?
    let link: ZoomLink
    var label: String
    var identifier: String

    func makeUIView(context: Context) -> ZoomScrollView {
        let surface = PlayerSurface()
        surface.isAccessibilityElement = true
        surface.accessibilityTraits = .image
        let view = ZoomScrollView(content: surface)
        link.add(view)
        return view
    }

    func updateUIView(_ view: ZoomScrollView, context: Context) {
        guard let surface = view.content as? PlayerSurface else { return }
        surface.player = player
        view.aspect = size ?? .zero
        surface.accessibilityLabel = label
        surface.accessibilityIdentifier = identifier
    }

    static func dismantleUIView(_ view: ZoomScrollView, coordinator: ()) {
        (view.content as? PlayerSurface)?.player = nil
    }
}
