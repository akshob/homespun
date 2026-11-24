// SPDX-License-Identifier: Apache-2.0
import Foundation
import HomespunCore
import Photos

// The demo's backing up, freeing up and restoring: the same steps as `ServerCompactor`,
// `OriginalRemover` and `OriginalRestorer`, through the same `ServerClient` calls (answered by
// `DemoServer`), with the demo's library in place of Photos. The deletion gate is the real one.

/// Backs a sample up to the demo's server and saves the compact copy it sends back.
struct DemoCompactor: Compacting {
    let client: ServerClient
    let library: DemoLibrary
    let ledger: CompactLedger
    var pollInterval: Duration = .milliseconds(450)

    func compact(_ localIdentifier: String, compactNow: Bool,
                 progress: @escaping @Sendable (String) -> Void) async throws -> CompactOutcome {
        guard let item = library.demoItem(localIdentifier) else { throw PhotoLibrary.Failure.notFound }
        if library.isCopy(localIdentifier) { return .unchanged("This is a Homespun compact copy") }
        if let entry = try await ledger.entry(for: localIdentifier), entry.serverAssetID != nil,
           library.demoItem(entry.compactIdentifier) != nil {
            return .unchanged("Already has a compact copy")
        }
        progress("Reading")
        var descriptors: [ServerAPI.ResourceDescriptor] = []
        for (role, url) in item.files.sorted(by: { $0.key.rawValue > $1.key.rawValue }) {
            let digests = try await Task.detached { try Fingerprint.digests(of: url) }.value
            descriptors.append(.init(role: role, filename: url.lastPathComponent, size: digests.size, sha256: digests.sha256,
                                     sha1: digests.sha1))
        }
        let originalBytes = descriptors.reduce(0) { $0 + $1.size }

        progress("Contacting server")
        let request = ServerAPI.RegisterAssetRequest(kind: item.kind.api, captureDate: item.creationDate, resources: descriptors,
                                                     compact: compactNow)
        guard let assetID = request.assetID else { throw PhotoLibrary.Failure.missingResource(request.primaryRole.rawValue) }
        var status: ServerAPI.AssetStatus
        do {
            status = try await client.register(request)
        } catch let failure as ServerClient.Failure where failure.code == ServerAPI.ErrorCode.compactCopy {
            return .unchanged(failure.message)
        }
        for descriptor in descriptors where status.resources.first(where: { $0.role == descriptor.role })?.state != .verified {
            guard let url = item.files[descriptor.role] else { continue }
            let size = descriptor.size, label = descriptor.role == .pairedVideo ? "motion" : descriptor.role.rawValue
            try await client.upload(url, assetID: assetID, role: descriptor.role, size: size) { sent in
                progress("Uploading \(label) \(Int(Double(sent) / Double(max(size, 1)) * 100))%")
            }
        }
        status = try await client.status(assetID)

        if !compactNow {
            guard status.resources.allSatisfy({ $0.state == .verified }) else {
                throw ServerClient.Failure(status: 0, message: "The server is still missing some files; try again.")
            }
            try await ledger.recordBackedUp(original: localIdentifier, serverAssetID: assetID, originalBytes: originalBytes)
            return .backedUp(originalBytes: originalBytes)
        }
        while ![.ready, .imported].contains(status.state) {
            switch status.state {
            case .failed, .held, .trashed, .waitingForImmich:
                throw ServerClient.Failure(status: 0, message: status.message ?? "The server could not process it.")
            case .compressing: progress("Compressing on server")
            case .verifying: progress("Verifying")
            default: progress("Queued on server")
            }
            try await Task.sleep(for: pollInterval)
            status = try await client.status(assetID)
        }

        progress("Downloading compact copy")
        let work = try PhotoLibrary.workDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        var files: [ServerAPI.ResourceRole: URL] = [:]
        for compact in status.compact {
            files[compact.role] = try await client.download(compact, assetID: assetID, to: work)
        }
        guard !files.isEmpty else { return .unchanged("Already compact") }
        let compactBytes = try files.values.reduce(0) { $0 + (try PhotoLibrary.size(of: $1)) }

        progress("Saving")
        let identifier = try await library.addCompactCopy(of: localIdentifier, files: files)
        try await ledger.record(original: localIdentifier, compact: identifier, originalBytes: originalBytes,
                                compactBytes: compactBytes, serverAssetID: assetID)
        try? await client.imported(assetID)
        return .saved(compactIdentifier: identifier, originalBytes: originalBytes, compactBytes: compactBytes)
    }
}

/// Free Up Space in the demo: every original is checked again (its files here against the server's
/// fresh check, through `DeletionGate`), then the pretend question, then out of the demo's library.
struct DemoRemover: RemovingOriginals {
    let client: ServerClient
    let library: DemoLibrary
    let ledger: CompactLedger

    func candidates(only: Set<String>?) async throws -> [(original: String, entry: CompactLedger.Entry)] {
        let backed = try await ledger.serverBacked().filter { only?.contains($0.original) ?? true }
        let present = library.existing(backed.map(\.original), includeHidden: false)
        return backed.filter { present.contains($0.original) }
    }

    func removeEligible(limit: Int?, only: Set<String>?,
                        progress: @escaping @Sendable (String) -> Void) async throws -> OriginalRemover.Report {
        var report = OriginalRemover.Report()
        var approved: [(id: String, name: String, bytes: Int)] = []
        let candidates = Array(try await candidates(only: only).prefix(limit ?? .max))
        for (index, candidate) in candidates.enumerated() {
            guard let item = library.demoItem(candidate.original), let assetID = candidate.entry.serverAssetID else { continue }
            progress("Checking \(index + 1) of \(candidates.count)")
            do {
                var device: [DeletionGate.Resource] = []
                for (role, url) in item.files {
                    let digests = try await Task.detached { try Fingerprint.digests(of: url) }.value
                    device.append(.init(role: role.rawValue, sha256: digests.sha256, size: digests.size))
                }
                let verification = try await client.verify(assetID)
                let decision = DeletionGate().evaluate(
                    deviceResources: device,
                    serverVerified: verification.resources.compactMap { resource in
                        guard resource.verified, let sha256 = resource.sha256, let size = resource.size else { return nil }
                        return .init(role: resource.role.rawValue, sha256: sha256, size: size)
                    },
                    compactImported: library.demoItem(candidate.entry.compactIdentifier) != nil)
                switch decision {
                case .allowed: approved.append((item.localIdentifier, item.name, device.reduce(0) { $0 + $1.size }))
                case .blocked(let reason): report.blocked.append("\(item.name): \(reason)")
                }
            } catch {
                report.blocked.append("\(item.name): \(error.localizedDescription)")
            }
        }
        guard !approved.isEmpty else { return report }
        progress("Waiting for your confirmation")
        do {
            try await library.delete(approved.map(\.id))
        } catch let error as PHPhotosError where error.code == .userCancelled {
            report.cancelled = true
            return report
        }
        report.removed = approved.map(\.name)
        report.freedBytes = approved.reduce(0) { $0 + $1.bytes }
        return report
    }
}

/// Restore Original in the demo: each original comes back from the demo's server and is checked
/// against its record, then its compact copy goes (after the pretend question).
struct DemoRestorer: RestoringOriginals {
    let client: ServerClient
    let library: DemoLibrary
    let ledger: CompactLedger

    func restore(_ items: [OriginalRestorer.Item],
                 progress: @escaping @Sendable (OriginalRestorer.Progress) -> Void) async -> OriginalRestorer.Report {
        var report = OriginalRestorer.Report()
        var done: [(item: OriginalRestorer.Item, restored: String)] = []
        for (index, item) in items.enumerated() {
            guard !Task.isCancelled else { break }
            progress(.init(done: index, total: items.count,
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
        progress(.init(done: done.count, total: items.count, message: "Waiting for your confirmation"))
        var deleted = true
        do {
            try await library.delete(done.map(\.item.compact))
        } catch {
            deleted = false
            report.copiesKept = true
        }
        do {
            let entries = try await ledger.snapshot()
            try await ledger.restored(done.compactMap { pair in entries[pair.item.key].map { (pair.item.key, pair.restored, $0) } },
                                      copiesDeleted: deleted)
        } catch { report.problems.append("The demo changed, but its restored mapping could not be saved: \(error.localizedDescription)") }
        return report
    }

    private func restoreOne(_ item: OriginalRestorer.Item) async throws -> String {
        let verification = try await client.verify(item.serverAssetID)
        guard !verification.resources.isEmpty, verification.resources.allSatisfy(\.verified) else {
            throw OriginalRestorer.Failure("Its original isn't complete on the server, so it stays a compact copy.")
        }
        let work = try PhotoLibrary.workDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        for resource in verification.resources {
            guard let sha256 = resource.sha256 else { throw OriginalRestorer.Failure("The server doesn't know this original's fingerprint.") }
            let url = try await client.downloadOriginalFile(assetID: item.serverAssetID, role: resource.role,
                                                            to: work.appendingPathComponent(resource.role.rawValue, isDirectory: true),
                                                            fallback: resource.role.rawValue)
            let received = try await Task.detached { try Fingerprint.sha256(of: url) }.value
            guard received == sha256 else { throw OriginalRestorer.Failure("The original changed on the way. Try again.") }
        }
        // The demo's originals come with the app: the one the server sent back is that same file, so it
        // simply returns to the library.
        guard let restored = library.restore(item.key) else { throw OriginalRestorer.Failure("This original isn't part of the demo.") }
        return restored
    }
}
