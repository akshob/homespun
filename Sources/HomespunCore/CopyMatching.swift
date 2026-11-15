// SPDX-License-Identifier: Apache-2.0
import Foundation

/// What an item on the phone is, given the server's answers (`POST /api/v1/copies/lookup`)
/// for the SHA-256 of its files. Only the photo, Live Photo motion, and video count: an edit
/// made on the phone doesn't change what the item is a copy of.
public enum CopyMatching {
    public static let roles: Set<ServerAPI.ResourceRole> = [.photo, .pairedVideo, .video]

    public enum Outcome: Equatable, Sendable {
        /// A compact copy of the item `assetID`, whose originals are all verified on the server.
        case copy(assetID: String, originalBytes: Int)
        /// The files are the item's originals themselves (on the server too).
        case original(assetID: String)
        /// Some files match and some don't, they match different items, a file matches in another
        /// role, or the item's originals aren't all verified on the server.
        case partial
        /// Nothing matches.
        case unknown
    }

    public static func classify(_ hashes: [ServerAPI.ResourceRole: String],
                                matches: [String: ServerAPI.CopyLookupResponse.Match]) -> Outcome {
        let relevant = hashes.filter { roles.contains($0.key) }
        let found = relevant.compactMap { role, hash in matches[hash.lowercased()].map { (role, $0) } }
        guard !found.isEmpty else { return .unknown }
        guard found.count == relevant.count, Set(found.map(\.1.assetID)).count == 1,
              found.allSatisfy({ $0.0 == $0.1.role && $0.1.originalsVerified }) else { return .partial }
        let assetID = found[0].1.assetID
        if found.allSatisfy({ $0.1.isOriginal }) { return .original(assetID: assetID) }
        return .copy(assetID: assetID, originalBytes: found[0].1.originalBytes)
    }
}
