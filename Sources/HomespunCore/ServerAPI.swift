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
        /// Missing from servers older than the setup check.
        public var platform: ServerSetup.Platform?
        public var hardware: Hardware?
        /// Free space where originals go.
        public var freeBytes: Int64?

        public init(name: String, version: String, apiVersion: Int = ServerAPI.version, mode: StorageMode,
                    profile: CompressionProfile, platform: ServerSetup.Platform? = nil, hardware: Hardware? = nil,
                    freeBytes: Int64? = nil) {
            self.name = name
            self.version = version
            self.apiVersion = apiVersion
            self.mode = mode
            self.profile = profile
            self.platform = platform
            self.hardware = hardware
            self.freeBytes = freeBytes
        }
    }

    /// `PATCH /api/v1/devices/{id}`: a phone renames itself (and its originals folder on the server).
    public struct RenameDeviceRequest: Codable, Equatable, Sendable {
        public static let maximumLength = 64
        public var name: String
        public init(name: String) { self.name = name }
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

    /// `GET /api/v1/pair/options`: how this server lets a new device pair.
    public struct PairingOptions: Codable, Equatable, Sendable {
        public var serverName: String
        /// Someone at the server's screen can allow a device (a Mac with a user logged in).
        public var canApprove: Bool
        /// Run on the server to show a pairing code and QR code.
        public var pairCommand: String
        /// What the server runs on, so the app can recommend among servers before pairing.
        public var platform: ServerSetup.Platform?
        public var hardware: Hardware?
        /// Free space where originals go.
        public var freeBytes: Int64?
        public init(serverName: String, canApprove: Bool, pairCommand: String, platform: ServerSetup.Platform? = nil,
                    hardware: Hardware? = nil, freeBytes: Int64? = nil) {
            self.serverName = serverName
            self.canApprove = canApprove
            self.pairCommand = pairCommand
            self.platform = platform
            self.hardware = hardware
            self.freeBytes = freeBytes
        }
    }

    /// The kind of computer a server runs on, for recommending one and wording its trade-offs.
    public struct Hardware: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable {
            /// Stays on at home: Mac mini, iMac, Mac Studio, a desktop PC.
            case desktop
            /// Sleeps when closed.
            case laptop
            /// A rack or small server, always on.
            case server
            /// Homespun in a container (Docker), usually on a NAS.
            case container
        }
        public var kind: Kind
        /// For example "Mac mini", "MacBook Air" or "Synology DS923+".
        public var model: String?
        public init(kind: Kind, model: String?) {
            self.kind = kind
            self.model = model
        }
    }

    /// `GET /api/v1/devices`: phones and tablets paired with the server.
    public struct DeviceInfo: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var name: String
        /// Its folder in the originals folder.
        public var folder: String?
        public var pairedAt: Date?
        public var lastSeenAt: Date?
        /// The device asking.
        public var isThisDevice: Bool
        public init(id: String, name: String, folder: String?, pairedAt: Date?, lastSeenAt: Date?, isThisDevice: Bool) {
            self.id = id
            self.name = name
            self.folder = folder
            self.pairedAt = pairedAt
            self.lastSeenAt = lastSeenAt
            self.isThisDevice = isThisDevice
        }
    }

    /// `POST /api/v1/pair/requests`: ask someone at the server to allow this device.
    public struct ApprovalRequest: Codable, Equatable, Sendable {
        public var deviceName: String
        public init(deviceName: String) { self.deviceName = deviceName }
    }

    /// The pending request. Poll `GET /api/v1/pair/requests/{id}` with `secret` as the bearer token.
    public struct ApprovalTicket: Codable, Equatable, Sendable {
        public var id: String
        public var secret: String
        /// Shown on both screens, so the person at the server allows the right device.
        public var match: String
        public var expiresIn: Int
        public init(id: String, secret: String, match: String, expiresIn: Int) {
            self.id = id
            self.secret = secret
            self.match = match
            self.expiresIn = expiresIn
        }
    }

    public enum ApprovalState: String, Codable, Sendable {
        case waiting, approved, denied, expired
    }

    public struct ApprovalStatus: Codable, Equatable, Sendable {
        public var state: ApprovalState
        /// Set once, when approved.
        public var pairing: PairResponse?
        public init(state: ApprovalState, pairing: PairResponse? = nil) {
            self.state = state
            self.pairing = pairing
        }
    }

    /// `POST /api/v1/pairing-codes`: a paired device makes a code for another device.
    public struct PairingCode: Codable, Equatable, Sendable {
        public var code: String
        public var expiresIn: Int
        public init(code: String, expiresIn: Int) {
            self.code = code
            self.expiresIn = expiresIn
        }
    }

    // MARK: Connectors

    /// A setting a connector asks for; the app draws a form from these.
    public struct ConnectorField: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable { case text, secret, toggle, choice }
        public var key: String
        public var label: String
        public var kind: Kind
        public var help: String?
        public var placeholder: String?
        public var choices: [String]?
        /// The current value; never sent for secrets.
        public var value: String?
        /// A secret has a value (it is never sent back).
        public var isSet: Bool

        public init(key: String, label: String, kind: Kind = .text, help: String? = nil, placeholder: String? = nil,
                    choices: [String]? = nil, value: String? = nil, isSet: Bool = false) {
            self.key = key
            self.label = label
            self.kind = kind
            self.help = help
            self.placeholder = placeholder
            self.choices = choices
            self.value = value
            self.isSet = isSet
        }
    }

    public struct ConnectorCounts: Codable, Equatable, Sendable {
        public var copied: Int
        public var pending: Int
        public var failed: Int
        public init(copied: Int = 0, pending: Int = 0, failed: Int = 0) {
            self.copied = copied
            self.pending = pending
            self.failed = failed
        }
    }

    /// `GET /api/v1/connectors`: a destination the server copies originals to.
    public struct ConnectorInfo: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public var summary: String
        public var fields: [ConnectorField]
        /// Signs in with a code shown in the app (`POST /connectors/{id}/sign-in`).
        public var signsIn: Bool
        /// The signed-in account, if any.
        public var account: String?
        public var enabled: Bool
        /// A problem to show, for example the last copy error.
        public var message: String?
        public var counts: ConnectorCounts

        public init(id: String, name: String, summary: String, fields: [ConnectorField], signsIn: Bool,
                    account: String?, enabled: Bool, message: String?, counts: ConnectorCounts) {
            self.id = id
            self.name = name
            self.summary = summary
            self.fields = fields
            self.signsIn = signsIn
            self.account = account
            self.enabled = enabled
            self.message = message
            self.counts = counts
        }
    }

    /// `PUT /api/v1/connectors/{id}`. Missing values are unchanged; an empty secret is unchanged.
    public struct ConnectorUpdate: Codable, Equatable, Sendable {
        public var enabled: Bool?
        public var settings: [String: String]?
        /// Also copy originals already on the server, not only new ones.
        public var copyExisting: Bool?
        public init(enabled: Bool? = nil, settings: [String: String]? = nil, copyExisting: Bool? = nil) {
            self.enabled = enabled
            self.settings = settings
            self.copyExisting = copyExisting
        }
    }

    /// `POST /api/v1/connectors/{id}/sign-in`: open `url` and enter `userCode` there.
    public struct ConnectorSignIn: Codable, Equatable, Sendable {
        public var userCode: String
        public var url: String
        public var message: String?
        public var expiresIn: Int
        public init(userCode: String, url: String, message: String? = nil, expiresIn: Int) {
            self.userCode = userCode
            self.url = url
            self.message = message
            self.expiresIn = expiresIn
        }
    }

    /// `GET /api/v1/connectors/{id}/sign-in`.
    public struct ConnectorSignInStatus: Codable, Equatable, Sendable {
        public enum State: String, Codable, Sendable { case waiting, done, failed }
        public var state: State
        public var account: String?
        public var message: String?
        public init(state: State, account: String? = nil, message: String? = nil) {
            self.state = state
            self.account = account
            self.message = message
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
        /// False: back the originals up but don't make a compact copy yet (the item is recent); the
        /// asset waits as `stored` until it's registered again with this true (or left out, as older
        /// apps do). Files mode only.
        public var compact: Bool?

        public init(kind: AssetKind, captureDate: Date?, resources: [ResourceDescriptor], compact: Bool? = nil) {
            self.kind = kind
            self.captureDate = captureDate
            self.resources = resources
            self.compact = compact
        }

        public var wantsCompact: Bool { compact ?? true }

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
        /// Backed up; no compact copy until the app asks (registering again with `compact` true).
        case stored
        /// Removed on the phone while it waited as `stored`: the originals are in the server's trash
        /// until `trashedUntil`, then deleted. Backing it up again restores them.
        case trashed
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
        /// When a trashed asset's originals are deleted.
        public var trashedUntil: Date?

        public init(assetID: String, kind: AssetKind, state: AssetState, message: String?,
                    resources: [ResourceStatus], compact: [CompactResource], deviceCompresses: [ResourceRole],
                    trashedUntil: Date? = nil) {
            self.assetID = assetID
            self.kind = kind
            self.state = state
            self.message = message
            self.resources = resources
            self.compact = compact
            self.deviceCompresses = deviceCompresses
            self.trashedUntil = trashedUntil
        }

        enum CodingKeys: String, CodingKey {
            case assetID = "assetId", kind, state, message, resources, compact, deviceCompresses, trashedUntil
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

    /// `POST /api/v1/copies/lookup`: which of these files (by SHA-256) does the server know?
    /// The app uses it to find compact copies made elsewhere, or whose record it lost.
    public struct CopyLookupRequest: Codable, Equatable, Sendable {
        public static let maximumCount = 500
        public var sha256: [String]
        public init(sha256: [String]) { self.sha256 = sha256 }
    }

    public struct CopyLookupResponse: Codable, Equatable, Sendable {
        public struct Match: Codable, Equatable, Sendable {
            public var sha256: String
            public var assetID: String
            public var role: ResourceRole
            /// True when these bytes are the original itself (kept as is), not a compact copy.
            public var isOriginal: Bool
            /// Whether every original of the item is verified on the server.
            public var originalsVerified: Bool
            /// The originals' total size.
            public var originalBytes: Int

            public init(sha256: String, assetID: String, role: ResourceRole, isOriginal: Bool,
                        originalsVerified: Bool, originalBytes: Int) {
                self.sha256 = sha256
                self.assetID = assetID
                self.role = role
                self.isOriginal = isOriginal
                self.originalsVerified = originalsVerified
                self.originalBytes = originalBytes
            }

            enum CodingKeys: String, CodingKey {
                case sha256, assetID = "assetId", role, isOriginal, originalsVerified, originalBytes
            }
        }

        public var matches: [Match]
        public init(matches: [Match]) { self.matches = matches }
    }

    /// A compact file's fingerprint, so the server recognises the copy wherever it turns up.
    public struct CopyHash: Codable, Equatable, Sendable {
        public var role: ResourceRole
        public var sha256: String
        public var sha1: String?
        public init(role: ResourceRole, sha256: String, sha1: String? = nil) {
            self.role = role
            self.sha256 = sha256
            self.sha1 = sha1
        }
    }

    /// `POST /api/v1/assets/{id}/imported`, optionally with the files the phone compressed
    /// itself (`deviceCompresses`), whose hashes the server otherwise never sees.
    public struct ImportedRequest: Codable, Equatable, Sendable {
        public var deviceCopies: [CopyHash]
        public init(deviceCopies: [CopyHash]) { self.deviceCopies = deviceCopies }
    }

    /// One line of an import manifest (JSON Lines) for `homespun-server import`: originals kept
    /// elsewhere on the server's disks, and the compact copies already made from them.
    public struct ImportItem: Codable, Equatable, Sendable {
        public struct Original: Codable, Equatable, Sendable {
            public var role: ResourceRole
            /// An absolute path. The file is read, never moved, changed, or deleted.
            public var path: String
            /// If given, the file must still have this SHA-256 (and SHA-1), for example as recorded
            /// when it came off the phone or as a cloud service reports it.
            public var sha256: String?
            public var sha1: String?
            public init(role: ResourceRole, path: String, sha256: String? = nil, sha1: String? = nil) {
                self.role = role
                self.path = path
                self.sha256 = sha256
                self.sha1 = sha1
            }
        }

        public var kind: AssetKind
        public var captureDate: Date?
        public var originals: [Original]
        public var copies: [CopyHash]

        public init(kind: AssetKind, captureDate: Date?, originals: [Original], copies: [CopyHash]) {
            self.kind = kind
            self.captureDate = captureDate
            self.originals = originals
            self.copies = copies
        }
    }

    /// `GET /api/v1/storage`: where originals are kept, and a move in progress.
    public struct StorageInfo: Codable, Equatable, Sendable {
        /// The originals folder on the server.
        public var originalsFolder: String
        /// This phone's folder in it.
        public var deviceFolder: String?
        public var freeBytes: Int64?
        public var capacityBytes: Int64?
        /// Originals kept in the folder (not counting ones imported in place elsewhere).
        public var storedCount: Int
        public var storedBytes: Int64
        public var move: MoveStatus?
        /// Originals of items removed on a phone before their compact copy, waiting to be deleted.
        public var trashCount: Int?
        public var trashBytes: Int64?

        public init(originalsFolder: String, deviceFolder: String?, freeBytes: Int64?, capacityBytes: Int64?,
                    storedCount: Int, storedBytes: Int64, move: MoveStatus?, trashCount: Int? = nil, trashBytes: Int64? = nil) {
            self.originalsFolder = originalsFolder
            self.deviceFolder = deviceFolder
            self.freeBytes = freeBytes
            self.capacityBytes = capacityBytes
            self.storedCount = storedCount
            self.storedBytes = storedBytes
            self.move = move
            self.trashCount = trashCount
            self.trashBytes = trashBytes
        }
    }

    /// Moving every original to a new folder (`PUT /api/v1/storage`).
    public struct MoveStatus: Codable, Equatable, Sendable {
        public enum State: String, Codable, Sendable { case copying, finishing, done, failed }
        public var state: State
        public var from: String
        public var to: String
        public var copied: Int
        public var total: Int
        public var copiedBytes: Int64
        public var totalBytes: Int64
        public var message: String?
        public var finishedAt: Date?

        public init(state: State, from: String, to: String, copied: Int, total: Int, copiedBytes: Int64, totalBytes: Int64,
                    message: String? = nil, finishedAt: Date? = nil) {
            self.state = state
            self.from = from
            self.to = to
            self.copied = copied
            self.total = total
            self.copiedBytes = copiedBytes
            self.totalBytes = totalBytes
            self.message = message
            self.finishedAt = finishedAt
        }
    }

    public struct MoveOriginalsRequest: Codable, Equatable, Sendable {
        public var originalsFolder: String
        public init(originalsFolder: String) { self.originalsFolder = originalsFolder }
    }

    /// `GET /api/v1/storage/locations`: folders on the server's disks the app can offer.
    public struct StorageLocation: Codable, Equatable, Sendable, Identifiable {
        public var path: String
        public var name: String
        public var freeBytes: Int64?
        public var capacityBytes: Int64?
        public var isCurrent: Bool
        public var id: String { path }

        public init(path: String, name: String, freeBytes: Int64?, capacityBytes: Int64?, isCurrent: Bool) {
            self.path = path
            self.name = name
            self.freeBytes = freeBytes
            self.capacityBytes = capacityBytes
            self.isCurrent = isCurrent
        }
    }

    /// `GET`/`PUT`/`DELETE /api/v1/settings/immich`. The API key itself is never sent back.
    public struct ImmichSettings: Codable, Equatable, Sendable {
        public var url: String?
        /// The key's last four characters.
        public var keyHint: String?
        public var permissions: [String]
        public var connected: Bool
        public var message: String?

        public init(url: String?, keyHint: String?, permissions: [String], connected: Bool, message: String?) {
            self.url = url
            self.keyHint = keyHint
            self.permissions = permissions
            self.connected = connected
            self.message = message
        }
    }

    public struct ImmichSettingsRequest: Codable, Equatable, Sendable {
        public var url: String
        public var apiKey: String
        public init(url: String, apiKey: String) {
            self.url = url
            self.apiKey = apiKey
        }
    }

    public struct ErrorBody: Codable, Equatable, Sendable {
        public struct Detail: Codable, Equatable, Sendable {
            public var message: String
            /// Set for errors a client handles specially, for example `compact_copy`.
            public var code: String?
            public init(message: String, code: String? = nil) {
                self.message = message
                self.code = code
            }
        }
        public var error: Detail
        public init(error: Detail) { self.error = error }
    }

    public enum ErrorCode {
        /// The registered file is a compact copy this server made, not an original.
        public static let compactCopy = "compact_copy"
        /// `removed` for an item whose original the server keeps (it has a compact copy, or was kept as is).
        public static let keptOriginal = "kept_original"
    }
}
