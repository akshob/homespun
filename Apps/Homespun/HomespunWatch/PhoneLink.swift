// SPDX-License-Identifier: Apache-2.0
import Foundation
import Observation
import WatchConnectivity
import WidgetKit

/// The latest snapshot from the iPhone, kept in the watch's App Group for its widgets.
@MainActor @Observable
final class WatchStatus {
    static let shared = WatchStatus()

    private(set) var snapshot: StatusSnapshot?
    /// When the snapshot the widgets last drew was written on the iPhone.
    @ObservationIgnored private var drawnUpdatedAt: Date?

    /// The widgets reload for the same facts only when the news is this much fresher ("Updated …").
    static let refreshAfter: TimeInterval = 15 * 60

    init(snapshot: StatusSnapshot? = StatusStore.read()) {
        self.snapshot = snapshot
        drawnUpdatedAt = snapshot?.updatedAt
    }

    func apply(_ new: StatusSnapshot) {
        // The application context and complication data can arrive out of order: the newest wins.
        if let snapshot, snapshot.updatedAt >= new.updatedAt { return }
        let facts = !new.sameFacts(as: snapshot)
        snapshot = new
        StatusStore.write(new)
        if facts || new.updatedAt.timeIntervalSince(drawnUpdatedAt ?? .distantPast) > Self.refreshAfter {
            drawnUpdatedAt = new.updatedAt
            WidgetCenter.shared.reloadTimelines(ofKind: StatusStore.widgetKind)
        }
    }
}

/// Receives the snapshot from the iPhone (application context and complication data).
final class PhoneLink: NSObject, WCSessionDelegate, Sendable {
    static let shared = PhoneLink()

    func activate() {
        guard WCSession.isSupported(), WCSession.default.activationState != .activated else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Waits (a little) for what the iPhone is still delivering, in a background task.
    func receivePending() async {
        activate()
        var waited = 0
        while waited < 20, WCSession.default.activationState != .activated || WCSession.default.hasContentPending {
            try? await Task.sleep(for: .milliseconds(250))
            waited += 1
        }
    }

    private func receive(_ values: [String: Any]) {
        guard let data = values["status"] as? Data, let snapshot = StatusStore.decode(data) else { return }
        Task { @MainActor in WatchStatus.shared.apply(snapshot) }
    }

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: (any Error)?) {
        receive(session.receivedApplicationContext)
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        receive(applicationContext)
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        receive(userInfo)
    }
}
