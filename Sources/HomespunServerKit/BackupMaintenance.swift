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
                    } catch is CancellationError { return }
                    catch { break }
                }
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }
}
