// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import HomespunCore

/// `homespun-server import <manifest>`: records originals that already live elsewhere (a photo
/// archive, say), together with the compact copies made from them before Homespun, so the app
/// recognises those copies on the phone instead of backing them up as originals.
///
/// By default the originals stay where they are: read, never moved, changed, or deleted, and
/// hashed again where they are whenever an item is checked. With `copyInto`, each is copied into
/// the originals folder (under `folder`), checked byte for byte, and then kept there like an
/// uploaded original; the source is still only read.
struct LibraryImport: Sendable {
    struct Summary: Equatable, Sendable {
        var items = 0
        var imported = 0
        /// Already here: imported before, or uploaded by the app; only the copies were added.
        var linked = 0
        var problems = 0
        var bytes = 0
    }

    struct Problem: Error, CustomStringConvertible { var description: String }

    let catalog: Catalog
    var dryRun = false
    var jobs = 4
    var copyInto: OriginalsStore? = nil
    var folder = "Camera Roll"

    /// Imports every line of the manifest (JSON Lines). Bad lines and missing or changed files are
    /// reported through `report` and skipped; running again picks them up once fixed.
    func run(manifest: URL, report: @escaping @Sendable (String) -> Void) async throws -> Summary {
        var contents = try String(contentsOf: manifest, encoding: .utf8)
        if contents.hasPrefix("\u{FEFF}") { contents.removeFirst() }
        // Characters, not bytes: "\r\n" is one Character, so split on any line break.
        let lines = contents.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        var work: [(line: Int, text: String)] = []
        for (index, line) in lines.enumerated() {
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty, !text.hasPrefix("#") { work.append((index + 1, text)) }
        }
        var summary = Summary()
        var next = 0
        try await withThrowingTaskGroup(of: (Int, Result<(ImportOutcome?, Int), Problem>).self) { group in
            func addNext() {
                guard next < work.count else { return }
                let (line, text) = work[next]
                next += 1
                group.addTask { (line, await self.item(text)) }
            }
            for _ in 0..<max(1, jobs) { addNext() }
            while let (line, result) = try await group.next() {
                summary.items += 1
                switch result {
                case .success(let (outcome, bytes)):
                    summary.bytes += bytes
                    if outcome == .imported { summary.imported += 1 }
                    if outcome == .linked { summary.linked += 1 }
                case .failure(let problem):
                    summary.problems += 1
                    report("line \(line): \(problem)")
                }
                if summary.items % 500 == 0 { report(Self.progress(summary, of: work.count, dryRun: dryRun)) }
                addNext()
            }
        }
        return summary
    }

    typealias ImportOutcome = Catalog.ImportOutcome

    private func item(_ text: String) async -> Result<(ImportOutcome?, Int), Problem> {
        do {
            let item = try ServerAPI.decoder.decode(ServerAPI.ImportItem.self, from: Data(text.utf8))
            return .success(try await importItem(item))
        } catch let problem as Problem {
            return .failure(problem)
        } catch is DecodingError {
            return .failure(Problem(description: "not a valid item (see the manifest format in the README)"))
        } catch {
            return .failure(Problem(description: "\(error)"))
        }
    }

    private func importItem(_ item: ServerAPI.ImportItem) async throws -> (ImportOutcome?, Int) {
        try Self.validate(item)
        var item = item
        for index in item.originals.indices {
            item.originals[index].path = URL(fileURLWithPath: item.originals[index].path).standardizedFileURL.path
        }
        var sizes: [Int] = []
        for original in item.originals {
            guard let size = try? JobRunner.size(of: URL(fileURLWithPath: original.path)) else {
                throw Problem(description: "\(original.path) is missing or unreadable")
            }
            guard size > 0 else { throw Problem(description: "\(original.path) is empty") }
            sizes.append(size)
        }
        let total = sizes.reduce(0, +)
        if dryRun { return (nil, total) }

        // Imported before (same paths and sizes): only make sure every copy is known.
        var known: Set<String> = []
        for (original, size) in zip(item.originals, sizes) {
            if let asset = try await catalog.importedAsset(path: original.path, size: size) { known.insert(asset) }
        }
        if known.count == 1, let asset = known.first {
            let stored = try await catalog.resources(asset).filter { $0.externalPath != nil || $0.importedFrom != nil }
            if stored.count == item.originals.count {
                for original in item.originals {
                    let recorded = stored.first { $0.externalPath == original.path || $0.importedFrom == original.path }
                    try Self.check(original, sha256: recorded?.sha256 ?? "", sha1: recorded?.sha1 ?? "")
                }
                return (try await catalog.importExisting(assetID: asset, kind: item.kind, captureDate: item.captureDate,
                                                         originals: [], copies: item.copies), 0)
            }
        }

        if let store = copyInto { return try await copy(item, sizes: sizes, into: store) }

        var records: [ResourceRecord] = []
        for (original, size) in zip(item.originals, sizes) {
            let url = URL(fileURLWithPath: original.path)
            let digests = try await detached { try Fingerprint.digests(of: url) }
            guard digests.size == size else { throw Problem(description: "\(original.path) changed while being read") }
            try Self.check(original, sha256: digests.sha256, sha1: digests.sha1)
            records.append(ResourceRecord(role: original.role, filename: url.lastPathComponent, size: size,
                                          sha256: digests.sha256, sha1: digests.sha1, state: .verified,
                                          receivedBytes: size, verifiedAt: nil, externalPath: original.path))
        }
        let primary: ServerAPI.ResourceRole = item.kind == .video ? .video : .photo
        let assetID = records.first { $0.role == primary }!.sha256
        let outcome = try await catalog.importExisting(assetID: assetID, kind: item.kind, captureDate: item.captureDate,
                                                       originals: records, copies: item.copies)
        return (outcome, total)
    }

    private static func check(_ original: ServerAPI.ImportItem.Original, sha256: String, sha1: String) throws {
        if let expected = original.sha256?.lowercased(), expected != sha256 {
            throw Problem(description: "\(original.path) no longer matches its recorded SHA-256")
        }
        if let expected = original.sha1?.lowercased(), expected != sha1 {
            throw Problem(description: "\(original.path) no longer matches its recorded SHA-1")
        }
    }

    /// Copies an item's originals into the originals folder, checking each copy on disk.
    private func copy(_ item: ServerAPI.ImportItem, sizes: [Int], into store: OriginalsStore) async throws -> (ImportOutcome?, Int) {
        let folder = folder, catalog = catalog
        return try await store.place { root in
            guard FileManager.default.fileExists(atPath: root.path) else {
                throw Problem(description: "the originals folder \(root.path) isn't there (is its disk connected?)")
            }
            let total = sizes.reduce(0, +)
            if let free = OriginalsStore.space(at: root.path).free, free < Int64(total) + (1 << 30) {
                throw Problem(description: "not enough space in \(root.path) for \(item.originals[0].path)")
            }
            var copied: [(original: ServerAPI.ImportItem.Original, partial: URL, sha256: String, sha1: String, size: Int)] = []
            let staging = root.appendingPathComponent(".homespun-import", isDirectory: true)
            defer { for file in copied { try? FileManager.default.removeItem(at: file.partial) } }
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            for (original, size) in zip(item.originals, sizes) {
                let source = URL(fileURLWithPath: original.path)
                let partial = staging.appendingPathComponent(UUID().uuidString + ".partial")
                let read = try await detached { try Fingerprint.copy(from: source, to: partial) }
                copied.append((original, partial, read.sha256, read.sha1, read.size))
                guard read.size == size, try await detached({ try Fingerprint.sha256(of: partial) }) == read.sha256 else {
                    throw Problem(description: "the copy of \(original.path) didn't match it; nothing was recorded")
                }
                try Self.check(original, sha256: read.sha256, sha1: read.sha1)
            }
            let primary: ServerAPI.ResourceRole = item.kind == .video ? .video : .photo
            let assetID = copied.first { $0.original.role == primary }!.sha256
            // Already here (uploaded from a phone, say): keep that, just learn the copies.
            if try await catalog.asset(assetID) != nil {
                return (try await catalog.importExisting(assetID: assetID, kind: item.kind, captureDate: item.captureDate,
                                                         originals: [], copies: item.copies), total)
            }
            var records: [ResourceRecord] = [], placed: [URL] = []
            do {
                for file in copied {
                    let name = (file.original.path as NSString).lastPathComponent
                    let destination = OriginalsStore.destination(root: root, folder: folder, filename: name,
                                                                  sha256: file.sha256, captureDate: item.captureDate)
                    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.moveItem(at: file.partial, to: destination)
                    placed.append(destination)
                    try? FileManager.default.setAttributes([.posixPermissions: 0o440], ofItemAtPath: destination.path)
                    records.append(ResourceRecord(role: file.original.role, filename: name, size: file.size, sha256: file.sha256,
                                                  sha1: file.sha1, state: .verified, receivedBytes: file.size,
                                                  storedPath: OriginalsStore.relative(destination, to: root), verifiedAt: nil,
                                                  importedFrom: file.original.path))
                }
                let outcome = try await catalog.importExisting(assetID: assetID, kind: item.kind, captureDate: item.captureDate,
                                                               originals: records, copies: item.copies,
                                                               placedIn: root.standardizedFileURL.path)
                if outcome == .linked { throw CancellationError() }
                return (outcome, total)
            } catch {
                for url in placed {
                    try? FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: url.path)
                    try? FileManager.default.removeItem(at: url)
                    // And the folders made for it, if nothing else is in them.
                    var folder = url.deletingLastPathComponent()
                    while folder.path.hasPrefix(root.path + "/"),
                          (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
                        try? FileManager.default.removeItem(at: folder)
                        folder.deleteLastPathComponent()
                    }
                }
                if error is CancellationError { return (.linked, total) }
                if let blocked = error as? OriginalsMover.Failure { throw Problem(description: blocked.description) }
                throw error
            }
        }
    }

    static func validate(_ item: ServerAPI.ImportItem) throws {
        let roles = item.originals.map(\.role)
        guard !roles.isEmpty, Set(roles).count == roles.count else {
            throw Problem(description: "an item needs originals with distinct roles")
        }
        let primary: ServerAPI.ResourceRole = item.kind == .video ? .video : .photo
        guard roles.contains(primary) else { throw Problem(description: "a \(item.kind.rawValue) needs its \(primary.rawValue) original") }
        if item.kind == .livePhoto, !roles.contains(.pairedVideo) {
            throw Problem(description: "a Live Photo needs its paired video")
        }
        for original in item.originals where !original.path.hasPrefix("/") {
            throw Problem(description: "\(original.path): use an absolute path")
        }
        for original in item.originals {
            if let sha256 = original.sha256, !Validation.isSHA256(sha256) { throw Problem(description: "bad SHA-256 for \(original.path)") }
            if let sha1 = original.sha1, !Validation.isSHA1(sha1) { throw Problem(description: "bad SHA-1 for \(original.path)") }
        }
        for copy in item.copies {
            guard Validation.isSHA256(copy.sha256) else { throw Problem(description: "bad compact copy SHA-256") }
            if let sha1 = copy.sha1, !Validation.isSHA1(sha1) { throw Problem(description: "bad compact copy SHA-1") }
        }
    }

    static func progress(_ summary: Summary, of total: Int, dryRun: Bool) -> String {
        let read = ByteCountFormatter.string(fromByteCount: Int64(summary.bytes), countStyle: .file)
        if dryRun {
            return "\(summary.items) of \(total) checked · \(read) of originals found · \(summary.problems) problems"
        }
        return "\(summary.items) of \(total) · \(summary.imported) imported · \(summary.linked) already here · "
            + "\(summary.problems) problems · \(read) read"
    }
}
