// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import HomespunCore

private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

@Test func fingerprintEncodingsRoundTrip() throws {
    let fingerprint = try #require(ServerKeyFingerprint(bytes: Data(0..<32)))
    #expect(fingerprint.base64url == "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8")
    #expect(fingerprint.display == "AAEC AwQF BgcI CQoL DA0O")
    #expect(fingerprint.curlPin == "sha256//AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=")
    #expect(ServerKeyFingerprint(base64url: fingerprint.base64url) == fingerprint)
    #expect(try ServerAPI.decoder.decode(ServerKeyFingerprint.self, from: ServerAPI.encoder.encode(fingerprint)) == fingerprint)
    for bad in ["", fingerprint.base64url + "=", String(fingerprint.base64url.dropLast()),
                String(repeating: "!", count: 43), String(fingerprint.base64url.dropLast()) + "9"] {
        #expect(ServerKeyFingerprint(base64url: bad) == nil)
    }
    #expect(ServerKeyFingerprint(bytes: Data(count: 31)) == nil)
}

@Test func pairingLinkCarriesTheServerKey() throws {
    let fingerprint = try #require(ServerKeyFingerprint(bytes: Data(0..<32)))
    let link = PairingLink(serverURL: URL(string: "https://192.168.1.20:8787")!, code: "K7Q4-M9XT",
                           name: "Linux Box", fingerprint: fingerprint)
    #expect(PairingLink(link.url) == link)
    #expect(link.url.absoluteString.contains("server=192.168.1.20:8787&code=K7Q4-M9XT&fp="))
    for suffix in ["", "bad", fingerprint.base64url + "=", fingerprint.base64url + "&fp=" + fingerprint.base64url] {
        #expect(PairingLink(URL(string: "homespun://pair?server=192.168.1.20:8787&code=X&fp=" + suffix)!) == nil)
    }
    let proxy = PairingLink(serverURL: URL(string: "https://photos.example.com")!, code: "K7Q4-M9XT")
    #expect(PairingLink(proxy.url) == proxy)
    #expect(!proxy.url.absoluteString.contains("fp="))
    #expect(PairingLink(URL(string: "homespun://pair?server=nas.local&code=X")!)?.fingerprint == nil)
}

@Test func sasAndCommitmentBindEveryInput() throws {
    let fingerprint = try #require(ServerKeyFingerprint(bytes: Data(0..<32)))
    let app = Data(32..<64), server = Data(64..<96)
    #expect(hex(PairingCrypto.commitment(nonce: app)) == "b242c816eb9ee93b8c8f7adac32271d01ffbea066e2b1a4f33378ab513389827")
    #expect(PairingCrypto.sas(fingerprint: fingerprint, appNonce: app, serverNonce: server) == "018599")
    let other = ServerKeyFingerprint(spki: Data("another key".utf8))
    #expect(PairingCrypto.sas(fingerprint: other, appNonce: app, serverNonce: server) != "018599")
    #expect(PairingCrypto.sas(fingerprint: fingerprint, appNonce: server, serverNonce: app) != "018599")
    // A six-digit SAS can collide. Check the distribution without a probabilistically failing test.
    let numbers = (0..<10_000).map { _ in
        PairingCrypto.sas(fingerprint: fingerprint, appNonce: PairingCrypto.nonce(), serverNonce: server)
    }
    #expect(numbers.allSatisfy { $0.count == 6 && $0.allSatisfy(\.isNumber) })
    #expect(Set(numbers).count > 9_800)
}

@Test func pbkdf2MatchesRFC7914() throws {
    #expect(hex(try PairingCrypto.pbkdf2(password: Data("passwd".utf8), salt: Data("salt".utf8), rounds: 1, count: 64))
        == "55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783")
    #expect(hex(try PairingCrypto.pbkdf2(password: Data("Password".utf8), salt: Data("NaCl".utf8), rounds: 80_000, count: 64))
        == "4ddcd8f60b98be21830cee5ef22701f9641a4418d04c0414aeff08876b34ab56a1d425a1225833549adb841b51c9b3176a272bdebba1d078478f62b397f33c8d")
}

@Test func codeProofVectors() throws {
    let fingerprint = try #require(ServerKeyFingerprint(bytes: Data(0..<32)))
    let nonce = Data(32..<64), salt = Data(0..<16), id = "01234567-89AB-CDEF-0123-456789ABCDEF"
    let key = try PairingCrypto.codeKey(codeHash: PairingCrypto.codeHash("k7q4-m9xt"), salt: salt)
    #expect(hex(key) == "cd8cc7a780a4447eb2794a0b60770e549055ac5e920ac21f3c596897d0b68289")
    #expect(hex(PairingCrypto.codeCheck(key: key, nonce: nonce, salt: salt, id: id))
        == "1751016209da8a47a3b90c71d8500e89bfac258abfacf7d798bce4889ba0c3af")
    #expect(hex(PairingCrypto.codeProof(key: key, fingerprint: fingerprint, nonce: nonce, salt: salt, id: id))
        == "fd785e97d414df9bb3d4b6b71505ea3245e80f697d2336f9415a6637adb4a259")
}

@Test func verifyProofAndKeyIDVectors() throws {
    let hash = PairingCrypto.tokenHash("test token")
    let fingerprint = try #require(ServerKeyFingerprint(bytes: Data(0..<32)))
    #expect(PairingCrypto.keyID(tokenHash: hash) == "3XVUf8Jf-oo4UbasRIMsnA")
    #expect(hex(PairingCrypto.verifyProof(tokenHash: hash, nonce: Data(32..<64), fingerprint: fingerprint))
        == "0e095582530b12255dbb96831bab6825f43fa708cf2423f20969a71f8634067c")
    #expect(try PairingCrypto.tokenHash(hex: hex(hash)) == hash)
    #expect(throws: PairingCrypto.Failure.self) { try PairingCrypto.tokenHash(hex: "not a hash") }
    #expect(PairingCrypto.equal(hash, hash))
    #expect(!PairingCrypto.equal(hash, Data(hash.dropLast())))
    #expect(!PairingCrypto.equal(hash, Data(count: 32)))
}

@Test func tlsWireTypesAreAdditiveAndUseSnakeCase() throws {
    let old = Data(#"{"server_name":"Server","can_approve":false,"pair_command":"homespun-server pair"}"#.utf8)
    let options = try ServerAPI.decoder.decode(ServerAPI.PairingOptions.self, from: old)
    #expect(options.pairingVersion == nil && options.encrypted == nil)
    let request = ServerAPI.IdentityRequest(keyID: "id", nonce: "nonce")
    let bytes = try ServerAPI.encoder.encode(request)
    #expect(String(decoding: bytes, as: UTF8.self) == #"{"key_id":"id","nonce":"nonce"}"#)
    #expect(try ServerAPI.decoder.decode(ServerAPI.IdentityRequest.self, from: bytes) == request)
}
