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

    func compactIdentifier(for original: String) -> String? {
        entries[original]?.compactIdentifier
    }

    func record(original: String, compact: String, originalBytes: Int, compactBytes: Int) throws {
        entries[original] = Entry(compactIdentifier: compact, originalBytes: originalBytes,
                                  compactBytes: compactBytes, savedAt: Date())
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(entries).write(to: url, options: .atomic)
    }
}
