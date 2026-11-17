// SPDX-License-Identifier: Apache-2.0
import Photos
import SwiftUI
import UIKit

/// One square thumbnail in a UIKit collection view, with rounded corners: optionally Free Up Space's
/// compare mark and its outline while it's the one compared. When it can be tapped, it's one button
/// for VoiceOver (its label and identifier from `accessibility`).
final class ThumbnailCell: UICollectionViewCell {
    static let reuse = "thumbnail"

    private let imageView = UIImageView()
    private let mark = UIImageView()
    private let ring = UIView()
    /// The element VoiceOver and the UI tests see: a button over the whole cell.
    private let element = UIView()
    private var request: PHImageRequestID?
    private weak var loader: ThumbnailLoader?
    private(set) var identifier: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = UIColor(Theme.fill)
        contentView.layer.cornerRadius = 8
        contentView.layer.cornerCurve = .continuous
        contentView.clipsToBounds = true
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        mark.image = UIImage(systemName: "rectangle.split.2x1.fill",
                             withConfiguration: UIImage.SymbolConfiguration(textStyle: .caption1))
        mark.tintColor = .white
        mark.layer.shadowColor = UIColor.black.cgColor
        mark.layer.shadowOpacity = 0.5
        mark.layer.shadowRadius = 2
        mark.layer.shadowOffset = .zero
        mark.isHidden = true
        ring.layer.cornerRadius = 8
        ring.layer.cornerCurve = .continuous
        ring.layer.borderWidth = 3
        ring.isHidden = true
        element.isUserInteractionEnabled = false
        element.isAccessibilityElement = false
        for view in [imageView, ring, element] {
            view.frame = contentView.bounds
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            contentView.addSubview(view)
        }
        contentView.addSubview(mark)
        isAccessibilityElement = false
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) { (cell: ThumbnailCell, _) in
            cell.recolour()
        }
        recolour()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = mark.intrinsicContentSize
        mark.frame = CGRect(x: contentView.bounds.maxX - size.width - 5, y: contentView.bounds.maxY - size.height - 5,
                            width: size.width, height: size.height)
    }

    /// The outline is a layer's colour, which doesn't follow light and dark by itself.
    private func recolour() {
        ring.layer.borderColor = UIColor(Theme.accent).resolvedColor(with: traitCollection).cgColor
    }

    /// Shows an item's thumbnail (loading it unless it's the one already shown).
    func show(_ identifier: String, loader: ThumbnailLoader) {
        guard identifier != self.identifier || loader !== self.loader else { return }
        if let request { self.loader?.cancel(request) }
        self.identifier = identifier
        self.loader = loader
        imageView.image = nil
        request = loader.request(identifier) { [weak self] image in
            guard let self, self.identifier == identifier else { return }
            self.imageView.image = image
        }
    }

    /// Free Up Space's compare mark, and the outline of the one compared.
    func decorate(marked: Bool, selected: Bool) {
        mark.isHidden = !marked
        ring.isHidden = !selected
    }

    /// A button for VoiceOver (nil: hidden, like the picture it is).
    func accessibility(label: String?, identifier: String?, selected: Bool) {
        element.isAccessibilityElement = label != nil
        element.accessibilityLabel = label
        element.accessibilityIdentifier = identifier
        element.accessibilityTraits = selected ? [.button, .selected] : .button
    }
}

/// A row of small square thumbnails that scrolls sideways: UIKit, one reused cell per item on screen,
/// so a row of thousands costs no more than a screenful (Needs Attention groups can be that big).
struct ThumbnailRow: UIViewRepresentable {
    struct Item: Hashable {
        /// Unique in the row.
        var id: String
        /// The Photos item shown.
        var photo: String
        var marked = false
        var selected = false
    }

    let items: [Item]
    let manager: PHCachingImageManager
    var side: CGFloat = 56
    var spacing: CGFloat = 6
    /// Each item's VoiceOver label and identifier when it can be tapped; nil hides the row from VoiceOver.
    var accessibility: (label: String, identifier: String)?
    var tap: (Int) -> Void = { _ in }

    func makeCoordinator() -> ThumbnailCollection { ThumbnailCollection() }

    func makeUIView(context: Context) -> UICollectionView {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = CGSize(width: side, height: side)
        layout.minimumLineSpacing = spacing
        layout.minimumInteritemSpacing = spacing
        layout.sectionInset = .zero
        let view = UICollectionView(frame: .zero, collectionViewLayout: layout)
        view.backgroundColor = .clear
        view.showsHorizontalScrollIndicator = false
        view.alwaysBounceVertical = false
        view.contentInsetAdjustmentBehavior = .never
        view.accessibilityElementsHidden = accessibility == nil
        context.coordinator.attach(to: view, manager: manager, side: side, scale: context.environment.displayScale)
        context.coordinator.update(items: items, accessibility: accessibility, tap: tap)
        return view
    }

    func updateUIView(_ view: UICollectionView, context: Context) {
        if let layout = view.collectionViewLayout as? UICollectionViewFlowLayout,
           layout.itemSize.width != side || layout.minimumLineSpacing != spacing {
            layout.itemSize = CGSize(width: side, height: side)
            layout.minimumLineSpacing = spacing
        }
        context.coordinator.resize(side: side, scale: context.environment.displayScale)
        view.accessibilityElementsHidden = accessibility == nil
        context.coordinator.update(items: items, accessibility: accessibility, tap: tap)
    }

    static func dismantleUIView(_ view: UICollectionView, coordinator: ThumbnailCollection) {
        coordinator.loader?.stopPreheatingAll()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UICollectionView, context: Context) -> CGSize? {
        let content = CGFloat(items.count) * side + CGFloat(max(items.count - 1, 0)) * spacing
        return CGSize(width: proposal.width ?? content, height: side)
    }
}

/// The data source behind a collection of thumbnails (a row, or the cells of a grid among other content).
@MainActor
final class ThumbnailCollection: NSObject, UICollectionViewDataSource, UICollectionViewDelegate,
                                 UICollectionViewDataSourcePrefetching {
    private(set) var items: [ThumbnailRow.Item] = []
    private(set) var loader: ThumbnailLoader?
    private var accessibility: (label: String, identifier: String)?
    private var tap: (Int) -> Void = { _ in }
    private weak var view: UICollectionView?
    /// The section the thumbnails are in (a grid among other sections).
    var section = 0

    /// `own`: this is the view's data source (a row); otherwise the view's own forwards the section.
    func attach(to view: UICollectionView, manager: PHCachingImageManager, side: CGFloat, scale: CGFloat, own: Bool = true) {
        self.view = view
        loader = ThumbnailLoader(manager: manager, side: side, scale: scale)
        view.register(ThumbnailCell.self, forCellWithReuseIdentifier: ThumbnailCell.reuse)
        guard own else { return }
        view.dataSource = self
        view.delegate = self
        view.prefetchDataSource = self
    }

    /// Another size or screen scale: thumbnails load again at the new size.
    func resize(side: CGFloat, scale: CGFloat) {
        guard let old = loader, old.pixels != ThumbnailLoader.pixels(side: side, scale: scale) else { return }
        old.stopPreheatingAll()
        loader = ThumbnailLoader(manager: old.manager, side: side, scale: scale)
        view?.reloadData()
    }

    /// New items reload; the same ones (another selected) only redraw what's on screen.
    func update(items new: [ThumbnailRow.Item], accessibility: (label: String, identifier: String)?, tap: @escaping (Int) -> Void) {
        self.accessibility = accessibility
        self.tap = tap
        guard new != items else { return }
        let same = new.count == items.count && zip(new, items).allSatisfy { $0.id == $1.id && $0.photo == $1.photo }
        items = new
        guard let view else { return }
        if same {
            for path in view.indexPathsForVisibleItems where path.section == section {
                if let cell = view.cellForItem(at: path) as? ThumbnailCell { configure(cell, at: path.item) }
            }
        } else if view.numberOfSections == 1 {
            view.reloadData()
        } else {
            view.reloadSections(IndexSet(integer: section))
        }
    }

    func configure(_ cell: ThumbnailCell, at item: Int) {
        guard items.indices.contains(item), let loader else { return }
        let thumbnail = items[item]
        cell.show(thumbnail.photo, loader: loader)
        cell.decorate(marked: thumbnail.marked, selected: thumbnail.selected)
        cell.accessibility(label: accessibility?.label, identifier: accessibility?.identifier, selected: thumbnail.selected)
    }

    func dequeue(_ view: UICollectionView, at indexPath: IndexPath) -> UICollectionViewCell {
        let cell = view.dequeueReusableCell(withReuseIdentifier: ThumbnailCell.reuse, for: indexPath)
        if let cell = cell as? ThumbnailCell { configure(cell, at: indexPath.item) }
        return cell
    }

    // MARK: Data source and delegate

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { items.count }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        dequeue(collectionView, at: indexPath)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        if items.indices.contains(indexPath.item) { tap(indexPath.item) }
    }

    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        loader?.preheat(photos(indexPaths))
    }

    func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        loader?.stopPreheating(photos(indexPaths))
    }

    func photos(_ indexPaths: [IndexPath]) -> [String] {
        indexPaths.compactMap { path in
            path.section == section && items.indices.contains(path.item) ? items[path.item].photo : nil
        }
    }
}

/// A row of small thumbnails, for what a sheet or a group of items is about to act on. Hidden from
/// VoiceOver, which reads the words beside it.
struct ThumbnailStrip: View {
    let identifiers: [String]
    let manager: PHCachingImageManager

    var body: some View {
        ThumbnailRow(items: identifiers.map { ThumbnailRow.Item(id: $0, photo: $0) }, manager: manager)
            .accessibilityHidden(true)
    }
}
