// SPDX-License-Identifier: AGPL-3.0-only
import Crypto
import Foundation
import HomespunCore
import NIOConcurrencyHelpers
import NIOSSL
import SwiftASN1
import X509
#if os(Linux)
import Glibc
#else
import Darwin
#endif

public struct TLSIdentity: Sendable {
    public let fingerprint: ServerKeyFingerprint
    public let notAfter: Date
    private let privateKeyBytes: Data
    var privateKey: P256.Signing.PrivateKey { get throws { try P256.Signing.PrivateKey(rawRepresentation: privateKeyBytes) } }
    let certificateDER: [UInt8]
    let names: TLSNames

    init(key: P256.Signing.PrivateKey, certificate: Certificate, names: TLSNames) throws {
        guard let publicKey = P256.Signing.PublicKey(certificate.publicKey),
              publicKey.derRepresentation == key.publicKey.derRepresentation else { throw TLSStore.Failure.unreadable }
        // subjectPublicKeyInfoBytes is only the key bits, not the DER SubjectPublicKeyInfo.
        fingerprint = ServerKeyFingerprint(spki: publicKey.derRepresentation)
        privateKeyBytes = key.rawRepresentation
        notAfter = certificate.notValidAfter
        var serializer = DER.Serializer()
        try serializer.serialize(certificate)
        certificateDER = serializer.serializedBytes
        self.names = names
    }

    var certificate: NIOSSLCertificate { get throws { try NIOSSLCertificate(bytes: certificateDER, format: .der) } }
    var key: NIOSSLPrivateKey { get throws { try NIOSSLPrivateKey(bytes: Array(privateKey.pemRepresentation.utf8), format: .pem) } }
}

struct TLSNames: Sendable {
    var hostnames: [String]
    var addresses: [String]

    static func current() -> Self {
        let host = ProcessInfo.processInfo.hostName
        let local = host.hasSuffix(".local") ? host : host + ".local"
        return Self(hostnames: Array(Set(["localhost", host, local])).sorted(),
                    addresses: Array(Set(["127.0.0.1"] + Network.interfaces().map(\.address))).sorted())
    }
}

enum TLSStore {
    enum Failure: Error, CustomStringConvertible {
        case unreadable
        var description: String {
            "Can't read the server's encryption identity. Restore tls/ from your backup, or move the tls folder "
                + "away to make a new key; paired iPhones confirm the new key automatically."
        }
    }

    static func folder(_ data: URL) -> URL { data.appendingPathComponent("tls", isDirectory: true) }
    static func identityFile(_ data: URL) -> URL { folder(data).appendingPathComponent("identity.pem") }
    static func certificateFile(_ data: URL) -> URL { folder(data).appendingPathComponent("certificate.pem") }

    static func loadOrCreate(data: URL, names: TLSNames = .current(), now: Date = Date()) throws -> (TLSIdentity, created: Bool) {
        let files = FileManager.default, destination = folder(data)
        if files.fileExists(atPath: destination.path) { return (try load(data: data), false) }
        let staging = data.appendingPathComponent("tls.\(UUID().uuidString).new", isDirectory: true)
        try files.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: staging) }
        let key = P256.Signing.PrivateKey()
        let certificate = try makeCertificate(key: key, names: names, now: now)
        try write(key: key, certificate: certificate, to: staging)
        if rename(staging.path, destination.path) != 0 {
            guard files.fileExists(atPath: destination.path) else { throw CocoaError(.fileWriteUnknown) }
            return (try load(data: data), false)
        }
        try syncDirectory(data)
        return (try TLSIdentity(key: key, certificate: certificate, names: names), true)
    }

    static func load(data: URL) throws -> TLSIdentity {
        do {
            let files = FileManager.default
            try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder(data).path)
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: identityFile(data).path)
            let pem = try String(contentsOf: identityFile(data), encoding: .utf8)
            let documents = try PEMDocument.parseMultiple(pemString: pem)
            guard documents.count == 2, let keyPEM = documents.first(where: { $0.discriminator == "PRIVATE KEY" }),
                  let certPEM = documents.first(where: { $0.discriminator == "CERTIFICATE" }) else { throw Failure.unreadable }
            let key = try P256.Signing.PrivateKey(pemRepresentation: keyPEM.pemString)
            let certificate = try Certificate(pemEncoded: certPEM.pemString)
            let sans = try certificate.extensions.subjectAlternativeNames
            let names = TLSNames(hostnames: sans?.compactMap { if case .dnsName(let name) = $0 { return name }; return nil } ?? [],
                                 addresses: [])
            return try TLSIdentity(key: key, certificate: certificate, names: names)
        } catch { throw Failure.unreadable }
    }

    static func renew(data: URL, names: TLSNames = .current(), now: Date = Date()) throws -> TLSIdentity {
        let key = try load(data: data).privateKey
        let certificate = try makeCertificate(key: key, names: names, now: now)
        try write(key: key, certificate: certificate, to: folder(data))
        return try TLSIdentity(key: key, certificate: certificate, names: names)
    }

    static func replaceKey(data: URL, names: TLSNames = .current(), now: Date = Date()) throws -> TLSIdentity {
        _ = try load(data: data)
        let backup = folder(data).appendingPathComponent("previous-\(Int(now.timeIntervalSince1970))-\(UUID().uuidString).pem")
        try atomicWrite(Data(contentsOf: identityFile(data)), to: backup, mode: 0o600)
        let key = P256.Signing.PrivateKey()
        let certificate = try makeCertificate(key: key, names: names, now: now)
        try write(key: key, certificate: certificate, to: folder(data))
        return try TLSIdentity(key: key, certificate: certificate, names: names)
    }

    static func makeCertificate(key: P256.Signing.PrivateKey, names: TLSNames, now: Date) throws -> Certificate {
        let name = try DistinguishedName { CommonName("Homespun Server") }
        let alternativeNames: [GeneralName] = names.hostnames.map { .dnsName($0) } + names.addresses.compactMap { address in
            let bytes = address.split(separator: ".").compactMap { UInt8($0) }
            return bytes.count == 4 ? .ipAddress(ASN1OctetString(contentBytes: bytes[...])) : nil
        }
        let extensions = try Certificate.Extensions {
            Critical(BasicConstraints.notCertificateAuthority)
            try ExtendedKeyUsage([.serverAuth])
            SubjectAlternativeNames(alternativeNames)
        }
        let signingKey = Certificate.PrivateKey(key)
        return try Certificate(version: .v3, serialNumber: .init(), publicKey: signingKey.publicKey,
                               notValidBefore: now.addingTimeInterval(-3600),
                               notValidAfter: now.addingTimeInterval(825 * 86400),
                               issuer: name, subject: name, signatureAlgorithm: .ecdsaWithSHA256,
                               extensions: extensions, issuerPrivateKey: signingKey)
    }

    private static func write(key: P256.Signing.PrivateKey, certificate: Certificate, to folder: URL) throws {
        let pem = try certificate.serializeAsPEM().pemString + "\n"
        try atomicWrite(Data((key.pemRepresentation + "\n" + pem).utf8),
                        to: folder.appendingPathComponent("identity.pem"), mode: 0o600)
        try atomicWrite(Data(pem.utf8), to: folder.appendingPathComponent("certificate.pem"), mode: 0o644)
        try syncDirectory(folder)
    }

    private static func atomicWrite(_ bytes: Data, to destination: URL, mode: mode_t) throws {
        let staging = destination.appendingPathExtension("\(UUID().uuidString).new")
        let descriptor = open(staging.path, O_WRONLY | O_CREAT | O_EXCL, mode)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: staging) }
        try handle.write(contentsOf: bytes)
        guard fchmod(descriptor, mode) == 0 else { throw CocoaError(.fileWriteNoPermission) }
        try handle.synchronize()
        guard rename(staging.path, destination.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    private static func syncDirectory(_ folder: URL) throws {
        let descriptor = open(folder.path, O_RDONLY)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}

public final class TLSIdentityBox: Sendable {
    private struct State: Sendable {
        var identity: TLSIdentity
        var certificate: NIOSSLCertificate
        var key: NIOSSLPrivateKey
        var renewalError: String?
    }
    private let state: NIOLockedValueBox<State>

    init(_ identity: TLSIdentity) throws {
        state = try NIOLockedValueBox(State(identity: identity, certificate: identity.certificate, key: identity.key))
    }

    public var current: TLSIdentity { state.withLockedValue { $0.identity } }
    var renewalError: String? { state.withLockedValue { $0.renewalError } }
    func record(error: String) { state.withLockedValue { $0.renewalError = error } }

    func update(_ identity: TLSIdentity) throws {
        let certificate = try identity.certificate, key = try identity.key
        state.withLockedValue { $0 = State(identity: identity, certificate: certificate, key: key) }
    }

    func override() -> NIOSSLContextConfigurationOverride {
        state.withLockedValue {
            var override = NIOSSLContextConfigurationOverride()
            override.certificateChain = [.certificate($0.certificate)]
            override.privateKey = .privateKey($0.key)
            return override
        }
    }
}
