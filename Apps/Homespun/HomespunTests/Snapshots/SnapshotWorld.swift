// SPDX-License-Identifier: Apache-2.0
import Foundation
import HomespunCore
import SwiftUI
import Synchronization
@testable import Homespun

@MainActor
final class SnapshotWorld {
    static let now = Date(timeIntervalSince1970: 1_781_517_600)
    static let clock: AppClock = {
        let zone = TimeZone(secondsFromGMT: 0)!
        let fixed = now
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return AppClock(now: { fixed }, locale: Locale(identifier: "en_US"), calendar: calendar, timeZone: zone)
    }()

    let catalog: FixtureCatalog
    let stub: StubServer
    let model: AppModel
    let defaults: UserDefaults
    private let suite: String
    private let folder: URL
    var settings: AppSettings { model.settings }
    var library: LibraryController { model.library }
    var ledger: CompactLedger { model.job.ledger }

    init(count: Int = 96) async throws {
        suite = "photos.homespun.snapshots.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: "onboardingComplete")
        defaults.set(true, forKey: "trialConfirmed")
        folder = SnapshotEnvironment.results.deletingLastPathComponent()
            .appendingPathComponent("snapshot-state/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        catalog = FixtureCatalog(count: count)
        let jpeg = catalog.items[FixtureCatalog.original(72)]?.poster.jpegData(compressionQuality: 0.9) ?? Data()
        stub = try StubServer(now: Self.now, original: jpeg)
        defaults.set(StubServer.baseURL, forKey: "serverURL")
        defaults.set(try ServerAPI.encoder.encode(StubServer.info), forKey: "serverInfo")
        defaults.set("snapshot-device", forKey: "serverDeviceID")
        let tokens = SnapshotTokens()
        try tokens.setToken("synthetic-token", for: StubServer.baseURL.absoluteString)
        try tokens.setPins(StubServer.pins, for: StubServer.baseURL.absoluteString)
        let settings = AppSettings(
            defaults: defaults, photos: catalog, tokens: tokens, session: stub.session,
            verifyIdentity: { url, _ in .init(url: url, fingerprint: StubServer.fingerprint, systemTrusted: false) },
            locateServer: { _, _, _ in nil }, installationStore: SnapshotInstallation(), clock: Self.clock,
            initialServerStatus: .reachable)
        let ledger = CompactLedger(url: folder.appendingPathComponent("ledger.json"), now: Self.clock.now)
        let states: [String: CompactJob.State] = count == 0 ? [:] : [
            FixtureCatalog.original(81): .waiting,
            FixtureCatalog.original(82): .working("Uploading the original"),
            FixtureCatalog.original(83): .failed("Couldn't reach Sample Computer"),
            FixtureCatalog.original(84): .unchanged("Kept as is"),
            FixtureCatalog.original(85): .backedUp(originalBytes: 12_400_000),
        ]
        let job = CompactJob(settings: settings, ledger: ledger, initialStates: states)
        let premium = Premium(ownBuild: false, owned: { false }, testFlightWithoutProduct: { false }, listens: false)
        let automatic = AutomaticMode(url: folder.appendingPathComponent("automatic.json"), photos: catalog, system: false)
        let copyFinder = CopyFinder(url: folder.appendingPathComponent("copies.json"), photos: catalog)
        let history = RunHistory(url: folder.appendingPathComponent("history.json"), now: Self.clock.now, load: false)
        let library = LibraryController(settings: settings, job: job, premium: premium, automatic: automatic,
                                        copyFinder: copyFinder, clock: Self.clock, tips: false,
                                        phoneFreeSpace: { 48_000_000_000 })
        model = AppModel(parts: .init(settings: settings, job: job, premium: premium, automatic: automatic,
                                      copyFinder: copyFinder, history: history, library: library))
        var finished = false
        defer { if !finished { close() } }
        if count > 0 {
            var entries: [String: CompactLedger.Entry] = [:]
            for number in FixtureCatalog.ready + [FixtureCatalog.freed] where catalog.items[FixtureCatalog.compact(number)] != nil {
                entries[FixtureCatalog.original(number)] = .init(
                    compactIdentifier: FixtureCatalog.compact(number), originalBytes: 12_400_000, compactBytes: 2_300_000,
                    savedAt: Self.now.addingTimeInterval(-3_600), serverAssetID: StubServer.asset(number))
            }
            try await ledger.record(entries)
            try await ledger.recordBackedUp(original: FixtureCatalog.original(85),
                                             serverAssetID: StubServer.asset(85), originalBytes: 12_400_000)
            try await ledger.keepOriginals([(FixtureCatalog.original(84), StubServer.asset(84), 12_400_000)])
        }
        await library.library.reload()
        await library.refreshGrid()
        await library.refreshReady()
        guard let client = settings.client, try await client.info() == StubServer.info else {
            throw SnapshotFailure("Snapshot server did not finish its pinned health check")
        }
        finished = true
    }

    func setup(_ page: SetupFlow.Page) -> SetupFlow {
        settings.onboardingComplete = false
        let found = ServerDiscovery.Found(name: StubServer.info.name, url: StubServer.baseURL, options: StubServer.options)
        return SetupFlow(settings: settings, library: library, start: page,
                         discovery: ServerDiscovery(known: page == .looking ? [] : [found]),
                         returning: (StubServer.baseURL, "synthetic-token", StubServer.info, StubServer.pins),
                         autofocusFields: false)
    }

    func close() {
        stub.close()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: folder)
    }
}

private final class SnapshotTokens: TokenStore, @unchecked Sendable {
    private struct Values: Sendable {
        var tokens: [String: String] = [:]
        var pins: [String: ServerPins] = [:]
    }
    private let values = Mutex(Values())
    func token(for account: String) -> String? { values.withLock { $0.tokens[account] } }
    func setToken(_ token: String, for account: String) throws { values.withLock { $0.tokens[account] = token } }
    func removeToken(for account: String) { values.withLock { $0.tokens[account] = nil } }
    func pins(for account: String) -> ServerPins? { values.withLock { $0.pins[account] } }
    func setPins(_ pins: ServerPins, for account: String) throws { values.withLock { $0.pins[account] = pins } }
    func removePins(for account: String) { values.withLock { $0.pins[account] = nil } }
}

private struct SnapshotInstallation: InstallationStore {
    func load() throws -> DeviceInstallation { .init(id: "snapshot-device", name: "Sample iPhone") }
    func confirm(name: String) throws {}
}
