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
