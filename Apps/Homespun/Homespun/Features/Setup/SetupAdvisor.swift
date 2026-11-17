// SPDX-License-Identifier: Apache-2.0
import Foundation
import HomespunCore

/// Recommends where originals should live (DESIGN §6): among the Homespun servers found on the
/// Wi‑Fi, or, when none answers, from what people say they have at home. Nothing else on the
/// network is looked at. Pure, so the rules can be tested without a network.
enum SetupAdvisor {
    /// A kind of computer, found running Homespun Server or named in an answer.
    enum Machine: String, Hashable, Sendable {
        case macDesktop, macLaptop, nas, linux

        /// The guide that sets Homespun Server up on it.
        var guide: Guide {
            switch self {
            case .macDesktop, .macLaptop: .mac
            case .nas: .nas
            case .linux: .linux
            }
        }

        var symbol: String {
            switch self {
            case .macDesktop: "macmini"
            case .macLaptop: "laptopcomputer"
            case .nas: "externaldrive.connected.to.line.below"
            case .linux: "terminal"
            }
        }

        /// "your Mac", for pages that talk about a machine not yet running Homespun.
        var yours: String {
            switch self {
            case .macDesktop, .macLaptop: "your Mac"
            case .nas: "your NAS"
            case .linux: "your Linux computer"
            }
        }
    }

    enum Guide: String, Hashable, Sendable { case mac, nas, linux }

    /// An answer to "What do you have at home?" (01·3.2). Several can be chosen.
    enum Answer: String, Hashable, Sendable, CaseIterable, Identifiable {
        case macDesktop, macLaptop, linux, nas, immich, none
        var id: String { rawValue }

        var title: String {
            switch self {
            case .macDesktop: "A Mac desktop"
            case .macLaptop: "A Mac laptop"
            case .linux: "A Linux computer"
            case .nas: "A NAS"
            case .immich: "I already use Immich"
            case .none: "None of these"
            }
        }

        var detail: String? {
            switch self {
            case .macDesktop: "Mac mini, iMac, Mac Studio"
            case .macLaptop: "MacBook Air, MacBook Pro"
            case .linux: "Ubuntu, Debian, Fedora, Arch…"
            case .nas: "Synology, QNAP, UGREEN, TrueNAS, Unraid…"
            case .immich: "Homespun can read originals from it"
            case .none: nil
            }
        }

        var symbol: String {
            switch self {
            case .immich: "camera.macro"
            case .none: "nosign"
            default: machine!.symbol
            }
        }

        var machine: Machine? {
            switch self {
            case .macDesktop: .macDesktop
            case .macLaptop: .macLaptop
            case .linux: .linux
            case .nas: .nas
            case .immich, .none: nil
            }
        }
    }

    /// Chooses or clears an answer. "None of these" clears the others, and any other answer clears it.
    static func toggle(_ answer: Answer, in answers: Set<Answer>) -> Set<Answer> {
        if answers.contains(answer) { return answers.subtracting([answer]) }
        if answer == .none { return [.none] }
        return answers.subtracting([.none]).union([answer])
    }

    /// One line next to a recommendation: a reason (✓), a trade-off (ⓘ) or how long it takes.
    struct Reason: Hashable, Sendable {
        enum Kind: Hashable, Sendable { case plus, note, time }
        var kind: Kind
        var text: String

        var symbol: String {
            switch kind {
            case .plus: "checkmark"
            case .note: "info.circle"
            case .time: "clock"
            }
        }
    }

    /// Another way to go, never hidden (rule 5: never trap): "Use Linux Box Anyway", "Use Your NAS
    /// Instead", "Use Both (Later)".
    struct Alternative: Hashable, Sendable, Identifiable {
        enum Target: Hashable, Sendable {
            case server(String)
            case machine(Machine)
            /// A NAS keeps originals and a Mac compresses Live Photos (§6.4, coming later).
            case both
        }

        var target: Target
        var title: String
        /// The one-line trade-off.
        var detail: String
        var symbol: String

        var id: String {
            switch target {
            case .server(let id): "server.\(id)"
            case .machine(let machine): "machine.\(machine.rawValue)"
            case .both: "both"
            }
        }
    }

    // MARK: Found servers

    /// A Homespun server that answered on the Wi‑Fi, with what it says about itself
    /// (`GET /api/v1/pair/options`, which needs no pairing).
    struct Server: Hashable, Sendable, Identifiable {
        /// Its Bonjour name.
        var id: String
        var name: String
        var os: ServerSetup.OperatingSystem?
        var kind: ServerAPI.Hardware.Kind?
        var model: String?
        var freeBytes: Int64?
        /// This iPhone has a token for it in the Keychain.
        var pairedBefore = false
        /// It answered, but is too old for this app.
        var needsUpdate = false

        init(id: String, name: String? = nil, os: ServerSetup.OperatingSystem? = nil, kind: ServerAPI.Hardware.Kind? = nil,
             model: String? = nil, freeBytes: Int64? = nil, pairedBefore: Bool = false, needsUpdate: Bool = false) {
            self.id = id
            self.name = name ?? id
            self.os = os
            self.kind = kind
            self.model = model
            self.freeBytes = freeBytes
            self.pairedBefore = pairedBefore
            self.needsUpdate = needsUpdate
        }

        var isLaptop: Bool { kind == .laptop }

        var machine: Machine {
            if os == .macOS { return isLaptop ? .macLaptop : .macDesktop }
            return kind == .container ? .nas : .linux
        }

        var symbol: String { machine.symbol }

        /// "Mac mini", "Linux", "Synology DS923+".
        var kindName: String {
            switch machine {
            case .macDesktop, .macLaptop: model ?? (isLaptop ? "Mac laptop" : "Mac")
            case .nas: model ?? "NAS (Docker)"
            case .linux: isLaptop ? "Linux laptop" : "Linux"
            }
        }

        /// "Mac mini · Homespun running · 1.7 TB free".
        var summary: String {
            if needsUpdate { return "Homespun Server needs an update" }
            var parts = [kindName, "Homespun running"]
            if isLaptop {
                parts.append("sleeps when closed")
            } else if let freeBytes {
                parts.append("\(SetupAdvisor.roughBytes(freeBytes)) free")
            }
            return parts.joined(separator: " · ")
        }

        /// Mac, then NAS, then Linux; a desktop before a laptop (rule 3). Too old comes last.
        var tier: Int {
            if needsUpdate { return 9 }
            switch machine {
            case .macDesktop: return 0
            case .nas: return 1
            case .linux: return isLaptop ? 4 : 2
            case .macLaptop: return 3
            }
        }
    }

    /// Found servers, best first: by platform (rule 3), then more free space, then paired before (rule 4).
    static func rank(_ servers: [Server]) -> [Server] {
        servers.sorted { a, b in
            if a.tier != b.tier { return a.tier < b.tier }
            if (a.freeBytes ?? 0) != (b.freeBytes ?? 0) { return (a.freeBytes ?? 0) > (b.freeBytes ?? 0) }
            if a.pairedBefore != b.pairedBefore { return a.pairedBefore }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// What the page after looking shows (01·1.5, 2.5, 6.6).
    struct FoundAdvice: Hashable, Sendable {
        enum Layout: Hashable, Sendable {
            /// Several servers: one recommended, the others "Use … Anyway" (1.5).
            case recommend
            /// Only one server answered (2.5).
            case onlyOne
            /// Several Macs: preselected, but asked (6.6).
            case chooseMac
        }

        var layout: Layout
        var title: String
        var recommended: Server
        var reasons: [Reason]
        /// Every other found server, with its trade-off.
        var others: [Alternative]
        /// Every server, best first (the list on 6.6).
        var ranked: [Server]
        /// The trade-off under "Set Up a Different Computer".
        var differentDetail: String
    }

    static func advise(found servers: [Server]) -> FoundAdvice? {
        let ranked = rank(servers)
        guard let best = ranked.first else { return nil }
        let macs = ranked.filter { !$0.needsUpdate && [.macDesktop, .macLaptop].contains($0.machine) }
        let layout: FoundAdvice.Layout = ranked.count == 1 ? .onlyOne : macs.count > 1 ? .chooseMac : .recommend
        let title = switch layout {
        case .onlyOne: best.needsUpdate ? "\(best.name) needs an update" : "\(best.name) is ready to pair"
        case .chooseMac: "Which Mac should keep your originals?"
        case .recommend:
            switch best.machine {
            case .macDesktop, .macLaptop: "We recommend your Mac"
            case .nas: "We recommend your NAS"
            case .linux: "We recommend \(best.name)"
            }
        }
        var reasons: [Reason] = []
        if best.needsUpdate {
            reasons.append(.init(kind: .note, text: "It runs an older Homespun Server. Update it, then pair."))
        } else {
            if layout == .onlyOne { reasons.append(.init(kind: .plus, text: "Already running, so there's nothing to install.")) }
            switch best.machine {
            case .macDesktop:
                reasons.append(.init(kind: .plus, text: "Makes every compact copy itself, Live Photos included."))
                if layout != .onlyOne { reasons.append(.init(kind: .plus, text: "A desktop Mac that stays on at home.")) }
            case .macLaptop:
                reasons.append(.init(kind: .plus, text: "Makes every compact copy itself, Live Photos included."))
                reasons.append(.init(kind: .note, text: "Sleeps when closed. Works while it's awake and at home."))
            case .nas:
                if layout != .onlyOne { reasons.append(.init(kind: .plus, text: "Plenty of space, and it stays on.")) }
                reasons.append(.init(kind: .note, text: liveMotionOnPhone))
            case .linux:
                if layout != .onlyOne, !best.isLaptop { reasons.append(.init(kind: .plus, text: "Stays on at home.")) }
                reasons.append(.init(kind: .note, text: liveMotionOnPhone))
            }
        }
        let others = ranked.dropFirst().map { server in
            Alternative(target: .server(server.id), title: "Use \(server.name) Anyway",
                        detail: "\(server.kindName) · Homespun running. \(anywayTradeOff(server))", symbol: server.symbol)
        }
        let different = [.macDesktop, .macLaptop].contains(best.machine) && !best.needsUpdate
            ? "Tell Homespun what you have at home." : "A Mac compresses Live Photos itself."
        return FoundAdvice(layout: layout, title: title, recommended: best, reasons: reasons, others: Array(others),
                           ranked: ranked, differentDetail: different)
    }

    private static func anywayTradeOff(_ server: Server) -> String {
        if server.needsUpdate { return "Needs an update first." }
        switch server.machine {
        case .macDesktop: return "Makes every compact copy itself."
        case .macLaptop: return "Sleeps when closed."
        case .nas, .linux: return liveMotionOnPhone
        }
    }

    static let liveMotionOnPhone = "Live Photo motion is compressed on this iPhone."

    // MARK: Answers

    /// What follows "What do you have at home?".
    enum Next: Hashable, Sendable {
        /// Nothing usable chosen yet; the hint says why (Immich alone).
        case ask(hint: String?)
        /// One machine, with the others as alternatives (01·3.0, 4.1).
        case recommend(AnswerAdvice)
        /// "None of these": the honest page (01·3.7).
        case noneOfThese
    }

    struct AnswerAdvice: Hashable, Sendable {
        var machine: Machine
        var title: String
        /// "Your Mac": no names until Homespun runs there.
        var name: String
        var summary: String
        var reasons: [Reason]
        var action: String
        var alternatives: [Alternative]
        /// After pairing, set up Immich mode (01·5.1).
        var usesImmich: Bool
    }

    static let immichAlone = "Also choose the computer that runs Immich. Homespun Server can run there too."

    /// Mac desktop, then NAS, then Linux, then a Mac laptop (rule 3, pick 2).
    static func advise(answers: Set<Answer>) -> Next {
        if answers.contains(.none) { return .noneOfThese }
        let order: [Machine] = [.macDesktop, .nas, .linux, .macLaptop]
        let chosen = Set(answers.compactMap(\.machine))
        let machines = order.filter { chosen.contains($0) }
        guard let best = machines.first else {
            return .ask(hint: answers.contains(.immich) ? immichAlone : nil)
        }
        let usesImmich = answers.contains(.immich)
        var reasons: [Reason]
        let title: String, name: String, summary: String, action: String
        switch best {
        case .macDesktop:
            (title, name, summary, action) = ("We recommend your Mac", "Your Mac", "Mac desktop · needs Homespun Server",
                                              "Set Up on My Mac")
            reasons = [.init(kind: .plus, text: "A Mac makes every compact copy itself, Live Photos included."),
                       .init(kind: .plus, text: "A desktop Mac can stay on at home.")]
        case .macLaptop:
            (title, name, summary, action) = ("We recommend your Mac", "Your Mac", "Mac laptop · needs Homespun Server",
                                              "Set Up on My Mac")
            reasons = [.init(kind: .plus, text: "Makes every compact copy itself, Live Photos included."),
                       .init(kind: .note, text: "Backs up while it's awake and at home.")]
        case .nas:
            (title, name, summary, action) = ("We recommend your NAS", "Your NAS", "Needs Homespun Server (Docker)",
                                              "Set Up on My NAS")
            reasons = [.init(kind: .plus, text: "Plenty of space, and it stays on."),
                       .init(kind: .note, text: liveMotionOnPhone)]
        case .linux:
            (title, name, summary, action) = ("We recommend your Linux computer", "Your Linux computer",
                                              "Linux · needs Homespun Server", "Set Up on My Linux Computer")
            reasons = [.init(kind: .plus, text: "It can stay on at home."),
                       .init(kind: .note, text: liveMotionOnPhone)]
        }
        if usesImmich {
            reasons.append(.init(kind: .plus, text: "Reads the originals your Immich already has, and stores none itself."))
        }
        switch best {
        case .macDesktop, .macLaptop: reasons.append(.init(kind: .time, text: "Takes about 15 minutes on the Mac."))
        case .linux: reasons.append(.init(kind: .time, text: "Takes about 15 minutes on the computer."))
        case .nas: reasons.append(.init(kind: .time, text: "Takes about 10 minutes on the NAS."))
        }
        var alternatives = machines.dropFirst().map { machine in
            Alternative(target: .machine(machine), title: insteadTitle(machine),
                        detail: insteadTradeOff(machine), symbol: machine.symbol)
        }
        let hasMac = machines.contains(.macDesktop) || machines.contains(.macLaptop)
        if machines.contains(.nas), hasMac {
            alternatives.append(Alternative(target: .both, title: "Use Both (Later)",
                                            detail: "Your NAS keeps originals; your Mac compresses Live Photos.",
                                            symbol: "sparkles"))
        }
        return .recommend(AnswerAdvice(machine: best, title: title, name: name, summary: summary, reasons: reasons,
                                       action: action, alternatives: Array(alternatives), usesImmich: usesImmich))
    }

    /// "Use Your NAS Instead" (§9.2 `rec.instead`).
    static func insteadTitle(_ machine: Machine) -> String {
        switch machine {
        case .macDesktop: "Use Your Mac Instead"
        case .macLaptop: "Use Your Mac Laptop Instead"
        case .nas: "Use Your NAS Instead"
        case .linux: "Use Your Linux Computer Instead"
        }
    }

    /// The trade-off under "Use … Instead" (§9.2 `rec.instead`).
    static func insteadTradeOff(_ machine: Machine) -> String {
        switch machine {
        case .macDesktop: "Makes every compact copy itself, Live Photos included."
        case .macLaptop: "Compresses Live Photos itself, but backs up only while it's awake and at home."
        case .nas: "Lots of room, and it stays on; Live Photo motion is compressed on this iPhone."
        case .linux: liveMotionOnPhone
        }
    }

    // MARK: Words and numbers


    /// "33 GB", "84 MB", "1.7 TB": rounded for estimates and free space.
    static func roughBytes(_ bytes: Int64) -> String {
        let value = Double(max(bytes, 0))
        if value >= 1e12 { return "\((value / 1e12 * 10).rounded() / 10) TB".replacingOccurrences(of: ".0 ", with: " ") }
        if value >= 1e9 { return "\(Int((value / 1e9).rounded())) GB" }
        if value >= 1e6 { return "\(Int((value / 1e6).rounded())) MB" }
        return "\(Int((value / 1e3).rounded())) KB"
    }

    static func roughBytes(_ bytes: Int) -> String { roughBytes(Int64(bytes)) }

    /// "52 s", "3 min 5 s".
    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(1, Int(seconds.rounded()))
        if total < 60 { return "\(total) s" }
        let minutes = total / 60, rest = total % 60
        return rest == 0 ? "\(minutes) min" : "\(minutes) min \(rest) s"
    }

    /// "0:42".
    static func clock(_ seconds: Int) -> String {
        let seconds = max(0, seconds)
        return "\(seconds / 60):" + String(format: "%02d", seconds % 60)
    }

    /// "42 seconds", "1 minute 50 seconds", for VoiceOver.
    static func spokenClock(_ seconds: Int) -> String {
        let minutes = seconds / 60, rest = seconds % 60
        var parts: [String] = []
        if minutes > 0 { parts.append("\(minutes) minute\(minutes == 1 ? "" : "s")") }
        if rest > 0 || minutes == 0 { parts.append("\(rest) second\(rest == 1 ? "" : "s")") }
        return parts.joined(separator: " ")
    }

    // MARK: Pairing codes

    static let codeLength = 8

    /// Formats what was typed: capitals, letters and digits only, at most 8, shown as XXXX-XXXX
    /// once complete. The dash goes in only then (or where it was typed), so the field isn't
    /// rewritten under every keystroke, which can drop characters typed quickly.
    static func formatCode(_ text: String) -> String {
        let characters = text.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(codeLength)
        let dashed = characters.count == codeLength
            || (characters.count >= 4 && text.firstIndex(of: "-").map { text.distance(from: text.startIndex, to: $0) == 4 } == true)
        guard dashed else { return String(characters) }
        return String(characters.prefix(4)) + "-" + String(characters.dropFirst(4))
    }

    /// How many of the 8 characters are typed.
    static func codeCount(_ code: String) -> Int { code.filter { $0 != "-" }.count }
}

/// The first task (DESIGN 01·1.10–1.12, §16.2): the 10 newest, and the estimate before it.
enum FirstTask {
    static let size = 10
    /// Videos longer than this wait for a later backup: the first task should take about a minute.
    static let longVideo: TimeInterval = 30

    struct Candidate: Equatable, Sendable {
        var id: String
        var isVideo = false
        var duration: TimeInterval = 0
        var isScreenshot = false
    }

    /// The newest items to try it on, newest first: photos, Live Photos and short videos, then
    /// anything else when there aren't enough. `newestFirst` holds only items not backed up yet.
    static func pick(_ newestFirst: [Candidate], limit: Int = size) -> [String] {
        let preferred = newestFirst.filter { !$0.isScreenshot && !($0.isVideo && $0.duration > longVideo) }
        var picked = Array(preferred.prefix(limit).map(\.id))
        if picked.count < limit {
            let chosen = Set(picked)
            picked += newestFirst.filter { !chosen.contains($0.id) }.prefix(limit - picked.count).map(\.id)
            let order = Dictionary(uniqueKeysWithValues: newestFirst.enumerated().map { ($1.id, $0) })
            picked.sort { order[$0, default: 0] < order[$1, default: 0] }
        }
        return picked
    }

    /// What the library takes on this iPhone, and roughly what compact copies would take.
    struct Estimate: Equatable, Sendable {
        struct Group: Equatable, Sendable {
            var count = 0
            var bytes: Int64 = 0
        }

        var photos = Group()
        var livePhotos = Group()
        var videos = Group()
        /// Compact copies are about a fifth of the original's size.
        static let ratio = 0.2
        /// Live Photo motion compressed on this iPhone, per item (Linux and NAS servers).
        static let secondsPerMotion: Double = 5

        var count: Int { photos.count + livePhotos.count + videos.count }
        var bytes: Int64 { photos.bytes + livePhotos.bytes + videos.bytes }
        var compactBytes: Int64 { Int64((Double(bytes) * Self.ratio).rounded()) }
        var freeable: Int64 { bytes - compactBytes }

        /// "about 40 min" of motion compressing for this many Live Photos.
        var motionMinutes: Int { max(1, Int((Double(livePhotos.count) * Self.secondsPerMotion / 60).rounded(.up))) }
    }
}
