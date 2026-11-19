// SPDX-License-Identifier: Apache-2.0
import Foundation

/// What the widgets and the Apple Watch show: written by the iPhone app into the App Group and sent
/// to the watch. Counts, sizes, dates and the server's name as the app shows it; never photos, file
/// names or the server's address.
struct StatusSnapshot: Codable, Equatable, Sendable {
    struct Ready: Codable, Equatable, Sendable {
        /// What freeing them up gives back on the iPhone.
        var bytes: Int
        var count: Int
    }

    struct Backup: Codable, Equatable, Sendable {
        var date: Date
        /// Items that went home in that backup.
        var count: Int
    }

    struct Server: Codable, Equatable, Sendable {
        var name: String
        var reachable: Bool
        /// When the iPhone last heard from it (or tried to).
        var checkedAt: Date?
    }

    struct Automatic: Codable, Equatable, Sendable {
        var enabled: Bool
        var lastRun: Date?
    }

    /// Premium (or a build that unlocks it): widgets show data only when unlocked.
    var unlocked: Bool
    var ready: Ready
    var lastBackup: Backup?
    /// Nil until a server is paired.
    var server: Server?
    var automatic: Automatic
    /// When the iPhone wrote it: the watch says how old it is.
    var updatedAt: Date
    /// Old snapshots have no marker. Demo facts must never become the person's cached status.
    var demo: Bool?

    /// The same facts, whenever they were written or checked: nothing worth redrawing a widget for.
    func sameFacts(as other: StatusSnapshot?) -> Bool {
        guard var other else { return false }
        other.updatedAt = updatedAt
        other.server?.checkedAt = server?.checkedAt
        return other == self
    }

    /// For the widget gallery before the app has written anything.
    static func sample(now: Date = Date()) -> StatusSnapshot {
        StatusSnapshot(unlocked: true, ready: Ready(bytes: 1_200_000_000, count: 48),
                       lastBackup: Backup(date: now.addingTimeInterval(-2 * 3600), count: 12),
                       server: Server(name: "Home Mac", reachable: true, checkedAt: now),
                       automatic: Automatic(enabled: true, lastRun: nil), updatedAt: now)
    }
}

/// The snapshot as a file in the App Group container, shared by the app and its widgets (on the
/// iPhone; on the watch, by the watch app and its widgets).
enum StatusStore {
    /// The widget's kind, for reloading it (the same on the iPhone and the watch).
    static let widgetKind = "photos.homespun.status"

    /// `group.<the app's bundle ID>`, from Info.plist (Debug builds have IDs of their own).
    static var groupID: String? { Bundle.main.object(forInfoDictionaryKey: "HomespunAppGroup") as? String }

    static var url: URL? {
        guard let groupID, let folder = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
        else { return nil }
        return folder.appendingPathComponent("status.json")
    }

    static func encode(_ snapshot: StatusSnapshot) -> Data? { try? JSONEncoder().encode(snapshot) }

    static func decode(_ data: Data) -> StatusSnapshot? { try? JSONDecoder().decode(StatusSnapshot.self, from: data) }

    static func read(from url: URL? = url) -> StatusSnapshot? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)
    }

    @discardableResult
    static func write(_ snapshot: StatusSnapshot, to url: URL? = url) -> Bool {
        guard let url, let data = encode(snapshot) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }
}

/// Where tapping a widget leads in the app: `homespun://<place>`.
enum AppLink: Equatable, Sendable {
    case freeUp, activity, server, automatic
    /// The unlock sheet for a Premium feature: `homespun://unlock?feature=widgets`.
    case unlock(feature: String)

    var url: URL {
        var parts = URLComponents()
        parts.scheme = "homespun"
        switch self {
        case .freeUp: parts.host = "free-up"
        case .activity: parts.host = "activity"
        case .server: parts.host = "server"
        case .automatic: parts.host = "automatic"
        case .unlock(let feature):
            parts.host = "unlock"
            parts.queryItems = [URLQueryItem(name: "feature", value: feature)]
        }
        return parts.url!
    }

    init?(_ url: URL) {
        guard url.scheme?.lowercased() == "homespun" else { return nil }
        switch url.host?.lowercased() {
        case "free-up": self = .freeUp
        case "activity": self = .activity
        case "server": self = .server
        case "automatic": self = .automatic
        case "unlock":
            let feature = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "feature" }?.value
            self = .unlock(feature: feature ?? "premium")
        default: return nil
        }
    }
}
