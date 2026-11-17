// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Which originals already have a compact copy, so picking an item twice does not save a
/// second copy. Stored in Application Support as a JSON snapshot plus a journal of changes since
/// (one JSON line each), so recording an item appends a line instead of rewriting a library's
/// worth of entries; the snapshot is rewritten every `compactEvery` changes. Replaying the journal
/// is idempotent, so a crash at any point loses nothing that was written.
actor CompactLedger {
    /// One journal line: entries set, and originals forgotten.
    private struct Change: Codable {
        var set: [String: Entry]?
        var remove: [String]?
    }

    static let compactEvery = 1_000
    private var journalLines = 0
    /// The journal ends with a whole line (false after a crash or a full disk cut one short: the
    /// next change starts on a line of its own, or the fragment would swallow it).
    private var journalEndsClean = true
    struct Entry: Codable, Equatable, Sendable {
        var compactIdentifier: String
        var originalBytes: Int
        var compactBytes: Int
        var savedAt: Date
        /// Set when the original is on a Homespun Server (server modes); needed before removing it.
        var serverAssetID: String?
    }

    /// An original backed up without a compact copy yet (a recent item, for automatic mode).
    struct BackedUp: Codable, Equatable, Sendable {
        var serverAssetID: String
        var originalBytes: Int
        var backedUpAt: Date
    }

    private let url: URL
    /// Read on first use, on the ledger's own executor: a library's worth of entries (tens of
    /// thousands) takes too long to decode on the main thread while the app launches.
    private lazy var entries: [String: Entry] = loadWithJournal()
    /// Kept in a file of its own next to the ledger, so the ledger's format doesn't change.
    private lazy var backedUp: [String: BackedUp] = Self.load(backedUpURL)
    private var backedUpURL: URL { url.deletingLastPathComponent().appendingPathComponent("backed-up.json") }
    private var journalURL: URL { url.deletingPathExtension().appendingPathExtension("journal") }

    /// The snapshot with the journal replayed over it (a torn last line, from a crash mid-write, is skipped).
    private func loadWithJournal() -> [String: Entry] {
        var entries: [String: Entry] = Self.load(url)
        guard let data = try? Data(contentsOf: journalURL), !data.isEmpty else { return entries }
        journalEndsClean = data.last == UInt8(ascii: "\n")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let change = try? decoder.decode(Change.self, from: Data(line)) else { continue }
            for key in change.remove ?? [] { entries[key] = nil }
            if let set = change.set { entries.merge(set) { _, latest in latest } }
            journalLines += 1
        }
        return entries
    }

    static var defaultURL: URL {
        URL.applicationSupportDirectory.appendingPathComponent("Homespun/ledger.json")
    }

    init(url: URL = CompactLedger.defaultURL) {
        self.url = url
    }

    /// Reads the ledger. A file that can't be read is set aside, never overwritten: it's the only
    /// record of which originals are on the server and where their compact copies are.
    private static func load<Value: Decodable>(_ url: URL) -> [String: Value] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let entries = try? decoder.decode([String: Value].self, from: data) { return entries }
        let aside = url.deletingPathExtension()
            .appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
        try? FileManager.default.moveItem(at: url, to: aside)
        return [:]
    }

    func snapshot() -> [String: Entry] { entries }

    func entry(for original: String) -> Entry? { entries[original] }

    func compactIdentifier(for original: String) -> String? {
        entries[original]?.compactIdentifier
    }

    /// Whether this item is a compact copy Homespun saved, wherever it is in Photos now.
    func isCompactCopy(_ identifier: String) -> Bool {
        if compactIdentifiers == nil { compactIdentifiers = Set(entries.values.map(\.compactIdentifier)) }
        return compactIdentifiers?.contains(identifier) ?? false
    }

    /// Every compact copy's identifier, built when first asked and dropped on changes.
    private var compactIdentifiers: Set<String>?

    /// Originals whose server copy is known, with their entries.
    func serverBacked() -> [(original: String, entry: Entry)] {
        entries.compactMap { key, value in value.serverAssetID == nil ? nil : (key, value) }
            .sorted { $0.entry.savedAt < $1.entry.savedAt }
    }

    func record(original: String, compact: String, originalBytes: Int, compactBytes: Int,
                serverAssetID: String? = nil) throws {
        let entry = Entry(compactIdentifier: compact, originalBytes: originalBytes, compactBytes: compactBytes,
                          savedAt: Date(), serverAssetID: serverAssetID)
        entries[original] = entry
        try append(Change(set: [original: entry]))
        if backedUp.removeValue(forKey: original) != nil { try saveBackedUp() }
    }

    // MARK: Backed up, compact copy later

    func backedUpSnapshot() -> [String: BackedUp] { backedUp }

    /// The original is safe on the server; its compact copy comes when the item is old enough.
    func recordBackedUp(original: String, serverAssetID: String, originalBytes: Int) throws {
        guard entries[original]?.serverAssetID == nil else { return }
        backedUp[original] = BackedUp(serverAssetID: serverAssetID, originalBytes: originalBytes, backedUpAt: Date())
        try saveBackedUp()
    }

    /// Forgets items that were removed on this iPhone before their compact copy (the server has
    /// been told) or that got one meanwhile.
    func forgetBackedUp(_ originals: [String]) throws {
        var changed = false
        for original in originals where backedUp.removeValue(forKey: original) != nil { changed = true }
        if changed { try saveBackedUp() }
    }

    private func saveBackedUp() throws {
        try FileManager.default.createDirectory(at: backedUpURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(backedUp).write(to: backedUpURL, options: .atomic)
    }

    /// The key for a compact copy whose original isn't on this iPhone: it was made elsewhere, or
    /// its original was removed before this record was kept.
    static func elsewhere(_ compactIdentifier: String) -> String { "elsewhere:" + compactIdentifier }

    /// Records several entries, and forgets `removing`, in one write.
    func record(_ new: [String: Entry], removing: [String] = []) throws {
        guard !new.isEmpty || !removing.isEmpty else { return }
        for key in removing { entries[key] = nil }
        entries.merge(new) { _, latest in latest }
        try append(Change(set: new.isEmpty ? nil : new, remove: removing.isEmpty ? nil : removing))
        try forgetBackedUp(Array(new.keys))
    }

    /// Appends a change to the journal; every `compactEvery` changes, writes the snapshot and
    /// starts the journal afresh.
    private func append(_ change: Change) throws {
        _ = entries
        compactIdentifiers = nil
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var line = try encoder.encode(change)
        line.append(UInt8(ascii: "\n"))
        if !journalEndsClean { line.insert(UInt8(ascii: "\n"), at: line.startIndex) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: journalURL.path) {
            FileManager.default.createFile(atPath: journalURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: journalURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        do {
            try handle.write(contentsOf: line)
        } catch {
            journalEndsClean = false
            throw error
        }
        journalEndsClean = true
        journalLines += 1
        if journalLines >= Self.compactEvery { try compact() }
    }

    /// Writes every entry to the snapshot (atomically), then empties the journal. A crash between
    /// the two only replays changes already in the snapshot.
    func compact() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(entries).write(to: url, options: .atomic)
        try? FileManager.default.removeItem(at: journalURL)
        journalLines = 0
        journalEndsClean = true
    }
}
