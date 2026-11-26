// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import HomespunCore
import Hummingbird
import ServiceLifecycle

/// A v1 reference is only a candidate, never a v2 proof. Freshly copy/hash it into an
/// immutable, durable local object before satisfying the versioned consumer.
struct BackupAdoption: Service {
    let catalog: Catalog
    let storage: Storage
    let originals: OriginalsStore
    let budget: ServerWorkBudget
    let configuration: ServerConfiguration
    var lane: String? = nil

    func run() async throws {
        await cancelWhenGracefulShutdown {
            while !Task.isCancelled {
                do {
                    if try await runNext() { continue }
                } catch is CancellationError {
                    if Task.isCancelled { return }
                } catch {}
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    @discardableResult
    func runNext() async throws -> Bool {
        guard let candidate = try await catalog.nextBackupAdoption(lane: lane) else { return false }
        try await adopt(candidate)
        return true
    }

    /// A bounded foreground recovery uses the same object lock, reservation, byte verification
    /// and publication as the worker. Already-published objects are never copied again.
    func retain(request: String, principal: String) async throws {
        let version = try await catalog.backupVersion(request, principal: principal)
        for object in try await catalog.backupObjects(version.manifestID) where object.path == nil {
            guard let source = try await catalog.legacyBackupSource(manifest: version.manifestID, role: object.role) else {
                throw HTTPError(.conflict, message: "An original is unavailable. Reconnect its archive and run Find Compact Copies again.")
            }
            try await adopt(.init(request: request, principal: principal, manifest: version.manifestID,
                                  role: object.role, sourceAsset: source.asset))
        }
    }

    private func adopt(_ candidate: BackupAdoptionCandidate) async throws {
        do {
            try await catalog.mutations.withClaim(candidate.sourceAsset) {
                try await catalog.retainBackupAdoptionSource(candidate)
                try await catalog.mutations.withClaim("v2-object/" + candidate.manifest + "/" + candidate.role.rawValue) {
                    guard try await catalog.backupObjects(candidate.manifest).first(where: { $0.role == candidate.role })?.path == nil else { return }
                    try await budget.run(.verification) {
                        let version = try await catalog.backupVersion(candidate.request, principal: candidate.principal)
                        let upload = try await catalog.createBackupUpload(.init(uploadID: UUID(),
                            requestID: UUID(uuidString: candidate.request)!, version: version, role: candidate.role),
                            principal: candidate.principal, staging: storage.staging, originalRoot: await originals.root,
                            maximumStaging: configuration.maximumStagingBytes, minimumFree: configuration.minimumFreeBytes)
                        do {
                            try await originals.place { root in
                                guard let source = try await catalog.legacyBackupSource(manifest: candidate.manifest, role: candidate.role),
                                      source.asset == candidate.sourceAsset else { throw HTTPError(.conflict) }
                                let input: URL
                                if let path = source.stored, let file = OriginalsStore.resolve(path, in: root) { input = file }
                                else if let external = source.external { input = URL(fileURLWithPath: external) }
                                else { throw HTTPError(.conflict) }
                                let target = BackupPublication.partial(upload.id, storage: storage)
                                let copied = try await detached { try Fingerprint.copy(from: input, to: target) }
                                guard copied.size == upload.object.size, copied.sha256 == upload.object.sha256 else {
                                    throw HTTPError(.conflict)
                                }
                                try BackupDurability.publish(target, root: storage.root)
                                try await catalog.advanceBackupUpload(upload, to: Int64(copied.size))
                                let complete = try await catalog.backupUpload(upload.id, principal: candidate.principal)
                                _ = try await BackupPublication.finish(complete, catalog: catalog, storage: storage, root: root)
                            }
                        } catch {
                            try await catalog.abandonInternalUpload(upload.id)
                            throw error
                        }
                    }
                }
            }
        } catch {
            try await catalog.postponeBackupAdoption(candidate)
            throw error
        }
    }
}
