import AppKit
import AVFoundation
import QuartzCore
import StudioCore
import StudioRender

/// A CAMetalLayer that reports size changes, so a static scene can redraw when its display is resized or rotated.
final class StudioMetalLayer: CAMetalLayer {
    var onResize: (() -> Void)?
    /// The screen area this layer's picture covers (the display, or the whole desktop in span mode), for pointer mapping.
    var screenFrame: CGRect?
    /// Rotation applied to the content on its display.
    var contentRotation = Rotation.r0
    override var bounds: CGRect { didSet { if oldValue.size != bounds.size { onResize?() } } }
}

/// Paces rendering to the display. Uses a `CADisplayLink` so frames are aligned with the screen; the requested
/// rate is passed as the link's preferred range, which lets the system actually lower the refresh work.
final class FrameDriver: NSObject {
    private var link: CADisplayLink?
    private var fallback: Timer?
    private let onFrame: (CFTimeInterval) -> Void
    private(set) var framesTicked = 0

    init(fps: Int, screen: NSScreen?, useDisplayLink: Bool = true, onFrame: @escaping (CFTimeInterval) -> Void) {
        self.onFrame = onFrame
        super.init()
        if useDisplayLink, let screen {
            let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: Float(fps), maximum: Float(fps), preferred: Float(fps))
            link.add(to: .main, forMode: .common)
            self.link = link
        } else {
            // Timer pacing: used in tests (a display link is silent while the display sleeps or the screen is locked)
            // and when no screen is available.
            fallback = Timer.scheduledTimer(withTimeInterval: 1.0 / Double(max(fps, 1)), repeats: true) { [weak self] _ in
                self?.framesTicked += 1
                self?.onFrame(CACurrentMediaTime())
            }
            fallback?.tolerance = 0.002
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        framesTicked += 1
        onFrame(link.timestamp)
    }

    func stop() {
        link?.invalidate(); link = nil
        fallback?.invalidate(); fallback = nil
    }

    deinit { stop() }
}

/// Draws scenes, effect-wrapped media and frame-capped video on the GPU.
///
/// * One `SceneRenderer` (one set of textures / one video decoder) feeds a `CAMetalLayer` per display.
/// * Animated scenes render on every display-link tick at the requested frame rate; static scenes (a picture with a
///   vignette, say) render once and again only when something changes, so they cost nothing while idle.
/// * `resolutionScale` shrinks the drawable and lets Core Animation scale it up (cheap quality/power trade-off).
enum FramePacingMode { case displayLink, timer }

final class MetalSceneRenderer: WallpaperRenderer {
    /// How frames are paced. Always `.displayLink` in the app; tests switch to `.timer` so they do not depend on the display being awake.
    static var pacingMode = FramePacingMode.displayLink

    let kind: WallpaperKind
    var onFinished: (() -> Void)?

    private let scene: SceneRenderer
    private let context: MetalContext
    private let layers = LayerRegistry<StudioMetalLayer>()
    private var settings: RenderSettings
    private var driver: FrameDriver?
    private var playing = false
    private var sceneTime = 0.0
    private var lastTick: CFTimeInterval?
    private var nextDue: CFTimeInterval?
    private var redrawPending = false
    private let interaction: InteractionHub?
    private var interactionToken: InteractionHub.Token?
    private var subscription: Int?
    /// The input used for the most recent simulation step (for diagnostics and tests).
    private(set) var lastSimInput = SceneInput()

    var stats: RenderStats.Snapshot { scene.stats.snapshot() }
    var isContinuous: Bool { scene.needsContinuousRendering }
    var framesTicked: Int { driver?.framesTicked ?? 0 }
    var currentFPSTarget: Int { RenderQuality.effectiveFPS(maxFPS: settings.effectiveMaxFPS, displayMax: NSScreen.main?.maximumFramesPerSecond ?? 60) }

    /// - Parameters:
    ///   - kind: what the user picked (scene file, or the media file being wrapped).
    ///   - wrapsMedia: true when a plain image/video is wrapped in a one-layer scene (scaling then follows the settings).
    init?(scene: Scene, assetBase: URL?, kind: WallpaperKind, wrapsMedia: Bool, settings: RenderSettings, loops: Bool, interaction: InteractionHub? = nil) {
        guard let context = MetalContext.shared else { return nil }
        self.context = context
        self.interaction = interaction
        self.kind = kind
        self.settings = settings
        self.scene = SceneRenderer(context: context, scene: scene, assetBase: assetBase, loops: loops)
        if !self.scene.missingAssets.isEmpty {
            Log.engine.error("Scene \(scene.name) is missing assets: \(self.scene.missingAssets.joined(separator: ", "))")
            if wrapsMedia { return nil }
        }
        if wrapsMedia { self.scene.mediaScaling = settings.scaling }
        self.wrapsMedia = wrapsMedia
        self.scene.onVideoEnded = { [weak self] in self?.onFinished?() }
        applyVideoSettings()
    }

    private var wrapsMedia = false

    // MARK: WallpaperRenderer

    func makeLayer() -> CALayer {
        let layer = StudioMetalLayer()
        layer.device = context.device
        layer.pixelFormat = MetalContext.pixelFormat
        layer.framebufferOnly = true
        layer.maximumDrawableCount = 2
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        layer.backgroundColor = NSColor.black.cgColor
        layer.onResize = { [weak self] in self?.scheduleRedraw() }
        layers.add(layer)
        scheduleRedraw()
        return layer
    }

    func apply(_ newSettings: RenderSettings) {
        let paceChanged = newSettings.effectiveMaxFPS != settings.effectiveMaxFPS
        let needsRedraw = newSettings.scaling != settings.scaling || newSettings.resolutionScale != settings.resolutionScale
        settings = newSettings
        if wrapsMedia { scene.mediaScaling = newSettings.scaling }
        applyVideoSettings()
        if paceChanged && playing { restartDriver() }
        if needsRedraw { scheduleRedraw() }
    }

    func play() {
        guard !playing else { return }
        playing = true
        lastTick = nil
        nextDue = nil
        scene.play()
        applyVideoSettings()
        startInteraction()
        if scene.needsContinuousRendering { restartDriver() } else { scheduleRedraw() }
    }

    func pause() {
        guard playing else { return }
        playing = false
        scene.pause()
        driver?.stop(); driver = nil
        stopInteraction()
    }

    func refreshLayers() { scheduleRedraw() }

    func snapshot() -> CGImage? {
        // Sized like the main display (up to 4K) so a still made from it (lock screen) is sharp.
        let frame = NSScreen.main?.frame.size ?? CGSize(width: 1920, height: 1080)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        var w = Int(frame.width * scale), h = Int(frame.height * scale)
        if w > 3840 { h = h * 3840 / w; w = 3840 }
        return OffscreenRenderer(context: context).capture(scene, width: max(w, 640), height: max(h, 360), time: sceneTime, input: lastSimInput)
    }

    func teardown() {
        driver?.stop(); driver = nil
        playing = false
        stopInteraction()
        scene.onVideoEnded = nil
        scene.teardown()
        layers.layers.forEach { $0.onResize = nil }
        layers.removeAll()
        onFinished = nil
    }

    // MARK: Drawing

    private func applyVideoSettings() {
        for video in scene.videoSources.values {
            video.player.isMuted = settings.muted
            video.player.volume = settings.volume
            video.player.defaultRate = settings.speed
            if playing && video.player.rate != 0 { video.player.rate = settings.speed }
        }
    }

    private func restartDriver() {
        nextDue = nil
        driver?.stop()
        driver = FrameDriver(fps: currentFPSTarget, screen: NSScreen.main, useDisplayLink: Self.pacingMode == .displayLink) { [weak self] timestamp in self?.tick(timestamp) }
    }

    /// The display link only offers rates that divide the display's refresh rate (a 10 fps request on a 144 Hz
    /// screen ticks at 12 Hz), so the cap is enforced here with a time budget: a frame is drawn only when it is due,
    /// and the schedule advances by exactly one interval, so the average rate matches the cap.
    private func tick(_ timestamp: CFTimeInterval) {
        if settings.effectiveMaxFPS != nil {
            let interval = 1.0 / Double(currentFPSTarget)
            let due = nextDue ?? timestamp
            guard timestamp + 0.001 >= due else { return }
            nextDue = due + interval
            if nextDue! < timestamp - interval { nextDue = timestamp + interval }      // fell far behind: resynchronise
        }
        if let last = lastTick { sceneTime += min(max(timestamp - last, 0), 0.25) * Double(settings.speed) }
        lastTick = timestamp
        drawAll()
    }

    /// Draws once on the next run-loop turn (coalesces bursts of changes).
    private func scheduleRedraw() {
        guard !redrawPending else { return }
        redrawPending = true
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            guard let self else { return }
            self.redrawPending = false
            self.drawAll()
        }
    }

    // MARK: Interaction

    /// Starts the input monitors this scene needs (and only those), and redraws on input if the scene is otherwise static.
    private func startInteraction() {
        guard let interaction, interactionToken == nil, subscription == nil else { return }
        let wantsPointer = scene.scene.reactsToPointer, wantsKeys = scene.scene.reactsToKeys, wantsAudio = scene.scene.reactsToAudio
        guard wantsPointer || wantsKeys || wantsAudio else { return }
        interactionToken = interaction.acquire(pointer: wantsPointer, keys: wantsKeys, audio: wantsAudio)
        subscription = interaction.subscribe { [weak self] in
            guard let self, self.playing, !self.scene.needsContinuousRendering else { return }
            self.scheduleRedraw()
        }
    }

    private func stopInteraction() {
        if let interaction {
            if let token = interactionToken { interaction.release(token) }
            if let id = subscription { interaction.unsubscribe(id) }
        }
        interactionToken = nil
        subscription = nil
    }

    /// Input as seen by one layer: the cursor mapped onto that layer's display (or the whole desktop in span mode).
    private func input(for layer: StudioMetalLayer, snapshot: InteractionSnapshot) -> SceneInput {
        var input = SceneInput(keyPulse: snapshot.keyPulse, audio: snapshot.audio)
        guard let sample = snapshot.pointer else { return input }
        let frame = layer.screenFrame ?? NSScreen.main?.frame ?? .zero
        input.clickSerial = sample.clickSerial
        input.clickPulse = sample.clickPulse
        input.pointerSpeed = min(sample.speed / max(Double(frame.height), 1), 1)
        if let p = PointerMapper.normalize(location: sample.location, screen: frame, rotation: layer.contentRotation) {
            input.pointerX = p.x; input.pointerY = p.y; input.pointerActive = true
        }
        if let c = PointerMapper.normalize(location: sample.clickLocation, screen: frame, rotation: layer.contentRotation) {
            input.clickX = c.x; input.clickY = c.y
        }
        return input
    }

    private func drawAll() {
        let snapshot = interaction?.snapshot() ?? .idle
        let targets = layers.layers.filter { $0.bounds.width > 0 && $0.bounds.height > 0 }
        guard !targets.isEmpty else { return }
        let inputs = targets.map { input(for: $0, snapshot: snapshot) }
        // The particle simulation runs once per frame, driven by the display the cursor is on.
        let simInput = inputs.first(where: \.pointerActive) ?? inputs[0]
        lastSimInput = simInput
        if let buffer = context.queue.makeCommandBuffer() {
            scene.advance(commandBuffer: buffer, time: sceneTime, input: simInput)
            buffer.commit()
        }
        for (layer, input) in zip(targets, inputs) { draw(layer, input: input) }
    }

    private func draw(_ layer: StudioMetalLayer, input: SceneInput) {
        let pixels = RenderQuality.drawableSize(points: layer.bounds.size, scale: layer.contentsScale, resolutionScale: settings.resolutionScale)
        let size = CGSize(width: pixels.width, height: pixels.height)
        if layer.drawableSize != size { layer.drawableSize = size }
        guard let drawable = layer.nextDrawable(), let buffer = context.queue.makeCommandBuffer() else { return }
        scene.encode(into: drawable.texture, commandBuffer: buffer, time: sceneTime, input: input, advance: false)
        buffer.present(drawable)
        buffer.commit()
    }
}
