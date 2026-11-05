// SPDX-License-Identifier: Apache-2.0
import Foundation

/// The HTTP API between the Homespun app and Homespun Server (`/api/v1`). JSON uses
/// snake_case keys and ISO 8601 dates; use `ServerAPI.encoder` and `ServerAPI.decoder`.
///
/// An asset's ID is the SHA-256 of its primary resource (`photo`, or `video` for videos).
/// Every request except `health` and `pair` carries `Authorization: Bearer <token>`.
public enum ServerAPI {
    public static let version = 1

    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// Where the server keeps originals.
    public enum StorageMode: String, Codable, Sendable {
        /// Originals are uploaded to and stored by Homespun Server.
        case files
        /// Originals are read from an Immich server; nothing is uploaded.
        case immich
    }

    public enum AssetKind: String, Codable, Sendable {
        case photo, livePhoto = "live_photo", video
    }

    /// PhotoKit resource roles. Edited items also carry `full_size_*` renders and adjustment data.
    public enum ResourceRole: String, Codable, Sendable, CaseIterable {
        case photo, video, audio
        case pairedVideo = "paired_video"
        case alternatePhoto = "alternate_photo"
        case fullSizePhoto = "full_size_photo"
        case fullSizeVideo = "full_size_video"
        case fullSizePairedVideo = "full_size_paired_video"
        case adjustmentData = "adjustment_data"
        case adjustmentBasePhoto = "adjustment_base_photo"
        case adjustmentBaseVideo = "adjustment_base_video"
        case adjustmentBasePairedVideo = "adjustment_base_paired_video"
        case photoProxy = "photo_proxy"
        case other
    }

    public struct Health: Codable, Equatable, Sendable {
        public var status: String
        public var apiVersion: Int
        public init(status: String = "ok", apiVersion: Int = ServerAPI.version) {
            self.status = status
            self.apiVersion = apiVersion
        }
    }

    public struct ServerInfo: Codable, Equatable, Sendable {
        public var name: String
        public var version: String
        public var apiVersion: Int
        public var mode: StorageMode
        public var profile: CompressionProfile

        public init(name: String, version: String, apiVersion: Int = ServerAPI.version, mode: StorageMode,
                    profile: CompressionProfile) {
            self.name = name
            self.version = version
            self.apiVersion = apiVersion
            self.mode = mode
            self.profile = profile
        }
    }

    /// `POST /api/v1/pair` with a one-time code from `homespun-server pair`.
    public struct PairRequest: Codable, Equatable, Sendable {
        public var code: String
        public var deviceName: String
        public init(code: String, deviceName: String) {
            self.code = code
            self.deviceName = deviceName
        }
    }

    public struct PairResponse: Codable, Equatable, Sendable {
        public var deviceID: String
        public var token: String
        public var server: ServerInfo
        public init(deviceID: String, token: String, server: ServerInfo) {
            self.deviceID = deviceID
            self.token = token
            self.server = server
        }

        enum CodingKeys: String, CodingKey {
            case deviceID = "deviceId", token, server
        }
    }

    public struct ResourceDescriptor: Codable, Equatable, Sendable {
        public var role: ResourceRole
        public var filename: String
        public var size: Int
        public var sha256: String
        /// Immich identifies files by SHA-1.
        public var sha1: String?

        public init(role: ResourceRole, filename: String, size: Int, sha256: String, sha1: String? = nil) {
            self.role = role
            self.filename = filename
            self.size = size
            self.sha256 = sha256
            self.sha1 = sha1
        }
    }

    /// `POST /api/v1/assets`. Registering again is safe and re-checks Immich in Immich mode.
    public struct RegisterAssetRequest: Codable, Equatable, Sendable {
        public var kind: AssetKind
        public var captureDate: Date?
        public var resources: [ResourceDescriptor]

        public init(kind: AssetKind, captureDate: Date?, resources: [ResourceDescriptor]) {
            self.kind = kind
            self.captureDate = captureDate
            self.resources = resources
        }

        /// The role whose SHA-256 is the asset ID.
        public var primaryRole: ResourceRole { kind == .video ? .video : .photo }

        public var assetID: String? { resources.first { $0.role == primaryRole }?.sha256.lowercased() }
    }

    public enum AssetState: String, Codable, Sendable {
        /// Files mode: waiting for uploads.
        case receiving
        /// Immich mode: some resources are not in Immich yet.
        case waitingForImmich = "waiting_for_immich"
        /// Checking stored or Immich copies.
        case verifying
        case queued
        case compressing
        /// Compact copies can be downloaded.
        case ready
        /// The app saved the compact copy.
        case imported
        /// Nothing smaller can be made yet; `message` says why. The original stays as is.
        case held
        case failed
    }

    public enum ResourceState: String, Codable, Sendable {
        case missing, partial, verified
        case notInImmich = "not_in_immich"
        case mismatch
    }

    public struct ResourceStatus: Codable, Equatable, Sendable {
        public var role: ResourceRole
        public var sha256: String
        public var size: Int
        public var state: ResourceState
        public var receivedBytes: Int
        public var verifiedAt: Date?

        public init(role: ResourceRole, sha256: String, size: Int, state: ResourceState, receivedBytes: Int,
                    verifiedAt: Date?) {
            self.role = role
            self.sha256 = sha256
            self.size = size
            self.state = state
            self.receivedBytes = receivedBytes
            self.verifiedAt = verifiedAt
        }
    }

    /// A compact file to download from `GET /api/v1/assets/{id}/compact/{role}`.
    public struct CompactResource: Codable, Equatable, Sendable {
        public var role: ResourceRole
        public var filename: String
        public var size: Int
        public var sha256: String

        public init(role: ResourceRole, filename: String, size: Int, sha256: String) {
            self.role = role
            self.filename = filename
            self.size = size
            self.sha256 = sha256
        }
    }

    public struct AssetStatus: Codable, Equatable, Sendable {
        public var assetID: String
        public var kind: AssetKind
        public var state: AssetState
        public var message: String?
        public var resources: [ResourceStatus]
        public var compact: [CompactResource]
        /// Roles the app compresses itself (Live Photo motion needs AVFoundation).
        public var deviceCompresses: [ResourceRole]

        public init(assetID: String, kind: AssetKind, state: AssetState, message: String?,
                    resources: [ResourceStatus], compact: [CompactResource], deviceCompresses: [ResourceRole]) {
            self.assetID = assetID
            self.kind = kind
            self.state = state
            self.message = message
            self.resources = resources
            self.compact = compact
            self.deviceCompresses = deviceCompresses
        }

        enum CodingKeys: String, CodingKey {
            case assetID = "assetId", kind, state, message, resources, compact, deviceCompresses
        }
    }

    /// `POST /api/v1/assets/{id}/verify`: the server re-checks its copies of every resource now.
    public struct Verification: Codable, Equatable, Sendable {
        public struct Resource: Codable, Equatable, Sendable {
            public var role: ResourceRole
            public var sha256: String?
            public var size: Int?
            public var verified: Bool
            public var detail: String?

            public init(role: ResourceRole, sha256: String?, size: Int?, verified: Bool, detail: String?) {
                self.role = role
                self.sha256 = sha256
                self.size = size
                self.verified = verified
                self.detail = detail
            }
        }

        public var assetID: String
        public var checkedAt: Date
        public var resources: [Resource]

        public init(assetID: String, checkedAt: Date, resources: [Resource]) {
            self.assetID = assetID
            self.checkedAt = checkedAt
            self.resources = resources
        }

        public var allVerified: Bool { !resources.isEmpty && resources.allSatisfy(\.verified) }

        enum CodingKeys: String, CodingKey {
            case assetID = "assetId", checkedAt, resources
        }
    }

    public struct ErrorBody: Codable, Equatable, Sendable {
        public struct Detail: Codable, Equatable, Sendable { public var message: String }
        public var error: Detail
    }
}
