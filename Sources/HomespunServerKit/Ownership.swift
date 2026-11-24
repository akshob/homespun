// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Hummingbird
import Logging
import ServiceLifecycle
#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// Serving and offline imports share this advisory lock. Never unlink the lock file: another
/// process may already have it open. Pairing/device inspection does not take this lease.
final class ServerOwnership: @unchecked Sendable {
    struct Busy: Error, CustomStringConvertible {
        var description: String {
            "This catalog is in use by Homespun Server or an import. Stop it before running another server or an offline import."
        }
    }

    private let descriptor: Int32

    init(dataDirectory: URL) throws {
        let path = dataDirectory.appendingPathComponent("server.lock").path
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw Busy()
        }
        self.descriptor = descriptor
    }

    deinit { close(descriptor) }
}

/// In-process lock order: asset claim -> originals placement/read lease -> catalog transaction.
/// Root mutations never wait for asset claims. No catalog transaction spans an await.
actor AssetMutations {
    private var owners: [String: UUID] = [:]
    private(set) var waiting: [String: Int] = [:]

    func withClaim<T: Sendable>(_ asset: String, _ body: @Sendable () async throws -> T) async throws -> T {
        waiting[asset, default: 0] += 1
        do {
            while owners[asset] != nil { try await Task.sleep(for: .milliseconds(10)) }
        } catch {
            waiting[asset, default: 0] -= 1
            throw error
        }
        waiting[asset, default: 0] -= 1
        try Task.checkCancellation()
        let owner = UUID()
        owners[asset] = owner
        defer { if owners[asset] == owner { owners[asset] = nil } }
        return try await body()
    }
}

/// One service owns all workers, recovery, and their lifetime. The listener waits for recovery
/// before binding; workers cannot start early through Application's independent service tasks.
actor ServingStartup {
    private var result: Result<Void, any Error>?
    private var ownership: ServerOwnership?

    func complete(_ result: Result<Void, any Error>, ownership: ServerOwnership? = nil) {
        self.ownership = ownership
        self.result = result
    }

    func admit() throws -> ServerOwnership {
        guard let ownership else { throw HTTPError(.serviceUnavailable, message: "Homespun Server is starting or stopping.") }
        return ownership
    }

    func close() {
        ownership = nil
        result = .failure(CancellationError())
    }

    func wait() async throws {
        while result == nil { try await Task.sleep(for: .milliseconds(10)) }
        try result?.get()
    }
}

/// An admitted request keeps the file lease even if a worker fails and the listener has not
/// stopped yet. Closing admission rejects new work before the service drops its own lease.
struct ServingAdmission: RouterMiddleware {
    let startup: ServingStartup
    func handle(_ request: Request, context: HomespunRequestContext,
                next: (Request, HomespunRequestContext) async throws -> Response) async throws -> Response {
        let ownership = try await startup.admit()
        defer { withExtendedLifetime(ownership) {} }
        return try await next(request, context)
    }
}

struct OwnedServerServices: Service {
    let dataDirectory: URL
    let catalog: Catalog
    let originals: OriginalsStore
    let storage: Storage
    let mover: OriginalsMover
    let startup: ServingStartup
    let services: [any Service]
    let logger: Logger
    let immich: ImmichState

    func run() async throws {
        do {
            let ownership = try ServerOwnership(dataDirectory: dataDirectory)
            defer { withExtendedLifetime(ownership) {} }
            try await originals.refreshRoot(catalog: catalog)
            try await DeviceRename.recover(catalog: catalog, root: await originals.root)
            try await Trash(catalog: catalog, originals: originals, storage: storage).recover()
            try await BackupPublication.recover(catalog: catalog, storage: storage, originals: originals)
            try await catalog.assignMissingFolders()
            _ = try await catalog.backupOrigin()
            try await catalog.configureBackupExternal(await immich.backupBinding)
            try await catalog.releaseLeases()
            try await catalog.releaseBackupLeases()
            try await catalog.releaseBackupCopyLeases()
            try await catalog.releaseExternalBackupLeases()
            try await catalog.releaseBackupWakeLeases()
            try await BackupExternal.cleanupOrphans(catalog: catalog, storage: storage)
            await mover.resume()
            await startup.complete(.success(()), ownership: ownership)
            do {
                try await ServiceGroup(configuration: .init(services: services, logger: logger)).run()
            } catch {
                await startup.close()
                await mover.stop()
                throw error
            }
            await startup.close()
            await mover.stop()
        } catch {
            await startup.complete(.failure(error))
            throw error
        }
    }
}
