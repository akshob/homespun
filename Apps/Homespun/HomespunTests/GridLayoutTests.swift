// SPDX-License-Identifier: Apache-2.0
import CoreGraphics
import Photos
import Testing
@testable import Homespun

/// A library like a real one: 35,000 items over 140-odd months of different sizes.
private let months: [Int] = {
    var counts: [Int] = [], total = 0, month = 0
    while total < 35_000 {
        let count = min(35_000 - total, 20 + (month * 97) % 480)
        counts.append(count)
        total += count
        month += 1
    }
    return counts
}()

private func geometry(width: CGFloat = 402, columns: Int = 4, top: CGFloat = 0, counts: [Int] = months) -> GridGeometry {
    GridGeometry(metrics: .init(width: width, columns: columns, spacing: 2, header: 44, top: top, scale: 3), months: counts)
}

/// Every frame is arithmetic: 4 columns of 99 pt with 2 pt between them across 402 pt, a 44 pt header
/// and 2 pt above each month's first row; the content ends at the last row.
@Test func gridFramesAreExact() {
    let grid = geometry(counts: [10, 5])
    #expect(grid.side == 99)
    #expect(grid.headerFrame(0) == CGRect(x: 0, y: 0, width: 402, height: 44))
    #expect(grid.frame(ofItem: 0) == CGRect(x: 0, y: 46, width: 99, height: 99))
    #expect(grid.frame(ofItem: 1) == CGRect(x: 101, y: 46, width: 99, height: 99))
    #expect(grid.frame(ofItem: 3) == CGRect(x: 303, y: 46, width: 99, height: 99))
    #expect(grid.frame(ofItem: 4) == CGRect(x: 0, y: 147, width: 99, height: 99))
    // Three rows (10 items), then the next month's header.
    let second: CGFloat = 44 + 2 + 3 * 101, end: CGFloat = 349 + 44 + 2 + 2 * 101 - 2
    #expect(grid.headerFrame(1).minY == second)
    #expect(grid.frame(ofItem: 10) == CGRect(x: 0, y: 349 + 46, width: 99, height: 99))
    #expect(grid.contentHeight == grid.frame(ofItem: 14).maxY)
    #expect(grid.contentHeight == end)
    // The notice above the first month moves everything down.
    let moved: CGFloat = 120 + 349 + 46, notice: CGFloat = 120
    #expect(geometry(top: 120, counts: [10, 5]).frame(ofItem: 10).minY == moved)
    #expect(geometry(top: 120, counts: []).contentHeight == notice)
}

/// Columns that don't divide the width evenly still meet edge to edge, on whole pixels, 2 pt apart.
@Test func gridColumnsFallOnPixels() {
    let grid = geometry(width: 867, columns: 10, counts: [10])
    let frames = (0..<10).map { grid.frame(ofItem: $0) }
    #expect(frames[0].minX == 0 && abs(frames[9].maxX - 867) < 0.001)
    for (left, right) in zip(frames, frames.dropFirst()) {
        #expect(abs(right.minX - left.maxX - 2) < 0.34)
        #expect(abs(left.width - right.width) < 0.34)
    }
    for frame in frames {
        #expect(abs((frame.minX * 3).rounded() - frame.minX * 3) < 0.001)
        #expect(abs((frame.width * 3).rounded() - frame.width * 3) < 0.001)
    }
}

/// At 35,000 items every item is found where its frame is, frames follow each other in order, and
/// the content ends at the last row.
@Test func everyItemIsWhereItsFrameIs() {
    for columns in [4, 6, 10] {
        let grid = geometry(width: columns == 10 ? 867 : 402, columns: columns)
        #expect(grid.count == 35_000 && grid.months == months.count)
        var previous = CGRect.zero
        for item in 0..<grid.count {
            let frame = grid.frame(ofItem: item)
            let inOrder = item == 0 || frame.minY > previous.minY || (frame.minY == previous.minY && frame.minX > previous.minX)
            if grid.item(at: CGPoint(x: frame.midX, y: frame.midY)) != item || !inOrder {
                Issue.record("\(columns) columns: item \(item) isn't under its frame \(frame), or out of order")
                break
            }
            previous = frame
        }
        #expect(grid.contentHeight == grid.frame(ofItem: grid.count - 1).maxY)
    }
}

/// Headers, the gaps between cells and rows, a short last row and below the end hold no item.
@Test func noItemOverHeadersOrGaps() {
    let grid = geometry(counts: [10, 5])
    #expect(grid.item(at: CGPoint(x: 50, y: 20)) == nil)           // the first header
    #expect(grid.item(at: CGPoint(x: 100, y: 80)) == nil)          // between columns
    #expect(grid.item(at: CGPoint(x: 50, y: 146)) == nil)          // between rows
    #expect(grid.item(at: CGPoint(x: 250, y: 46 + 2 * 101 + 50)) == nil) // past the 10th item in the 3rd row
    #expect(grid.item(at: CGPoint(x: 50, y: 349 + 20)) == nil)     // the second header
    #expect(grid.item(at: CGPoint(x: 50, y: grid.contentHeight + 10)) == nil)
    #expect(grid.item(at: CGPoint(x: -1, y: 80)) == nil && grid.item(at: CGPoint(x: 402, y: 80)) == nil)
    // Nearest: a header gives its month's first item; a gap the cell beside it; past the end the last.
    #expect(grid.item(near: CGPoint(x: 50, y: 349 + 20)) == 10)
    #expect(grid.item(near: CGPoint(x: 100, y: 80)) == 0)
    #expect(grid.item(near: CGPoint(x: 350, y: 46 + 2 * 101 + 50)) == 9)
    #expect(grid.item(near: CGPoint(x: 50, y: 100_000)) == 14)
}

/// What's in a band of the grid (what's on screen, the thumbnail window) is worked out without
/// looking at other items, and matches a check of every frame.
@Test func bandsHoldExactlyTheirItems() {
    let grid = geometry()
    var random = SystemRandomNumberGenerator()
    for _ in 0..<200 {
        let low = CGFloat.random(in: -100...grid.contentHeight, using: &random)
        let band = low...(low + CGFloat.random(in: 1...2_000, using: &random))
        let found = grid.items(inBand: band)
        // Everything whose frame crosses the band is in it, and nothing far from it.
        guard !found.isEmpty else {
            #expect(!(0..<grid.count).contains { grid.frame(ofItem: $0).minY < band.upperBound && grid.frame(ofItem: $0).maxY > band.lowerBound })
            continue
        }
        let first = grid.frame(ofItem: found.lowerBound), last = grid.frame(ofItem: found.upperBound - 1)
        #expect(first.minY <= band.upperBound && first.maxY + 2 >= band.lowerBound)
        #expect(last.minY <= band.upperBound && last.maxY + 2 >= band.lowerBound)
        if found.lowerBound > 0 { #expect(grid.frame(ofItem: found.lowerBound - 1).maxY <= band.lowerBound + 0.001) }
        if found.upperBound < grid.count { #expect(grid.frame(ofItem: found.upperBound).minY >= band.upperBound - 0.001) }
        if let headers = grid.headers(inBand: band) {
            for month in headers { #expect(grid.headerFrame(month).intersects(CGRect(x: 0, y: band.lowerBound, width: 1, height: band.upperBound - band.lowerBound))) }
            if headers.lowerBound > 0 { #expect(grid.headerFrame(headers.lowerBound - 1).maxY <= band.lowerBound) }
            if headers.upperBound < grid.months - 1 { #expect(grid.headerFrame(headers.upperBound + 1).minY > band.upperBound) }
        }
    }
    #expect(grid.items(inBand: -500 ... -10).isEmpty && grid.items(inBand: grid.contentHeight + 1 ... grid.contentHeight + 900).isEmpty)
}

/// Changing the columns (Grid Size, a pinch) or the width (unfolding, turning) keeps the item that was
/// in the middle of the screen at the same height on screen.
@Test func theItemInViewStaysInViewWhenTheColumnsChange() throws {
    let phone = geometry(width: 402, columns: 4), small = geometry(width: 402, columns: 6), open = geometry(width: 867, columns: 6)
    let visible = CGRect(x: 0, y: 400_000, width: 402, height: 700)
    let anchor = try #require(phone.anchor(in: visible))
    #expect(visible.contains(CGPoint(x: visible.midX, y: phone.frame(ofItem: anchor.item).midY)))
    for (other, height) in [(small, 700.0), (open, 560.0)] {
        let top = other.top(for: anchor, visibleHeight: height)
        let frame = other.frame(ofItem: anchor.item)
        #expect(abs((frame.midY - top) / height - anchor.fraction) < 0.0001)
        #expect(frame.minY >= top && frame.maxY <= top + height)
    }
    // A pinch keeps the item under the fingers.
    let pinched = try #require(phone.anchor(in: visible, at: CGPoint(x: 300, y: 400_100)))
    #expect(phone.frame(ofItem: pinched.item).insetBy(dx: -2, dy: -2).contains(CGPoint(x: 300, y: 400_100)))
    // Mid-turn the bars can leave a sliver of a screen: the item stays on screen, not far above it.
    let sliver = try #require(phone.anchor(in: CGRect(x: 0, y: 400_000, width: 402, height: 1)))
    #expect((0...1).contains(sliver.fraction))
}

/// The thumbnail window reaches further in the direction of scrolling, follows only once the screen
/// has moved by a third, and starts and stops caching only what changed.
@Test func thumbnailWindowFollowsTheScrolling() {
    #expect(PreheatWindow.band(visible: 100...900, direction: 1) == -300...1_700)
    #expect(PreheatWindow.band(visible: 100...900, direction: -1) == -700...1_300)
    #expect(PreheatWindow.band(visible: 100...900, direction: 0) == -500...1_500)
    #expect(PreheatWindow.moved(from: nil, to: 0...800))
    #expect(!PreheatWindow.moved(from: 0...800, to: 200...1_000))
    #expect(PreheatWindow.moved(from: 0...800, to: 300...1_100))
    func changes(_ old: Range<Int>, _ new: Range<Int>) -> ([Range<Int>], [Range<Int>]) {
        let result = PreheatWindow.changes(from: old, to: new)
        return (result.start, result.stop)
    }
    #expect(changes(0..<10, 5..<15) == ([10..<15], [0..<5]))
    #expect(changes(5..<15, 0..<10) == ([0..<5], [10..<15]))
    #expect(changes(0..<10, 20..<30) == ([20..<30], [0..<10]))
    #expect(changes(0..<30, 10..<20) == ([], [0..<10, 20..<30]))
    #expect(changes(0..<0, 3..<9) == ([3..<9], []))
    #expect(changes(3..<9, 3..<9) == ([], []))
}

/// The window never reaches past the items there are (a shorter grid after a filter trapped the
/// old preheater: reports HS-UHJXHW, HS-5MX4AG).
@MainActor @Test func thumbnailWindowStaysWithinTheItems() {
    let thumbnails = GridThumbnails(manager: PHCachingImageManager(), source: { AssetSource(result: nil, index: [:]) })
    thumbnails.reset(order: (0..<285).map { "item-\($0)" }, pixels: 300)
    thumbnails.keep(250..<33_010)
    #expect(thumbnails.window == 250..<285)
    thumbnails.keep(33_000..<33_010)
    #expect(thumbnails.window.isEmpty)
    thumbnails.reset(order: [], pixels: 300)
    thumbnails.keep(0..<40)
    #expect(thumbnails.window.isEmpty)
}

/// Items prefetched ahead of the window pass to the window when it reaches them, so it lets go of
/// them once it has moved on (they stayed cached for the rest of the session).
@MainActor @Test func thumbnailWindowTakesOverPrefetchedItems() {
    let thumbnails = GridThumbnails(manager: PHCachingImageManager(), source: { AssetSource(result: nil, index: [:]) })
    thumbnails.reset(order: (0..<100).map { "item-\($0)" }, pixels: 300)
    thumbnails.keep(0..<20)
    thumbnails.prefetch([10, 25, 26])
    #expect(thumbnails.prefetched == ["item-25", "item-26"])
    thumbnails.keep(10..<30)
    #expect(thumbnails.prefetched.isEmpty)
    thumbnails.cancelPrefetching([25])
    #expect(thumbnails.prefetched.isEmpty)
}
