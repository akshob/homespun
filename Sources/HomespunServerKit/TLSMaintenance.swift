// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Logging
import ServiceLifecycle

struct TLSMaintenance: Service {
    let data: URL
    let identity: TLSIdentityBox
    let logger: Logger
    var interval: Duration = .seconds(10)

    func run() async throws {
        await cancelWhenGracefulShutdown {
            var modified = Date.distantPast
            var checked = Date.distantPast
            while !Task.isCancelled {
                do {
                    let now = Date()
                    let timestamp = try FileManager.default.attributesOfItem(atPath: TLSStore.identityFile(data).path)[.modificationDate]
                        as? Date ?? .distantPast
                    if timestamp != modified {
                        try identity.update(TLSStore.load(data: data))
                        modified = timestamp
                    }
                    if now.timeIntervalSince(checked) >= 86400 {
                        checked = now
                        if identity.current.notAfter.timeIntervalSince(now) < 90 * 86400 {
                            try identity.update(TLSStore.renew(data: data))
                            logger.notice("Renewed the server certificate with the same encryption key.")
                        }
                    }
                } catch {
                    identity.record(error: String(describing: error))
                    logger.error("Can't maintain the server certificate: \(error)")
                }
                try? await Task.sleep(for: interval)
            }
        }
    }
}
