import Foundation

/// What the server tells the app to download for one asset. The app verifies every
/// resource's SHA-256 before saving anything to the photo library.
public struct DownloadManifest: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable { case photo, video, pairedVideo = "paired_video" }

    public struct Resource: Codable, Equatable, Sendable {
        public var role: Role
        public var downloadURL: URL
        public var sha256: String
        public var size: Int

        public init(role: Role, downloadURL: URL, sha256: String, size: Int) {
            self.role = role
            self.downloadURL = downloadURL
            self.sha256 = sha256
            self.size = size
        }

        enum CodingKeys: String, CodingKey {
            case role, sha256, size
            case downloadURL = "download_url"
        }
    }

    /// SHA-256 of the original's primary resource.
    public var assetID: String
    public var captureDate: Date?
    public var resources: [Resource]

    public init(assetID: String, captureDate: Date?, resources: [Resource]) {
        self.assetID = assetID
        self.captureDate = captureDate
        self.resources = resources
    }

    enum CodingKeys: String, CodingKey {
        case resources
        case assetID = "asset_id"
        case captureDate = "capture_date"
    }

    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
