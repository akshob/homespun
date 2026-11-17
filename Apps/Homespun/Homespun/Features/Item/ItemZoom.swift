// SPDX-License-Identifier: Apache-2.0
import UIKit

/// Zooms one view like Photos: pinch, pan and double-tap, the content fitted and centred. At
/// its smallest it doesn't scroll, so a paging scroll view around it still swipes between items.
final class ZoomScrollView: UIScrollView, UIScrollViewDelegate {
    let content: UIView
    /// The content's size in any unit, for its aspect ratio.
    var aspect: CGSize = .zero {
        didSet { if Self.ratio(aspect) != Self.ratio(oldValue) { fit() } }
    }
    /// After every zoom or scroll (Compare keeps its split line where it is on screen).
    var onTransform: (() -> Void)?
    /// Whether it's zoomed in, when that changes.
    var onZoom: ((Bool) -> Void)?
    /// Touch and hold: true when it starts, false when the finger lifts.
    var onHold: ((Bool) -> Void)? {
        didSet { hold.isEnabled = onHold != nil }
    }
    private var fittedSize: CGSize = .zero
    private var wasZoomed = false
    private lazy var hold: UILongPressGestureRecognizer = {
        let gesture = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
        gesture.minimumPressDuration = 0.3
        gesture.cancelsTouchesInView = false
        gesture.isEnabled = false
        return gesture
    }()

    init(content: UIView) {
        self.content = content
        super.init(frame: .zero)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 5
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .fast
        alwaysBounceHorizontal = false
        alwaysBounceVertical = false
        addSubview(content)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
        addGestureRecognizer(hold)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var isZoomed: Bool { zoomScale > minimumZoomScale * 1.01 }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != fittedSize { fit() }
    }

    /// Back to the whole item, fitted.
    func reset(animated: Bool = false) {
        guard isZoomed else { return }
        setZoomScale(minimumZoomScale, animated: animated)
    }

    private func fit() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        fittedSize = bounds.size
        zoomScale = minimumZoomScale
        let size = Self.fitted(aspect, in: bounds.size)
        content.frame = CGRect(origin: .zero, size: size)
        contentSize = size
        centre()
        contentOffset = CGPoint(x: -contentInset.left, y: -contentInset.top)
        onTransform?()
    }

    /// `aspect` scaled to fit inside `container` (all of it when the aspect is unknown).
    static func fitted(_ aspect: CGSize, in container: CGSize) -> CGSize {
        guard aspect.width > 0, aspect.height > 0 else { return container }
        let scale = min(container.width / aspect.width, container.height / aspect.height)
        return CGSize(width: aspect.width * scale, height: aspect.height * scale)
    }

    /// Width over height to three places, so the same photo at another size doesn't refit.
    private static func ratio(_ size: CGSize) -> Int {
        size.width > 0 && size.height > 0 ? Int((size.width / size.height * 1000).rounded()) : 0
    }

    private func centre() {
        let x = max(0, (bounds.width - contentSize.width) / 2), y = max(0, (bounds.height - contentSize.height) / 2)
        let insets = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
        if contentInset != insets { contentInset = insets }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { content }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centre()
        onTransform?()
        if isZoomed != wasZoomed {
            wasZoomed = isZoomed
            onZoom?(wasZoomed)
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) { onTransform?() }

    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        if isZoomed { return setZoomScale(minimumZoomScale, animated: !UIAccessibility.isReduceMotionEnabled) }
        let point = gesture.location(in: content)
        let scale = min(maximumZoomScale, 2.5)
        let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
        zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height),
             animated: !UIAccessibility.isReduceMotionEnabled)
    }

    @objc private func held(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began: onHold?(true)
        case .ended, .cancelled, .failed: onHold?(false)
        default: break
        }
    }
}
