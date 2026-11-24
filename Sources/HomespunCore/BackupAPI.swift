// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Versioned backup control plane. Transport, compression and device delivery advance independently.
public enum BackupAPI {
    public static let version = 2

    public enum ValidationError: Error, Equatable, Sendable {
        case invalidManifest
        case invalidRecipe
    }

    public struct Origin: Codable, Equatable, Hashable, Sendable {
        public var serverID: String
        public var historyEpoch: String

        public init(serverID: String, historyEpoch: String) {
            self.serverID = serverID
            self.historyEpoch = historyEpoch
        }

        enum CodingKeys: String, CodingKey { case serverID = "serverId", historyEpoch }
    }

    public struct Manifest: Codable, Equatable, Sendable {
        public var kind: ServerAPI.AssetKind
        public var resources: [ServerAPI.ResourceDescriptor]

        public init(kind: ServerAPI.AssetKind, resources: [ServerAPI.ResourceDescriptor]) {
            self.kind = kind
            self.resources = resources
        }

        public func validated() throws -> Self {
            guard !resources.isEmpty, resources.count <= ServerAPI.ResourceRole.allCases.count,
                  Set(resources.map(\.role)).count == resources.count,
                  resources.allSatisfy({ $0.size > 0 && BackupAPI.isSHA256($0.sha256) }) else {
                throw ValidationError.invalidManifest
            }
            var total = 0
            for resource in resources {
                let (next, overflow) = total.addingReportingOverflow(resource.size)
                guard !overflow else { throw ValidationError.invalidManifest }
                total = next
            }
            let roles = Set(resources.map(\.role))
            let primary: ServerAPI.ResourceRole = kind == .video ? .video : .photo
            guard roles.contains(primary), kind != .livePhoto || roles.contains(.pairedVideo) else {
                throw ValidationError.invalidManifest
            }
            return self
        }

        public func assetID() throws -> String {
            let manifest = try validated()
            let role: ServerAPI.ResourceRole = kind == .video ? .video : .photo
            guard let primary = manifest.resources.first(where: { $0.role == role }) else {
                throw ValidationError.invalidManifest
            }
            return primary.sha256.lowercased()
        }

        /// Names and display metadata are deliberately not byte identity.
        public func identifier() throws -> String {
            let manifest = try validated()
            var fields = ["homespun.manifest.v1", kind.rawValue, String(resources.count)]
            for resource in manifest.resources.sorted(by: { $0.role.rawValue < $1.role.rawValue }) {
                fields += [resource.role.rawValue, String(resource.size), resource.sha256.lowercased()]
            }
            return Fingerprint.sha256(of: Data(fields.joined(separator: "\n").utf8))
        }
    }

    public struct Recipe: Codable, Equatable, Sendable {
        public var profile: CompressionProfile
        public var backend: String
        public var pipelineVersion: Int

        public init(profile: CompressionProfile, backend: String, pipelineVersion: Int) {
            self.profile = profile
            self.backend = backend
            self.pipelineVersion = pipelineVersion
        }

        public func identifier() throws -> String {
            guard profile.photoMaxEdge > 0, (1...100).contains(profile.photoQuality),
                  profile.videoLongEdge >= 2, profile.videoShortEdge >= 2,
                  profile.videoLongEdge >= profile.videoShortEdge,
                  (0...51).contains(profile.videoCRF), profile.audioBitrateKbps > 0,
                  !backend.isEmpty, backend.utf8.count <= 128,
                  backend.utf8.allSatisfy({
                      (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                          || [45, 46, 47, 95].contains($0)
                  }), pipelineVersion > 0 else {
                throw ValidationError.invalidRecipe
            }
            let fields = ["homespun.recipe.v1", backend, String(pipelineVersion),
                          String(profile.photoMaxEdge), String(profile.photoQuality),
                          String(profile.videoLongEdge), String(profile.videoShortEdge),
                          String(profile.videoCRF), String(profile.audioBitrateKbps)]
            return Fingerprint.sha256(of: Data(fields.joined(separator: "\n").utf8))
        }
    }

    public enum RetentionPolicy: String, Codable, Sendable {
        case permanent, deferred
    }

    public enum RetentionState: String, Codable, Sendable {
        case pending, permanent, deferred, external, unavailable
    }

    public enum BackupState: String, Codable, Sendable {
        case selected, preparing, uploading, verifying, retained, blocked, failed
    }

    public enum CompactState: String, Codable, Sendable {
        case requested, queued, processing, ready, held, failed
    }

    public enum DeliveryState: String, Codable, Sendable {
        case pending, downloading, validating
        case localMotionPending = "local_motion_pending"
        case importPlanned = "import_planned"
        case uncertain
        case importedVerified = "imported_verified"
    }

    public enum UploadProtocol: String, Codable, Sendable {
        case httpResumable = "http_resumable"
        case multipart
        case foregroundOffset = "foreground_offset"
    }

    public struct Capabilities: Codable, Equatable, Sendable {
        public var apiVersion: Int
        public var origin: Origin
        public var uploadProtocols: [UploadProtocol]
        public var recipe: Recipe
        public var maximumChanges: Int

        public init(origin: Origin, uploadProtocols: [UploadProtocol], recipe: Recipe, maximumChanges: Int = 200) {
            self.apiVersion = BackupAPI.version
            self.origin = origin
            self.uploadProtocols = uploadProtocols
            self.recipe = recipe
            self.maximumChanges = maximumChanges
        }
    }

    /// The authenticated principal plus operation ID is the idempotency key.
    public struct Request: Codable, Equatable, Sendable {
        public var operationID: UUID
        public var origin: Origin
        public var manifest: Manifest
        public var profile: CompressionProfile
        public var retention: RetentionPolicy
        public var compact: Bool
        public var captureDate: Date?

        public init(operationID: UUID, origin: Origin, manifest: Manifest, profile: CompressionProfile,
                    retention: RetentionPolicy = .permanent, compact: Bool = true, captureDate: Date? = nil) {
            self.operationID = operationID
            self.origin = origin
            self.manifest = manifest
            self.profile = profile
            self.retention = retention
            self.compact = compact
            self.captureDate = captureDate
        }

        enum CodingKeys: String, CodingKey {
            case operationID = "operationId", origin, manifest, profile, retention, compact, captureDate
        }
    }

    public struct Version: Codable, Equatable, Hashable, Sendable {
        public var origin: Origin
        public var assetID: String
        public var manifestID: String
        public var descriptorGeneration: Int64
        public var recipeID: String

        public init(origin: Origin, assetID: String, manifestID: String, descriptorGeneration: Int64, recipeID: String) {
            self.origin = origin
            self.assetID = assetID
            self.manifestID = manifestID
            self.descriptorGeneration = descriptorGeneration
            self.recipeID = recipeID
        }

        enum CodingKeys: String, CodingKey {
            case origin, assetID = "assetId", manifestID = "manifestId", descriptorGeneration, recipeID = "recipeId"
        }
    }

    public struct Derivative: Codable, Equatable, Sendable {
        public var generationID: UUID
        public var version: Version
        public var resources: [ServerAPI.CompactResource]
        public var deviceCompresses: [ServerAPI.ResourceRole]

        public init(generationID: UUID, version: Version, resources: [ServerAPI.CompactResource],
                    deviceCompresses: [ServerAPI.ResourceRole] = []) {
            self.generationID = generationID
            self.version = version
            self.resources = resources
            self.deviceCompresses = deviceCompresses
        }

        enum CodingKeys: String, CodingKey {
            case generationID = "generationId", version, resources, deviceCompresses
        }
    }

    public struct Receipt: Codable, Equatable, Sendable {
        public var requestID: UUID
        public var operationID: UUID
        public var version: Version
        public var revision: Int64
        public var backup: BackupState
        public var compact: CompactState
        public var retention: RetentionState
        public var originals: [ServerAPI.ResourceStatus]
        public var derivative: Derivative?
        public var message: String?

        public init(requestID: UUID, operationID: UUID, version: Version, revision: Int64, backup: BackupState,
                    compact: CompactState, retention: RetentionState, originals: [ServerAPI.ResourceStatus],
                    derivative: Derivative? = nil, message: String? = nil) {
            self.requestID = requestID
            self.operationID = operationID
            self.version = version
            self.revision = revision
            self.backup = backup
            self.compact = compact
            self.retention = retention
            self.originals = originals
            self.derivative = derivative
            self.message = message
        }

        enum CodingKeys: String, CodingKey {
            case requestID = "requestId", operationID = "operationId"
            case version, revision, backup, compact, retention, originals, derivative, message
        }
    }

    public struct Change: Codable, Equatable, Sendable {
        public var sequence: Int64
        public var receipt: Receipt
        public init(sequence: Int64, receipt: Receipt) {
            self.sequence = sequence
            self.receipt = receipt
        }
    }

    public struct Changes: Codable, Equatable, Sendable {
        public var origin: Origin
        public var cursor: Int64
        public var hasMore: Bool
        public var changes: [Change]
        public init(origin: Origin, cursor: Int64, hasMore: Bool, changes: [Change]) {
            self.origin = origin
            self.cursor = cursor
            self.hasMore = hasMore
            self.changes = changes
        }
    }

    public struct Snapshot: Codable, Equatable, Sendable {
        public var origin: Origin
        public var cursor: Int64
        public var receipts: [Receipt]
        public var continuation: String?
        public init(origin: Origin, cursor: Int64, receipts: [Receipt], continuation: String? = nil) {
            self.origin = origin
            self.cursor = cursor
            self.receipts = receipts
            self.continuation = continuation
        }
    }

    public struct DeliveryAcknowledgement: Codable, Equatable, Sendable {
        public var deliveryID: UUID
        public var requestID: UUID
        public var generationID: UUID
        public var version: Version
        public init(deliveryID: UUID, requestID: UUID, generationID: UUID, version: Version) {
            self.deliveryID = deliveryID
            self.requestID = requestID
            self.generationID = generationID
            self.version = version
        }
        enum CodingKeys: String, CodingKey {
            case deliveryID = "deliveryId", requestID = "requestId", generationID = "generationId", version
        }
    }

    public enum CommandAction: String, Codable, Sendable {
        case pause, cancel, retry
        case compactNow = "compact_now"
    }

    public struct Command: Codable, Equatable, Sendable {
        public var operationID: UUID
        public var version: Version
        public var action: CommandAction
        public init(operationID: UUID, version: Version, action: CommandAction) {
            self.operationID = operationID
            self.version = version
            self.action = action
        }
        enum CodingKeys: String, CodingKey { case operationID = "operationId", version, action }
    }

    public struct UploadRequest: Codable, Equatable, Sendable {
        public var uploadID: UUID
        public var requestID: UUID
        public var version: Version
        public var role: ServerAPI.ResourceRole
        public init(uploadID: UUID, requestID: UUID, version: Version, role: ServerAPI.ResourceRole) {
            self.uploadID = uploadID
            self.requestID = requestID
            self.version = version
            self.role = role
        }
        enum CodingKeys: String, CodingKey {
            case uploadID = "uploadId", requestID = "requestId", version, role
        }
    }

    public struct UploadAdmission: Codable, Equatable, Sendable {
        public var upload: UploadRequest
        public var uploadProtocol: UploadProtocol
        public var offset: Int64
        public var size: Int64
        public var maximumChunkBytes: Int64
        public init(upload: UploadRequest, uploadProtocol: UploadProtocol, offset: Int64, size: Int64,
                    maximumChunkBytes: Int64) {
            self.upload = upload
            self.uploadProtocol = uploadProtocol
            self.offset = offset
            self.size = size
            self.maximumChunkBytes = maximumChunkBytes
        }
    }

    public enum ErrorCode {
        public static let historyChanged = "history_changed"
        public static let snapshotRequired = "snapshot_required"
        public static let idempotencyConflict = "idempotency_conflict"
        public static let versionChanged = "version_changed"
    }

    public struct OriginalProof: Codable, Equatable, Sendable {
        public var version: Version
        public var retention: RetentionState
        public var claimID: UUID?
        public var verifiedAt: Date
        public var resources: [ServerAPI.ResourceStatus]
        public init(version: Version, retention: RetentionState, claimID: UUID?, verifiedAt: Date,
                    resources: [ServerAPI.ResourceStatus]) {
            self.version = version
            self.retention = retention
            self.claimID = claimID
            self.verifiedAt = verifiedAt
            self.resources = resources
        }
        enum CodingKeys: String, CodingKey {
            case version, retention, claimID = "claimId", verifiedAt, resources
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.lowercased().utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}
