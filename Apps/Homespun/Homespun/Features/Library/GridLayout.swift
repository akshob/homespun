// SPDX-License-Identifier: Apache-2.0
import UIKit

/// Where everything in the Library grid is, worked out by arithmetic: square cells with 2 pt
/// between them, a month header of one fixed height above each month's rows, and the notice (or
/// the empty state) above the first month. Nothing is measured or estimated, so the grid never
/// moves by itself (a lazy grid that estimated the rows it hadn't built jumped when a drag began),
/// and any item's frame, the item at a point and the content's height cost the same for 35,000 items
/// as for 10: building it is a pass over the months, a lookup a binary search over them.
struct GridGeometry: Equatable, Sendable {
    struct Metrics: Equatable, Sendable {
        /// The content's width (the scroll view's, less the safe area at its sides).
        var width: CGFloat = 0
        var columns = 1
        var spacing: CGFloat = 2
        /// A month header's height (it depends only on the text size).
        var header: CGFloat = 44
        /// Above the first month: the notice and the empty state, when there are any.
        var top: CGFloat = 0
        /// The display's scale: frames fall on whole pixels.
        var scale: CGFloat = 3
    }

    let metrics: Metrics
    /// Each month's first item, and the number of items after the last month (`starts.last`).
    private let starts: [Int]
    /// Each month header's top, and the end of the last month.
    private let tops: [CGFloat]
    /// Each column's left edge and width (the widths differ by a pixel at most).
    private let lefts: [CGFloat]
    private let widths: [CGFloat]
    /// A row's height: the cells' side.
    let side: CGFloat

    /// The items in every month, in order (the months' sizes).
    init(metrics: Metrics, months counts: [Int]) {
        var metrics = metrics
        metrics.columns = max(1, metrics.columns)
        metrics.width = max(0, metrics.width)
        self.metrics = metrics
        let columns = metrics.columns, spacing = metrics.spacing, scale = max(1, metrics.scale)
        func pixel(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        let exact = max(0, (metrics.width - spacing * CGFloat(columns - 1)) / CGFloat(columns))
        var lefts: [CGFloat] = [], widths: [CGFloat] = []
        lefts.reserveCapacity(columns)
        widths.reserveCapacity(columns)
        for column in 0..<columns {
            let left = pixel(CGFloat(column) * (exact + spacing))
            let right = column == columns - 1 ? pixel(metrics.width) : pixel(CGFloat(column) * (exact + spacing) + exact)
            lefts.append(left)
            widths.append(max(0, right - left))
        }
        self.lefts = lefts
        self.widths = widths
        side = pixel(exact)
        var starts = [0], tops = [metrics.top]
        starts.reserveCapacity(counts.count + 1)
        tops.reserveCapacity(counts.count + 1)
        let pitch = side + spacing
        for count in counts {
            let rows = (max(0, count) + columns - 1) / columns
            starts.append(starts[starts.count - 1] + max(0, count))
            tops.append(tops[tops.count - 1] + metrics.header + spacing + CGFloat(rows) * pitch)
        }
        self.starts = starts
        self.tops = tops
    }

    init() { self.init(metrics: Metrics(), months: []) }

    var count: Int { starts[starts.count - 1] }
    var months: Int { starts.count - 1 }
    var columns: Int { metrics.columns }
    private var pitch: CGFloat { side + metrics.spacing }

    /// The whole grid's height: the notice, then every month (no space after the last row).
    var contentHeight: CGFloat { months == 0 ? metrics.top : tops[months] - metrics.spacing }

    /// The month an item is in.
    func month(ofItem item: Int) -> Int {
        // The last month starting at or before the item (months are never empty, but an empty one
        // is passed over).
        var low = 0, high = months - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if starts[middle] <= item { low = middle } else { high = middle - 1 }
        }
        return low
    }

    /// The month whose header or rows are at this height (the first above the grid's top, the last below its end).
    func month(atY y: CGFloat) -> Int {
        var low = 0, high = months - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if tops[middle] <= y { low = middle } else { high = middle - 1 }
        }
        return low
    }

    func monthRange(_ month: Int) -> Range<Int> { starts[month]..<starts[month + 1] }

    func headerFrame(_ month: Int) -> CGRect {
        CGRect(x: 0, y: tops[month], width: metrics.width, height: metrics.header)
    }

    /// Where a month's first row starts.
    private func rowsTop(_ month: Int) -> CGFloat { tops[month] + metrics.header + metrics.spacing }

    private func rows(_ month: Int) -> Int { (starts[month + 1] - starts[month] + columns - 1) / columns }

    func frame(ofItem item: Int) -> CGRect {
        guard months > 0, item >= 0, item < count else { return .zero }
        let month = month(ofItem: item), local = item - starts[month]
        let row = local / columns, column = local % columns
        return CGRect(x: lefts[column], y: rowsTop(month) + CGFloat(row) * pitch, width: widths[column], height: side)
    }

    /// The item under a point, or nil over a header, a gap, or past a month's last item.
    func item(at point: CGPoint) -> Int? {
        guard months > 0, point.y >= tops[0], point.y < contentHeight, let column = column(at: point.x) else { return nil }
        let month = month(atY: point.y)
        let inRows = point.y - rowsTop(month)
        guard inRows >= 0 else { return nil }
        let row = Int(inRows / pitch)
        guard inRows - CGFloat(row) * pitch < side, row < rows(month) else { return nil }
        let item = starts[month] + row * columns + column
        return item < starts[month + 1] ? item : nil
    }

    private func column(at x: CGFloat) -> Int? {
        guard x >= 0, x < metrics.width else { return nil }
        let guess = min(columns - 1, max(0, Int(x / max(1, side + metrics.spacing))))
        for column in [guess, guess - 1, guess + 1] where column >= 0 && column < columns {
            if x >= lefts[column], x < lefts[column] + widths[column] { return column }
        }
        return nil
    }

    /// The item nearest a point: over a header, its month's first row; in a gap, the cell beside it.
    func item(near point: CGPoint) -> Int? {
        guard count > 0 else { return nil }
        let month = month(atY: min(max(point.y, tops[0]), contentHeight))
        let row = min(max(0, Int(floor((point.y - rowsTop(month)) / pitch))), rows(month) - 1)
        let column = min(columns - 1, max(0, Int(point.x / max(1, pitch))))
        return min(starts[month] + row * columns + column, starts[month + 1] - 1)
    }

    /// The items whose rows cross a band of the grid: always one run, in order (empty if none).
    func items(inBand band: ClosedRange<CGFloat>) -> Range<Int> {
        guard months > 0, band.upperBound >= tops[0], band.lowerBound < contentHeight else { return 0..<0 }
        let first = month(atY: band.lowerBound), last = month(atY: band.upperBound)
        let firstRow = min(max(0, Int(floor((band.lowerBound - rowsTop(first)) / pitch))), rows(first))
        let lower = min(starts[first] + firstRow * columns, starts[first + 1])
        let lastRow = Int(floor((band.upperBound - rowsTop(last)) / pitch))
        guard lastRow >= 0 else { return lower..<max(lower, starts[last]) }
        let upper = min(starts[last] + (min(lastRow, rows(last) - 1) + 1) * columns, starts[last + 1])
        return lower..<max(lower, upper)
    }

    /// The months whose header crosses a band.
    func headers(inBand band: ClosedRange<CGFloat>) -> ClosedRange<Int>? {
        guard months > 0, band.upperBound >= tops[0], band.lowerBound < contentHeight else { return nil }
        var first = month(atY: band.lowerBound)
        if tops[first] + metrics.header <= band.lowerBound { first += 1 }
        let last = month(atY: band.upperBound)
        return first <= last ? first...last : nil
    }

    // MARK: Keeping the place

    /// An item in view and where it is on screen: its middle's height as a fraction of the visible
    /// height. Kept when the columns, the width or the items change.
    struct Anchor: Equatable, Sendable {
        var item: Int
        var fraction: CGFloat
    }

    /// The item nearest the middle of what's visible (`visible` in the grid's coordinates).
    func anchor(in visible: CGRect, at point: CGPoint? = nil) -> Anchor? {
        let point = point ?? CGPoint(x: visible.midX, y: visible.midY)
        guard visible.height > 0, let item = item(near: point) else { return nil }
        // On screen (the nearest item to a point in a sliver of a screen can be far outside it).
        return Anchor(item: item, fraction: min(max((frame(ofItem: item).midY - visible.minY) / visible.height, 0), 1))
    }

    /// The visible area's top that puts an anchored item back where it was on screen.
    func top(for anchor: Anchor, visibleHeight: CGFloat) -> CGFloat {
        frame(ofItem: min(max(0, anchor.item), max(0, count - 1))).midY - anchor.fraction * visibleHeight
    }
}

/// The Library grid's layout: frames straight from `GridGeometry`, only for what's on screen.
final class GridLayout: UICollectionViewLayout {
    static let headerKind = "month"

    var geometry = GridGeometry() {
        didSet { if geometry != oldValue { invalidateLayout() } }
    }

    override var collectionViewContentSize: CGSize {
        CGSize(width: geometry.metrics.width, height: geometry.contentHeight)
    }

    /// The controller sets the geometry for the new size before the collection view lays out.
    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool { false }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        let band = rect.minY...max(rect.minY, rect.maxY)
        var result: [UICollectionViewLayoutAttributes] = []
        if let headers = geometry.headers(inBand: band) {
            for month in headers { result.append(headerAttributes(month)) }
        }
        let items = geometry.items(inBand: band)
        result.reserveCapacity(result.count + items.count)
        var month = items.isEmpty ? 0 : geometry.month(ofItem: items.lowerBound)
        for item in items {
            while item >= geometry.monthRange(month).upperBound { month += 1 }
            let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: item - geometry.monthRange(month).lowerBound,
                                                                                     section: month))
            attributes.frame = geometry.frame(ofItem: item)
            result.append(attributes)
        }
        return result
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard indexPath.section < geometry.months else { return nil }
        let item = geometry.monthRange(indexPath.section).lowerBound + indexPath.item
        guard geometry.monthRange(indexPath.section).contains(item) else { return nil }
        let attributes = UICollectionViewLayoutAttributes(forCellWith: indexPath)
        attributes.frame = geometry.frame(ofItem: item)
        return attributes
    }

    override func layoutAttributesForSupplementaryView(ofKind kind: String, at indexPath: IndexPath)
        -> UICollectionViewLayoutAttributes? {
        kind == Self.headerKind && indexPath.section < geometry.months ? headerAttributes(indexPath.section) : nil
    }

    private func headerAttributes(_ month: Int) -> UICollectionViewLayoutAttributes {
        let attributes = UICollectionViewLayoutAttributes(forSupplementaryViewOfKind: Self.headerKind,
                                                          with: IndexPath(item: 0, section: month))
        attributes.frame = geometry.headerFrame(month)
        return attributes
    }
}
