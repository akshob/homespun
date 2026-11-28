// SPDX-License-Identifier: Apache-2.0
import Foundation
import HomespunCore

/// A projection/facade over the one canonical backup database. Legacy JSON is a read-only migration
/// source; neither this facade nor an old adapter writes another ledger.
actor CompactLedger {
    struct Entry: Codable, Equatable, Sendable {
        var compactIdentifier: String
        var originalBytes: Int
        var compactBytes: Int
        var savedAt: Date
        var serverAssetID: String?
        var origin: BackupAPI.Origin?
        var version: BackupAPI.Version?
        var requestID: UUID?
        var bindingID: UUID?
        var operationID: UUID?
        var serverName: String?
        var compactResources: [ServerAPI.ResourceDescriptor]?
        var retention: BackupAPI.RetentionState?
        var externalVerification: BackupAPI.ExternalVerification?
        /// A current equivalent backup was checked; this does not identify the copy's maker.
        var revalidatedCopy: Bool?

        var verifiedCompact: Bool {
            origin != nil && version != nil && requestID != nil
                && (retention == .permanent || retention == .external && externalVerification == .fullResourceScrub)
                && originalBytes > 0 && compactBytes > 0 && compactResources?.isEmpty == false
        }
    }

    struct BackedUp: Codable, Equatable, Sendable {
        var serverAssetID: String
        var originalBytes: Int
        var backedUpAt: Date
        var kept: Bool?
        var origin: BackupAPI.Origin?
        var version: BackupAPI.Version?
        var requestID: UUID?
        var bindingID: UUID?
        var operationID: UUID?
    }

    static let compactEvery = 1_000
    nonisolated let store: BackupStore
    nonisolated let namespace: String
    private var cached: (revision: BackupStore.ProjectionRevision, projection: BackupStore.LedgerProjection)?

    static var defaultURL: URL { URL.applicationSupportDirectory.appendingPathComponent("Homespun/ledger.json") }

    init(url: URL = CompactLedger.defaultURL, namespace: String = "photos") {
        self.namespace = namespace
        store = BackupStore(directory: url.deletingLastPathComponent().appendingPathComponent("Backup", isDirectory: true),
                            legacyURL: url, namespace: namespace)
    }

    init(store: BackupStore, namespace: String = "photos") {
        self.store = store
        self.namespace = namespace
    }

    func snapshot() async throws -> [String: Entry] {
        try await projection().entries
    }

    func projection() async throws -> BackupStore.LedgerProjection {
        let started = ContinuousClock.now
        let signpost = PerfMonitor.signposter.beginInterval("LedgerProjection", id: PerfMonitor.signposter.makeSignpostID())
        var cacheHit = false
        var entries = 0
        defer {
            PerfMonitor.signposter.endInterval("LedgerProjection", signpost)
            if !cacheHit {
                let milliseconds = PerfMonitor.milliseconds(since: started)
                AppLog.app.info("launch LedgerProjection: \(milliseconds, privacy: .public) ms, \(entries, privacy: .public) entries")
            }
        }
        let revision = try await store.projectionRevision()
        if let cached, cached.revision == revision {
            cacheHit = true
            return cached.projection
        }
        let result = try await store.ledgerProjection(namespace: namespace)
        entries = result.entries.count
        cached = (revision, result)
        return result
    }

    func entry(for original: String) async throws -> Entry? { try await snapshot()[original] }
    func compactIdentifier(for original: String) async throws -> String? { try await entry(for: original)?.compactIdentifier }
    func isCompactCopy(_ identifier: String) async throws -> Bool {
        try await snapshot().values.contains { $0.compactIdentifier == identifier }
    }

    func serverBacked() async throws -> [(original: String, entry: Entry)] {
        try await snapshot().compactMap { $0.value.verifiedCompact ? (original: $0.key, entry: $0.value) : nil }
            .sorted { $0.entry.savedAt < $1.entry.savedAt }
    }

    func backedUpSnapshot() async throws -> [String: BackedUp] {
        try await projection().backedUp
    }

    func decisions() async throws -> Set<String> { try await store.keptDecisions(namespace: namespace) }

    func record(original: String, compact: String, originalBytes: Int, compactBytes: Int,
                serverAssetID: String? = nil) async throws {
        try await record([original: .init(compactIdentifier: compact, originalBytes: originalBytes,
                                         compactBytes: compactBytes, savedAt: Date(), serverAssetID: serverAssetID)])
    }

    func record(_ entries: [String: Entry], removing: [String] = []) async throws {
        try await store.recordLegacy(entries, removing: removing, namespace: namespace)
    }

    func recordBackedUp(original: String, serverAssetID: String, originalBytes: Int) async throws {
        try await store.recordLegacyBackedUp(
            [original: .init(serverAssetID: serverAssetID, originalBytes: originalBytes, backedUpAt: Date())],
            namespace: namespace)
    }

    func keepOriginals(_ items: [(original: String, serverAssetID: String, originalBytes: Int)]) async throws {
        let records = Dictionary(uniqueKeysWithValues: items.map {
            ($0.original, BackedUp(serverAssetID: $0.serverAssetID, originalBytes: $0.originalBytes, backedUpAt: Date(), kept: true))
        })
        try await store.recordLegacyBackedUp(records, namespace: namespace, removingMappings: items.map(\.original))
    }

    func restored(_ items: [(key: String, restored: String, entry: Entry)], copiesDeleted: Bool) async throws {
        if copiesDeleted {
            let kept = Dictionary(uniqueKeysWithValues: items.map {
                ($0.restored, BackedUp(serverAssetID: $0.entry.serverAssetID ?? "", originalBytes: $0.entry.originalBytes,
                                      backedUpAt: Date(), kept: true))
            })
            try await store.recordLegacyBackedUp(kept, namespace: namespace, removingMappings: items.map(\.key))
        } else {
            try await record(Dictionary(uniqueKeysWithValues: items.map { ($0.restored, $0.entry) }), removing: items.map(\.key))
        }
    }

    func forgetBackedUp(_ ids: [String]) async throws {
        try await store.forgetLegacyBackedUp(ids, namespace: namespace)
    }

    func compact() async throws { try await store.open() }
    static func elsewhere(_ compactIdentifier: String) -> String { "elsewhere:" + compactIdentifier }
}
