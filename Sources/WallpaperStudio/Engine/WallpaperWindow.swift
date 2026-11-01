import AppKit
import StudioCore

/// Where a window's content layer sits.
enum ContentPlacement: Equatable {
    /// Cover the display, optionally rotated.
    case cover(Rotation)
    /// One big picture spanning every display; `union` is the whole desktop in global coordinates.
    case span(union: CGRect)
}

/// One borderless window per display, sitting at the documented desktop window level.
///
/// macOS behaviour worth knowing:
/// * `desktopWindow` level is above the system wallpaper but below Finder's desktop icons, so icons stay clickable.
/// * `ignoresMouseEvents` lets every click fall through to Finder.
/// * `.canJoinAllSpaces + .stationary` keep it on every Space and out of Mission Control's window picker.
final class WallpaperWindow: NSWindow {
    let displayID: UInt32
    private let host = CALayer()
    private(set) var contentLayer: CALayer?
    private(set) var embeddedView: NSView?
    var hasContent: Bool { contentLayer != nil || embeddedView != nil }
    private(set) var placement: ContentPlacement = .cover(.r0)

    /// `frame` is in global desktop coordinates (what `NSScreen.frame` reports).
    init(displayID: UInt32, frame: CGRect) {
        self.displayID = displayID
        super.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        applyDesktopLevel()
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false

        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        host.frame = view.bounds
        host.backgroundColor = NSColor.black.cgColor
        host.masksToBounds = true            // span mode draws a layer larger than the window; clip to this display
        host.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer = CALayer()
        view.layer?.addSublayer(host)
        contentView = view
        setFrame(frame, display: true)
    }

    func applyDesktopLevel() {
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
    }

    /// Follows a resolution or arrangement change without recreating the window.
    func realign(to newFrame: CGRect) {
        if frame != newFrame { setFrame(newFrame, display: true) }
        host.frame = CGRect(origin: .zero, size: newFrame.size)
        layoutContent()
    }

    func setPlacement(_ newPlacement: ContentPlacement) {
        placement = newPlacement
        layoutContent()
    }

    /// Shows a view (a web page) instead of a layer. Rotation and span placement do not apply to embedded views.
    func setEmbeddedView(_ view: NSView?) {
        embeddedView?.removeFromSuperview()
        embeddedView = view
        if let view, let root = contentView {
            view.frame = root.bounds
            view.autoresizingMask = [.width, .height]
            root.addSubview(view)
        }
    }

    /// Replaces the displayed layer, optionally with a short cross-fade.
    func setContent(_ layer: CALayer?, animated: Bool) {
        if animated {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.6
            host.add(fade, forKey: "swap")
        }
        contentLayer?.removeFromSuperlayer()
        contentLayer = layer
        if let layer {
            host.addSublayer(layer)
            layoutContent()
        }
    }

    /// Sizes, positions and rotates the content layer for the current placement (no implicit animation).
    func layoutContent() {
        guard let layer = contentLayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch placement {
        case .cover(let rotation):
            let g = RotationGeometry.layerGeometry(screen: host.bounds.size, rotation: rotation)
            layer.bounds = CGRect(origin: .zero, size: g.size)
            layer.position = CGPoint(x: host.bounds.midX, y: host.bounds.midY)
            layer.transform = CATransform3DMakeRotation(g.angle, 0, 0, 1)
        case .span(let union):
            let f = SpanLayout.contentFrame(union: union, screen: frame)
            layer.bounds = CGRect(origin: .zero, size: f.size)
            layer.position = CGPoint(x: f.midX, y: f.midY)
            layer.transform = CATransform3DIdentity
        }
        CATransaction.commit()
    }
}
