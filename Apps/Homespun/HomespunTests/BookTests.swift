// SPDX-License-Identifier: Apache-2.0
import CoreGraphics
import Testing
@testable import Homespun

/// The book's pages meet at the fold on iPhone Duo (measured: content 867 × 635 pt, division
/// region 40 pt wide at x 455.5 when open and landscape; 669 × 835 with it at y 373.5 when tall).
@Test func bookSplitsAtTheFold() {
    let open = BookSplit.make(size: CGSize(width: 867, height: 635), fold: CGRect(x: 455.5, y: 0, width: 40, height: 669))
    #expect(open.axis == .horizontal)
    #expect(open.first == CGRect(x: 0, y: 0, width: 455.5, height: 635))
    #expect(open.gutter == CGRect(x: 455.5, y: 0, width: 40, height: 635))
    #expect(open.second == CGRect(x: 495.5, y: 0, width: 371.5, height: 635))
    #expect(open.isUsable)

    let tall = BookSplit.make(size: CGSize(width: 669, height: 835), fold: CGRect(x: 0, y: 373.5, width: 669, height: 40))
    #expect(tall.axis == .vertical)
    #expect(tall.first.height == 373.5 && tall.second.minY == 413.5 && tall.second.height == 421.5)

    // No fold (an iPad, a big iPhone in landscape): about half and half with a hairline.
    let plain = BookSplit.make(size: CGSize(width: 900, height: 400), fold: nil)
    #expect(plain.first.width == 449 && plain.gutter.width == 1 && plain.second.width == 450)
    // A fold outside these bounds (a page that doesn't contain it) counts as none.
    #expect(BookSplit.make(size: CGSize(width: 455, height: 635), fold: CGRect(x: 455.5, y: 0, width: 40, height: 669))
            .gutter.width == 1)
    // A region far from the middle (the closed Duo reports the inner display's) isn't a fold.
    #expect(BookSplit.make(size: CGSize(width: 382, height: 644), fold: CGRect(x: 360, y: 0, width: 40, height: 669))
            .gutter.width == 1)
    // Too narrow for two pages: one page.
    #expect(!BookSplit.make(size: CGSize(width: 402, height: 800), fold: nil).isUsable)
}

/// Columns are even everywhere, so a grid across both pages has the same count on each.
@Test func gridColumnsAreEven() {
    func medium(_ width: CGFloat) -> Int { GridColumns.count(width: width, density: 4, accessibility: false) }
    #expect(medium(402) == 4)   // iPhone 18 Pro
    #expect(medium(382) == 4)   // Duo cover
    #expect(medium(594) == 6)   // Duo cover, landscape
    #expect(medium(455.5) == 4) // a page of the open Duo
    #expect(medium(669) == 6)   // the open Duo held tall
    #expect(medium(371.5) == 4) // the right page
    #expect(GridColumns.count(width: 402, density: 2, accessibility: false) == 2)
    #expect(GridColumns.count(width: 402, density: 6, accessibility: false) == 6)
    #expect(GridColumns.count(width: 402, density: 4, accessibility: true) == 2)
    for width in stride(from: 300.0, through: 1400, by: 37) {
        for density in [2, 4, 6] {
            let count = GridColumns.count(width: width, density: density, accessibility: false)
            #expect(count % 2 == 0 && count >= 2)
        }
    }
}
