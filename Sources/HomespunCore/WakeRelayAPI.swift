// SPDX-License-Identifier: Apache-2.0
import Foundation

/// An optional opaque wake hint. No media identity, server address or backup progress is sent here.
public enum WakeRelayAPI {
    public enum Environment: String, Codable, Sendable { case production, sandbox }

    public struct Registration: Codable, Equatable, Sendable {
        public var generationID: UUID
        public init(generationID: UUID) { self.generationID = generationID }
        enum CodingKeys: String, CodingKey { case generationID = "generationId" }
    }

    public struct Activation: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        public var generationID: UUID
        public var deviceToken: String
        public var environment: Environment
        public var senderToken: String
        public init(generationID: UUID, deviceToken: String, environment: Environment, senderToken: String) {
            self.generationID = generationID
            self.deviceToken = deviceToken
            self.environment = environment
            self.senderToken = senderToken
        }
        public var description: String { "WakeRelayAPI.Activation(redacted)" }
        public var debugDescription: String { description }
        enum CodingKeys: String, CodingKey { case generationID = "generationId", deviceToken, environment, senderToken }
    }

    public struct Hint: Codable, Equatable, Sendable {
        public var generationID: UUID
        public var nonce: UUID
        public init(generationID: UUID, nonce: UUID) {
            self.generationID = generationID
            self.nonce = nonce
        }
        enum CodingKeys: String, CodingKey { case generationID = "generationId", nonce }
    }

    public struct Sender: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        public var routeID: UUID
        public var generationID: UUID
        public var token: String
        public init(routeID: UUID, generationID: UUID, token: String) {
            self.routeID = routeID
            self.generationID = generationID
            self.token = token
        }
        public var description: String { "WakeRelayAPI.Sender(redacted)" }
        public var debugDescription: String { description }
        enum CodingKeys: String, CodingKey { case routeID = "routeId", generationID = "generationId", token }
    }
}
