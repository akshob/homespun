// SPDX-License-Identifier: Apache-2.0
import Foundation
import os
import QuartzCore
import SwiftUI
import UIKit

/// Measures smoothness for the performance tests (launch argument `-perfMonitor YES`; off otherwise):
/// frames that took longer than one refresh while something scrolls, and how long interactions take
/// from the touch to the result (opening an item, switching a filter, Select All, a tab). The UI
/// tests read the totals from a hidden label (`perf.monitor`) and fail past their budgets. Every
/// interval is also an `OSSignposter` interval ("Homespun", category "Interactions"), so Instruments
/// and `XCTOSSignpostMetric` see them too.
@MainActor
final class PerfMonitor {
    static let shared = PerfMonitor()
    nonisolated static let signposter = OSSignposter(subsystem: "photos.homespun.app", category: "Interactions")

    let enabled = ProcessInfo.processInfo.arguments.contains("-perfMonitor")
        || UserDefaults.standard.bool(forKey: "perfMonitor")

    /// Something is scrolling (a grid, a list, the item pager); frames count only then, so the
    /// test runner's own pauses (it inspects the app between gestures) don't.
    private var scrolling = 0
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private(set) var frames = 0
    /// Frames that took longer than 1.5 refreshes, and the time lost to them.
    private(set) var hitches = 0
    private(set) var hitchTime: CFTimeInterval = 0
    private(set) var scrollTime: CFTimeInterval = 0
    private(set) var longestFrame: CFTimeInterval = 0
    /// Frames longer than 50 ms (a visible stutter): the tests compare counts before and after.
    private(set) var slowFrames = 0
    /// Grid cells on screen without their picture yet, and all grid cells on screen, summed over the
    /// frames counted (the grid answers `blankProbe`).
    private(set) var blankCells = 0
    private(set) var shownCells = 0
    var blankProbe: (() -> (blank: Int, shown: Int))?
    /// Other results (the autoscroll's phases), by name.
    private(set) var results: [String: Double] = [:]
    /// The latest duration of each interaction, in milliseconds, and the longest.
    private(set) var spans: [String: Double] = [:]
    private(set) var longestSpans: [String: Double] = [:]
    /// How many times each interaction was timed (two can take the same time).
    private(set) var spanCounts: [String: Int] = [:]
    private var open: [String: (start: CFTimeInterval, state: OSSignpostIntervalState)] = [:]
    /// Bumped on every change so the hidden label redraws.
    private(set) var version = 0
    var observers: [UUID: () -> Void] = [:]

    private init() {}

    // MARK: Frames

    func scrollBegan() {
        guard enabled else { return }
        scrolling += 1
        if link == nil {
            let link = CADisplayLink(target: Ticker(self), selector: #selector(Ticker.tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        last = 0
    }

    func scrollEnded() {
        guard enabled, scrolling > 0 else { return }
        scrolling -= 1
        if scrolling == 0 {
            last = 0
            changed()
        }
    }

    fileprivate func tick(_ link: CADisplayLink) {
        guard scrolling > 0 else {
            last = 0
            return
        }
        let now = link.timestamp
        let refresh = max(link.targetTimestamp - link.timestamp, 1.0 / 120)
        if last > 0 {
            let interval = now - last
            frames += 1
            scrollTime += interval
            longestFrame = max(longestFrame, interval)
            if interval > 0.050 { slowFrames += 1 }
            if interval > refresh * 1.5 {
                hitches += 1
                hitchTime += interval - refresh
            }
            if let probe = blankProbe?() {
                blankCells += probe.blank
                shownCells += probe.shown
            }
        }
        last = now
    }

    // MARK: Interactions

    /// Starts timing an interaction (a tap, a filter); `end` with the same name stops it.
    func begin(_ name: StaticString) {
        let key = "\(name)"
        guard open[key] == nil else { return }
        let state = Self.signposter.beginInterval(name, id: Self.signposter.makeSignpostID())
        open[key] = (CACurrentMediaTime(), state)
    }

    func end(_ name: StaticString) {
        let key = "\(name)"
        guard let started = open.removeValue(forKey: key) else { return }
        Self.signposter.endInterval(name, started.state)
        guard enabled else { return }
        let milliseconds = (CACurrentMediaTime() - started.start) * 1000
        spans[key] = milliseconds
        longestSpans[key] = max(longestSpans[key] ?? 0, milliseconds)
        spanCounts[key, default: 0] += 1
        changed()
    }

    /// Ends the span once the frame showing the result has been committed (the main queue runs
    /// again only after this run loop turn's layout and render commit).
    func endAfterFrame(_ name: StaticString) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.end(name) } }
    }

    /// Values for the tests that aren't spans (where the grid is, for one).
    func note(_ values: [String: Double]) {
        guard enabled else { return }
        results.merge(values) { $1 }
        changed()
    }

    /// Records a span measured elsewhere (launch, from the process's start).
    func record(_ name: String, milliseconds: Double) {
        guard enabled else { return }
        spans[name] = milliseconds
        longestSpans[name] = max(longestSpans[name] ?? 0, milliseconds)
        changed()
    }

    private func changed() {
        version += 1
        for observer in observers.values { observer() }
        // Also in a file, for measuring without the UI test runner (which turns accessibility on).
        try? Data(summary.utf8).write(to: URL.documentsDirectory.appendingPathComponent("perf-monitor.txt"))
    }

    /// `frames=…;hitches=…;hitchMs=…;scrollMs=…;longestMs=…;slowFrames=…;open=…;filter=…` for the tests.
    var summary: String {
        var parts = ["frames=\(frames)", "hitches=\(hitches)", String(format: "hitchMs=%.1f", hitchTime * 1000),
                     String(format: "scrollMs=%.0f", scrollTime * 1000), String(format: "longestMs=%.1f", longestFrame * 1000),
                     "slowFrames=\(slowFrames)", "blankCells=\(blankCells)", "shownCells=\(shownCells)"]
        for (name, value) in spans.sorted(by: { $0.key < $1.key }) {
            parts.append(String(format: "%@=%.1f", name, value))
            parts.append(String(format: "%@.max=%.1f", name, longestSpans[name] ?? value))
            parts.append("\(name).n=\(spanCounts[name] ?? 0)")
        }
        for (name, value) in results.sorted(by: { $0.key < $1.key }) { parts.append(String(format: "%@=%.1f", name, value)) }
        return parts.joined(separator: ";")
    }

    /// When the app's code started (after loading, which the simulator makes much slower than a phone).
    nonisolated(unsafe) static var mainStarted: CFTimeInterval = 0

    // MARK: Autoscroll

    /// `-perfAutoscroll`: once the grid shows, the app scrolls it by itself through these phases
    /// (points per second; negative is toward the top, the oldest items), without touches. The
    /// test runner's gestures make the app walk its accessibility tree on the main thread, which
    /// would be measured too; this measures the app alone. Each phase's hitch time per second,
    /// frames over 50 ms and longest frame go into `results` ("auto.slow.hitchMsPerS", …), then
    /// "autoscroll=1".
    static let autoscrollPhases: [(name: String, speed: CGFloat, seconds: Double)] = [
        ("slow", -400, 6), ("fast", -2_500, 6), ("faster", 6_000, 4), ("back", -1_200, 5),
    ]

    private var autoscrollStarted = false

    func startAutoscrollIfAsked() {
        guard enabled, ProcessInfo.processInfo.arguments.contains("-perfAutoscroll"), !autoscrollStarted else { return }
        autoscrollStarted = true
        Task {
            // The grid settles first (thumbnails of the first screen, and the test runner's checks
            // after launch, which walk the accessibility tree).
            try? await Task.sleep(for: .seconds(6))
            await autoscroll()
        }
    }

    private func autoscroll() async {
        guard let scrollView = Self.largestScrollView() else {
            results["autoscroll"] = -1
            return changed()
        }
        for phase in Self.autoscrollPhases {
            let before = (frames, hitchTime, scrollTime, slowFrames, blankCells, shownCells)
            longestFrame = 0
            scrollBegan()
            // One step per frame, like a finger: the offset the speed gives for the time that passed.
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                let start = CACurrentMediaTime()
                var last = start
                let stepper = FrameStepper { now in
                    let top = -scrollView.adjustedContentInset.top
                    let bottom = max(top, scrollView.contentSize.height - scrollView.bounds.height
                                     + scrollView.adjustedContentInset.bottom)
                    var offset = scrollView.contentOffset
                    offset.y = min(max(offset.y + phase.speed * (now - last), top), bottom)
                    scrollView.setContentOffset(offset, animated: false)
                    last = now
                    guard now - start >= phase.seconds else { return true }
                    done.resume()
                    return false
                }
                stepper.start()
            }
            scrollEnded()
            let seconds = scrollTime - before.2
            results["auto.\(phase.name).frames"] = Double(frames - before.0)
            results["auto.\(phase.name).hitchMsPerS"] = seconds > 0 ? (hitchTime - before.1) * 1000 / seconds : 0
            results["auto.\(phase.name).slowFrames"] = Double(slowFrames - before.3)
            results["auto.\(phase.name).longestMs"] = longestFrame * 1000
            let shown = shownCells - before.5
            results["auto.\(phase.name).blankPct"] = shown > 0 ? Double(blankCells - before.4) * 100 / Double(shown) : 0
            try? await Task.sleep(for: .seconds(1))
        }
        results["autoscroll"] = 1
        changed()
    }

    /// The scroll view with the most content on screen (the grid).
    private static func largestScrollView() -> UIScrollView? {
        var best: UIScrollView?
        func visit(_ view: UIView) {
            if let scroll = view as? UIScrollView, !scroll.isHidden, scroll.window != nil,
               scroll.contentSize.height > (best?.contentSize.height ?? 0) { best = scroll }
            view.subviews.forEach(visit)
        }
        for scene in UIApplication.shared.connectedScenes {
            for window in (scene as? UIWindowScene)?.windows ?? [] { visit(window) }
        }
        return best
    }

    /// Milliseconds since the process started (for launch spans).
    static var sinceProcessStart: Double {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0 else { return 0 }
        let start = info.kp_proc.p_un.__p_starttime
        let started = Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
        return (Date().timeIntervalSince1970 - started) * 1000
    }

    /// Calls `step` with each frame's time until it returns false.
    @MainActor private final class FrameStepper: NSObject {
        private let step: (CFTimeInterval) -> Bool
        private var link: CADisplayLink?

        init(_ step: @escaping (CFTimeInterval) -> Bool) { self.step = step }

        func start() {
            let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }

        @objc private func tick(_ link: CADisplayLink) {
            guard step(link.timestamp) else {
                link.invalidate()
                self.link = nil
                return
            }
        }
    }

    /// The display link's target (on the main run loop).
    @MainActor private final class Ticker: NSObject {
        weak var monitor: PerfMonitor?
        init(_ monitor: PerfMonitor) { self.monitor = monitor }
        @objc func tick(_ link: CADisplayLink) { monitor?.tick(link) }
    }
}

/// The monitor's totals in a hidden label the UI tests read (only with `-perfMonitor`).
struct PerfMonitorLabel: View {
    @State private var text = ""
    @State private var observer = UUID()

    var body: some View {
        if PerfMonitor.shared.enabled {
            Text(text)
                .font(.system(size: 1))
                .opacity(0.01)
                .frame(width: 1, height: 1)
                .accessibilityIdentifier("perf.monitor")
                .accessibilityLabel(text)
                .allowsHitTesting(false)
                .onAppear {
                    text = PerfMonitor.shared.summary
                    PerfMonitor.shared.observers[observer] = { text = PerfMonitor.shared.summary }
                }
                .onDisappear { PerfMonitor.shared.observers.removeValue(forKey: observer) }
        }
    }
}

extension View {
    /// Counts this scroll view's frames while it moves (for the performance tests).
    func perfScrollTracking() -> some View {
        onScrollPhaseChange { old, new in
            guard PerfMonitor.shared.enabled else { return }
            if old == .idle, new != .idle { PerfMonitor.shared.scrollBegan() }
            if old != .idle, new == .idle { PerfMonitor.shared.scrollEnded() }
        }
    }
}
