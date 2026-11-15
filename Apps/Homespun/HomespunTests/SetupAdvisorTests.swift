// SPDX-License-Identifier: Apache-2.0
import Foundation
import HomespunCore
import Testing
@testable import Homespun

private let mini = SetupAdvisor.Server(id: "polonium", os: .macOS, kind: .desktop, model: "Mac mini", freeBytes: 1_700_000_000_000)
private let studio = SetupAdvisor.Server(id: "studio", os: .macOS, kind: .desktop, model: "Mac Studio", freeBytes: 410_000_000_000)
private let air = SetupAdvisor.Server(id: "Sam's MacBook Air", os: .macOS, kind: .laptop, model: "MacBook Air",
                                      freeBytes: 2_000_000_000_000)
private let hydrogen = SetupAdvisor.Server(id: "hydrogen", os: .linux, kind: .desktop, freeBytes: 2_100_000_000_000)
private let attic = SetupAdvisor.Server(id: "attic", os: .linux, kind: .container, model: "Synology DS923+",
                                        freeBytes: 8_000_000_000_000)

/// The recommendation rules (DESIGN §6) and the words and numbers setup shows.
struct SetupAdvisorTests {
    @Test func foundServersAreRankedMacThenNASThenLinuxWithLaptopsLast() {
        #expect(SetupAdvisor.rank([hydrogen, air, attic, mini]).map(\.id) == ["polonium", "attic", "hydrogen", air.id])
        // Ties: more free space, then paired before.
        var small = studio
        small.freeBytes = mini.freeBytes
        small.pairedBefore = true
        #expect(SetupAdvisor.rank([mini, studio]).map(\.id) == ["polonium", "studio"])
        #expect(SetupAdvisor.rank([mini, small]).map(\.id) == ["studio", "polonium"])
        // A server too old to pair with goes last, whatever it runs on.
        var old = mini
        old.id = "old"
        old.needsUpdate = true
        #expect(SetupAdvisor.rank([old, hydrogen]).map(\.id) == ["hydrogen", "old"])
    }

    @Test func aMacAndLinuxFoundRecommendsTheMacWithLinuxAnyway() throws {
        let advice = try #require(SetupAdvisor.advise(found: [hydrogen, mini]))
        #expect(advice.layout == .recommend)
        #expect(advice.title == "We recommend your Mac")
        #expect(advice.recommended.id == "polonium")
        #expect(advice.recommended.summary == "Mac mini · Homespun running · 1.7 TB free")
        #expect(advice.reasons.map(\.text) == ["Makes every compact copy itself, Live Photos included.",
                                               "A desktop Mac that stays on at home."])
        #expect(advice.others.map(\.title) == ["Use hydrogen Anyway"])
        #expect(advice.others.first?.detail == "Linux · Homespun running. Live Photo motion is compressed on this iPhone.")
        #expect(advice.others.first?.target == .server("hydrogen"))
    }

    @Test func oneServerFoundNeedsNothingInstalled() throws {
        let advice = try #require(SetupAdvisor.advise(found: [hydrogen]))
        #expect(advice.layout == .onlyOne)
        #expect(advice.title == "hydrogen is ready to pair")
        #expect(advice.reasons == [.init(kind: .plus, text: "Already running, so there's nothing to install."),
                                   .init(kind: .note, text: "Live Photo motion is compressed on this iPhone.")])
        #expect(advice.others.isEmpty)
        #expect(advice.differentDetail == "A Mac compresses Live Photos itself.")
        #expect(SetupAdvisor.advise(found: []) == nil)
    }

    @Test func severalMacsAreAskedAboutWithTheBestPreselected() throws {
        let advice = try #require(SetupAdvisor.advise(found: [air, studio, mini]))
        #expect(advice.layout == .chooseMac)
        #expect(advice.title == "Which Mac should keep your originals?")
        #expect(advice.recommended.id == "polonium")
        #expect(advice.ranked.map(\.id) == ["polonium", "studio", air.id])
        #expect(air.summary == "MacBook Air · Homespun running · sleeps when closed")
    }

    @Test func aNASFoundBeforeLinuxSaysWhereLivePhotosAreCompressed() throws {
        let advice = try #require(SetupAdvisor.advise(found: [hydrogen, attic]))
        #expect(advice.title == "We recommend your NAS")
        #expect(advice.recommended.summary == "Synology DS923+ · Homespun running · 8 TB free")
        #expect(advice.reasons.map(\.kind) == [.plus, .note])
    }

    @Test func answersRecommendTheMacDesktopFirstAndOfferTheRest() throws {
        guard case .recommend(let advice) = SetupAdvisor.advise(answers: [.nas, .macDesktop]) else {
            Issue.record("no recommendation")
            return
        }
        #expect(advice.machine == .macDesktop)
        #expect(advice.title == "We recommend your Mac")
        #expect(advice.action == "Set Up on My Mac")
        #expect(advice.machine.guide == .mac)
        #expect(advice.alternatives.map(\.title) == ["Use Your NAS Instead", "Use Both (Later)"])
        #expect(advice.alternatives.first?.detail
                == "Lots of room, and it stays on; Live Photo motion is compressed on this iPhone.")
        #expect(advice.alternatives.last?.target == .both)
        #expect(!advice.usesImmich)
    }

    @Test func answersWithoutAMacDesktopFollowTheOrder() throws {
        guard case .recommend(let nas) = SetupAdvisor.advise(answers: [.macLaptop, .nas, .linux]) else {
            Issue.record("no recommendation")
            return
        }
        #expect(nas.machine == .nas)
        #expect(nas.title == "We recommend your NAS")
        #expect(nas.machine.guide == .nas)
        #expect(nas.alternatives.map(\.title) == ["Use Your Linux Computer Instead", "Use Your Mac Laptop Instead",
                                                  "Use Both (Later)"])
        #expect(nas.alternatives[1].detail == "Compresses Live Photos itself, but backs up only while it's awake and at home.")

        guard case .recommend(let linux) = SetupAdvisor.advise(answers: [.linux, .macLaptop]) else {
            Issue.record("no recommendation")
            return
        }
        #expect(linux.machine == .linux)
        #expect(linux.alternatives.map(\.title) == ["Use Your Mac Laptop Instead"])

        guard case .recommend(let laptop) = SetupAdvisor.advise(answers: [.macLaptop]) else {
            Issue.record("no recommendation")
            return
        }
        #expect(laptop.machine == .macLaptop)
        #expect(laptop.reasons.contains(.init(kind: .note, text: "Backs up while it's awake and at home.")))
        #expect(laptop.alternatives.isEmpty)
    }

    @Test func immichNeedsAComputerAndNoneOfTheseIsHonest() throws {
        #expect(SetupAdvisor.advise(answers: []) == .ask(hint: nil))
        #expect(SetupAdvisor.advise(answers: [.immich]) == .ask(hint: SetupAdvisor.immichAlone))
        #expect(SetupAdvisor.advise(answers: [.none]) == .noneOfThese)
        guard case .recommend(let advice) = SetupAdvisor.advise(answers: [.immich, .linux]) else {
            Issue.record("no recommendation")
            return
        }
        #expect(advice.usesImmich)
        #expect(advice.machine == .linux)
    }

    @Test func noneOfTheseClearsTheOtherAnswers() {
        var answers: Set<SetupAdvisor.Answer> = []
        answers = SetupAdvisor.toggle(.macDesktop, in: answers)
        answers = SetupAdvisor.toggle(.nas, in: answers)
        #expect(answers == [.macDesktop, .nas])
        answers = SetupAdvisor.toggle(.none, in: answers)
        #expect(answers == [.none])
        answers = SetupAdvisor.toggle(.linux, in: answers)
        #expect(answers == [.linux])
        #expect(SetupAdvisor.toggle(.linux, in: answers).isEmpty)
    }

    @Test func pairingCodesAreFormattedAsTheyAreTyped() {
        #expect(SetupAdvisor.formatCode("tbte") == "TBTE")
        // Typed without a dash, it goes in once all 8 are there.
        #expect(SetupAdvisor.formatCode("TBTE9") == "TBTE9")
        #expect(SetupAdvisor.formatCode("tbte93n4") == "TBTE-93N4")
        // A dash typed after the first four stays.
        #expect(SetupAdvisor.formatCode("TBTE-9") == "TBTE-9")
        #expect(SetupAdvisor.formatCode("TBTE-93N4") == "TBTE-93N4")
        #expect(SetupAdvisor.formatCode(" tb te 93 n4 xx") == "TBTE-93N4")
        #expect(SetupAdvisor.formatCode("TBTE-") == "TBTE-")
        #expect(SetupAdvisor.codeCount("TBTE-93") == 6)
    }

    @Test func wordsForSizesTimesAndCountdowns() {
        #expect(SetupAdvisor.roughBytes(Int64(33_400_000_000)) == "33 GB")
        #expect(SetupAdvisor.roughBytes(Int64(84_200_000)) == "84 MB")
        #expect(SetupAdvisor.roughBytes(Int64(1_700_000_000_000)) == "1.7 TB")
        #expect(SetupAdvisor.roughBytes(Int64(2_000_000_000_000)) == "2 TB")
        #expect(SetupAdvisor.duration(52) == "52 s")
        #expect(SetupAdvisor.duration(185) == "3 min 5 s")
        #expect(SetupAdvisor.clock(42) == "0:42")
        #expect(SetupAdvisor.clock(110) == "1:50")
        #expect(SetupAdvisor.spokenClock(110) == "1 minute 50 seconds")
        #expect(SetupAdvisor.spokenClock(18) == "18 seconds")
    }

    @Test func theFirstTaskTakesTheNewestPhotosAndShortVideos() {
        let items: [FirstTask.Candidate] = [
            .init(id: "screenshot", isScreenshot: true),
            .init(id: "long", isVideo: true, duration: 95),
            .init(id: "short", isVideo: true, duration: 12),
        ] + (1...12).map { .init(id: "p\($0)") }
        #expect(FirstTask.pick(items) == ["short", "p1", "p2", "p3", "p4", "p5", "p6", "p7", "p8", "p9"])
        // A small library: everything, newest first, even what would wait otherwise.
        #expect(FirstTask.pick(Array(items.prefix(4))) == ["screenshot", "long", "short", "p1"])
    }

    @Test func theEstimateCountsAFifthForCompactCopies() {
        let estimate = FirstTask.Estimate(photos: .init(count: 1912, bytes: 14_000_000_000),
                                          livePhotos: .init(count: 402, bytes: 9_000_000_000),
                                          videos: .init(count: 117, bytes: 18_000_000_000))
        #expect(estimate.count == 2431)
        #expect(SetupAdvisor.roughBytes(estimate.bytes) == "41 GB")
        #expect(SetupAdvisor.roughBytes(estimate.compactBytes) == "8 GB")
        #expect(SetupAdvisor.roughBytes(estimate.freeable) == "33 GB")
        #expect(estimate.motionMinutes == 34)
    }
}
