// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import HomespunCore
import Hummingbird

extension Catalog {
    /// Resolve whole resource identities, never a descriptor version inferred from a primary hash.
    /// Legacy associations establish only an equivalent backup available here now.
    func resolveBackupCopy(_ lookup: BackupAPI.CopyLookup) throws -> BackupAPI.CopyCandidate {
        try checkBackupOrigin(lookup.origin)
        let compact = try lookup.compact.validated()
        guard Validation.isSHA256(lookup.assetID) else { throw HTTPError(.badRequest) }
        let assetID = lookup.assetID.lowercased()
        var candidates: [String: BackupAPI.Manifest] = [:]
        var hasVersionedHash = false
        let rows = try database.query("""
            SELECT d.files_json, d.device_compresses_json, m.id, m.manifest_json, m.generation
            FROM backup_derivatives d JOIN backup_manifests m ON m.id = d.manifest_id
            WHERE m.asset_id = ? LIMIT 201
            """, [.text(assetID)])
        guard rows.count <= 200 else { throw Self.copyRecoveryRequired() }
        for row in rows {
            let files = try Self.backupDecode([ServerAPI.CompactResource].self, row["files_json"]!.string!)
            if files.contains(where: { file in compact.resources.contains { $0.sha256.lowercased() == file.sha256.lowercased() } }) {
                hasVersionedHash = true
            }
            let delegated = try Self.backupDecode([Role].self, row["device_compresses_json"]!.string!)
            let manifest = try Self.backupDecode(BackupAPI.Manifest.self, row["manifest_json"]!.string!)
            if delegated.isEmpty, manifest.kind == compact.kind, row["generation"]!.int! > 0,
               Self.copyResourcesMatch(compact.resources, files.map {
                   .init(role: $0.role, filename: $0.filename, size: $0.size, sha256: $0.sha256)
               }) {
                candidates[row["id"]!.string!] = manifest
            }
        }
        if candidates.count == 1, let manifest = candidates.values.first {
            return .init(origin: lookup.origin, manifest: manifest,
                         captureDate: try backupCaptureDate(manifest.identifier()))
        }
        guard candidates.isEmpty, !hasVersionedHash, let asset = try asset(assetID),
              asset.kind == compact.kind, !asset.purging, asset.trashedAt == nil else { throw Self.copyRecoveryRequired() }
        let roles: Set<Role> = switch asset.kind {
        case .photo: [.photo]
        case .video: [.video]
        case .livePhoto: [.photo, .pairedVideo]
        }
        guard Set(compact.resources.map(\.role)) == roles else { throw Self.copyRecoveryRequired() }
        for file in compact.resources {
            guard try database.query("""
                SELECT 1 FROM made_copies WHERE asset_id = ? AND role = ? AND sha256 = ?
                """, [.text(assetID), .text(file.role.rawValue), .text(file.sha256.lowercased())]).count == 1 else {
                throw Self.copyRecoveryRequired()
            }
        }
        // A legacy asset ID cannot disambiguate changed secondary originals or historical recipes.
        guard try database.query("SELECT 1 FROM resource_history WHERE asset_id = ? LIMIT 1", [.text(assetID)]).isEmpty else {
            throw Self.copyRecoveryRequired()
        }
        let originals = try resources(assetID)
        guard !originals.isEmpty, originals.allSatisfy({
            $0.state == .verified && $0.size > 0 && $0.receivedBytes == $0.size
                && ($0.storedPath != nil || $0.externalPath != nil)
        }) else { throw Self.copyRecoveryRequired() }
        let manifest = try BackupAPI.Manifest(kind: asset.kind, resources: originals.map {
            .init(role: $0.role, filename: $0.filename, size: $0.size, sha256: $0.sha256, sha1: $0.sha1)
        }).validated()
        let identity = try manifest.identifier()
        guard try database.query("SELECT id FROM backup_manifests WHERE asset_id = ? AND id != ? LIMIT 1",
                                 [.text(assetID), .text(identity)]).isEmpty else { throw Self.copyRecoveryRequired() }
        return .init(origin: lookup.origin, manifest: manifest, captureDate: Timestamp.date(asset.captureDate))
    }

    static func copyResourcesMatch(_ left: [ServerAPI.ResourceDescriptor], _ right: [ServerAPI.ResourceDescriptor]) -> Bool {
        !left.isEmpty && left.count == right.count && Set(left.map(\.role)).count == left.count
            && Set(right.map(\.role)).count == right.count && left.allSatisfy { file in
                right.contains { $0.role == file.role && $0.size == file.size && $0.sha256.lowercased() == file.sha256.lowercased() }
            }
    }

    static func copyRecoveryRequired() -> APIError {
        APIError(.conflict, code: "copy_recovery_required",
                 message: "The complete copy cannot be linked to one exact original version. Keep both items, reconnect the original archive, and run Find Compact Copies again.")
    }
}
