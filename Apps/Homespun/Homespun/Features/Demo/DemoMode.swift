// SPDX-License-Identifier: Apache-2.0
import Foundation
import Observation
import Synchronization
import UIKit

/// Try the Demo: Homespun with sample photos and a pretend server, "Homespun Demo", for anyone curious
/// (and App Review) without a server at home. The demo runs on a model of its own (`AppModel(demo:)`)
/// whose photos (`DemoLibrary`), server (`DemoServer`), settings and records all live in one folder and
/// one settings domain: the person's own photos, pairing, settings, records and analytics are never
/// touched. Leave the Demo deletes both, so nothing is left behind.
@MainActor @Observable
final class DemoMode {
    static let shared = DemoMode()

    /// The demo's model while it's on.
    private(set) var model: AppModel?
    /// Just left: what the demo was in the middle of may still be finishing. Try the Demo waits until
    /// it has and the folder is deleted again, so a new demo never gets the last one's leftovers.
    private(set) var settling = false

    nonisolated static let settingsName = "photos.homespun.demo"
    nonisolated static var folder: URL {
        URL.applicationSupportDirectory.appendingPathComponent("Homespun Demo", isDirectory: true)
    }
    nonisolated static var marker: URL { folder.appendingPathComponent("demo.json") }

    private init() {
        #if DEBUG
        // UI tests start without a demo left by an earlier test.
        if ProcessInfo.processInfo.arguments.contains("-resetDemo") { Self.wipe() }
        #endif
        // On when the app last closed: it carries on where it was. (Without its marker, the folder is
        // what a demo left was still writing as it ended.)
        if FileManager.default.fileExists(atPath: Self.marker.path) {
            begin()
        } else if FileManager.default.fileExists(atPath: Self.folder.path) {
            Self.wipe()
        }
        #if DEBUG
        // Screenshots where gestures can't reach the app (the open iPhone Duo) start in the demo.
        if ProcessInfo.processInfo.arguments.contains("-startDemo"), model == nil { begin() }
        #endif
    }

    var isOn: Bool { model != nil }

    /// Starts afresh.
    func start() {
        guard model == nil, !settling else { return }
        Self.wipe()
        begin()
        Announce.say("The demo is on. Nothing on this iPhone is changed.")
    }

    private func begin() {
        let session = DemoSession(folder: Self.folder, defaults: UserDefaults(suiteName: Self.settingsName) ?? .standard)
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        try? Data("{\"started\":\"\(Date().ISO8601Format())\"}".utf8).write(to: Self.marker, options: .atomic)
        DemoServer.running.withLock { $0 = session.server }
        // Setup's pages reach the server through the shared session.
        URLProtocol.registerClass(DemoURLProtocol.self)
        Telemetry.shared.paused = true
        let own = AppModel.shared
        let model = AppModel(demo: session, premium: own.premium, status: own.status)
        self.model = model
        own.status?.showDemo(model)
    }

    /// Ends the demo: what it was doing stops, and everything it kept is deleted.
    func leave() {
        guard let model else { return }
        model.job.stop()
        model.library.stopRestoring()
        model.copyFinder.stop()
        AppModel.shared.status?.showDemo(nil)
        self.model = nil
        DemoServer.running.withLock { $0 = nil }
        URLProtocol.unregisterClass(DemoURLProtocol.self)
        Telemetry.shared.paused = false
        DemoPictures.forget()
        Self.wipe()
        // Again once anything it was in the middle of has stopped writing.
        settling = true
        Task {
            try? await Task.sleep(for: .seconds(3))
            Self.wipe()
            DemoMode.shared.settling = false
        }
        Announce.say("Left the demo.")
    }

    /// Deletes the demo's folder and settings.
    nonisolated static func wipe() {
        try? FileManager.default.removeItem(at: folder)
        UserDefaults.standard.removePersistentDomain(forName: settingsName)
    }
}

/// What a demo runs on: its folder, its own settings, its sample library and its pretend server.
final class DemoSession: Sendable {
    let folder: URL
    nonisolated(unsafe) let defaults: UserDefaults
    let library: DemoLibrary
    let server: DemoServer
    let tokens: DemoTokens

    init(folder: URL, defaults: UserDefaults, pace: Double = 1, media: URL = DemoSample.folder,
         ask: @escaping @Sendable (DemoLibrary.Question) async -> Bool = { await DemoPrompt.ask($0) }) {
        self.folder = folder
        self.defaults = defaults
        library = DemoLibrary(folder: folder.appendingPathComponent("library", isDirectory: true), media: media, ask: ask)
        let library = library
        server = DemoServer(folder: folder.appendingPathComponent("server", isDirectory: true), pace: pace) {
            library.bundledCompact(sha256: $0)
        }
        tokens = DemoTokens(defaults: defaults)
    }
}

/// The pretend server's token, kept with the demo's settings (never in the Keychain).
struct DemoTokens: TokenStore, @unchecked Sendable {
    let defaults: UserDefaults

    func token(for server: String) -> String? { (defaults.dictionary(forKey: "demo.tokens") as? [String: String])?[server] }

    func setToken(_ token: String, for server: String) throws {
        var tokens = (defaults.dictionary(forKey: "demo.tokens") as? [String: String]) ?? [:]
        tokens[server] = token
        defaults.set(tokens, forKey: "demo.tokens")
    }

    func removeToken(for server: String) {
        var tokens = (defaults.dictionary(forKey: "demo.tokens") as? [String: String]) ?? [:]
        tokens[server] = nil
        defaults.set(tokens, forKey: "demo.tokens")
    }

    func pins(for server: String) -> ServerPins? {
        guard let data = (defaults.dictionary(forKey: "demo.pins") as? [String: Data])?[server] else { return nil }
        return try? JSONDecoder().decode(ServerPins.self, from: data)
    }

    func setPins(_ pins: ServerPins, for server: String) throws {
        var saved = (defaults.dictionary(forKey: "demo.pins") as? [String: Data]) ?? [:]
        saved[server] = try JSONEncoder().encode(pins)
        defaults.set(saved, forKey: "demo.pins")
    }

    func removePins(for server: String) {
        var saved = (defaults.dictionary(forKey: "demo.pins") as? [String: Data]) ?? [:]
        saved[server] = nil
        defaults.set(saved, forKey: "demo.pins")
    }
}

/// The demo's stand-in for the question iOS asks before deleting: its own words (so it never passes
/// for iOS's), saying it's pretend, above everything on screen (sheets included), as iOS's is.
@MainActor
enum DemoPrompt {
    private static var window: UIWindow?

    static func ask(_ question: DemoLibrary.Question) async -> Bool {
        guard window == nil, let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) ?? UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first else { return false }
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.backgroundColor = .clear
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        Self.window = window
        let allowed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let alert = UIAlertController(title: question.title, message: question.message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Don't Allow", style: .cancel) { _ in continuation.resume(returning: false) })
            alert.addAction(UIAlertAction(title: question.confirm, style: .destructive) { _ in continuation.resume(returning: true) })
            window.rootViewController?.present(alert, animated: true)
        }
        window.isHidden = true
        Self.window = nil
        previous?.makeKey()
        return allowed
    }
}
