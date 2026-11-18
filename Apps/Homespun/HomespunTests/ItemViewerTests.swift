// SPDX-License-Identifier: Apache-2.0
import Foundation
import HomespunCore
import Testing
@testable import Homespun

/// The viewer's words, its one action, where Compare gets the original, and the split line.
@MainActor struct ItemViewerTests {
    private let locale = Locale(identifier: "en_US")

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 9, _ minute: Int = 41) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    /// Formatters may use narrow or non-breaking spaces; compare with plain ones.
    private func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    @Test func titleIsTheDayWithTheYearOnlyWhenItIsntThisYear() {
        let now = date(2026, 11, 14)
        #expect(ItemText.title(date(2026, 11, 12), now: now, calendar: calendar, locale: locale) == "November 12")
        #expect(ItemText.title(date(2024, 11, 12), now: now, calendar: calendar, locale: locale) == "November 12, 2024")
        #expect(ItemText.title(nil) == "Item")
    }

    @Test func subtitleIsTheTimeAndTheKind() {
        let when = date(2026, 11, 12)
        #expect(plain(ItemText.subtitle(when, kind: .livePhoto, calendar: calendar, locale: locale)) == "9:41 AM · Live")
        #expect(plain(ItemText.subtitle(when, kind: .photo, calendar: calendar, locale: locale)) == "9:41 AM")
        #expect(plain(ItemText.subtitle(when, kind: .video, duration: 47.6, calendar: calendar, locale: locale))
            == "9:41 AM · Video, 0:48")
        #expect(ItemText.subtitle(nil, kind: .livePhoto) == "Live")
    }

    @Test func sentenceSaysWhereTheOriginalIs() {
        #expect(ItemText.sentence(.originalOnPhone, server: "Home Mac", immich: false)
            == "Ready to free up · original on Home Mac")
        #expect(ItemText.sentence(.originalOnPhone, server: "Home Mac", immich: true) == "Ready to free up · original in Immich")
        #expect(ItemText.sentence(.backedUp, server: "Home Mac", immich: false) == "Original at home · on Home Mac")
        #expect(ItemText.sentence(.working, server: "Home Mac", immich: false, job: .working("Uploading 62%"))
            == "Backing up · Uploading 62%")
        #expect(ItemText.sentence(.none, server: "Home Mac", immich: false, job: .notYet("Not in Immich yet"))
            == "Not backed up yet · Not in Immich yet")
        #expect(ItemText.spoken("Ready to free up · original on Home Mac") == "Ready to free up, original on Home Mac.")
    }

    @Test func oneActionForEachState() {
        let ready = LibraryState.Cell(id: "copy", badge: .originalOnPhone, original: "original", canFree: true)
        #expect(ItemAction.for(ready) == .freeUp(original: "original"))
        #expect(ItemAction.for(.init(id: "a", badge: .none, original: nil, canFree: false)) == .backUp)
        #expect(ItemAction.for(.init(id: "a", badge: .failed, original: nil, canFree: false)) == .tryAgain)
        for badge in [Badge.backedUp, .kept, .waiting, .working, .compactCopy] {
            #expect(ItemAction.for(.init(id: "a", badge: badge, original: badge == .backedUp ? "o" : nil, canFree: false)) == .none)
        }
    }

    @Test func compareNeedsACopyAndAnOriginalItCanReach() {
        let ready = LibraryState.Cell(id: "copy", badge: .originalOnPhone, original: "original", canFree: true)
        let atHome = LibraryState.Cell(id: "copy", badge: .backedUp, original: "original", canFree: false)
        #expect(ItemAction.canCompare(ready, immich: false))
        // Still on this iPhone, so Immich mode doesn't matter.
        #expect(ItemAction.canCompare(ready, immich: true))
        #expect(ItemAction.canCompare(atHome, immich: false))
        // Only in Immich: the server can't send it.
        #expect(!ItemAction.canCompare(atHome, immich: true))
        #expect(!ItemAction.canCompare(.init(id: "copy", badge: .compactCopy, original: nil, canFree: false), immich: false))
        #expect(!ItemAction.canCompare(.init(id: "a", badge: .none, original: nil, canFree: false), immich: false))
        // Restore Original: only what's at home and not on this iPhone, and not from Immich.
        #expect(ItemAction.canRestore(atHome, immich: false) && !ItemAction.canRestore(atHome, immich: true))
        #expect(!ItemAction.canRestore(ready, immich: false))
        #expect(!ItemAction.canRestore(.init(id: "copy", badge: .compactCopy, original: nil, canFree: false), immich: false))
    }

    @Test func originalComesFromThePhoneThenTheServer() {
        #expect(OriginalSource.choose(original: "o", onPhone: true, serverAssetID: "s", mode: .files) == .phone("o"))
        #expect(OriginalSource.choose(original: "o", onPhone: true, serverAssetID: "s", mode: .immich) == .phone("o"))
        #expect(OriginalSource.choose(original: "o", onPhone: false, serverAssetID: "s", mode: .files) == .server(assetID: "s"))
        #expect(OriginalSource.choose(original: "o", onPhone: false, serverAssetID: "s", mode: nil) == .server(assetID: "s"))
        #expect(OriginalSource.choose(original: "o", onPhone: false, serverAssetID: "s", mode: .immich) == .immich)
        #expect(OriginalSource.choose(original: "o", onPhone: false, serverAssetID: nil, mode: .files) == .unknown)
        #expect(OriginalSource.choose(original: nil, onPhone: false, serverAssetID: nil, mode: .files) == .unknown)
        #expect(OriginalSource.role(for: .photo) == .photo)
        #expect(OriginalSource.role(for: .livePhoto) == .photo)
        #expect(OriginalSource.role(for: .video) == .video)
        #expect(OriginalSource.fileName(for: .video).hasSuffix(".mov"))
    }

    @Test func factsReadAsOneLine() {
        #expect(plain(MediaFacts(bytes: 12_400_000, format: "HEIC", width: 4032, height: 3024).line) == "12.4 MB · HEIC · 4032×3024")
        #expect(plain(MediaFacts(bytes: 2_300_000, format: "JPEG", width: 2048, height: 1536).line) == "2.3 MB · JPEG · 2048×1536")
        #expect(plain(MediaFacts(bytes: 2_300_000).line) == "2.3 MB")
        #expect(MediaFacts(width: 0, height: 0).isEmpty)
        #expect(MediaFacts.format(uti: "public.heic") == "HEIC")
        #expect(MediaFacts.format(uti: "public.jpeg") == "JPEG")
        #expect(MediaFacts.format(uti: "com.apple.quicktime-movie") == "MOV")
        #expect(MediaFacts.format(uti: "public.mpeg-4") == "MP4")
        #expect(MediaFacts.format(uti: nil) == nil)
    }

    @Test func motionChangeUsesTheOriginalsUnit() {
        #expect(plain(MediaFacts.change(from: 3_100_000, to: 600_000) ?? "") == "3.1 → 0.6 MB")
        #expect(plain(MediaFacts.change(from: 3_100_000, to: nil) ?? "") == "3.1 MB")
        // Too small to show in the original's unit.
        #expect(plain(MediaFacts.change(from: 3_100_000, to: 8_000) ?? "") == "3.1 MB → 8 kB")
        #expect(MediaFacts.change(from: nil, to: 600_000) == nil)
    }

    @Test func videoContainerFromItsBrand() {
        let header = { (brand: String) in Data([0, 0, 0, 20] + Array("ftyp".utf8) + Array(brand.utf8)) }
        #expect(MediaFacts.videoFormat(header: header("qt  ")) == "MOV")
        #expect(MediaFacts.videoFormat(header: header("isom")) == "MP4")
        #expect(MediaFacts.videoFormat(header: Data("not a video".utf8)) == nil)
    }

    @Test func splitStaysAcrossThePhotoAndMovesByTenths() {
        #expect(SplitPosition.clamp(-0.2) == 0)
        #expect(SplitPosition.clamp(1.4) == 1)
        #expect(SplitPosition.clamp(.nan) == 0.5)
        #expect(SplitPosition.at(x: 100, width: 400) == 0.25)
        #expect(SplitPosition.at(x: 500, width: 400) == 1)
        #expect(SplitPosition.at(x: 10, width: 0) == 0.5)
        #expect(abs(SplitPosition.adjusted(0.5, increment: true) - 0.6) < 0.0001)
        #expect(abs(SplitPosition.adjusted(0.53, increment: false) - 0.4) < 0.0001)
        #expect(SplitPosition.adjusted(0.95, increment: true) == 1)
        #expect(SplitPosition.adjusted(0.04, increment: false) == 0)
        #expect(SplitPosition.spoken(0.5) == "Split at 50 percent")
        #expect(SplitPosition.spoken(0.333) == "Split at 33 percent")
    }

    /// Pages are whole strides apart (a page and the gap after it), the one under the middle is the
    /// one shown, and a new size puts the same page back at its own offset.
    @Test func pagerPagesAreExactStrides() {
        let pager = PagerGeometry(page: CGSize(width: 400, height: 800), gap: 20, count: 35_000)
        #expect(pager.offset(of: 3) == 1260)
        #expect(pager.frame(of: 3) == CGRect(x: 1260, y: 0, width: 400, height: 800))
        #expect(pager.contentSize == CGSize(width: 35_000 * 420, height: 800))
        #expect(pager.offset(of: 40_000) == pager.offset(of: 34_999) && pager.offset(of: -1) == 0)
        // Past half a stride, the next page is the one shown; never one outside the items.
        #expect(pager.index(at: 1260 + 209) == 3 && pager.index(at: 1260 + 211) == 4)
        #expect(pager.index(at: -300) == 0 && pager.index(at: 1e9) == 34_999)
        // At rest one page is on screen (the gap after it is empty); mid-swipe, two.
        #expect(pager.pages(from: 1260, to: 1680) == 3..<4)
        #expect(pager.pages(from: 1400, to: 1820) == 3..<5)
        #expect(pager.pages(from: 1661, to: 1675).isEmpty)
        #expect(pager.pages(from: 0, to: 1e12) == 0..<35_000)
        #expect(PagerGeometry(page: .zero, gap: 20, count: 10).pages(from: 0, to: 100).isEmpty)
        // Folding: the old offset is another page at the new width; the page's own offset isn't.
        let folded = PagerGeometry(page: CGSize(width: 300, height: 700), gap: 20, count: 35_000)
        #expect(folded.index(at: pager.offset(of: 3)) != 3)
        #expect(folded.index(at: folded.offset(of: 3)) == 3)
    }

    @Test func photoFitsInsideTheScreen() {
        #expect(ZoomScrollView.fitted(CGSize(width: 4032, height: 3024), in: CGSize(width: 400, height: 800))
            == CGSize(width: 400, height: 300))
        #expect(ZoomScrollView.fitted(CGSize(width: 1080, height: 1920), in: CGSize(width: 400, height: 400))
            == CGSize(width: 225, height: 400))
        #expect(ZoomScrollView.fitted(.zero, in: CGSize(width: 400, height: 800)) == CGSize(width: 400, height: 800))
    }

    @Test func detailsFooterSaysWhereMotionWasCompressedAndWhatItSaves() {
        let entry = CompactLedger.Entry(compactIdentifier: "copy", originalBytes: 15_500_000, compactBytes: 2_900_000,
                                        savedAt: Date(), serverAssetID: "s")
        var details = ItemDetails(isLive: true, entry: entry)
        details.originalOnPhone = true
        #expect(plain(details.footer(server: "Home Mac", backedUp: true) ?? "")
            == "Motion was compressed on Home Mac. Saves 12.6 MB when you free up space.")
        details.originalOnPhone = false
        details.motionOnPhone = true
        #expect(plain(details.footer(server: "Home Mac", backedUp: true) ?? "")
            == "Motion was compressed on this iPhone. Saved 12.6 MB on this iPhone.")
        #expect(ItemDetails().footer(server: "Home Mac", backedUp: false) == nil)
    }
}
