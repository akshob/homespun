// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import ServiceLifecycle

struct BackupMaintenance: Service {
    let catalog: Catalog
    let storage: Storage

    func run() async throws {
        await cancelWhenGracefulShutdown {
            while !Task.isCancelled {
                for id in (try? await catalog.backupStagingCleanup()) ?? [] {
                    do {
                        try await catalog.mutations.withClaim("v2-upload/" + id) {
                            let file = BackupPublication.partial(id, storage: storage)
                            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
                            try await catalog.backupStagingCleaned(id)
                        }
                        for path in (try? await catalog.externalCacheCleanup()) ?? [] {
                            if path.hasPrefix("cache/external-v2-"), let directory = storage.resolve(path) {
                                try? FileManager.default.removeItem(at: directory)
                            }
                        }
                    } catch is CancellationError { return }
                    catch { break }
                }
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }
}
