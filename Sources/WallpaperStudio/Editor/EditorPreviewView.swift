import AppKit
import SwiftUI
import StudioCore
import StudioRender

/// The editor's live preview: a Metal view that renders the scene being edited, with the mouse over it acting as the
/// pointer (so parallax, cursor lights, zones and particles can be tried) and synthetic audio for audio-reactive scenes.
final class PreviewHostView: NSView {
    /// Tests use `.timer`; the app uses the display link.
    static var pacing = FramePacingMode.displayLink

    private weak var project: EditorProject?
    private var renderer: SceneRenderer?
    private var driver: FrameDriver?
    private var lastTimestamp: CFTimeInterval?
    private var pointer = SceneInput()
    private var clickSerial = 0
    private var clickTime = -Double.infinity
    private var clickPoint = CGPoint.zero
    private var lastRevision = -1
    private(set) var framesDrawn = 0
    var stats: RenderStats.Snapshot? { renderer?.stats.snapshot() }

    override var wantsUpdateLayer: Bool { true }
    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.pixelFormat = MetalContext.pixelFormat
        layer.framebufferOnly = true
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.maximumDrawableCount = 2
        layer.device = MetalContext.shared?.device
        return layer
    }
    private var metalLayer: CAMetalLayer? { layer as? CAMetalLayer }

    func attach(_ project: EditorProject) {
        guard self.project !== project else { return }
        self.project = project
        renderer?.teardown()
        renderer = MetalContext.shared.map { SceneRenderer(context: $0, scene: project.scene, assetBase: project.directory) }
        lastRevision = project.revision
    }

    /// Called by SwiftUI when the project changed.
    func refresh() {
        guard let project, project.revision != lastRevision else { return }
        lastRevision = project.revision
        renderer?.update(project.scene)
        draw()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        driver?.stop(); driver = nil
        guard window != nil else { return }
        driver = FrameDriver(fps: 30, screen: window?.screen, useDisplayLink: Self.pacing == .displayLink) { [weak self] ts in self?.tick(ts) }
        updateTrackingAreas()
    }

    deinit { driver?.stop(); renderer?.teardown() }

    func stop() { driver?.stop(); driver = nil; renderer?.teardown(); renderer = nil }

    private func tick(_ timestamp: CFTimeInterval) {
        if let last = lastTimestamp { project?.advance(by: min(max(timestamp - last, 0), 0.25)) }
        lastTimestamp = timestamp
        draw()
    }

    private func currentInput() -> SceneInput {
        var input = pointer
        let now = ProcessInfo.processInfo.systemUptime
        input.clickSerial = clickSerial
        input.clickPulse = max(0, min(1, exp(-(now - clickTime) / 0.45)))
        input.clickX = Double(clickPoint.x); input.clickY = Double(clickPoint.y)
        if project?.simulateAudio == true { input.audio = SyntheticAudio.frame(at: project?.playhead ?? 0) }
        return input
    }

    func draw() {
        guard let renderer, let layer = metalLayer, let project, bounds.width > 1, bounds.height > 1 else { return }
        let scale = window?.backingScaleFactor ?? 2
        let size = CGSize(width: min(bounds.width * scale, 1920), height: min(bounds.height * scale, 1920))
        if layer.drawableSize != size { layer.drawableSize = size }
        guard let drawable = layer.nextDrawable(), let buffer = renderer.context.queue.makeCommandBuffer() else { return }
        renderer.encode(into: drawable.texture, commandBuffer: buffer, time: project.playhead, input: currentInput())
        buffer.present(drawable)
        buffer.commit()
        framesDrawn += 1
    }

    // MARK: Mouse = pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil))
    }

    private func normalized(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: Double(p.x / max(bounds.width, 1)) * 2 - 1, y: Double(p.y / max(bounds.height, 1)) * 2 - 1)
    }

    override func mouseMoved(with event: NSEvent) {
        let p = normalized(event)
        pointer.pointerX = p.x; pointer.pointerY = p.y; pointer.pointerActive = true
    }
    override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) { pointer.pointerActive = false }
    override func mouseDown(with event: NSEvent) {
        mouseMoved(with: event)
        clickSerial += 1
        clickTime = ProcessInfo.processInfo.systemUptime
        clickPoint = normalized(event)
    }
}

struct EditorPreview: NSViewRepresentable {
    @ObservedObject var project: EditorProject

    func makeNSView(context: Context) -> PreviewHostView {
        let view = PreviewHostView()
        view.wantsLayer = true
        view.attach(project)
        return view
    }

    func updateNSView(_ view: PreviewHostView, context: Context) {
        view.attach(project)
        _ = project.revision
        view.refresh()
    }

    static func dismantleNSView(_ view: PreviewHostView, coordinator: ()) { view.stop() }
}
