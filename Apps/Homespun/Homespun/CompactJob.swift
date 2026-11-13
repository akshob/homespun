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

        var isWorking: Bool { if case .working = state { true } else { false } }
    }

    private(set) var items: [Item] = []
    private(set) var isRunning = false
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

    /// Queues items oldest first, skipping any already waiting or working. One fetch for all of
    /// them, so selecting a whole library is quick; file names are filled in as each starts.
    func enqueue(_ assetIdentifiers: [String]) {
        var assets: [String: PHAsset] = [:]
        PHAsset.fetchAssets(withLocalIdentifiers: assetIdentifiers, options: nil).enumerateObjects { asset, _, _ in
            assets[asset.localIdentifier] = asset
        }
        let busy = Set(items.filter { $0.state == .waiting || $0.isWorking }.map(\.assetIdentifier))
        for identifier in PhotoLibrary.chronological(assetIdentifiers, dates: assets.compactMapValues(\.creationDate))
        where !busy.contains(identifier) {
            guard let asset = assets[identifier], let kind = PhotoLibrary.kind(of: asset) else {
                items.append(Item(assetIdentifier: identifier, name: "Item", symbol: "questionmark.square",
                                  state: .failed(PhotoLibrary.Failure.notFound.localizedDescription)))
                continue
            }
            let date = asset.creationDate?.formatted(date: .abbreviated, time: .shortened)
            items.append(Item(assetIdentifier: identifier, name: date.map { "\(kind.name), \($0)" } ?? kind.name,
                              symbol: kind.symbol, state: .waiting))
        }
        if !isRunning { Task { await run() } }
    }

    /// Drops these items if they haven't started (when iOS ends a background run); an item
    /// being worked on finishes, and items the user queued are left alone.
    func stopWaiting(_ identifiers: Set<String>) {
        items.removeAll { $0.state == .waiting && identifiers.contains($0.assetIdentifier) }
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
            isRunning = false
            UIApplication.shared.isIdleTimerDisabled = false
        }
        if settings.usesServer { await settings.refreshServerInfo() }
        while let index = items.firstIndex(where: { $0.state == .waiting }) {
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
                case .saved(_, let original, let compact): state = .saved(originalBytes: original, compactBytes: compact)
                case .unchanged(let reason): state = .unchanged(reason)
                case .notYet(let reason): state = .notYet(reason)
                }
            } catch {
                state = .failed(error.localizedDescription)
            }
            if let index = items.firstIndex(where: { $0.id == id }) { items[index].state = state }
        }
    }

    private func report(_ message: String, for id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), case .working = items[index].state else { return }
        items[index].state = .working(message)
    }
}
