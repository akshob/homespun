// SPDX-License-Identifier: Apache-2.0
import Photos
import PhotosUI
import UIKit

/// A page of the item viewer: exactly the layout's size, nothing to measure.
class ItemPageCell: UICollectionViewCell {
    override func preferredLayoutAttributesFitting(_ attributes: UICollectionViewLayoutAttributes)
        -> UICollectionViewLayoutAttributes { attributes }
}

/// A photo or Live Photo page, zoomable like Photos (pinch, double-tap), a Live Photo playing while
/// touched and held. The screen-size image shows at once when the pager has it; the page shown then
/// loads at full size. UIKit, so turning pages makes no SwiftUI views; reused for the next item.
final class PhotoPageCell: ItemPageCell {
    static let reuse = "photo"

    private let content = PhotoContent()
    private lazy var zoom = ZoomScrollView(content: content)
    private var id: String?
    private var item: (any LibraryItem)?
    private var current = false
    /// The full-size image or the Live Photo is in.
    private var sharp = false
    private var revision = 0
    private var loading: Task<Void, Never>?
    private var loaded: (id: String, current: Bool)?
    private weak var images: ItemImages?
    private var onZoom: (Bool) -> Void = { _ in }

    override init(frame: CGRect) {
        super.init(frame: frame)
        zoom.frame = contentView.bounds
        zoom.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        // Not during SwiftUI's update (showing an item can reset the zoom while the pager updates).
        zoom.onZoom = { [weak self] zoomed in Task { @MainActor in self?.onZoom(zoomed) } }
        contentView.addSubview(zoom)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func invalidate(_ id: String) {
        guard self.id == id else { return }
        loading?.cancel()
        loading = nil
        loaded = nil
        self.id = nil
        item = nil
        sharp = false
        content.image = nil
        content.livePhoto = nil
    }

    /// Shows an item (or the same one again, current or not, with new words).
    func show(id: String, item: () -> (any LibraryItem)?, current: Bool, label: String, placeholder: UIImage?,
              images: ItemImages, onZoom: @escaping (Bool) -> Void) {
        let revision = images.revision(id)
        if id != self.id || revision != self.revision {
            loading?.cancel()
            loading = nil
            loaded = nil
            self.id = id
            self.revision = revision
            self.item = item()
            sharp = false
            content.image = nil
            content.livePhoto = nil
            zoom.reset()
            zoom.aspect = CGSize(width: self.item?.pixelWidth ?? 0, height: self.item?.pixelHeight ?? 0)
        }
        self.images = images
        self.onZoom = onZoom
        if content.image == nil, let placeholder { show(placeholder) }
        if content.accessibilityLabel != label { content.accessibilityLabel = label }
        if current != self.current {
            self.current = current
            if !current { zoom.reset() }
        }
        load()
    }

    private func show(_ image: UIImage) {
        content.image = image
        if zoom.aspect.width == 0 { zoom.aspect = image.size }
        content.tellLoaded()
    }

    /// The screen-size image if it isn't in yet; the full-size one (or the Live Photo) on the page shown.
    private func load() {
        guard let id, let item, let images, loaded.map({ $0.id != id || $0.current != current }) ?? true else { return }
        loading?.cancel()
        loaded = (id, current)
        let current = current
        loading = Task { [weak self] in
            if self?.content.image == nil {
                let image = await images.load(item)
                guard let self, self.id == id, !Task.isCancelled else { return }
                if let image, self.content.image == nil { self.show(image) }
            }
            guard current, let self, !self.sharp, !Task.isCancelled else { return }
            let width = Double(item.pixelWidth), height = Double(item.pixelHeight)
            let scale = min(1, 4096 / max(width, height, 1))
            let full = CGSize(width: width * scale, height: height * scale)
            if item.itemKind == .livePhoto {
                let live = await item.livePhoto(size: full)
                guard self.id == id, !Task.isCancelled, let live else { return }
                self.content.livePhoto = live
                self.sharp = true
            } else if let sharper = await item.image(size: full, fast: false), self.id == id, !Task.isCancelled {
                self.show(sharper)
                self.sharp = true
            }
            self.content.tellLoaded()
        }
    }
}

/// A photo page's picture: the image, and over it the Live Photo once there is one (its view plays
/// while touched and held). One element for VoiceOver, "Loading" until there's a picture.
final class PhotoContent: UIView {
    private let imageView = UIImageView()
    /// Made for the first Live Photo shown (most pages never need one).
    private var liveView: PHLivePhotoView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        fill(imageView)
        isAccessibilityElement = true
        accessibilityTraits = .image
        accessibilityIdentifier = "item.page"
        tellLoaded()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var image: UIImage? {
        get { imageView.image }
        set { if newValue !== imageView.image { imageView.image = newValue } }
    }

    var livePhoto: PHLivePhoto? {
        get { liveView?.livePhoto }
        set {
            guard newValue !== liveView?.livePhoto else { return }
            if newValue != nil, liveView == nil {
                let view = PHLivePhotoView()
                fill(view)
                liveView = view
            }
            liveView?.livePhoto = newValue
            liveView?.isHidden = newValue == nil
        }
    }

    func tellLoaded() {
        accessibilityValue = image == nil && livePhoto == nil ? "Loading" : nil
    }

    private func fill(_ view: UIView) {
        view.frame = bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.contentMode = .scaleAspectFit
        addSubview(view)
    }
}

/// A video page has only a poster and a player layer. The viewer owns its one player and controls.
final class VideoPageCell: ItemPageCell {
    static let reuse = "video"
    private let poster = UIImageView()
    private let surface = PlayerSurface()
    private let glyph = UIVisualEffectView(effect: UIGlassEffect())
    private let spinner = UIActivityIndicatorView(style: .large)
    private let failure = UILabel()
    private var id: String?
    private var revision = 0
    private var item: (any LibraryItem)?
    private var current = false
    private weak var playback: VideoPlayback?
    private var loading: Task<Void, Never>?
    private var waiting: Task<Void, Never>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        for view in [poster, surface] {
            view.frame = contentView.bounds
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.isUserInteractionEnabled = false
            contentView.addSubview(view)
        }
        poster.contentMode = .scaleAspectFit
        surface.isHidden = true
        surface.onReady = { [weak self] ready in
            guard let self else { return }
            surface.isHidden = !ready || !current
            poster.isHidden = ready && current
        }
        let icon = UIImageView(image: UIImage(systemName: "play.fill",
                                              withConfiguration: UIImage.SymbolConfiguration(pointSize: 28, weight: .semibold)))
        icon.tintColor = .white
        icon.contentMode = .center
        icon.frame = CGRect(x: 0, y: 0, width: 72, height: 72)
        glyph.contentView.addSubview(icon)
        glyph.clipsToBounds = true
        glyph.layer.cornerRadius = 36
        glyph.isUserInteractionEnabled = false
        failure.font = .preferredFont(forTextStyle: .footnote)
        failure.adjustsFontForContentSizeCategory = true
        failure.textColor = .white
        failure.textAlignment = .center
        failure.numberOfLines = 0
        for view in [glyph, spinner, failure] { contentView.addSubview(view) }
        contentView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        isAccessibilityElement = true
        accessibilityIdentifier = "item.page"
        accessibilityTraits = [.image, .startsMediaSession]
        render()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        glyph.frame = CGRect(x: (contentView.bounds.width - 72) / 2, y: (contentView.bounds.height - 72) / 2,
                             width: 72, height: 72)
        spinner.center = CGPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
        let size = failure.sizeThatFits(CGSize(width: max(0, contentView.bounds.width - 48), height: .greatestFiniteMagnitude))
        failure.frame = CGRect(x: 24, y: (contentView.bounds.height - size.height) / 2,
                               width: max(0, contentView.bounds.width - 48), height: size.height)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        detach()
        loading?.cancel()
        loading = nil
        id = nil
        item = nil
        poster.image = nil
    }

    func endDisplaying() { detach() }

    func invalidate(_ id: String) {
        guard self.id == id else { return }
        prepareForReuse()
    }

    func show(id: String, item: () -> (any LibraryItem)?, current: Bool, label: String, placeholder: UIImage?,
              images: ItemImages, playback: VideoPlayback) {
        let revision = images.revision(id)
        if self.id != id || self.revision != revision {
            detach()
            loading?.cancel()
            loading = nil
            self.id = id
            self.revision = revision
            self.item = item()
            poster.image = nil
        }
        self.playback = playback
        accessibilityLabel = label
        if poster.image == nil { poster.image = placeholder }
        if poster.image == nil, loading == nil, let item = self.item {
            loading = Task { [weak self] in
                let image = await images.load(item)
                guard let self, self.id == id, !Task.isCancelled else { return }
                if poster.image == nil { poster.image = image }
            }
        }
        if !current {
            detach()
        } else {
            self.current = true
            surface.player = playback.player
            playback.stateOwner = self
            playback.stateChanged = { [weak self] in self?.render() }
            if let item = self.item {
                playback.load(item, id: id, autoplay: UIAccessibility.isVideoAutoplayEnabled)
            }
        }
        render()
    }

    private func detach() {
        current = false
        surface.player = nil
        surface.isHidden = true
        poster.isHidden = false
        waiting?.cancel()
        waiting = nil
        if let id, let playback, playback.stateOwner === self {
            playback.unload(id: id)
            playback.stateChanged = nil
            playback.stateOwner = nil
        }
    }

    private func render() {
        let status = current ? playback?.status ?? .idle : .idle
        glyph.isHidden = !(current && status == .ready && playback?.isPlaying == false)
        failure.isHidden = true
        if status != .loading {
            waiting?.cancel()
            waiting = nil
            spinner.stopAnimating()
        }
        switch status {
        case .idle: accessibilityValue = poster.image == nil ? "Loading" : nil
        case .loading:
            accessibilityValue = "Loading"
            if waiting == nil {
                waiting = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(500))
                    guard let self, !Task.isCancelled, current, playback?.status == .loading else { return }
                    spinner.startAnimating()
                }
            }
        case .ready: accessibilityValue = playback?.isPlaying == true ? "Playing" : "Paused"
        case .failed(let message):
            accessibilityValue = message
            failure.text = message
            failure.isHidden = false
            setNeedsLayout()
        }
    }

    @objc private func tapped() { if current { playback?.toggle() } }

    override func accessibilityActivate() -> Bool {
        guard current else { return false }
        playback?.toggle()
        return true
    }
}
