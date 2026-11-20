// SPDX-License-Identifier: Apache-2.0
import Foundation
import Observation
import Synchronization
import UIKit

/// Try the Demo: Homespun with sample photos and a pretend server, "Homespun Demo", for anyone curious
/// (and App Review) without a server at home. The demo runs on a model of its own (`AppModel(demo:)`)
/// whose library changes (`DemoLibrary`), server (`DemoServer`), settings and records live in one folder
/// and one settings domain: the person's own photos, pairing, settings, records and analytics are never
/// touched. Leaving deletes the demo's state; its drawn media stays until the next cold launch.
@MainActor @Observable
final class DemoMode {
    static let shared = DemoMode()

    /// The demo's model while it's on.
    private(set) var model: AppModel?
    /// Just left: what the demo was in the middle of may still be finishing. Try the Demo waits until
    /// it has and the folder is deleted again, so a new demo never gets the last one's leftovers.
    private(set) var settling = false
    enum Preparation: Equatable {
        case drawing(DemoMediaStore.Progress?)
        case failed(DemoMediaStore.Failure)
    }
    enum Origin: Equatable { case tapped, launch }
    private(set) var preparation: Preparation?
    private(set) var origin: Origin?
    private var work: Task<Void, Never>?
    private var preparationID: UUID?
    private var background: UIBackgroundTaskIdentifier = .invalid
    private var memoryWarning: NSObjectProtocol?
    #if DEBUG
    private var holdNextPreparation = ProcessInfo.processInfo.arguments.contains("-holdDemoPreparation")
    private var heldPreparationID: UUID?
    private var heldCompletion: CheckedContinuation<Void, Never>?
    #endif

    nonisolated static let settingsName = "photos.homespun.demo"
    nonisolated static var folder: URL {
        URL.applicationSupportDirectory.appendingPathComponent("Homespun Demo", isDirectory: true)
    }
    nonisolated static var marker: URL { folder.appendingPathComponent("demo.json") }

    private init() {
        DemoMediaStore.purgeAtLaunch()
        memoryWarning = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                if case .drawing = self?.preparation { await DemoMediaStore.shared.lowerLimit() }
            }
        }
        #if DEBUG
        // UI tests start without a demo left by an earlier test.
        if ProcessInfo.processInfo.arguments.contains("-resetDemo") {
            Self.wipe()
            try? DemoReviewCodeStore.forget()
        }
        #endif
        // On when the app last closed: it carries on where it was. (Without its marker, the folder is
        // what a demo left was still writing as it ended.)
        if FileManager.default.fileExists(atPath: Self.marker.path) {
            prepare(origin: .launch)
        } else if FileManager.default.fileExists(atPath: Self.folder.path) {
            Self.wipe()
        }
        #if DEBUG
        // Screenshots where gestures can't reach the app (the open iPhone Duo) start in the demo.
        if ProcessInfo.processInfo.arguments.contains("-startDemo"), origin == nil { prepare(origin: .launch) }
        #endif
    }

    var isOn: Bool { model != nil }
    var isPreparing: Bool { preparation != nil }

    /// Starts afresh.
    func start() {
        guard model == nil, !settling, preparation == nil, origin == nil else { return }
        prepare(origin: .tapped)
    }

    private func prepare(origin: Origin, forceDraw: Bool = false) {
        self.origin = origin
        if origin == .launch { Telemetry.shared.paused = true }
        let id = UUID(), previous = work
        #if DEBUG
        if holdNextPreparation {
            holdNextPreparation = false
            heldPreparationID = id
        }
        #endif
        preparationID = id
        work = Task(priority: .userInitiated) {
            guard !Task.isCancelled, preparationID == id else { return }
            do {
                let ready = await DemoMediaStore.shared.readyFolder()
                try Task.checkCancellation()
                guard preparationID == id else { return }
                if let folder = ready, !forceDraw, DemoDownload.configured(folder: folder) == nil,
                   await DemoMediaStore.shared.manifest()?.source != "reviewer-v1" {
                    await previous?.value
                    try await finish(folder, origin: origin, id: id, drawnSince: nil)
                    return
                }
                preparation = .drawing(nil)
                let appeared = ContinuousClock.now
                Announce.say("Preparing the demo.")
                beginBackgroundTask(id: id)
                // Show the cover while a cancelled encoder releases its buffers, before retrying.
                await previous?.value
                try Task.checkCancellation()
                guard preparationID == id else { return }
                let folder = try await DemoMediaStore.shared.prepare(forceDraw: forceDraw) { [weak self] progress in
                    guard let self else { return }
                    await MainActor.run {
                        guard self.preparationID == id, case .drawing = self.preparation else { return }
                        self.preparation = .drawing(progress)
                    }
                }
                try Task.checkCancellation()
                try await finish(folder, origin: origin, id: id, drawnSince: appeared)
            } catch is CancellationError {
                // Cancel already removed the cover; partial media is available for a retry.
            } catch {
                guard preparationID == id else { return }
                let failure = (error as? DemoMediaStore.Failure) ?? .failed(String(describing: error))
                preparation = .failed(failure)
                endBackgroundTask()
                Announce.say(failure.title)
            }
        }
    }

    private func finish(_ folder: URL, origin: Origin, id: UUID, drawnSince: ContinuousClock.Instant?) async throws {
        #if DEBUG
        if heldPreparationID == id, drawnSince != nil {
            heldPreparationID = nil
            // A cancellation test must not race media completion while XCTest takes a snapshot.
            await withCheckedContinuation { heldCompletion = $0 }
        }
        if let drawnSince {
            let minimum = UserDefaults.standard.double(forKey: "demoPrepareMinimum")
            if minimum > 0 { try await Task.sleep(until: drawnSince.advanced(by: .seconds(minimum)), clock: .continuous) }
        }
        #endif
        try Task.checkCancellation()
        guard preparationID == id else { throw CancellationError() }
        let restarted = origin == .launch && !Self.canResume(media: folder, state: Self.folder)
        if origin == .tapped || restarted { Self.wipe() }
        begin(media: folder)
        preparation = nil
        self.origin = nil
        preparationID = nil
        endBackgroundTask()
        Announce.say(restarted
                     ? "The demo started again because its sample photos were prepared again. The demo is ready. Nothing on this iPhone is changed."
                     : "The demo is ready. Nothing on this iPhone is changed.")
    }

    nonisolated static func canResume(media: URL, state: URL) -> Bool {
        let decoder = JSONDecoder()
        guard let old = try? decoder.decode(DemoMediaManifest.self, from: Data(contentsOf: state.appendingPathComponent("media.json"))),
              let new = try? decoder.decode(DemoMediaManifest.self, from: Data(contentsOf: media.appendingPathComponent("manifest.json")))
        else { return false }
        return old.files.filter { !$0.key.hasPrefix("thumbs/") } == new.files.filter { !$0.key.hasPrefix("thumbs/") }
    }

    func cancel() {
        guard origin != nil, model == nil else { return }
        let wasLaunch = origin == .launch
        work?.cancel()
        #if DEBUG
        heldCompletion?.resume()
        heldCompletion = nil
        #endif
        preparationID = nil
        preparation = nil
        origin = nil
        endBackgroundTask()
        if wasLaunch {
            Self.wipe()
            Telemetry.shared.paused = false
        }
        Announce.say(wasLaunch ? "Left the demo." : "The demo didn't start.")
    }

    func retry() {
        guard case .failed = preparation else { return }
        preparation = .drawing(nil)
        prepare(origin: origin ?? .tapped)
    }

    func drawInstead() {
        guard let origin, case .drawing(let progress) = preparation, progress?.phase == .downloading else { return }
        work?.cancel()
        prepare(origin: origin, forceDraw: true)
    }

    private func beginBackgroundTask(id: UUID) {
        endBackgroundTask()
        background = UIApplication.shared.beginBackgroundTask(withName: "Preparing the demo") { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.preparationID == id else { return }
                self.endBackgroundTask()
            }
        }
    }

    private func endBackgroundTask() {
        guard background != .invalid else { return }
        UIApplication.shared.endBackgroundTask(background)
        background = .invalid
    }

    private func begin(media: URL) {
        let session = DemoSession(folder: Self.folder, defaults: UserDefaults(suiteName: Self.settingsName) ?? .standard, media: media)
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        try? Data("{\"started\":\"\(Date().ISO8601Format())\"}".utf8).write(to: Self.marker, options: .atomic)
        if let manifest = try? Data(contentsOf: media.appendingPathComponent("manifest.json")) {
            try? manifest.write(to: Self.folder.appendingPathComponent("media.json"), options: .atomic)
        }
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
        if model == nil, origin != nil { cancel(); return }
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
            if await DemoMediaStore.shared.manifest()?.source == "reviewer-v1" || DemoReviewCodeStore().read() != nil {
                try? await DemoMediaStore.shared.reset()
            }
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

    init(folder: URL, defaults: UserDefaults, pace: Double = 1, media: URL,
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
