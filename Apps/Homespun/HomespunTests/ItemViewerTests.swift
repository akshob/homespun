// SPDX-License-Identifier: Apache-2.0
import AVFoundation
import Foundation
import HomespunCore
import HomespunTestSupport
import Photos
import Testing
import UIKit
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
        for badge in [Badge.backedUp, .kept, .waiting, .working, .processing, .compactCopy] {
            #expect(ItemAction.for(.init(id: "a", badge: badge, original: badge == .backedUp ? "o" : nil, canFree: false)) == .none)
        }
    }

    @Test func legacyDisplayExplainsTheCatalogCheckWithoutOfferingVersionedActions() {
        let checkedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let line = ItemText.legacyDetails(checkedAt: checkedAt, server: "polonium")
        #expect(line.contains("Backed up with Homespun 1.0 · polonium has this original (checked "))
        for onPhone in [false, true] {
            let cell = LibraryState.Cell(id: "copy", badge: onPhone ? .copyLater : .backedUp,
                original: "original", canFree: false, legacyCheckedAt: checkedAt)
            #expect(cell.badge.label == (onPhone ? "Backed up" : "Original at home"))
            #expect(ItemAction.for(cell) == .none && !cell.canCompact && !cell.canRestore && !cell.canFree)
            #expect(!ItemAction.canRestore(cell, immich: false) && !ItemAction.canCompare(cell, immich: false))
            #expect(ItemText.sentence(cell.badge, server: "polonium", immich: false, legacy: true).contains("Homespun 1.0"))
        }
        let backed = LibraryState.Cell(id: "original", badge: .copyLater, original: nil,
            canFree: false, legacyCheckedAt: checkedAt)
        #expect(ItemAction.for(backed) == .none && !backed.canCompact && !backed.canRestore)
        #expect(ItemText.sentence(backed.badge, server: "polonium", immich: false, legacy: true)
            == "Backed up · on polonium · Homespun 1.0")
        #expect(backed.badge.spoken(server: "polonium", legacy: true)
            == "Backed up with Homespun 1.0. Original on polonium.")
        #expect(!Badge.recovery.explanation.contains("Reconnect"))
        #expect(Badge.recovery.explanation.contains("Server › Existing Library"))
        var liveDetails = ItemDetails()
        liveDetails.isLive = true
        #expect(liveDetails.footer(server: "polonium", backedUp: true, legacy: true) == nil,
                "Unknown historical provenance must not invent where motion was compressed")
    }

    @Test func compactProgressDistinguishesPhoneDeliveryFromServerProcessing() {
        let saving = ItemText.sentence(.processing, server: "Home Mac", immich: false, job: .working("Downloading 40%"))
        #expect(saving == "Original backed up · saving compact copy · Downloading 40%")
        #expect(ItemText.spoken(saving) == "Original backed up, saving compact copy, Downloading 40%.")
        #expect(ItemText.sentence(.processing, server: "Home Mac", immich: false, job: .working(""))
            == "Original backed up · saving compact copy")
        #expect(ItemText.sentence(.processing, server: "Home Mac", immich: false, job: .processing("Making compact copy"))
            == "Original backed up · compact copy processing on Home Mac")
    }

    @Test func compactProgressDoesNotClaimServerExecutionAfterTheJobMovesOn() {
        let jobs: [CompactJob.State?] = [.saved(originalBytes: 100, compactBytes: 10), nil,
                                       .waiting, .notYet("Paused"), .unchanged("Kept"), .failed("Needs attention"),
                                       .backedUp(originalBytes: 100)]
        for job in jobs {
            let sentence = ItemText.sentence(.processing, server: "Home Mac", immich: false, job: job)
            #expect(sentence == "Original backed up · compact copy in progress")
            #expect(ItemText.spoken(sentence) == "Original backed up, compact copy in progress.")
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

    @Test func compareOffersOnlyModesThatFitTheMediaAndScreen() {
        #expect(CompareView.modes(video: false, regular: true) == [.sideBySide, .split, .original, .compact])
        #expect(CompareView.modes(video: false, regular: false) == [.original, .compact, .split])
        #expect(CompareView.modes(video: true, regular: true) == [.sideBySide, .original, .compact])
        #expect(CompareView.modes(video: true, regular: false) == [.original, .compact])
        #expect(CompareView.adjusted(.split, video: false, regular: true) == .sideBySide)
        #expect(CompareView.adjusted(.split, video: true, regular: true) == .sideBySide)
        #expect(CompareView.adjusted(.sideBySide, video: true, regular: false) == .compact)
        #expect(CompareView.adjusted(.sideBySide, video: false, regular: false) == .split)
        #expect(CompareView.adjusted(.split, video: true, regular: false) == .compact)
        #expect(CompareView.adjusted(.original, video: true, regular: true) == .original)
    }

    @Test func videoTimeFloorsAndIncludesHoursWhenNeeded() {
        #expect(VideoTime.text(2.99) == "0:02")
        #expect(VideoTime.text(3661.9) == "1:01:01")
        #expect(VideoTime.text(.nan) == "0:00")
        #expect(VideoTime.text(-1) == "0:00")
    }

    @Test func videoPlaybackAutoplaysEndsRestartsAndUnloads() async throws {
        let videos = try await videos()
        defer { try? FileManager.default.removeItem(at: videos.folder) }
        let playback = VideoPlayback()
        defer { playback.unload(id: "first") }
        playback.load(item: AVPlayerItem(url: videos.original), id: "first", duration: 3, autoplay: true)
        try #require(await eventually { playback.isPlaying && playback.time > 0.3 })
        let player = playback.player
        try #require(await eventually { !playback.isPlaying && playback.time > 2.9 })
        #expect(abs(playback.time - playback.duration) < 0.05)
        playback.play()
        try #require(await eventually { playback.isPlaying && playback.time > 0.1 && playback.time < 1 })
        playback.beginScrub()
        playback.scrub(to: 0.5)
        playback.scrub(to: 1)
        playback.scrub(to: 2)
        playback.endScrub()
        try #require(await eventually { playback.isPlaying && playback.time >= 2 })
        playback.unload(id: "another")
        #expect(playback.id == "first")
        playback.unload(id: "first")
        try await Task.sleep(for: .milliseconds(300))
        #expect(playback.status == .idle && !playback.isPlaying && playback.time == 0)
        #expect(player.currentItem == nil && player === playback.player)
        playback.load(item: AVPlayerItem(url: videos.compact), id: "second", duration: 3, autoplay: false)
        try #require(await eventually { playback.status == .ready })
        #expect(!playback.isPlaying && playback.player === player)
        let item = DemoItem(id: "second", created: nil, width: 320, height: 180, duration: 3, favorite: false,
                            screenshot: false, kind: .video, files: [.video: videos.compact], thumbnail: nil)
        let oldCell = VideoPageCell(frame: .zero), newCell = VideoPageCell(frame: .zero), images = ItemImages()
        for cell in [oldCell, newCell] {
            cell.show(id: "second", item: { item }, current: true, label: "Video", placeholder: nil,
                      images: images, playback: playback)
        }
        // A library reload can replace a cell without changing the item shown.
        oldCell.endDisplaying()
        #expect(playback.id == "second" && player.currentItem != nil)
        newCell.endDisplaying()
        #expect(playback.status == .idle && player.currentItem == nil)
    }

    @Test func videoPairPlaysSeeksAndEndsTogetherWithOneSound() async throws {
        let videos = try await videos()
        defer { try? FileManager.default.removeItem(at: videos.folder) }
        let original = AVPlayer(url: videos.original), compact = AVPlayer(url: videos.compact)
        let pair = VideoPair()
        defer { pair.stop() }
        pair.attach(original: original, compact: compact)
        pair.active = true
        try #require(await eventually { original.currentItem?.status == .readyToPlay && compact.currentItem?.status == .readyToPlay })
        #expect(original.isMuted && !compact.isMuted)
        pair.heard = .original
        #expect(!original.isMuted && compact.isMuted)
        pair.play()
        try await Task.sleep(for: .milliseconds(1200))
        pair.pause()
        try #require(await eventually {
            abs(original.currentTime().seconds - compact.currentTime().seconds) < 0.05
        })
        #expect(pair.time > 0.6)
        pair.beginScrub()
        pair.scrub(to: 0.2)
        pair.scrub(to: 1)
        pair.scrub(to: 2)
        pair.endScrub()
        try #require(await eventually {
            abs(original.currentTime().seconds - 2) < 0.04 && abs(compact.currentTime().seconds - 2) < 0.04
        })
        pair.play()
        try #require(await eventually { !pair.isPlaying && pair.time > 2.9 })
        pair.active = false
        #expect(!original.isMuted && !compact.isMuted)
    }

    @Test func videoPairJoinsALateOriginalWithoutChangingSound() async throws {
        let videos = try await videos()
        defer { try? FileManager.default.removeItem(at: videos.folder) }
        let compact = AVPlayer(url: videos.compact)
        let pair = VideoPair()
        defer { pair.stop() }
        pair.attach(original: nil, compact: compact)
        pair.active = true
        try #require(await eventually { compact.currentItem?.status == .readyToPlay })
        pair.play()
        try #require(await eventually { pair.time > 0.5 })
        let original = AVPlayer(url: videos.original)
        pair.attach(original: original, compact: compact)
        try #require(await eventually {
            original.timeControlStatus == .playing && abs(original.currentTime().seconds - compact.currentTime().seconds) < 0.1
        })
        try await Task.sleep(for: .seconds(1))
        #expect(abs(original.currentTime().seconds - compact.currentTime().seconds) < 0.1)
        #expect(pair.heard == .compact && original.isMuted && !compact.isMuted)
    }

    @Test func reviewKeepsOneNonFirstSelectionAndItsComparisonOwner() {
        let pairs = (0..<3).map { FreeUpPair(original: "original-\($0)", compact: "copy-\($0)") }
        let review = FreeUpReview()
        review.reconcile(pairs)
        review.path = [pairs[2]]
        let comparison = review.comparison
        comparison.mode = .original
        comparison.split = 0.27
        review.reconcile(pairs)
        #expect(review.selected == pairs[2] && review.path == [pairs[2]])
        #expect(review.comparison === comparison && comparison.mode == .original && comparison.split == 0.27)
        review.path = []
        #expect(review.selected == pairs[2])
        review.showingComparison = true
        #expect(review.path == [pairs[2]])
        review.reconcile(Array(pairs.prefix(2)))
        #expect(review.selected == pairs[0])
    }

    @Test func linkedZoomSurvivesResizeAndReplacementOfTheCanvas() {
        let link = ZoomLink()
        func canvas(_ size: CGSize) -> ZoomScrollView {
            let view = ZoomScrollView(content: UIView())
            view.aspect = CGSize(width: 1600, height: 1200)
            link.add(view)
            view.frame = CGRect(origin: .zero, size: size)
            view.layoutIfNeeded()
            return view
        }
        let original = canvas(CGSize(width: 600, height: 500))
        original.apply(ZoomPosition(scale: 2, middle: CGPoint(x: 0.5, y: 0.55)))
        let replacement = canvas(CGSize(width: 350, height: 400))
        #expect(abs(replacement.zoomScale - 2) < 0.001)
        #expect(abs(replacement.position.middle.y - 0.55) < 0.01)
        replacement.frame.size = CGSize(width: 400, height: 350)
        replacement.layoutIfNeeded()
        #expect(abs(replacement.zoomScale - 2) < 0.001)
        #expect(abs(replacement.position.middle.y - 0.55) < 0.01)
    }

    @MainActor private final class DelayedDetails {
        private var value: CheckedContinuation<ItemDetails, Never>?
        private var started: CheckedContinuation<Void, Never>?

        func read() async -> ItemDetails {
            await withCheckedContinuation {
                value = $0
                started?.resume()
                started = nil
            }
        }

        func waitForStart() async {
            if value != nil { return }
            await withCheckedContinuation { started = $0 }
        }

        func finish(_ bytes: Int) {
            value?.resume(returning: ItemDetails(shown: MediaFacts(bytes: bytes)))
            value = nil
        }
    }

    @Test func inspectorClearsOldFactsAndRejectsLateResultsFromThePreviousItem() async {
        let loader = ItemDetails.ItemDetailsLoader()
        await loader.load(id: "first") { ItemDetails(shown: MediaFacts(bytes: 10)) }
        let old = DelayedDetails(), new = DelayedDetails()
        let older = Task { await loader.load(id: "first") { await old.read() } }
        await old.waitForStart()
        let newer = Task { await loader.load(id: "second") { await new.read() } }
        await new.waitForStart()
        #expect(loader.id == "second" && loader.details == nil)
        new.finish(200)
        await newer.value
        old.finish(100)
        await older.value
        #expect(loader.id == "second" && loader.details?.shown.bytes == 200)
    }

    private final class RequestProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled: [Int32] = []
        private var callback: (@Sendable (Int) -> Void)?
        func cancel(_ id: Int32) { lock.withLock { cancelled.append(id) } }
        var ids: [Int32] { lock.withLock { cancelled } }
        func remember(_ callback: @escaping @Sendable (Int) -> Void) { lock.withLock { self.callback = callback } }
        func complete(_ value: Int) {
            let pending = lock.withLock { callback }
            pending?(value)
        }
    }

    @Test func photoRequestsResolveOnceAcrossEarlyCompletionAndCancellation() async {
        let probe = RequestProbe()
        let early = ItemMedia.PhotoRequest<Int>(cancelled: -1, cancel: { probe.cancel($0) })
        let success = await withCheckedContinuation { continuation in
            #expect(early.begin(continuation))
            early.finish(7)
            early.install(41)
            early.cancel()
            early.finish(8)
        }
        #expect(success == 7 && probe.ids.isEmpty)

        let lateID = ItemMedia.PhotoRequest<Int>(cancelled: -1, cancel: { probe.cancel($0) })
        let stopped = await withCheckedContinuation { continuation in
            #expect(lateID.begin(continuation))
            lateID.cancel()
            lateID.install(42)
            lateID.finish(9)
        }
        #expect(stopped == -1 && probe.ids == [42])

        for _ in 0..<20 {
            let pending = ItemMedia.PhotoRequest<Int>(cancelled: -1, cancel: { _ in })
            let result = await withCheckedContinuation { continuation in
                #expect(pending.begin(continuation))
                pending.install(43)
                DispatchQueue.concurrentPerform(iterations: 2) { index in
                    if index == 0 { pending.finish(10) } else { pending.cancel() }
                }
            }
            #expect(result == -1 || result == 10)
        }
    }

    @Test func cancellingTheCallingTaskCancelsItsPhotoKitRequestAndIgnoresALateCallback() async {
        let probe = RequestProbe()
        let started = AsyncStream<Void>.makeStream()
        let task = Task {
            await ItemMedia.PhotoRequest<Int>.value(cancelled: -1, cancel: { probe.cancel($0) }) {
                finish in
                probe.remember(finish)
                started.continuation.yield()
                return 44
            }
        }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        task.cancel()
        #expect(await task.value == -1 && probe.ids == [44])
        probe.complete(99)
        started.continuation.finish()
    }

    @Test func nameDraftDoesNotReloadOverAnUnsavedEdit() {
        let device = ServerAPI.DeviceInfo(id: "this", name: "Original", folder: "Original",
                                          pairedAt: nil, lastSeenAt: nil, isThisDevice: true)
        let draft = DeviceNameDraft()
        draft.receive(device)
        draft.name = "An unfinished name"
        var reload = device
        reload.name = "Server name"
        draft.receive(reload)
        #expect(draft.name == "An unfinished name" && draft.device == device && draft.wantsFocus)
    }

    @Test func sidebarTeardownRetainsTheNameRouteWithoutChangingOrdinaryFoldNavigation() {
        enum Route: Equatable { case name, devices, check }
        let retaining: (Route) -> Bool = { $0 == .name }
        let editor = SidebarNavigation.selecting(nil, in: [Route.devices, .name], retaining: retaining)
        #expect(editor == [.devices, .name])
        #expect(SidebarNavigation.selecting(nil, in: [Route.check], retaining: retaining).isEmpty)
        #expect(SidebarNavigation.selecting(Route.check, in: editor, retaining: retaining) == [.check])
        #expect(SidebarNavigation.selecting(nil, in: [Route](), retaining: retaining).isEmpty)
    }

    private final class MemoryItem: Homespun.LibraryItem {
        let localIdentifier: String
        let picture: UIImage
        let creationDate: Date? = nil
        let pixelWidth = 64
        let pixelHeight = 64
        let duration = 0.0
        let isFavorite = false
        let isHidden = false
        let itemKind: PhotoLibrary.Kind? = .photo
        let isEdited = false

        init(_ id: String, _ picture: UIImage) {
            localIdentifier = id
            self.picture = picture
        }

        func mediaFacts() -> (main: MediaFacts, motion: Int?) { (MediaFacts(width: 64, height: 64), nil) }
        @MainActor func image(size: CGSize?, fast: Bool) async -> UIImage? { picture }
        @MainActor func livePhoto(size: CGSize) async -> PHLivePhoto? { nil }
        @MainActor func playerItem() async -> Result<AVPlayerItem, Error> { .failure(CancellationError()) }
        @MainActor func player() async -> AVPlayer? { nil }
    }

    @Test func sameIDContentEditRefreshesThePageAndOnlyItsCachedPlaceholder() async throws {
        func picture(_ color: UIColor) -> UIImage {
            UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
                color.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            }
        }
        let original = MemoryItem("edited", picture(.red)), untouched = MemoryItem("untouched", picture(.green))
        let edited = MemoryItem("edited", picture(.blue))
        let images = ItemImages()
        images.resize(CGSize(width: 64, height: 64))
        images.keep(ids: ["edited", "untouched"], around: 0) { $0 == "edited" ? original : untouched }
        try #require(await eventually { images.image("edited") != nil && images.image("untouched") != nil })
        let neighbor = images.image("untouched")
        let cell = PhotoPageCell(frame: CGRect(x: 0, y: 0, width: 64, height: 64))
        cell.show(id: "edited", item: { original }, current: true, label: "Photo", placeholder: images.image("edited"),
                  images: images, onZoom: { _ in })
        let canvas = try #require(cell.contentView.subviews.compactMap { $0 as? ZoomScrollView }.first?.content as? PhotoContent)
        try #require(await eventually { canvas.image != nil })
        let oldPicture = canvas.image?.pngData()
        images.invalidate(["edited"])
        #expect(images.image("untouched") === neighbor)
        images.keep(ids: ["edited", "untouched"], around: 0) { $0 == "edited" ? edited : untouched }
        cell.show(id: "edited", item: { edited }, current: true, label: "Photo", placeholder: nil, images: images, onZoom: { _ in })
        try #require(await eventually { canvas.image != nil && canvas.image?.pngData() != oldPicture })
        #expect(images.image("untouched") === neighbor)
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(15)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(30))
        }
        return condition()
    }

    private func videos() async throws -> (folder: URL, original: URL, compact: URL) {
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("video-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let original = folder.appendingPathComponent("original.mov"), compact = folder.appendingPathComponent("compact.mov")
        do {
            try await Task.detached {
                try await Synthetic.video(at: original, .init(width: 640, height: 360, frames: 90, audioChannels: 0))
                try await Synthetic.video(at: compact, .init(width: 320, height: 180, frames: 90, audioChannels: 0))
            }.value
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return (folder, original, compact)
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
