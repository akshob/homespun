// SPDX-License-Identifier: Apache-2.0
import SwiftUI
import UIKit

/// One photo in the Library grid: its thumbnail, badge, selection, and a video's length or the Live
/// Photo mark. Plain views and pre-drawn images, so a row costs little to show at 120 Hz.
final class GridCell: UICollectionViewCell {
    static let reuse = "cell"

    private let imageView = UIImageView()
    private let dim = UIView()
    private let badgeView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let markLabel = UILabel()
    private let liveView = UIImageView()
    private let selectView = UIImageView()

    /// The item shown, and its thumbnail request (cancelled when the cell shows another item).
    private(set) var item: String?
    private var request: GridThumbnails.Request?
    /// The picture shown is the sharp one (not Photos' quick first one).
    private var sharp = false
    private var revision = 0
    private weak var loader: GridThumbnails?
    private var pixels: CGFloat = 0
    private var info: MediaInfo?
    private var state: LibraryState.Cell?
    private var serverName = ""

    /// Whether the cell has a picture yet (the performance tests count cells shown without one).
    var hasImage: Bool { imageView.image != nil }
    var image: UIImage? { imageView.image }

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = GridStyle.fill
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        dim.backgroundColor = UIColor.white.withAlphaComponent(0.2)
        dim.isHidden = true
        spinner.color = GridStyle.accent
        spinner.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
        spinner.hidesWhenStopped = true
        markLabel.numberOfLines = 1
        for view in [imageView, dim, markLabel, liveView, badgeView, spinner, selectView] as [UIView] {
            view.isUserInteractionEnabled = false
            contentView.addSubview(view)
        }
        isAccessibilityElement = true
        accessibilityIdentifier = "asset"
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: GridCell, _) in self.updateMarks() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Shows an item: its picture (asked for if it's another item or another size), then its state.
    func show(_ item: String, info: MediaInfo?, loader: GridThumbnails, pixels: CGFloat, keepImage: Bool = false) {
        self.info = info
        let revision = loader.revision(item)
        if item != self.item || pixels != self.pixels || revision != self.revision || request == nil && !sharp {
            if item != self.item, !keepImage {
                // Another item's picture never stays on: blank until this one's arrives (a new size
                // keeps the old picture meanwhile).
                let cached = loader.cached(item, pixels: pixels)
                if imageView.image != nil, cached == nil { RenderProbe.count("grid.imageClears") }
                imageView.image = cached
            }
            cancelRequest()
            self.item = item
            self.pixels = pixels
            self.revision = revision
            self.loader = loader
            sharp = false
            request = loader.request(item, pixels: pixels) { [weak self] image, final in
                guard let self, self.item == item else { return }
                self.imageView.image = image
                if final {
                    self.request = nil
                    self.sharp = true
                }
            }
        }
        updateMarks()
    }

    /// The badge, selection and VoiceOver's words, from the item's current state.
    func update(state: LibraryState.Cell, selecting: Bool, selected: Bool, serverName: String) {
        let badgeChanged = self.state?.badge != state.badge && self.state?.id == state.id
        self.state = state
        self.serverName = serverName
        let size: CGFloat = traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? 28 : 20
        let image = state.badge == .working ? GridStyle.halo(size: size) : GridStyle.badge(state.badge, size: size)
        if badgeChanged, badgeView.image != nil || image != nil {
            UIView.transition(with: badgeView, duration: 0.2, options: .transitionCrossDissolve) { self.badgeView.image = image }
        } else if badgeView.image !== image {
            badgeView.image = image
        }
        if state.badge == .working { spinner.startAnimating() } else { spinner.stopAnimating() }
        updateSelection(selecting: selecting, selected: selected)
        setNeedsLayout()
    }

    func updateSelection(selecting: Bool, selected: Bool) {
        RenderProbe.count("grid.selections")
        dim.isHidden = !selected
        let selectable = state.map { $0.canCompact || $0.canFree || $0.canRestore } ?? false
        let mark = selecting ? (selected ? GridStyle.checkmark(traitCollection) : selectable ? GridStyle.circle : nil) : nil
        if selectView.image !== mark { selectView.image = mark }
        selectView.isHidden = mark == nil
        accessibilityTraits = selected ? [.button, .selected] : .button
        setNeedsLayout()
    }

    private func updateMarks() {
        switch info?.kind {
        case .video?:
            markLabel.attributedText = GridStyle.duration(Int(info?.seconds ?? 0), traits: traitCollection)
            markLabel.isHidden = false
            liveView.isHidden = true
        case .livePhoto?:
            liveView.image = GridStyle.live(traitCollection)
            liveView.isHidden = false
            markLabel.isHidden = true
        default:
            markLabel.isHidden = true
            liveView.isHidden = true
        }
        setNeedsLayout()
    }

    override var accessibilityLabel: String? {
        get { GridCell.name(info) }
        set {}
    }

    override var accessibilityValue: String? {
        get { state.map { $0.badge.spoken(server: serverName, compactAfter: $0.compactAfter) } }
        set {}
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let bounds = contentView.bounds
        imageView.frame = bounds
        dim.frame = bounds
        let size: CGFloat = traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? 28 : 20
        if let image = badgeView.image {
            // The badge's own square, 6 pt from the corner; the picture has room for its halo and shadow.
            let side = image.size.width
            badgeView.frame = CGRect(x: bounds.maxX - 6 - size - (side - size) / 2, y: 6 - (side - size) / 2, width: side, height: side)
        }
        spinner.center = CGPoint(x: bounds.maxX - 6 - size / 2, y: 6 + size / 2)
        if !markLabel.isHidden {
            let fitted = markLabel.sizeThatFits(bounds.size)
            markLabel.frame = CGRect(x: 4, y: bounds.maxY - 4 - fitted.height, width: min(fitted.width, bounds.width - 8),
                                     height: fitted.height)
        }
        if let image = liveView.image, !liveView.isHidden {
            liveView.frame = CGRect(x: 4 - GridStyle.shadowMargin, y: bounds.maxY - 4 - image.size.height + GridStyle.shadowMargin,
                                    width: image.size.width, height: image.size.height)
        }
        if let image = selectView.image {
            selectView.frame = CGRect(x: bounds.maxX - 6 - image.size.width + GridStyle.shadowMargin,
                                      y: bounds.maxY - 6 - image.size.height + GridStyle.shadowMargin,
                                      width: image.size.width, height: image.size.height)
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        // The picture stays until the next item is shown (it's cleared there if the item differs).
        cancelRequest()
        spinner.stopAnimating()
    }

    private func cancelRequest() {
        if let request { loader?.cancel(request) }
        request = nil
    }

    func invalidateImage() {
        cancelRequest()
        sharp = false
    }

    private static let dateStyle = Date.FormatStyle(date: .abbreviated, time: .shortened)

    /// VoiceOver's name for an item: its kind and when it was taken.
    static func name(_ info: MediaInfo?) -> String {
        guard let info else { return "Item" }
        let kind = switch info.kind {
        case .video: "Video"
        case .livePhoto: "Live Photo"
        case .photo: "Photo"
        }
        guard let date = info.created else { return kind }
        return "\(kind), \(dateStyle.format(date))"
    }
}

/// A month's header: its name, how many aren't backed up, and in Select mode its own Select All.
final class MonthHeaderView: UICollectionReusableView {
    static let reuse = "month"

    private let title = UILabel()
    private let count = UILabel()
    private let button = UIButton(configuration: .plain())
    private var action: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        title.font = MonthHeaderView.titleFont(traitCollection)
        title.adjustsFontForContentSizeCategory = true
        title.textColor = .label
        title.accessibilityTraits = [.staticText, .header]
        count.font = MonthHeaderView.countFont(traitCollection)
        count.adjustsFontForContentSizeCategory = true
        count.textColor = GridStyle.secondaryLabel
        title.lineBreakMode = .byTruncatingTail
        // The largest text sizes shrink a long month name rather than cut it.
        title.adjustsFontSizeToFitWidth = true
        title.minimumScaleFactor = 0.5
        count.lineBreakMode = .byTruncatingTail
        button.configuration?.contentInsets = .zero
        button.configuration?.titleLineBreakMode = .byTruncatingTail
        button.tintColor = GridStyle.accent
        button.addAction(UIAction { [weak self] _ in self?.action?() }, for: .primaryActionTriggered)
        for view in [title, count, button] as [UIView] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static func titleFont(_ traits: UITraitCollection) -> UIFont { .preferredFont(forTextStyle: .headline, compatibleWith: traits) }
    static func countFont(_ traits: UITraitCollection) -> UIFont { .preferredFont(forTextStyle: .subheadline, compatibleWith: traits) }

    static func buttonFont(_ traits: UITraitCollection) -> UIFont {
        let base = UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: traits)
        return UIFont(descriptor: base.fontDescriptor.withSymbolicTraits(.traitBold) ?? base.fontDescriptor, size: base.pointSize)
    }

    private static var stackedCache: [String: Bool] = [:]

    /// Whether the count goes under the name: when the longest header wouldn't fit on one line.
    static func stacked(width: CGFloat, traits: UITraitCollection) -> Bool {
        let key = "\(width) \(traits.preferredContentSizeCategory.rawValue)"
        if let known = stackedCache[key] { return known }
        let longest = ("September 0000" as NSString).size(withAttributes: [.font: titleFont(traits)]).width
            + ("0,000 not backed up" as NSString).size(withAttributes: [.font: countFont(traits)]).width
            + ("Select All" as NSString).size(withAttributes: [.font: buttonFont(traits)]).width
        let stacked = longest + 24 + 16 > width
        stackedCache[key] = stacked
        return stacked
    }

    private static var heights: [String: CGFloat] = [:]

    /// Every header's height, from the text size: the space above and below, and one or two lines.
    static func height(width: CGFloat, traits: UITraitCollection) -> CGFloat {
        let key = "\(width) \(traits.preferredContentSizeCategory.rawValue)"
        if let known = heights[key] { return known }
        let second = max(countFont(traits).lineHeight, buttonFont(traits).lineHeight)
        let lines = titleFont(traits).lineHeight + (stacked(width: width, traits: traits) ? 2 + second : 0)
        let height = (14 + lines + 6).rounded(.up)
        heights[key] = height
        return height
    }

    struct Content {
        var title: String
        /// "12 not backed up", or nil.
        var count: String?
        /// "Select All" or "Deselect" in Select mode when the month has anything to select.
        var button: String?
        var action: () -> Void
    }

    func show(_ content: Content) {
        if title.text != content.title { title.text = content.title }
        count.text = content.count
        count.isHidden = content.count == nil
        if let label = content.button {
            if button.configuration?.title != label {
                var configuration = button.configuration ?? .plain()
                configuration.attributedTitle = AttributedString(label, attributes: AttributeContainer([.font: Self.buttonFont(traitCollection)]))
                configuration.title = label
                button.configuration = configuration
            }
            button.isHidden = false
        } else {
            button.isHidden = true
        }
        action = content.action
        setNeedsLayout()
    }

    /// One line: the name, the count on its baseline, the button at the end. When that doesn't fit
    /// (large text), the name on its own line and the count and the button under it.
    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width, inner = max(0, width - 24)
        let stacked = Self.stacked(width: width, traits: traitCollection)
        let titleFont = Self.titleFont(traitCollection), countFont = Self.countFont(traitCollection)
        let buttonFont = Self.buttonFont(traitCollection)
        // The baseline the count and the button sit on: the name's, or the second line's.
        let second = max(countFont.lineHeight, buttonFont.lineHeight)
        let baseline = stacked ? 14 + titleFont.lineHeight + 2 + (second - countFont.lineHeight) / 2 + countFont.ascender
            : 14 + titleFont.ascender
        var right = width - 12
        if !button.isHidden {
            // Under the name, the button may take what the count leaves.
            let widest = stacked ? (count.isHidden ? inner : inner * 0.6) : inner / 2
            let size = button.sizeThatFits(CGSize(width: widest, height: 200))
            let fitted = CGSize(width: min(size.width, widest), height: size.height)
            button.frame = CGRect(x: right - fitted.width, y: baseline - buttonFont.ascender - (fitted.height - buttonFont.lineHeight) / 2,
                                  width: fitted.width, height: fitted.height)
            right -= fitted.width + 8
        }
        let titleRight = stacked ? width - 12 : right
        let titleWidth = min(title.sizeThatFits(CGSize(width: inner, height: 200)).width, titleRight - 12)
        title.frame = CGRect(x: 12, y: 14, width: max(0, titleWidth), height: titleFont.lineHeight)
        guard !count.isHidden else { return }
        let x = stacked ? 12 : title.frame.maxX + 8
        count.frame = CGRect(x: x, y: baseline - countFont.ascender, width: max(0, right - x), height: countFont.lineHeight)
    }
}

/// The grid's colours, fonts and the small pictures every cell shares (drawn once per size).
@MainActor
enum GridStyle {
    static let fill = UIColor(Theme.fill)
    static let accent = UIColor(Theme.accent)
    static let secondaryLabel = UIColor(Theme.secondaryLabel)
    static let background = UIColor(Theme.background)
    /// Room for a mark's shadow around its picture.
    static let shadowMargin: CGFloat = 4

    private static var badges: [String: UIImage] = [:]

    private static func cached(_ key: String, _ draw: () -> UIImage?) -> UIImage? {
        if let image = badges[key] { return image }
        let image = draw()
        badges[key] = image
        return image
    }

    /// A badge on a white halo with a soft shadow (`BadgeView`'s look), `size` points square plus room for the halo.
    static func badge(_ badge: Badge, size: CGFloat) -> UIImage? {
        guard let symbol = badge.symbol else { return nil }
        return cached("badge.\(symbol).\(size)") {
            let color = UIColor(badge.color)
            let configuration = UIImage.SymbolConfiguration(pointSize: size * 0.8, weight: .semibold)
                .applying(UIImage.SymbolConfiguration(paletteColors: [color, color.withAlphaComponent(0.25)]))
            guard let glyph = UIImage(systemName: symbol, withConfiguration: configuration) else { return nil }
            return draw(side: size) { square in
                UIColor.white.setFill()
                UIBezierPath(ovalIn: square.insetBy(dx: -1.5, dy: -1.5)).fill()
                glyph.draw(in: CGRect(x: square.midX - glyph.size.width / 2, y: square.midY - glyph.size.height / 2,
                                      width: glyph.size.width, height: glyph.size.height))
            }
        }
    }

    /// The white circle behind the backing-up spinner.
    static func halo(size: CGFloat) -> UIImage? {
        cached("halo.\(size)") {
            draw(side: size) { square in
                UIColor.white.setFill()
                UIBezierPath(ovalIn: square).fill()
            }
        }
    }

    /// Select mode's mark on a selected item: a filled checkmark on white.
    static func checkmark(_ traits: UITraitCollection) -> UIImage? {
        let font = UIFont.preferredFont(forTextStyle: .title3, compatibleWith: traits)
        return cached("check.\(font.pointSize)") {
            let configuration = UIImage.SymbolConfiguration(font: font)
                .applying(UIImage.SymbolConfiguration(paletteColors: [.white, UIColor(Theme.BadgeColor.accent)]))
            guard let glyph = UIImage(systemName: "checkmark.circle.fill", withConfiguration: configuration) else { return nil }
            let side = max(glyph.size.width, glyph.size.height)
            return draw(side: side, shadow: false) { square in
                UIColor.white.setFill()
                UIBezierPath(ovalIn: square.insetBy(dx: 2, dy: 2)).fill()
                glyph.draw(in: CGRect(x: square.midX - glyph.size.width / 2, y: square.midY - glyph.size.height / 2,
                                      width: glyph.size.width, height: glyph.size.height))
            }
        }
    }

    /// Select mode's mark on an item that can be selected: a white ring.
    static var circle: UIImage? {
        cached("circle") {
            draw(side: 22, blur: 2, opacity: 0.33) { square in
                UIColor.white.setStroke()
                let path = UIBezierPath(ovalIn: square.insetBy(dx: 0.75, dy: 0.75))
                path.lineWidth = 1.5
                path.stroke()
            }
        }
    }

    /// The Live Photo mark.
    static func live(_ traits: UITraitCollection) -> UIImage? {
        let font = UIFont.preferredFont(forTextStyle: .caption2, compatibleWith: traits)
        return cached("live.\(font.pointSize)") {
            let configuration = UIImage.SymbolConfiguration(font: font)
            guard let glyph = UIImage(systemName: "livephoto", withConfiguration: configuration)?
                .withTintColor(.white, renderingMode: .alwaysOriginal) else { return nil }
            return draw(size: glyph.size, blur: 4, opacity: 0.33) { square in glyph.draw(in: square) }
        }
    }

    nonisolated(unsafe) private static let durationStyle = Duration.TimeFormatStyle(pattern: .minuteSecond)
    private static var durations: [Int: String] = [:]

    /// A video's length in white with a soft shadow, drawn with the text (no separate shadow pass).
    static func duration(_ seconds: Int, traits: UITraitCollection) -> NSAttributedString {
        let text: String
        if let known = durations[seconds] {
            text = known
        } else {
            text = Duration.seconds(Int64(seconds)).formatted(durationStyle)
            durations[seconds] = text
        }
        let base = UIFont.preferredFont(forTextStyle: .caption2, compatibleWith: traits)
        let font = UIFont.systemFont(ofSize: base.pointSize, weight: .semibold)
        let shadow = NSShadow()
        shadow.shadowColor = UIColor.black.withAlphaComponent(0.33)
        shadow.shadowBlurRadius = 4
        shadow.shadowOffset = .zero
        return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: UIColor.white, .shadow: shadow])
    }

    private static func draw(side: CGFloat, shadow: Bool = true, blur: CGFloat = 2, opacity: CGFloat = 0.25,
                             _ body: (CGRect) -> Void) -> UIImage {
        draw(size: CGSize(width: side, height: side), shadow: shadow, blur: blur, opacity: opacity, body)
    }

    /// A picture of `size` with `shadowMargin` around it for the shadow; `body` draws in the inner square.
    private static func draw(size: CGSize, shadow: Bool = true, blur: CGFloat = 2, opacity: CGFloat = 0.25,
                             _ body: (CGRect) -> Void) -> UIImage {
        let margin = shadowMargin
        let format = UIGraphicsImageRendererFormat.preferred()
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size.width + margin * 2, height: size.height + margin * 2),
                                               format: format)
        return renderer.image { context in
            let cg = context.cgContext
            if shadow { cg.setShadow(offset: .zero, blur: blur, color: UIColor.black.withAlphaComponent(opacity).cgColor) }
            cg.beginTransparencyLayer(auxiliaryInfo: nil)
            body(CGRect(x: margin, y: margin, width: size.width, height: size.height))
            cg.endTransparencyLayer()
        }
    }
}
