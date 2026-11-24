// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import HomespunCore
import Hummingbird
import Logging
import NIOCore
import ServiceLifecycle

struct WakeRelay: Sendable {
    let store: WakeRelayStore
    let environment: WakeRelayAPI.Environment

    func router() -> Router<HomespunRequestContext> {
        let router = Router(context: HomespunRequestContext.self)
        // Deliberately no request/path logging: tokens, IPs and route activity are not analytics.
        router.get("health") { _, _ in Response(status: .ok) }
        router.post("v1/routes/:id/begin") { request, context in
            try await mapped {
                let body = try await request.body.collect(upTo: 16)
                guard body.readableBytes == 0 else { throw HTTPError(.badRequest) }
                return try json(await store.begin(id: routeID(context), managementToken: bearer(request), now: Date()), status: .created)
            }
        }
        router.put("v1/routes/:id") { request, context in
            try await mapped {
                let body = try await decode(WakeRelayAPI.Activation.self, request,
                                             keys: ["generation_id", "device_token", "environment", "sender_token"])
                guard body.environment == environment else { throw HTTPError(.badRequest, message: "Unsupported push environment.") }
                try await store.activate(id: routeID(context), managementToken: bearer(request), body: body, now: Date())
                return Response(status: .noContent)
            }
        }
        router.post("v1/routes/:id/hint") { request, context in
            try await mapped {
                let body = try await decode(WakeRelayAPI.Hint.self, request, keys: ["generation_id", "nonce"])
                try await store.hint(id: routeID(context), senderToken: bearer(request), body: body, now: Date())
                return Response(status: .accepted)
            }
        }
        router.delete("v1/routes/:id") { request, context in
            try await mapped {
                let body = try await request.body.collect(upTo: 16)
                guard body.readableBytes == 0 else { throw HTTPError(.badRequest) }
                try await store.erase(id: routeID(context), managementToken: bearer(request))
                return Response(status: .noContent)
            }
        }
        return router
    }

    private func mapped(_ operation: () async throws -> Response) async throws -> Response {
        do { return try await operation() }
        catch let failure as WakeRelayFailure {
            switch failure {
            case .invalidInput: throw HTTPError(.badRequest, message: "Invalid wake request.")
            case .unauthorized: throw HTTPError(.unauthorized, message: "Not authorized.")
            case .notFound: throw HTTPError(.notFound, message: "Enrollment is no longer available.")
            case .generationChanged: throw HTTPError(.conflict, message: "Start a new enrollment.")
            case .capacity: throw HTTPError(.serviceUnavailable, message: "Enrollment is temporarily unavailable.")
            case .corruptStorage: throw HTTPError(.internalServerError, message: "Wake storage is unavailable.")
            }
        }
    }

    private func decode<Value: Decodable>(_ type: Value.Type, _ request: Request,
                                         keys: Set<String>) async throws -> Value {
        let bytes = try await request.body.collect(upTo: 2_048)
        let data = Data(bytes.readableBytesView)
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys) == keys else { throw WakeRelayFailure.invalidInput }
            return try ServerAPI.decoder.decode(type, from: data)
        } catch { throw HTTPError(.badRequest, message: "Invalid wake request.") }
    }

    private func routeID(_ context: HomespunRequestContext) throws -> UUID {
        guard let raw = context.parameters.get("id"), let id = UUID(uuidString: raw) else { throw WakeRelayFailure.invalidInput }
        return id
    }

    private func bearer(_ request: Request) throws -> String {
        guard let value = request.headers[.authorization], value.hasPrefix("Bearer ") else { throw WakeRelayFailure.unauthorized }
        return String(value.dropFirst(7))
    }
}

struct WakeRelayWorker: Service {
    let store: WakeRelayStore
    let provider: APNsWakeProvider
    let logger: Logger

    func run() async throws {
        let owner = UUID()
        try await cancelWhenGracefulShutdown {
            while !Task.isCancelled {
                guard let lease = try await store.claim(owner: owner, now: Date()) else {
                    try await Task.sleep(for: .seconds(1))
                    continue
                }
                let outcome: WakeRelayStore.Outcome
                do {
                    outcome = try await provider.send(lease)
                } catch is CancellationError {
                    try await store.finish(lease, outcome: .retry)
                    throw CancellationError()
                } catch {
                    logger.error("Wake provider request failed; the hint remains queued.")
                    try await store.finish(lease, outcome: .retry)
                    continue
                }
                if case .retry = outcome { logger.warning("Wake provider could not accept a hint; it remains queued.") }
                try await store.finish(lease, outcome: outcome)
            }
        }
    }
}
