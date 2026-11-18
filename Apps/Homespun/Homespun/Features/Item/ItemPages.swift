// SPDX-License-Identifier: Apache-2.0
import AVKit
import Photos
import PhotosUI
import SwiftUI
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

    /// Shows an item (or the same one again, current or not, with new words).
    func show(id: String, item: () -> (any LibraryItem)?, current: Bool, label: String, placeholder: UIImage?,
              images: ItemImages, onZoom: @escaping (Bool) -> Void) {
        if id != self.id {
            loading?.cancel()
            loading = nil
            loaded = nil
            self.id = id
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

/// A video page: its SwiftUI player in a hosting controller (the player needs one), reused for the
/// next video.
final class VideoPageCell: ItemPageCell {
    static let reuse = "video"

    struct Key: Equatable {
        var id: String
        var current: Bool
        var label: String
        var placeholder: Bool
    }

    var host: UIHostingController<ItemVideoPage>?
    var key: Key?
}

/// A video: its poster (the screen-size image) until it's the page shown, then the player, which
/// pauses when the page isn't shown any more.
struct ItemVideoPage: View {
    let item: (any LibraryItem)?
    let isCurrent: Bool
    let label: String
    /// The screen-size image, when the pager has it already.
    var placeholder: UIImage?
    var images: ItemImages?
    @State private var loaded = Media()

    private struct Media {
        var id: String?
        var image: UIImage?
        var player: AVPlayer?
    }

    private struct Load: Equatable {
        var id: String?
        var current: Bool
    }

    /// What's loaded, if it's for this item (the page may have just been given another).
    private var media: Media { loaded.id == item?.localIdentifier ? loaded : Media(id: item?.localIdentifier) }
    private var image: UIImage? { media.image ?? placeholder }

    var body: some View {
        Group {
            if let player = media.player {
                VideoPlayer(player: player)
                    .accessibilityLabel(label)
                    .accessibilityIdentifier("item.page")
            } else {
                Color.black.overlay {
                    if let image { Image(uiImage: image).resizable().scaledToFit() }
                }
                .accessibilityElement()
                .accessibilityLabel(label)
                .accessibilityValue(image == nil ? "Loading" : "")
                .accessibilityAddTraits(.isImage)
                .accessibilityIdentifier("item.page")
            }
        }
        .ignoresSafeArea()
        .task(id: Load(id: item?.localIdentifier, current: isCurrent)) { await load() }
        .onChange(of: isCurrent) { _, current in if !current { loaded.player?.pause() } }
        .onDisappear { loaded.player?.pause() }
    }

    private func load() async {
        guard let item else { return }
        let id = item.localIdentifier
        if loaded.id != id {
            loaded.player?.pause()
            loaded = Media(id: id)
        }
        if loaded.image == nil {
            var image = placeholder
            if image == nil { image = await images?.load(item) }
            guard loaded.id == id else { return }
            loaded.image = image
        }
        guard isCurrent, !Task.isCancelled, loaded.player == nil else { return }
        let player = await item.player()
        if loaded.id == id, !Task.isCancelled { loaded.player = player }
    }
}
