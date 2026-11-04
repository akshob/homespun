// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import RoundtripCore

@Test func photoSizeFitsLongEdgeWithoutUpscaling() {
    let profile = CompressionProfile.standard
    #expect(profile.photoSize(width: 4032, height: 3024) == (2048, 1536))
    #expect(profile.photoSize(width: 3024, height: 4032) == (1536, 2048))
    #expect(profile.photoSize(width: 1200, height: 800) == (1200, 800))
}

@Test func videoSizeFitsOrientationBoxWithEvenDimensions() {
    let profile = CompressionProfile.standard
    #expect(profile.videoSize(width: 1920, height: 1080) == (1280, 720))
    #expect(profile.videoSize(width: 1080, height: 1920) == (720, 1280))
    #expect(profile.videoSize(width: 3840, height: 2160) == (1280, 720))
    #expect(profile.videoSize(width: 640, height: 480) == (640, 480))
    let odd = profile.videoSize(width: 1281, height: 721)
    #expect(odd.width % 2 == 0 && odd.height % 2 == 0 && odd.width <= 1280 && odd.height <= 720)
}

@Test func sha256MatchesKnownVector() throws {
    #expect(Fingerprint.sha256(of: Data("abc".utf8))
        == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data("abc".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(try Fingerprint.sha256(of: url, chunkSize: 1) == Fingerprint.sha256(of: Data("abc".utf8)))
}

@Test func manifestUsesSnakeCaseAndRoundTrips() throws {
    let manifest = DownloadManifest(
        assetID: "abc", captureDate: Date(timeIntervalSince1970: 1_700_000_000),
        resources: [.init(role: .pairedVideo, downloadURL: URL(string: "https://h/x.mov")!,
                          sha256: "def", size: 10)])
    let data = try DownloadManifest.encoder.encode(manifest)
    let text = String(decoding: data, as: UTF8.self)
    #expect(text.contains("\"asset_id\"") && text.contains("\"download_url\"") && text.contains("\"paired_video\""))
    #expect(try DownloadManifest.decoder.decode(DownloadManifest.self, from: data) == manifest)
}

@Test func deletionGateRequiresMatchingServerCopyAndImport() {
    let gate = DeletionGate()
    func check(_ server: String?, _ serverSize: Int?, size: Int = 10, imported: Bool = true) -> DeletionGate.Decision {
        gate.evaluate(deviceOriginalSHA256: "AB", serverOriginalSHA256: server, serverOriginalSize: serverSize,
                      deviceOriginalSize: size, compactImported: imported)
    }
    #expect(check("ab", 10) == .allowed)
    #expect(check(nil, nil) == .blocked("server has no verified copy"))
    #expect(check("ab", 9) == .blocked("size mismatch"))
    #expect(check("cd", 10) == .blocked("hash mismatch"))
    #expect(check("ab", 10, imported: false) == .blocked("compact copy not imported yet"))
    #expect(check("ab", 0, size: 0) == .blocked("zero-byte original"))
}
