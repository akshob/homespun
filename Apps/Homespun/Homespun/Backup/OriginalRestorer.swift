// SPDX-License-Identifier: Apache-2.0
import Foundation
import HomespunCore
import Photos

/// Restore Original: brings originals that were freed up back from home into Photos, then deletes
/// their compact copies. Each original is checked twice: its files against the server's record as
/// they arrive, and again once Photos holds them. A compact copy is deleted only after both checks
/// pass (iOS asks once for the lot), and nothing on the server is ever deleted.
struct OriginalRestorer: Sendable {
    let client: ServerClient
    let ledger: CompactLedger

    /// A compact copy whose original is at home, not on this iPhone.
    struct Item: Sendable, Hashable {
        /// Its ledger key: the freed original's identifier, or `elsewhere:<copy>`.
        var key: String
        var compact: String
        var serverAssetID: String
        var originalBytes: Int
    }

    struct Progress: Sendable, Equatable {
        var done: Int
        var total: Int
        var message: String
    }

    struct Report: Sendable, Equatable {
        /// The restored originals' new identifiers.
        var restored: [String] = []
        var problems: [String] = []
        /// iOS asked to delete the compact copies and the person said no: both stay.
        var copiesKept = false
        var bytes = 0
    }

    struct Failure: LocalizedError {
        var errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// Whether this iPhone has room for `bytes` more, with 1 GB to spare; and how much is free.
    static func room(for bytes: Int) -> (enough: Bool, free: Int) {
        let values = try? URL.homeDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let free = values?.volumeAvailableCapacityForImportantUsage.map(Int.init) ?? Int.max
        return (free >= bytes + (1 << 30), free)
    }

    func restore(_ items: [Item], progress: @escaping @Sendable (Progress) -> Void) async -> Report {
        var report = Report()
        var done: [(item: Item, restored: String)] = []
        for (index, item) in items.enumerated() {
            guard !Task.isCancelled else { break }
            progress(Progress(done: index, total: items.count,
                              message: items.count == 1 ? "Getting the original" : "Getting original \(index + 1) of \(items.count)"))
            do {
                let restored = try await restoreOne(item)
                done.append((item, restored))
                report.restored.append(restored)
                report.bytes += item.originalBytes
            } catch {
                report.problems.append(error.localizedDescription)
            }
        }
        guard !done.isEmpty else { return report }
        // Every original is in Photos and checked: only now do the compact copies go.
        progress(Progress(done: done.count, total: items.count, message: "Waiting for your confirmation"))
        let copies = PHAsset.fetchAssets(withLocalIdentifiers: done.map(\.item.compact), options: nil)
        var deleted = true
        if copies.count > 0 {
            do {
                try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.deleteAssets(copies) }
            } catch {
                deleted = false
                report.copiesKept = true
            }
        }
        do {
            let entries = try await ledger.snapshot()
            try await ledger.restored(done.compactMap { pair in entries[pair.item.key].map { (pair.item.key, pair.restored, $0) } },
                                      copiesDeleted: deleted)
        } catch { report.problems.append("Photos changed, but recording the restored mapping failed: \(error.localizedDescription)") }
        return report
    }

    /// One original: downloaded and checked, added to Photos with the copy's favorite, hidden and
    /// albums, and checked again there. Returns its new identifier.
    private func restoreOne(_ item: Item) async throws -> String {
        let verification = try await client.verify(item.serverAssetID)
        guard !verification.resources.isEmpty, verification.resources.allSatisfy(\.verified) else {
            throw Failure("Its original isn't complete on the server, so it stays a compact copy.")
        }
        let work = try PhotoLibrary.workDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        var files: [(role: ServerAPI.ResourceRole, url: URL)] = []
        var expected: [ServerAPI.ResourceRole: String] = [:]
        for resource in verification.resources where PhotoLibrary.type(for: resource.role) != nil {
            guard let sha256 = resource.sha256 else { throw Failure("The server doesn't know this original's fingerprint.") }
            let url = try await client.downloadOriginalFile(assetID: item.serverAssetID, role: resource.role,
                                                            to: work.appendingPathComponent(resource.role.rawValue, isDirectory: true),
                                                            fallback: resource.role.rawValue)
            let received = try await Task.detached { try Fingerprint.sha256(of: url) }.value
            guard received == sha256 else { throw Failure("The original changed on the way. Try again.") }
            files.append((resource.role, url))
            expected[resource.role] = sha256
        }
        let copy = PhotoLibrary.asset(item.compact)
        let identifier = try await PhotoLibrary.restore(files, favorite: copy?.isFavorite ?? false, hidden: copy?.isHidden ?? false,
                                                        albums: copy.map(PhotoLibrary.userAlbums) ?? [],
                                                        metadata: .init(compact: copy))
        // What Photos holds now must be the server's original, byte for byte.
        guard let restored = PhotoLibrary.asset(identifier) else { throw Failure("Photos didn't keep the original.") }
        let check = try PhotoLibrary.workDirectory()
        defer { try? FileManager.default.removeItem(at: check) }
        let resources = PHAssetResource.assetResources(for: restored).filter { expected[PhotoLibrary.role(of: $0.type)] != nil }
        let held = try await ServerCompactor.export(resources, to: check) { _ in }
        let fingerprints = Dictionary(held.map { ($0.role, $0.descriptor.sha256) }, uniquingKeysWith: { first, _ in first })
        guard expected.allSatisfy({ fingerprints[$0.key] == $0.value }) else {
            throw Failure("Photos didn't keep the original exactly, so its compact copy stays.")
        }
        return identifier
    }
}
