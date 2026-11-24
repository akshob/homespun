// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import HomespunCore

private func backupManifest(_ primary: String = String(repeating: "a", count: 64),
                            motion: String = String(repeating: "b", count: 64)) -> BackupAPI.Manifest {
    .init(kind: .livePhoto, resources: [
        .init(role: .photo, filename: "photo.heic", size: 100, sha256: primary),
        .init(role: .pairedVideo, filename: "motion.mov", size: 200, sha256: motion),
    ])
}

@Test func backupManifestUsesCompleteCanonicalResourceIdentity() throws {
    let original = backupManifest()
    var reordered = original
    reordered.resources.reverse()
    reordered.resources[0].filename = "a different display name.mov"
    reordered.resources[0].sha256 = reordered.resources[0].sha256.uppercased()
    #expect(try original.identifier() == reordered.identifier())
    #expect(try original.assetID() == reordered.assetID())

    let editedMotion = backupManifest(motion: String(repeating: "c", count: 64))
    #expect(try original.assetID() == editedMotion.assetID())
    #expect(try original.identifier() != editedMotion.identifier())
    var resized = original
    resized.resources[1].size += 1
    #expect(try original.identifier() != resized.identifier())
}

@Test func backupManifestRejectsAmbiguousAndIncompleteIdentity() throws {
    let original = backupManifest()
    var duplicate = original
    duplicate.resources.append(original.resources[0])
    var missingMotion = original
    missingMotion.resources.removeLast()
    var empty = original
    empty.resources[0].size = 0
    var invalidHash = original
    invalidHash.resources[0].sha256 = String(repeating: "z", count: 64)
    var missingPrimary = original
    missingPrimary.resources.removeFirst()
    for candidate in [duplicate, missingMotion, empty, invalidHash, missingPrimary] {
        #expect(throws: BackupAPI.ValidationError.invalidManifest) { try candidate.identifier() }
    }
}

@Test func backupRecipeChangesWithProfileAndPipeline() throws {
    let original = BackupAPI.Recipe(profile: .standard, backend: "libvips-x265", pipelineVersion: 1)
    var newPipeline = original
    newPipeline.pipelineVersion += 1
    var newProfile = original
    newProfile.profile.videoCRF += 1
    var newBackend = original
    newBackend.backend = "imageio-avfoundation"
    for changed in [newPipeline, newProfile, newBackend] {
        #expect(try original.identifier() != changed.identifier())
    }
    var invalid = original
    invalid.profile.videoCRF = -1
    #expect(throws: BackupAPI.ValidationError.invalidRecipe) { try invalid.identifier() }
}

@Test func versionedBackupRoundTripsAcronymsAndIndependentStates() throws {
    let origin = BackupAPI.Origin(serverID: UUID().uuidString, historyEpoch: UUID().uuidString)
    let manifest = backupManifest()
    let recipe = BackupAPI.Recipe(profile: .standard, backend: "libvips-x265", pipelineVersion: 1)
    let version = BackupAPI.Version(origin: origin, assetID: try manifest.assetID(),
                                    manifestID: try manifest.identifier(), descriptorGeneration: 3,
                                    recipeID: try recipe.identifier())
    let request = BackupAPI.Request(operationID: UUID(), origin: origin, manifest: manifest,
                                    profile: .standard, compact: false)
    let requestData = try ServerAPI.encoder.encode(request)
    #expect(try ServerAPI.decoder.decode(BackupAPI.Request.self, from: requestData) == request)
    let requestJSON = String(decoding: requestData, as: UTF8.self)
    #expect(requestJSON.contains("\"operation_id\""))
    #expect(requestJSON.contains("\"server_id\""))
    #expect(requestJSON.contains("\"video_crf\":28"))

    let retainedWithFailedCompact = BackupAPI.Receipt(
        requestID: UUID(), operationID: request.operationID, version: version, revision: 3, backup: .retained,
        compact: .failed, retention: .permanent, originals: [], message: "compression_failed")
    let page = BackupAPI.Changes(origin: origin, cursor: 9, hasMore: false,
                                 changes: [.init(sequence: 9, receipt: retainedWithFailedCompact)])
    let data = try ServerAPI.encoder.encode(page)
    #expect(try ServerAPI.decoder.decode(BackupAPI.Changes.self, from: data) == page)
    let text = String(decoding: data, as: UTF8.self)
    for key in ["\"asset_id\"", "\"manifest_id\"", "\"recipe_id\"", "\"request_id\"", "\"operation_id\""] {
        #expect(text.contains(key))
    }
    let command = BackupAPI.Command(operationID: UUID(), version: version, action: .compactNow)
    #expect(try ServerAPI.decoder.decode(BackupAPI.Command.self, from: ServerAPI.encoder.encode(command)) == command)
    #expect(page.changes[0].receipt.backup == .retained)
    #expect(page.changes[0].receipt.compact == .failed)
}
