// SPDX-License-Identifier: Apache-2.0
import Photos
import SwiftUI
import UIKit

/// Free Up Space's review as one scrolling column, for the open iPhone Duo held wide: its words
/// (`head`), the compact copies as a grid in their card (`title` above them), then the rest
/// (`tail`). UIKit, so the grid reuses its cells (Free Up Space can offer thousands) and every
/// thumbnail is an exact square: nothing below the screen is laid out ahead with a guessed size.
struct FreeUpColumn<Head: View, Title: View, Tail: View>: UIViewRepresentable {
    let pairs: [FreeUpPair]
    let selected: FreeUpPair?
    let manager: PHCachingImageManager
    var compare: (FreeUpPair) -> Void
    @ViewBuilder var head: Head
    @ViewBuilder var title: Title
    @ViewBuilder var tail: Tail

    func makeCoordinator() -> FreeUpColumnSource { FreeUpColumnSource() }

    func makeUIView(context: Context) -> UICollectionView {
        let view = UICollectionView(frame: .zero, collectionViewLayout: FreeUpColumnLayout.make())
        view.backgroundColor = .clear
        view.alwaysBounceVertical = true
        view.accessibilityIdentifier = "remove.review"
        context.coordinator.attach(to: view, manager: manager, scale: context.environment.displayScale)
        update(view, context.coordinator)
        return view
    }

    func updateUIView(_ view: UICollectionView, context: Context) {
        update(view, context.coordinator)
    }

    private func update(_ view: UICollectionView, _ source: FreeUpColumnSource) {
        source.parts = [
            .head: UIHostingConfiguration { head }.margins(.all, 0),
            .title: UIHostingConfiguration { title }.margins(.all, 0),
            .tail: UIHostingConfiguration { tail }.margins(.all, 0),
        ]
        source.refresh()
        let pairs = pairs
        source.grid.update(items: pairs.map { ThumbnailRow.Item(id: $0.original, photo: $0.compact, marked: true, selected: $0 == selected) },
                           accessibility: (FreeUpThumbnails.label, FreeUpThumbnails.identifier)) { compare(pairs[$0]) }
    }

    static func dismantleUIView(_ view: UICollectionView, coordinator: FreeUpColumnSource) {
        coordinator.grid.loader?.stopPreheatingAll()
    }
}

/// What Free Up Space's compact copies say to VoiceOver and the UI tests, as a row or a grid.
enum FreeUpThumbnails {
    static let label = "Compare with the original"
    static let identifier = "remove.compare"
}

/// The column's sections: hosted SwiftUI for the words, the thumbnails' own cells for the grid.
@MainActor
final class FreeUpColumnSource: NSObject, UICollectionViewDataSource, UICollectionViewDelegate,
                                UICollectionViewDataSourcePrefetching {
    enum Part: Int, CaseIterable, Sendable {
        case head, title, grid, tail
    }

    let grid = ThumbnailCollection()
    var parts: [Part: any UIContentConfiguration] = [:]
    private weak var view: UICollectionView?
    private static let hosted = "hosted"

    override init() {
        super.init()
        grid.section = Part.grid.rawValue
    }

    func attach(to view: UICollectionView, manager: PHCachingImageManager, scale: CGFloat) {
        self.view = view
        view.register(UICollectionViewCell.self, forCellWithReuseIdentifier: Self.hosted)
        // About the largest side the column gives a thumbnail.
        grid.attach(to: view, manager: manager, side: 100, scale: scale, own: false)
        view.dataSource = self
        view.delegate = self
        view.prefetchDataSource = self
    }

    /// The words may have changed: the hosted cells on screen take them (and resize if they must).
    func refresh() {
        guard let view else { return }
        for path in view.indexPathsForVisibleItems {
            guard let part = Part(rawValue: path.section), part != .grid else { continue }
            view.cellForItem(at: path)?.contentConfiguration = parts[part]
        }
    }

    // MARK: Data source and delegate

    func numberOfSections(in collectionView: UICollectionView) -> Int { Part.allCases.count }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        Part(rawValue: section) == .grid ? grid.items.count : 1
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let part = Part(rawValue: indexPath.section) ?? .head
        if part == .grid { return grid.dequeue(collectionView, at: indexPath) }
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: Self.hosted, for: indexPath)
        cell.contentConfiguration = parts[part]
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        indexPath.section == Part.grid.rawValue
    }

    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        indexPath.section == Part.grid.rawValue
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        grid.collectionView(collectionView, didSelectItemAt: indexPath)
    }

    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        grid.collectionView(collectionView, prefetchItemsAt: indexPaths)
    }

    func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        grid.collectionView(collectionView, cancelPrefetchingForItemsAt: indexPaths)
    }
}

/// The column's layout: the words' cells size themselves; the grid is plain arithmetic.
enum FreeUpColumnLayout {
    /// The card around the grid (`card()`'s margin from the column, padding and corners), and the
    /// spacing between thumbnails.
    static let margin: CGFloat = 24
    static let padding: CGFloat = 16
    static let spacing: CGFloat = 6
    static let minimumSide: CGFloat = 72
    static let cardTop = "card.top"
    static let cardBottom = "card.bottom"

    /// As many columns of at least `minimumSide` as fit inside the card, every thumbnail square.
    static func columns(width: CGFloat) -> (count: Int, side: CGFloat) {
        let inside = max(minimumSide, width - 2 * (margin + padding))
        let count = max(1, Int((inside + spacing) / (minimumSide + spacing)))
        return (count, (inside - spacing * CGFloat(count - 1)) / CGFloat(count))
    }

    @MainActor static func make() -> UICollectionViewCompositionalLayout {
        let layout = UICollectionViewCompositionalLayout { section, environment in
            Self.section(FreeUpColumnSource.Part(rawValue: section) ?? .head, width: environment.container.effectiveContentSize.width)
        }
        layout.register(CardBackground.Top.self, forDecorationViewOfKind: cardTop)
        layout.register(CardBackground.Bottom.self, forDecorationViewOfKind: cardBottom)
        return layout
    }

    @MainActor static func section(_ part: FreeUpColumnSource.Part, width: CGFloat) -> NSCollectionLayoutSection {
        switch part {
        case .grid:
            let (count, side) = columns(width: width)
            let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(widthDimension: .absolute(side),
                                                                                 heightDimension: .absolute(side)))
            let group = NSCollectionLayoutGroup.horizontal(
                layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(side)),
                repeatingSubitem: item, count: count)
            group.interItemSpacing = .fixed(spacing)
            let grid = NSCollectionLayoutSection(group: group)
            grid.interGroupSpacing = spacing
            grid.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: margin + padding, bottom: padding, trailing: margin + padding)
            grid.decorationItems = [card(cardBottom)]
            return grid
        case .head:
            return single(estimate: 120, NSDirectionalEdgeInsets(top: margin, leading: margin, bottom: 20, trailing: margin))
        case .title:
            let title = single(estimate: 80, NSDirectionalEdgeInsets(top: 0, leading: margin, bottom: 0, trailing: margin))
            title.decorationItems = [card(cardTop)]
            return title
        case .tail:
            return single(estimate: 240, NSDirectionalEdgeInsets(top: 20, leading: margin, bottom: margin, trailing: margin))
        }
    }

    /// One full-width cell whose SwiftUI content sets its height.
    @MainActor private static func single(estimate: CGFloat, _ insets: NSDirectionalEdgeInsets) -> NSCollectionLayoutSection {
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(estimate))
        let section = NSCollectionLayoutSection(group: .vertical(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)]))
        section.contentInsets = insets
        return section
    }

    @MainActor private static func card(_ kind: String) -> NSCollectionLayoutDecorationItem {
        let card = NSCollectionLayoutDecorationItem.background(elementKind: kind)
        card.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: margin, bottom: 0, trailing: margin)
        return card
    }
}

/// The card behind the grid, in two parts (above the thumbnails, and around them) so its words can
/// size themselves: `Theme.card` with `card()`'s rounded corners.
class CardBackground: UICollectionReusableView {
    class var corners: CACornerMask { [] }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(Theme.card)
        layer.cornerRadius = 24
        layer.cornerCurve = .continuous
        layer.maskedCorners = Self.corners
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    final class Top: CardBackground {
        override class var corners: CACornerMask { [.layerMinXMinYCorner, .layerMaxXMinYCorner] }
    }

    final class Bottom: CardBackground {
        override class var corners: CACornerMask { [.layerMinXMaxYCorner, .layerMaxXMaxYCorner] }
    }
}
