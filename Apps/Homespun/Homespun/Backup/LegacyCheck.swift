// SPDX-License-Identifier: Apache-2.0
import Foundation
import HomespunCore
import Synchronization

/// Catalog observations for presentation only. These never supply a version, import proof or removal permission.
enum LegacyCheck {
    final class Generation: Sendable {
        private let value = Mutex(0)
        func invalidate() { value.withLock { $0 &+= 1 } }
        func authorization() -> @Sendable () -> Bool {
            let captured = value.withLock { $0 }
            return { [self] in value.withLock { $0 == captured } }
        }
    }

    static func scope(url: URL, pins: [ServerKeyFingerprint], token: String, consumer: String) -> String {
        Fingerprint.sha256(of: Data(("v1|" + url.absoluteString + "|"
            + pins.map(\.base64url).sorted().joined(separator: ",") + "|"
            + Fingerprint.sha256(of: Data(token.utf8)) + "|" + consumer).utf8))
    }
    static let maximumAge: TimeInterval = 7 * 24 * 60 * 60
    enum Failure: Error, Equatable { case serverChanged }

    struct Candidate: Equatable, Sendable {
        var item: String
        var asset: String
        var bytes: Int
        var role: ServerAPI.ResourceRole
        var compact: String?

        func matches(_ projection: BackupStore.LedgerProjection) -> Bool {
            if let compact {
                guard let entry = projection.entries[item], entry.origin == nil else { return false }
                return entry.serverAssetID?.lowercased() == asset && entry.originalBytes == bytes
                    && entry.compactIdentifier == compact
            }
            guard let entry = projection.backedUp[item], entry.origin == nil else { return false }
            return entry.serverAssetID.lowercased() == asset && entry.originalBytes == bytes
        }
    }

    struct Record: Equatable, Sendable {
        var candidate: Candidate
        var scope: String
        var origin: BackupAPI.Origin?
        var verified: Bool
        var checkedAt: Date

        func isCurrent(scope: String, origin: BackupAPI.Origin?, now: Date) -> Bool {
            let age = now.timeIntervalSince(checkedAt)
            return self.scope == scope && (self.origin == nil || origin == nil || self.origin == origin)
                && age >= 0 && age <= LegacyCheck.maximumAge
        }
    }

    static func candidates(_ projection: BackupStore.LedgerProjection,
                           role: (String) -> ServerAPI.ResourceRole?) -> [Candidate] {
        var result: [Candidate] = []
        for (item, entry) in projection.entries where entry.origin == nil {
            guard let asset = entry.serverAssetID, let primary = role(entry.compactIdentifier) ?? role(item) else { continue }
            result.append(.init(item: item, asset: asset.lowercased(), bytes: entry.originalBytes,
                                role: primary, compact: entry.compactIdentifier))
        }
        for (item, entry) in projection.backedUp where entry.origin == nil {
            guard let primary = role(item) else { continue }
            result.append(.init(item: item, asset: entry.serverAssetID.lowercased(), bytes: entry.originalBytes,
                                role: primary))
        }
        return result.filter { candidate in
            candidate.bytes > 0 && candidate.asset.utf8.count == 64
                && candidate.asset.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
                && (candidate.role == .photo || candidate.role == .video)
        }
    }

    static func pending(_ candidates: [Candidate], projection: BackupStore.LedgerProjection,
                        scope: String, origin: BackupAPI.Origin?, now: Date) -> [Candidate] {
        candidates.filter {
            guard let record = projection.legacyChecks[$0.item] else { return true }
            return record.candidate != $0 || !record.isCurrent(scope: scope, origin: origin, now: now)
        }
    }

    @MainActor static func run(_ candidates: [Candidate], ledger: CompactLedger, scope: String, origin: BackupAPI.Origin?,
                               lookup: CopyFinder.Lookup, current: @MainActor @Sendable () -> Bool,
                               authorized: @Sendable () -> Bool = { true },
                               serverOrigin: @Sendable () async throws -> BackupAPI.Origin? = { nil },
                               now: @Sendable () -> Date = { Date() }) async throws {
        try Task.checkCancellation()
        guard current() else { throw CancellationError() }
        if let origin, let actual = try await serverOrigin(), actual != origin { throw Failure.serverChanged }
        let grouped = Dictionary(grouping: candidates, by: \.asset)
        let hashes = grouped.keys.sorted()
        for start in stride(from: 0, to: hashes.count, by: ServerAPI.CopyLookupRequest.maximumCount) {
            try Task.checkCancellation()
            guard current() else { throw CancellationError() }
            let chunk = Array(hashes[start..<min(start + ServerAPI.CopyLookupRequest.maximumCount, hashes.count)])
            let matches = Dictionary(grouping: try await lookup(chunk), by: { $0.sha256.lowercased() })
            try Task.checkCancellation()
            guard current() else { throw CancellationError() }
            let checkedAt = now()
            let records = chunk.flatMap { hash in
                grouped[hash, default: []].map { candidate in
                    let verified = matches[hash, default: []].contains {
                        $0.isOriginal && $0.originalsVerified && $0.assetID.lowercased() == candidate.asset
                            && $0.role == candidate.role && $0.originalBytes == candidate.bytes
                    }
                    return Record(candidate: candidate, scope: scope, origin: origin,
                                  verified: verified, checkedAt: checkedAt)
                }
            }
            try await ledger.store.recordLegacyChecks(records, scope: scope, namespace: ledger.namespace,
                current: current, authorized: authorized)
        }
    }
}
