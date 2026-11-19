// SPDX-License-Identifier: AGPL-3.0-only
import Hummingbird
import HummingbirdCore
import HummingbirdTLS
import NIOCore
import NIOSSL

func serverTLSConfiguration(_ identity: TLSIdentityBox) throws -> TLSConfiguration {
    let current = identity.override()
    var configuration = TLSConfiguration.makeServerConfiguration(certificateChain: current.certificateChain!,
                                                                 privateKey: current.privateKey!)
    configuration.minimumTLSVersion = .tlsv12
    configuration.cipherSuites = "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305"
    configuration.applicationProtocols = ["http/1.1"]
    configuration.sslContextCallback = { _, promise in promise.succeed(identity.override()) }
    return configuration
}

extension HTTPServerBuilder {
    static func homespun(identity: TLSIdentityBox, idleTimeout: TimeAmount = .seconds(60)) throws -> HTTPServerBuilder {
        try .tls(.http1(configuration: .init(idleTimeout: idleTimeout)), tlsConfiguration: serverTLSConfiguration(identity))
    }
}
