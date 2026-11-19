// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import HomespunCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Asks someone at the server to allow a new device.
protocol PairingApprover: Sendable {
    /// `true` allowed, `false` denied, `nil` no answer. Cancelling withdraws the question.
    func ask(device: String, match: String, server: String, seconds: Int) async -> Bool?
}

/// A dialog on the Mac's screen. Only works when the server runs in a logged-in user's
/// session (the LaunchAgent `install-service` makes), not from SSH or on Linux.
struct DialogApprover: PairingApprover {
    static func detect() -> DialogApprover? {
        #if os(macOS)
        let manager = Tools.output("launchctl", ["managername"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        return manager == "Aqua" ? DialogApprover() : nil
        #else
        return nil
        #endif
    }

    func ask(device: String, match: String, server: String, seconds: Int) async -> Bool? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        // The text is passed as an argument, never inside the script. Return chooses Deny, so a
        // dialog that pops up while someone is typing can't be allowed by accident.
        let message = "\u{201C}\(device)\u{201D} wants to use Homespun Server on \(server).\n\n"
            + "Allow it only if that device shows the number \(match)."
        process.arguments = ["-e", "on run argv", "-e", "activate", "-e",
                             "display dialog (item 1 of argv) with title \"Homespun\" buttons {\"Deny\", \"Allow\"} "
                                + "default button \"Deny\" with icon caution giving up after \(seconds)",
                             "-e", "end run", message]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let pid = process.processIdentifier
        let output = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    continuation.resume(returning: String(decoding: data, as: UTF8.self))
                }
            }
        } onCancel: {
            kill(pid, SIGKILL)
        }
        if output.contains("gave up:true") { return nil }
        if output.contains("button returned:Allow") { return true }
        if output.contains("button returned:Deny") { return false }
        return nil
    }
}

/// Pairing requests waiting for someone at the server. One at a time (including an approved
/// one until its device collects the token), so a device on the network can't stack up or
/// slip in dialogs, with a pause after each one and a longer one after "Deny".
actor PairingApprovals {
    enum Failure: Error { case unavailable, busy, invalidReveal }

    private struct Pending {
        var id: String
        var secretHash: String
        var device: String
        var commitment: Data
        var serverNonce: Data
        var revealed = false
        var expires: Date
        var state: ServerAPI.ApprovalState = .waiting
        var task: Task<Void, Never>?
    }

    let approver: (any PairingApprover)?
    let serverName: String
    let seconds: Int
    let pause: TimeInterval
    let pauseAfterDenial: TimeInterval
    /// How long an approved device has to collect its token.
    let collection: TimeInterval = 30
    private var pending: Pending?
    private var pausedUntil = Date.distantPast

    init(approver: (any PairingApprover)?, serverName: String, seconds: Int = 110, pause: TimeInterval = 5,
         pauseAfterDenial: TimeInterval = 20) {
        self.approver = approver
        self.serverName = serverName
        self.seconds = seconds
        self.pause = pause
        self.pauseAfterDenial = pauseAfterDenial
    }

    nonisolated var canApprove: Bool { approver != nil }

    func start(device rawName: String, commitment: Data, now: Date = Date()) throws -> ServerAPI.ApprovalTicket {
        guard approver != nil else { throw Failure.unavailable }
        expireIfDue()
        if let pending, pending.state == .waiting || pending.state == .approved { throw Failure.busy }
        guard Date() >= pausedUntil else { throw Failure.busy }
        // The name comes from the network; keep it short and on one line.
        let hidden = CharacterSet.controlCharacters.union(.illegalCharacters)
        let device = String(rawName.unicodeScalars
            .filter { !hidden.contains($0) }
            .map { CharacterSet.whitespacesAndNewlines.contains($0) ? " " : $0 }
            .prefix(40).map(Character.init)).trimmingCharacters(in: .whitespaces)
        let secret = Pairing.newToken()
        let request = Pending(id: UUID().uuidString, secretHash: Pairing.hash(secret),
                              device: device.isEmpty ? "A device" : device,
                              commitment: commitment, serverNonce: PairingCrypto.nonce(),
                              expires: now.addingTimeInterval(30))
        pending = request
        return .init(id: request.id, secret: secret, expiresIn: seconds,
                     serverNonce: PairingCrypto.encode(request.serverNonce))
    }

    func reveal(id: String, secret: String, nonce: Data, fingerprint: ServerKeyFingerprint, now: Date = Date()) throws {
        expireIfDue(now: now)
        guard var request = pending, request.id == id, request.secretHash == Pairing.hash(secret),
              request.state == .waiting, !request.revealed, let approver else { throw Failure.invalidReveal }
        guard PairingCrypto.equal(request.commitment, PairingCrypto.commitment(nonce: nonce)) else {
            pending = nil
            throw Failure.invalidReveal
        }
        let number = PairingCrypto.sas(fingerprint: fingerprint, appNonce: nonce, serverNonce: request.serverNonce)
        let match = String(number.prefix(3)) + " " + number.suffix(3)
        let name = request.device
        let server = serverName, seconds = seconds
        request.revealed = true
        request.expires = now.addingTimeInterval(TimeInterval(seconds + 10))
        request.task = Task {
            let answer = await approver.ask(device: name, match: match, server: server, seconds: seconds)
            self.finish(id: id, answer: answer)
        }
        pending = request
    }

    private func finish(id: String, answer: Bool?) {
        guard pending?.id == id, pending?.state == .waiting else { return }
        switch answer {
        case true?:
            pending?.state = .approved
            pending?.expires = Date().addingTimeInterval(collection)
        case false?:
            pending?.state = .denied
            pausedUntil = Date().addingTimeInterval(pauseAfterDenial)
        case nil:
            pending?.state = .expired
            pausedUntil = Date().addingTimeInterval(pause)
        }
    }

    private func expireIfDue(now: Date = Date()) {
        guard let request = pending, now > request.expires else { return }
        request.task?.cancel()
        if request.state == .waiting { pending?.state = .expired }
        if request.state == .approved { pending = nil }
        pausedUntil = max(pausedUntil, Date().addingTimeInterval(pause))
    }

    func status(id: String, secret: String) -> ServerAPI.ApprovalStatus? {
        expireIfDue()
        guard let request = pending, request.id == id, request.secretHash == Pairing.hash(secret) else { return nil }
        if request.state == .waiting || request.state == .approved { return .init(state: request.state) }
        pending = nil
        pausedUntil = max(pausedUntil, Date().addingTimeInterval(pause))
        return .init(state: request.state)
    }

    func complete(id: String, secret: String, installHash: String,
                  register: @Sendable (String, String) async throws -> ServerAPI.PairResponse) async throws -> ServerAPI.PairResponse? {
        expireIfDue()
        guard let request = pending, request.id == id, request.secretHash == Pairing.hash(secret),
              request.revealed, request.state == .approved else { return nil }
        pending = nil
        pausedUntil = max(pausedUntil, Date().addingTimeInterval(pause))
        return try await register(request.device, installHash)
    }

    func cancel(id: String, secret: String) -> Bool {
        guard let request = pending, request.id == id, request.secretHash == Pairing.hash(secret) else { return false }
        request.task?.cancel()
        pending = nil
        pausedUntil = max(pausedUntil, Date().addingTimeInterval(pause))
        return true
    }
}
