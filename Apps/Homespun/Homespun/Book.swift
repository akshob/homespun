// SPDX-License-Identifier: Apache-2.0
import SwiftUI

/// Where the two pages of a book go (DUO §8, §11): split exactly at the fold when the display has
/// one, so the gutter sits on the crease flat and half open; about half and half without one.
/// Pure, so it's tested with fixed fold frames.
struct BookSplit: Equatable {
    enum Axis: Equatable { case horizontal, vertical }

    var axis: Axis
    /// The first page (left, or top when stacked) and the second page, in the book's coordinates.
    var first: CGRect
    var gutter: CGRect
    var second: CGRect

    /// A gutter between pages when there's no fold to put it on.
    static let plainGutter: CGFloat = 1
    /// A page narrower than this can't hold a list or a grid; then the book shows one page.
    static let minimumPage: CGFloat = 280

    /// `fold` is the division region's frame in the same coordinates as `size`, if there is one.
    static func make(size: CGSize, fold: CGRect?) -> BookSplit {
        let bounds = CGRect(origin: .zero, size: size)
        if let fold, !fold.isEmpty, bounds.intersects(fold), isCentral(fold.intersection(bounds), in: size) {
            let clipped = fold.intersection(bounds)
            if clipped.height >= clipped.width {
                // A vertical crease: pages side by side.
                return BookSplit(axis: .horizontal,
                                 first: CGRect(x: 0, y: 0, width: clipped.minX, height: size.height),
                                 gutter: CGRect(x: clipped.minX, y: 0, width: clipped.width, height: size.height),
                                 second: CGRect(x: clipped.maxX, y: 0, width: size.width - clipped.maxX, height: size.height))
            }
            // A horizontal crease (the open device held tall): pages stacked.
            return BookSplit(axis: .vertical,
                             first: CGRect(x: 0, y: 0, width: size.width, height: clipped.minY),
                             gutter: CGRect(x: 0, y: clipped.minY, width: size.width, height: clipped.height),
                             second: CGRect(x: 0, y: clipped.maxY, width: size.width, height: size.height - clipped.maxY))
        }
        let half = ((size.width - plainGutter) / 2).rounded(.down)
        return BookSplit(axis: .horizontal,
                         first: CGRect(x: 0, y: 0, width: half, height: size.height),
                         gutter: CGRect(x: half, y: 0, width: plainGutter, height: size.height),
                         second: CGRect(x: half + plainGutter, y: 0, width: size.width - half - plainGutter,
                                        height: size.height))
    }

    /// A crease near the middle; anything else isn't a fold to build a book on (the closed iPhone
    /// Duo still reports the inner display's division region, far off its own centre).
    private static func isCentral(_ fold: CGRect, in size: CGSize) -> Bool {
        fold.height >= fold.width ? abs(fold.midX - size.width / 2) < size.width / 4
            : abs(fold.midY - size.height / 2) < size.height / 4
    }

    /// Both pages are big enough to use.
    var isUsable: Bool {
        switch axis {
        case .horizontal: first.width >= Self.minimumPage && second.width >= Self.minimumPage
        case .vertical: first.height >= 200 && second.height >= 200
        }
    }
}

/// Even grid columns, so a two-page grid has the same count on each page and the fold is never
/// inside a cell (DUO §11): about one column per 110 pt, rounded to an even number, at least 2.
enum GridColumns {
    static func count(width: CGFloat, density: Int, accessibility: Bool) -> Int {
        // `density` is the person's choice: 2 (large), 4 (medium, the default) or 6 (small) on a phone.
        let target: CGFloat = switch density {
        case ..<3: 200
        case 3...4: 110
        default: 66
        }
        let even = max(2, Int((width / target / 2).rounded()) * 2)
        return accessibility ? max(2, even / 2) : even
    }
}

/// Two pages that meet at the fold on iPhone Duo, and in the middle elsewhere. On iOS 27.1 and
/// later the fold comes from the display's division region; before that there's no fold to find.
struct Book<First: View, Second: View>: View {
    var showsSecond = true
    @ViewBuilder var first: First
    @ViewBuilder var second: Second

    var body: some View {
        GeometryReader { proxy in
            let split = BookSplit.make(size: proxy.size, fold: Self.fold(in: proxy))
            if showsSecond, split.isUsable {
                ZStack(alignment: .topLeading) {
                    first.frame(width: split.first.width, height: split.first.height)
                        .offset(x: split.first.minX, y: split.first.minY)
                    Theme.separator.opacity(split.gutter.width > BookSplit.plainGutter ? 0 : 1)
                        .frame(width: split.gutter.width, height: split.gutter.height)
                        .offset(x: split.gutter.minX, y: split.gutter.minY)
                        .accessibilityHidden(true)
                    second.frame(width: split.second.width, height: split.second.height)
                        .offset(x: split.second.minX, y: split.second.minY)
                }
            } else {
                first.frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
    }

    static func fold(in proxy: GeometryProxy) -> CGRect? {
        if #available(iOS 27.1, *) {
            return proxy.reservedRegions(kind: .division, options: .includeInactive).first?.frame
        }
        return nil
    }
}

/// Whether this display has a fold (iPhone Duo open), from the division region; false before 27.1.
struct FoldReader: View {
    @Binding var hasFold: Bool

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { hasFold = Book<EmptyView, EmptyView>.fold(in: proxy) != nil }
                .onChange(of: proxy.size) { _, _ in hasFold = Book<EmptyView, EmptyView>.fold(in: proxy) != nil }
        }
    }
}
