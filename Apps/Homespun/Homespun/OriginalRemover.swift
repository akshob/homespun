// SPDX-License-Identifier: Apache-2.0
import Foundation
import HomespunCore
import Photos

/// Removes originals whose copies the server holds, after checking everything again now:
/// the phone re-reads and hashes every resource, the server re-verifies its copies, and the
/// compact copy must still be in the library (`DeletionGate`). iOS then asks the user to
/// confirm, and removed items stay in Recently Deleted. Homespun never empties it.
struct OriginalRemover: Sendable {
    struct Report: Equatable, Sendable {
        var removed: [String] = []
        var freedBytes = 0
        var blocked: [String] = []
        var cancelled = false
    }

    let client: ServerClient
    let mode: ServerAPI.StorageMode
    let ledger: CompactLedger

    /// Originals still in the library that have a server copy and a compact copy on record.
    func candidates() async -> [(original: String, entry: CompactLedger.Entry)] {
        await ledger.serverBacked().filter { PhotoLibrary.asset($0.original) != nil }
    }

    /// Checks and removes eligible originals; `limit` caps how many (the first-time trial).
    func removeEligible(limit: Int? = nil, progress: @escaping @Sendable (String) -> Void) async throws -> Report {
        var report = Report()
        var approved: [(asset: PHAsset, name: String, bytes: Int)] = []
        let candidates = Array(await candidates().prefix(limit ?? .max))
        for (index, candidate) in candidates.enumerated() {
            guard let asset = PhotoLibrary.asset(candidate.original), let assetID = candidate.entry.serverAssetID else { continue }
            let name = PhotoLibrary.describe(candidate.original)?.name ?? "Item"
            progress("Checking \(index + 1) of \(candidates.count)")
            do {
                let work = try PhotoLibrary.workDirectory()
                defer { try? FileManager.default.removeItem(at: work) }
                let device = try await ServerCompactor.export(try ServerCompactor.resources(of: asset, mode: mode), to: work) { _ in }
                guard device.count == PHAssetResource.assetResources(for: asset).count else {
                    report.blocked.append("\(name): not every file of this item could be checked")
                    continue
                }
                let verification = try await client.verify(assetID)
                let decision = DeletionGate().evaluate(
                    deviceResources: device.map { .init(role: $0.role.rawValue, sha256: $0.descriptor.sha256, size: $0.descriptor.size) },
                    serverVerified: verification.resources.compactMap { resource in
                        guard resource.verified, let sha256 = resource.sha256, let size = resource.size else { return nil }
                        return .init(role: resource.role.rawValue, sha256: sha256, size: size)
                    },
                    compactImported: PhotoLibrary.asset(candidate.entry.compactIdentifier) != nil)
                switch decision {
                case .allowed: approved.append((asset, name, device.reduce(0) { $0 + $1.descriptor.size }))
                case .blocked(let reason): report.blocked.append("\(name): \(reason)")
                }
            } catch {
                report.blocked.append("\(name): \(error.localizedDescription)")
            }
        }
        guard !approved.isEmpty else { return report }

        progress("Waiting for your confirmation")
        let assets = approved.map(\.asset) as NSArray
        do {
            try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.deleteAssets(assets) }
        } catch let error as PHPhotosError where error.code == .userCancelled {
            report.cancelled = true
            return report
        }
        report.removed = approved.map(\.name)
        report.freedBytes = approved.reduce(0) { $0 + $1.bytes }
        return report
    }
}
