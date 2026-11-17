// SPDX-License-Identifier: Apache-2.0
import CoreGraphics
import SwiftUI
import Testing
@testable import Homespun

/// The grid runs across the whole width. On a phone (and iPhone Duo's cover) it has the person's 2, 4
/// or 6 columns; on the open iPhone Duo, one screen, about as many as Photos (5 held tall and 6 wide
/// at the default size), never split at the fold.
@Test func gridColumnsFollowTheWidth() {
    func count(_ width: CGFloat, _ density: Int = 4) -> Int {
        GridColumns.count(width: width, density: density, accessibility: false)
    }
    #expect(count(402) == 4 && count(382) == 4)            // iPhone 18 Pro, Duo cover
    #expect(count(402, 2) == 2 && count(402, 6) == 6)
    #expect(count(669) == 5 && count(867) == 6)            // Duo open: tall, wide
    #expect(count(669, 2) == 3 && count(867, 2) == 4)
    #expect(count(669, 6) == 8 && count(867, 6) == 10)
    #expect(GridColumns.count(width: 402, density: 4, accessibility: true) == 2)
    #expect(GridColumns.count(width: 867, density: 4, accessibility: true) == 3)
    // Wider never means fewer.
    for density in [2, 4, 6] {
        let counts = stride(from: 320.0, through: 1400, by: 10).map { count($0, density) }
        #expect(counts == counts.sorted())
    }
}

/// Drag-to-select finds the cell under a finger among the cells on screen.
@Test func cellFramesFindTheCellUnderAPoint() {
    let frames = CellFrames()
    frames.rects = [0: CGRect(x: 0, y: 0, width: 99, height: 99), 1: CGRect(x: 101, y: 0, width: 99, height: 99)]
    #expect(frames.position(at: CGPoint(x: 150, y: 50)) == 1)
    #expect(frames.position(at: CGPoint(x: 100, y: 50)) == nil) // the gap
}

/// Partly folded and held tall (like a laptop), iPhone Duo's crease runs across the screen; Compare's
/// split knob moves off it (below, or above when the line ends first) and stays put otherwise.
@Test func compareKnobAvoidsAnActiveFold() {
    let fold = CGRect(x: 0, y: 373.5, width: 669, height: 40)
    #expect(CompareView.knobY(middle: 300, line: 100...500, fold: fold) == 300)
    #expect(CompareView.knobY(middle: 390, line: 100...700, fold: fold) == 413.5 + 22 + 8)
    #expect(CompareView.knobY(middle: 390, line: 200...440, fold: fold) == 373.5 - 22 - 8)
}

/// Side by side puts the two photos where they show larger: a tall photo next to each other, a wide
/// one stacked, whatever the stage's shape; an active fold still decides, and without a photo the
/// stage's shape does.
@Test func sideBySideFitsThePhoto() {
    let stage = CGSize(width: 669, height: 400)
    let tall = SideBySide.panes(size: stage, fold: nil, photo: CGSize(width: 1668, height: 2500))
    #expect(tall.first.maxX <= tall.second.minX && tall.first.height == 400)
    let wide = SideBySide.panes(size: CGSize(width: 669, height: 860), fold: nil, photo: CGSize(width: 4032, height: 3024))
    #expect(wide.first.maxY <= wide.second.minY && wide.first.width == 669)
    let none = SideBySide.panes(size: stage, fold: nil)
    #expect(none.first.maxX <= none.second.minX)
    let crease = CGRect(x: 0, y: 180, width: 669, height: 40)
    let folded = SideBySide.panes(size: CGSize(width: 669, height: 860), fold: crease, photo: CGSize(width: 1668, height: 2500))
    #expect(folded.first.maxY == 180 && folded.second.minY == 220)
}

/// Cells of a longer grid can still report themselves after a filter made it shorter (or while
/// iPhone Duo unfolds): the preheat window ignores them instead of trapping (reports HS-UHJXHW,
/// HS-5MX4AG).
@MainActor @Test func preheatWindowIgnoresCellsPastTheEnd() {
    #expect(ThumbnailPreheater.window(visible: [33_000, 33_010], count: 285) == nil)
    let mixed = ThumbnailPreheater.window(visible: [3, 10, 33_000], count: 285)
    #expect(mixed?.range == 0...34 && mixed?.center == 6 && mixed?.span == 24)
    #expect(ThumbnailPreheater.window(visible: [270, 284], count: 285)?.range == 246...284)
    #expect(ThumbnailPreheater.window(visible: [], count: 285) == nil)
    #expect(ThumbnailPreheater.window(visible: [0], count: 0) == nil)
}
