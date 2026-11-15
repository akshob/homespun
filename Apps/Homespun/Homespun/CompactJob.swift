// SPDX-License-Identifier: Apache-2.0
import Foundation
import Observation
import Photos
import UIKit

/// The queue of items the user picked, processed one at a time.
@MainActor @Observable
final class CompactJob {
    enum State: Equatable {
        case waiting
        case working(String)
        case saved(originalBytes: Int, compactBytes: Int)
        case unchanged(String)
        /// Not done yet for a reason that may pass; automatic mode tries again later.
        case notYet(String)
        case failed(String)

        /// The state without its message or sizes; enough for the grid's badges.
        var phase: Phase {
            switch self {
            case .waiting: .waiting
            case .working: .working
            case .saved: .saved
            case .unchanged: .unchanged
            case .notYet: .notYet
            case .failed: .failed
            }
        }
    }

    enum Phase: Equatable { case waiting, working, saved, unchanged, notYet, failed }

    struct Item: Identifiable {
        let id = UUID()
        let assetIdentifier: String
        var name: String
        var symbol: String
        var state: State
        var trigger: RunHistory.Trigger = .manual

        var isWorking: Bool { if case .working = state { true } else { false } }
        var isLive: Bool { symbol == PhotoLibrary.Kind.livePhoto.symbol }
    }

    private(set) var items: [Item] = []
    private(set) var isRunning = false
    /// Paused between items: the item being worked on finishes, the rest wait (Activity 2.1).
    private(set) var isPaused = false
    /// When the current run started, and its items in order (kept until the next run starts).
    private(set) var runStarted: Date?
    private var runIDs: [UUID] = []
    private var compactIDs: [UUID: String] = [:]
    /// Finished runs are recorded here for Activity › History.
    var history: RunHistory?
    let settings: AppSettings
    let ledger: CompactLedger

    init(settings: AppSettings, ledger: CompactLedger = CompactLedger()) {
        self.settings = settings
        self.ledger = ledger
    }

    /// The latest state of each item picked this session.
    var states: [String: State] {
        Dictionary(items.map { ($0.assetIdentifier, $0.state) }, uniquingKeysWith: { _, latest in latest })
    }

    var savedOriginalBytes: Int { items.reduce(0) { if case .saved(let o, _) = $1.state { $0 + o } else { $0 } } }
    var savedCompactBytes: Int { items.reduce(0) { if case .saved(_, let c) = $1.state { $0 + c } else { $0 } } }

    /// The items of the run in progress, or of the last run until the next one starts.
    var runItems: [Item] {
        let ids = Set(runIDs)
        return items.filter { ids.contains($0.id) }
    }

    /// Queues items oldest first, skipping any already waiting or working. One fetch for all of
    /// them, so selecting a whole library is quick; file names are filled in as each starts.
    /// Without a `trigger`, items picked during setup count as the first task, later ones as manual.
    func enqueue(_ assetIdentifiers: [String], trigger: RunHistory.Trigger? = nil) {
        let trigger = trigger ?? (settings.onboardingComplete ? .manual : .firstTask)
        var assets: [String: PHAsset] = [:]
        PHAsset.fetchAssets(withLocalIdentifiers: assetIdentifiers, options: nil).enumerateObjects { asset, _, _ in
            assets[asset.localIdentifier] = asset
        }
        let busy = Set(items.filter { $0.state == .waiting || $0.isWorking }.map(\.assetIdentifier))
        var added: [Item] = []
        for identifier in PhotoLibrary.chronological(assetIdentifiers, dates: assets.compactMapValues(\.creationDate))
        where !busy.contains(identifier) {
            guard let asset = assets[identifier], let kind = PhotoLibrary.kind(of: asset) else {
                added.append(Item(assetIdentifier: identifier, name: "Item", symbol: "questionmark.square",
                                  state: .failed(PhotoLibrary.Failure.notFound.localizedDescription), trigger: trigger))
                continue
            }
            let date = asset.creationDate?.formatted(date: .abbreviated, time: .shortened)
            added.append(Item(assetIdentifier: identifier, name: date.map { "\(kind.name), \($0)" } ?? kind.name,
                              symbol: kind.symbol, state: .waiting, trigger: trigger))
        }
        guard !added.isEmpty else { return }
        // A new run starts: Activity's Now card counts from here.
        if !isRunning {
            runIDs = []
            runStarted = Date()
        }
        items += added
        runIDs += added.map(\.id)
        if !isRunning {
            isRunning = true
            Task { await run() }
        }
    }

    /// Drops these items if they haven't started (when iOS ends a background run); an item
    /// being worked on finishes, and items the user queued are left alone.
    func stopWaiting(_ identifiers: Set<String>) {
        items.removeAll { $0.state == .waiting && identifiers.contains($0.assetIdentifier) }
    }

    /// Stops after the item being worked on: items waiting are dropped, and everything already
    /// backed up stays backed up.
    func stop() {
        items.removeAll { $0.state == .waiting }
        isPaused = false
    }

    func pause() {
        guard isRunning else { return }
        isPaused = true
        UIApplication.shared.isIdleTimerDisabled = false
        Announce.say("Paused.")
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        UIApplication.shared.isIdleTimerDisabled = true
    }

    func clearFinished() {
        items.removeAll { item in
            switch item.state {
            case .waiting, .working: false
            default: true
            }
        }
    }

    private func run() async {
        isRunning = true
        // Encoding stops if the phone locks; keep the screen on while working.
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            record()
            isPaused = false
            isRunning = false
            UIApplication.shared.isIdleTimerDisabled = false
        }
        if settings.usesServer { await settings.refreshServerInfo() }
        while true {
            while isPaused, items.contains(where: { $0.state == .waiting }) {
                try? await Task.sleep(for: .milliseconds(300))
            }
            guard let index = items.firstIndex(where: { $0.state == .waiting }) else { break }
            let id = items[index].id
            items[index].state = .working("Starting")
            if let name = PhotoLibrary.describe(items[index].assetIdentifier)?.name { items[index].name = name }
            let state: State
            do {
                guard let compactor = settings.compactor(ledger: ledger) else {
                    throw ServerClient.Failure(status: 0, message: "Connect your Homespun Server first.")
                }
                let outcome = try await compactor.compact(items[index].assetIdentifier) { [weak self] message in
                    Task { @MainActor in self?.report(message, for: id) }
                }
                switch outcome {
                case .saved(let copy, let original, let compact):
                    compactIDs[id] = copy
                    state = .saved(originalBytes: original, compactBytes: compact)
                case .unchanged(let reason): state = .unchanged(reason)
                case .notYet(let reason): state = .notYet(reason)
                }
            } catch {
                state = .failed(error.localizedDescription)
            }
            if let index = items.firstIndex(where: { $0.id == id }) { items[index].state = state }
        }
    }

    /// Adds the run that just ended to the history: its trigger is manual if anything in it was.
    private func record() {
        let finished = runItems
        guard let history, let started = runStarted, !finished.isEmpty else { return }
        let triggers = Set(finished.map(\.trigger))
        let trigger: RunHistory.Trigger = triggers.contains(.manual) ? .manual
            : triggers.contains(.firstTask) ? .firstTask : .automatic
        history.record(RunHistory.Run(kind: .backUp, trigger: trigger, start: started, end: Date(),
                                      items: finished.map { Self.historyItem($0, compactID: compactIDs[$0.id]) }))
        for item in finished { compactIDs[item.id] = nil }
    }

    static func historyItem(_ item: Item, compactID: String? = nil) -> RunHistory.Item {
        var entry = RunHistory.Item(id: item.id, assetID: item.assetIdentifier, name: item.name, live: item.isLive,
                                    result: .waiting)
        switch item.state {
        case .waiting, .working: break
        case .saved(let original, let compact):
            entry.result = .saved
            entry.originalBytes = original
            entry.compactBytes = compact
            entry.compactID = compactID
        case .unchanged(let reason):
            entry.result = .kept
            entry.reason = reason
        case .notYet(let reason):
            entry.result = .notYet
            entry.reason = reason
        case .failed(let reason):
            entry.result = .failed
            entry.reason = reason
        }
        return entry
    }

    private func report(_ message: String, for id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), case .working = items[index].state else { return }
        items[index].state = .working(message)
    }
}
