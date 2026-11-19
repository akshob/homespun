// SPDX-License-Identifier: Apache-2.0
import Foundation
import Security

func serverTrustFixture() throws -> SecTrust {
    let bytes = Data(base64Encoded: """
        MIIBpjCCAUugAwIBAgIUbiMnX4ZhPz9mj7u4KdIJPiuw3UEwCgYIKoZIzj0EAwIwGjEYMBYGA1UEAwwPSG9tZXNwdW4gU2VydmVyMB4XDTI2MTExODE3MjYxN1oXDTI5MDIyMDE3MjYxN1owGjEYMBYGA1UEAwwPSG9tZXNwdW4gU2VydmVyMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEFzpgvUqCIGzM0ofHMz7//5xDTR27yZg7m1aEXyNs7y9f3BxneuJr2j3ggBPzPtw5TI17dhyg6OlXgkRuIVm2yqNvMG0wHQYDVR0OBBYEFB1PUhJ9H/TN71UckiRJ3nk0gU8mMB8GA1UdIwQYMBaAFB1PUhJ9H/TN71UckiRJ3nk0gU8mMA8GA1UdEwEB/wQFMAMBAf8wGgYDVR0RBBMwEYIJbG9jYWxob3N0hwR/AAABMAoGCCqGSM49BAMCA0kAMEYCIQDBjU4YMPr/j8goHVKxv0R3r9FlbuGmxp9/TWZ2RB0CggIhAMf9aUieCOqjtvud/ZSy5zSmMpb+3Jb5KHWTeplJ35Ab
        """)!
    guard let certificate = SecCertificateCreateWithData(nil, bytes as CFData) else {
        throw ServerTrustFixtureFailure.invalidCertificate
    }
    var trust: SecTrust?
    let status = SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(true, nil), &trust)
    guard status == errSecSuccess, let trust else { throw ServerTrustFixtureFailure.invalidTrust(status) }
    return trust
}

private enum ServerTrustFixtureFailure: Error {
    case invalidCertificate
    case invalidTrust(OSStatus)
}
