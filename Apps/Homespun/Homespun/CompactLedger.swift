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
        entries = (try? JSONDecoder().decode([String: Entry].self, from: Data(contentsOf: url))) ?? [:]
    }

    func snapshot() -> [String: Entry] { entries }

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
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(entries).write(to: url, options: .atomic)
    }
}
