// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Which originals already have a compact copy, so picking an item twice does not save a
/// second copy. Stored as JSON in Application Support and replaced atomically.
actor CompactLedger {
    struct Entry: Codable, Equatable, Sendable {
        var compactIdentifier: String
        var originalBytes: Int
        var compactBytes: Int
        var savedAt: Date
        /// Set when the original is on a Homespun Server (server modes); needed before removing it.
        var serverAssetID: String?
    }

    private let url: URL
    private var entries: [String: Entry]

    static var defaultURL: URL {
        URL.applicationSupportDirectory.appendingPathComponent("Homespun/ledger.json")
    }

    init(url: URL = CompactLedger.defaultURL) {
        self.url = url
        entries = Self.load(url)
    }

    /// Reads the ledger. A file that can't be read is set aside, never overwritten: it's the only
    /// record of which originals are on the server and where their compact copies are.
    private static func load(_ url: URL) -> [String: Entry] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let entries = try? decoder.decode([String: Entry].self, from: data) { return entries }
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
        entries.values.contains { $0.compactIdentifier == identifier }
    }

    /// Originals whose server copy is known, with their entries.
    func serverBacked() -> [(original: String, entry: Entry)] {
        entries.compactMap { key, value in value.serverAssetID == nil ? nil : (key, value) }
            .sorted { $0.entry.savedAt < $1.entry.savedAt }
    }

    func record(original: String, compact: String, originalBytes: Int, compactBytes: Int,
                serverAssetID: String? = nil) throws {
        entries[original] = Entry(compactIdentifier: compact, originalBytes: originalBytes,
                                  compactBytes: compactBytes, savedAt: Date(), serverAssetID: serverAssetID)
        try save()
    }

    /// The key for a compact copy whose original isn't on this iPhone: it was made elsewhere, or
    /// its original was removed before this record was kept.
    static func elsewhere(_ compactIdentifier: String) -> String { "elsewhere:" + compactIdentifier }

    /// Records several entries, and forgets `removing`, in one write.
    func record(_ new: [String: Entry], removing: [String] = []) throws {
        guard !new.isEmpty || !removing.isEmpty else { return }
        for key in removing { entries[key] = nil }
        entries.merge(new) { _, latest in latest }
        try save()
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(entries).write(to: url, options: .atomic)
    }
}
