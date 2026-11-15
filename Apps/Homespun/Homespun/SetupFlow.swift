// SPDX-License-Identifier: Apache-2.0
import Foundation
import HomespunCore
import Observation
import Photos
import Security
import SwiftUI

/// Where setup is, and what it has learned so far (DESIGN 01, §5 "First run"): the pages pushed so
/// far, the servers found, the answers to "What do you have at home?", the pairing, and the first
/// task. One per setup, shared by its pages.
@MainActor @Observable
final class SetupFlow {
    enum Page: Hashable {
        case welcome, welcomeBack
        case localNetwork, looking, found, question, recommendation
        case notShowingUp, noneOfThese, splitRole
        case guide(SetupAdvisor.Guide), terminalSteps(ServerSetup.OperatingSystem), nasGuide(NASBrand)
        case waiting(SetupAdvisor.Machine)
        case pair(PairTarget), otherWays, address
        case ready, immich, immichConnect, immichExclude, immichReady
        case analytics, photos, limitedPhotos
        case estimate, firstTask, receipt, freed
    }

    /// A server to pair with: found on the network, typed, or from a link.
    struct PairTarget: Hashable, Identifiable {
        var url: URL
        var name: String?
        /// Found on this Wi‑Fi.
        var discovered = false
        /// The new server the Waiting page was looking for (Ready then says "Paired with …", 3.5).
        var waitedFor = false
        var id: String { url.absoluteString }

        var address: String { url.host.map { "\($0):\(url.port ?? 8787)" } ?? url.absoluteString }
        var displayName: String { name ?? url.host ?? "the server" }
    }

    /// How this iPhone got paired, for the words on the Ready page.
    enum Pairing: Equatable { case discovered, typed, link, waited, returning }

    let settings: AppSettings
    let library: LibraryController?
    /// Opened from the Library's Set Up notice (or the Server tab) rather than on first launch.
    let isSheet: Bool
    /// Ends once paired and checked (the Server tab's Connect); no first task.
    let pairOnly: Bool
    var path: [Page] = []
    private(set) var root: Page
    let discovery = ServerDiscovery()
    /// Kept on Back (L6).
    var answers = Set<SetupAdvisor.Answer>()
    /// "I already use Immich" was chosen, so Immich mode follows pairing (01·5.1).
    var usesImmich = false
    private(set) var pairing: Pairing?
    /// Set by the hosting view: closes setup (sheet) after `settings.onboardingComplete` is set.
    var close: () -> Void = {}
    var onPaired: (() -> Void)?
    /// A pairing link pasted or scanned in setup, to confirm (6.5). Links opened from other apps
    /// arrive as `settings.pendingLink`.
    var link: PairingLink?

    /// When looking started, for "Still looking…" at 5 s and the question at 10 s (DI-S, DI-0).
    private(set) var lookingSince: Date?
    private(set) var stillLooking = false
    /// Looking moves on by itself only once; Back to it stays there (the list keeps updating).
    private(set) var advanced = false
    private var lookingTask: Task<Void, Never>?

    /// A Keychain token from an earlier install that still works (01·6.9).
    private(set) var returning: (url: URL, token: String, server: ServerAPI.ServerInfo)?
    /// Set Up Something Else was chosen: Welcome stays.
    private var declinedReturning = false

    /// The first task (01·1.10–1.15): the items it backs up, newest first.
    var taskIDs: [String] = []
    /// Everything not backed up yet, newest first (Back Up the Rest).
    var notBackedUp: [String] = []
    var freed: OriginalRemover.Report?
    var taskStarted: Date?
    var taskFinished: Date?
    var estimate: FirstTask.Estimate?

    /// The Local Network promises were shown and Continue tapped; later looks skip them (1.2).
    private var localNetworkExplained: Bool {
        get { UserDefaults.standard.bool(forKey: "setup.localNetworkExplained") }
        set { UserDefaults.standard.set(newValue, forKey: "setup.localNetworkExplained") }
    }

    init(settings: AppSettings, library: LibraryController?, start: Page? = nil, pairOnly: Bool = false) {
        self.settings = settings
        self.library = library
        self.pairOnly = pairOnly
        isSheet = settings.onboardingComplete || pairOnly
        root = start ?? (settings.onboardingComplete ? .localNetwork : .welcome)
        if root == .localNetwork, localNetworkExplained { root = .looking }
    }

    var serverName: String { settings.server?.name ?? "your computer" }

    // MARK: Moving between pages

    func go(_ page: Page) {
        path.append(page)
        Telemetry.shared.record(.setupStep(page.analyticsName))
    }

    /// Find My Home Computer: the promises page once, then looking (1.2 → 1.4).
    func findHomeComputer() {
        go(localNetworkExplained ? .looking : .localNetwork)
    }

    /// Continue on the Local Network promises: looking starts the browse, which shows the alert.
    func localNetworkContinue() {
        localNetworkExplained = true
        if root == .localNetwork, path.isEmpty {
            root = .looking
        } else {
            path.removeAll { $0 == .localNetwork }
            go(.looking)
        }
    }

    /// The page on top.
    var current: Page { path.last ?? root }

    /// Setup ends: unpaired with Set Up Later, or after the first task.
    func finish() {
        stop()
        if !pairOnly {
            Telemetry.shared.record(.setupDone(current == .freed ? "freed" : settings.isPaired ? "paired" : "later"))
        }
        if pairOnly, settings.isPaired { onPaired?() }
        settings.onboardingComplete = true
        close()
    }

    // MARK: Looking (01·1.4, 8.1, 3.2, 6.1)

    /// Runs while the Looking page is up: recommends once results settle (6 s, or 2 s with
    /// nothing new), says "Still looking…" at 5 s, and asks at 10 s. Looking goes on after.
    func look() {
        discovery.start()
        guard lookingTask == nil, !advanced else { return }
        let started = Date()
        lookingSince = started
        stillLooking = false
        lookingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, self.current == .looking else { break }
                let now = Date(), elapsed = now.timeIntervalSince(started)
                let ready = self.discovery.ready
                let pending = self.discovery.servers.contains { !$0.isReady && !$0.unreachable }
                if !ready.isEmpty, (!pending && now.timeIntervalSince(self.discovery.lastChange) >= 2) || elapsed >= 6 {
                    self.advanced = true
                    self.go(.found)
                    break
                }
                if ready.isEmpty, !self.discovery.blocked {
                    if elapsed >= 5, !self.stillLooking {
                        self.stillLooking = true
                        Announce.say("Still looking")
                    }
                    if elapsed >= 10 {
                        self.advanced = true
                        self.go(.question)
                        break
                    }
                }
            }
            // A task cancelled by Look Again leaves the new task's handle alone.
            if !Task.isCancelled { self?.lookingTask = nil }
        }
    }

    /// Setup closed (Close, a swipe, or done): stop looking.
    func stop() {
        lookingTask?.cancel()
        lookingTask = nil
        discovery.stop()
    }

    /// Look Again (3.1), or back from Settings with Local Network on (6.1).
    func lookAgain() {
        lookingTask?.cancel()
        lookingTask = nil
        advanced = false
        discovery.restart()
        if root == .looking {
            path = []
        } else if let index = path.firstIndex(of: .looking) {
            path.removeSubrange((index + 1)...)
        } else {
            go(.looking)
        }
        look()
    }

    var foundAdvice: SetupAdvisor.FoundAdvice? {
        SetupAdvisor.advise(found: discovery.ready.map(\.advisorServer))
    }

    func target(for id: String) -> PairTarget? {
        guard let found = discovery.found(id), let url = found.url else { return nil }
        return PairTarget(url: url, name: found.options?.serverName ?? found.name, discovered: true)
    }

    func options(for target: PairTarget) -> ServerAPI.PairingOptions? {
        discovery.servers.first { $0.url == target.url }?.options
    }

    // MARK: Answers (01·3.2)

    var answerAdvice: SetupAdvisor.Next { SetupAdvisor.advise(answers: answers) }

    func continueWithAnswers() {
        Telemetry.shared.record(.setupChoice("have", answers.map(\.rawValue).sorted().joined(separator: "+")))
        switch answerAdvice {
        case .ask: break
        case .noneOfThese: go(.noneOfThese)
        case .recommend(let advice):
            usesImmich = advice.usesImmich
            go(.recommendation)
        }
    }

    // MARK: Pairing

    /// Paired: Immich first if it was chosen, then Ready (the pages before can't be gone back to).
    func paired(_ how: Pairing) {
        pairing = how
        stop()
        Telemetry.shared.record(.pairResult(method: String(describing: how), error: nil))
        if let info = settings.server { Telemetry.shared.recordServerInfoDaily(info) }
        path = [usesImmich && !pairOnly ? .immich : .ready]
    }

    /// Lists Keychain tokens left by an earlier install, and keeps the first that still works.
    func checkReturning() async {
        guard !settings.isPaired, returning == nil, !declinedReturning, root == .welcome else { return }
        for account in Self.keychainServers() {
            guard let url = URL(string: account), let token = Keychain.token(for: account) else { continue }
            var client = ServerClient(baseURL: url, token: token)
            client.timeout = 3
            if let info = try? await client.info() {
                returning = (url, token, info)
                withAnimation { root = .welcomeBack }
                return
            }
        }
    }

    var returningName: String { returning?.server.name ?? "your server" }

    func reconnect() throws {
        guard let returning else { return }
        try settings.finishPairing(serverURL: returning.url, response: .init(deviceID: "", token: returning.token,
                                                                            server: returning.server))
        paired(.returning)
    }

    func setUpSomethingElse() {
        declinedReturning = true
        returning = nil
        withAnimation { root = .welcome }
    }

    /// Servers with a token in the Keychain (the same items `Keychain` keeps).
    private static func keychainServers() -> [String] {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: "photos.homespun.server-token",
                                      kSecReturnAttributes: true, kSecMatchLimit: kSecMatchLimitAll]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    // MARK: After pairing

    /// See What You Can Free Up: sharing analytics (asked once), then the Photos promises if access
    /// isn't decided, else the estimate.
    func afterReady() {
        if pairOnly {
            finish()
            return
        }
        if Telemetry.shared.consent == .unasked {
            go(.analytics)
            return
        }
        toPhotos()
    }

    func afterAnalytics(sharing: Bool) {
        Telemetry.shared.setSharing(sharing)
        toPhotos()
    }

    private func toPhotos() {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized: go(.estimate)
        case .notDetermined: go(.photos)
        default: go(.limitedPhotos)
        }
    }

    func afterPhotos(_ status: PHAuthorizationStatus) {
        if status == .authorized {
            go(.estimate)
        } else {
            go(.limitedPhotos)
        }
    }
}

/// NAS brands with their own guide (01·4.2): the same Docker image, each brand's click path.
enum NASBrand: String, Hashable, CaseIterable, Identifiable {
    case synology, qnap, ugreen, truenas, unraid, asustor, terramaster, other
    var id: String { rawValue }

    var name: String {
        switch self {
        case .synology: "Synology"
        case .qnap: "QNAP"
        case .ugreen: "UGREEN"
        case .truenas: "TrueNAS"
        case .unraid: "Unraid"
        case .asustor: "Asustor"
        case .terramaster: "TerraMaster"
        case .other: "Other (Docker)"
        }
    }
}

extension SetupFlow.Page {
    /// The page for analytics: its case, plus a plain choice (`guide.mac`, `nas.synology`). Values
    /// that aren't simple enum cases (a pairing target holds an address) are never included.
    var analyticsName: String {
        guard let child = Mirror(reflecting: self).children.first, let label = child.label else { return String(describing: self) }
        if let raw = (child.value as? any RawRepresentable)?.rawValue as? String { return "\(label).\(raw)" }
        let inner = Mirror(reflecting: child.value)
        if inner.displayStyle == .enum, inner.children.isEmpty { return "\(label).\(child.value)" }
        return label
    }
}
