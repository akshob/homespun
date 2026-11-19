// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import HomespunCore

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
    let digests = try Fingerprint.digests(of: url, chunkSize: 2)
    #expect(digests.sha1 == "a9993e364706816aba3e25717850c26c9cd0d89d" && digests.size == 3)
    #expect(digests.sha256 == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
}

@Test func serverAPIUsesSnakeCaseAndRoundTrips() throws {
    let status = ServerAPI.AssetStatus(
        assetID: "abc", kind: .livePhoto, state: .ready, message: nil,
        resources: [.init(role: .pairedVideo, sha256: "def", size: 10, state: .verified, receivedBytes: 10,
                          verifiedAt: Date(timeIntervalSince1970: 1_700_000_000))],
        compact: [.init(role: .photo, filename: "IMG_1.jpg", size: 5, sha256: "123")],
        deviceCompresses: [.pairedVideo])
    let data = try ServerAPI.encoder.encode(status)
    let text = String(decoding: data, as: UTF8.self)
    for key in ["\"asset_id\"", "\"live_photo\"", "\"paired_video\"", "\"received_bytes\"", "\"device_compresses\"",
                "\"verified_at\":\"2023-11-14T22:13:20Z\""] {
        #expect(text.contains(key), "\(key) in \(text)")
    }
    #expect(try ServerAPI.decoder.decode(ServerAPI.AssetStatus.self, from: data) == status)
    let pair = try ServerAPI.encoder.encode(ServerAPI.PairResponse(
        deviceID: "d", token: "t", server: .init(name: "n", version: "v", mode: .immich, profile: .standard)))
    #expect(String(decoding: pair, as: UTF8.self).contains("\"device_id\":\"d\""))
    let request = ServerAPI.RegisterAssetRequest(kind: .video, captureDate: nil, resources: [
        .init(role: .fullSizeVideo, filename: "a", size: 1, sha256: "AA"), .init(role: .video, filename: "b", size: 1, sha256: "BB")])
    #expect(request.assetID == "bb")
}

@Test func multiResourceGateNeedsEveryResourceVerified() {
    let gate = DeletionGate()
    let photo = DeletionGate.Resource(role: "photo", sha256: "aa", size: 5)
    let motion = DeletionGate.Resource(role: "paired_video", sha256: "bb", size: 9)
    #expect(gate.evaluate(deviceResources: [photo, motion], serverVerified: [motion, photo], compactImported: true) == .allowed)
    #expect(gate.evaluate(deviceResources: [photo, motion], serverVerified: [photo], compactImported: true)
            == .blocked("paired_video: server has no verified copy"))
    #expect(gate.evaluate(deviceResources: [photo], serverVerified: [photo], compactImported: false)
            == .blocked("photo: compact copy not imported yet"))
    #expect(gate.evaluate(deviceResources: [], serverVerified: [photo], compactImported: true) != .allowed)
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

@Test func pairingLinksRoundTripAndParseFromText() throws {
    let link = PairingLink(serverURL: URL(string: "https://192.168.1.20:8787")!, code: "K7Q4-M9XT", name: "Linux Box (test)")
    #expect(link.url.absoluteString == "homespun://pair?server=https://192.168.1.20:8787&code=K7Q4-M9XT&name=Linux%20Box%20(test)")
    #expect(PairingLink(link.url) == link)
    #expect(PairingLink(text: "Pairing link: \(link.url.absoluteString)\n") == link)
    let https = PairingLink(serverURL: URL(string: "https://home.example.com")!, code: "ABCD-EFGH")
    #expect(PairingLink(https.url)?.serverURL.absoluteString == "https://home.example.com")
    #expect(PairingLink(URL(string: "homespun://pair?server=nas.local&code=X")!)?.serverURL.absoluteString
            == "https://nas.local:8787")
    #expect(PairingLink.serverURL(from: "http://192.168.1.20:8787")?.scheme == "https")
    #expect(PairingLink(URL(string: "https://pair?server=a&code=b")!) == nil)
    #expect(PairingLink(URL(string: "homespun://pair?server=a")!) == nil)
    #expect(PairingLink.serverURL(from: "file:///etc") == nil)
}

@Test func linuxPlatformPicksPackageManager() {
    let ubuntu = ServerSetup.Platform.linux(osRelease: "PRETTY_NAME=\"Ubuntu 24.04.3 LTS\"\nID=ubuntu\nID_LIKE=debian\n")
    #expect(ubuntu.packageManager == .apt && ubuntu.name == "Ubuntu 24.04.3 LTS")
    #expect(ServerSetup.Platform.linux(osRelease: "ID=fedora\n").packageManager == .dnf)
    #expect(ServerSetup.Platform.linux(osRelease: "ID=\"rocky\"\nID_LIKE=\"rhel centos fedora\"").packageManager == .dnf)
    #expect(ServerSetup.Platform.linux(osRelease: "ID=nixos").packageManager == nil)
    let mac = ServerSetup.installSteps(for: .macOS)
    #expect(mac.contains { $0.commands.contains("brew install ffmpeg") })
    #expect(ServerSetup.installSteps(for: .linux, packageManager: .pacman).first?.commands.first?.hasPrefix("sudo pacman") == true)
}

@Test func phoneItemsAreClassifiedByTheServersAnswers() {
    typealias Match = ServerAPI.CopyLookupResponse.Match
    func match(_ hash: String, _ asset: String, _ role: ServerAPI.ResourceRole, original: Bool = false,
               verified: Bool = true) -> (String, Match) {
        (hash, Match(sha256: hash, assetID: asset, role: role, isOriginal: original, originalsVerified: verified,
                     originalBytes: 900))
    }
    let matches = Dictionary(uniqueKeysWithValues: [
        match("s", "A", .photo), match("m", "A", .pairedVideo, original: true), match("v", "B", .video, original: true),
        match("x", "C", .photo, verified: false), match("y", "B", .photo),
    ])
    // A Live Photo whose motion was kept as is is still a compact copy; an edit doesn't count.
    #expect(CopyMatching.classify([.photo: "S", .pairedVideo: "m", .adjustmentData: "edit"], matches: matches)
            == .copy(assetID: "A", originalBytes: 900))
    #expect(CopyMatching.classify([.video: "v"], matches: matches) == .original(assetID: "B"))
    #expect(CopyMatching.classify([.photo: "s"], matches: matches) == .copy(assetID: "A", originalBytes: 900))
    #expect(CopyMatching.classify([.photo: "s", .pairedVideo: "other"], matches: matches) == .partial)
    #expect(CopyMatching.classify([.photo: "s", .pairedVideo: "v"], matches: matches) == .partial)
    #expect(CopyMatching.classify([.video: "s"], matches: matches) == .partial)
    #expect(CopyMatching.classify([.photo: "x"], matches: matches) == .partial)
    #expect(CopyMatching.classify([.photo: "nothing"], matches: matches) == .unknown)
    #expect(CopyMatching.classify([.adjustmentData: "s"], matches: matches) == .unknown)
}
