import AppKit
import QuartzCore
import StudioCore

/// GIF / APNG playback as a Core Animation keyframe animation: frames are decoded once, then the render
/// server swaps them without any per-frame work in this process.
final class AnimatedImageRenderer: WallpaperRenderer {
    let kind = WallpaperKind.animatedImage
    var onFinished: (() -> Void)?

    /// Decoded frames may use at most this much memory; larger animations are downscaled.
    static let memoryBudget = 256 * 1024 * 1024

    private let frames: [CGImage]
    private let delays: [Double]
    private let layers = LayerRegistry<CALayer>()
    private var scaling = ScalingMode.fill
    private var speed: Float = 1
    private var maxFPS: Int?
    private var paused = true

    /// Returns nil when the file has fewer than two frames or cannot be decoded.
    init?(url: URL, maxPixel: Int, settings: RenderSettings) {
        guard let source = ImageLoading.source(url) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 1, let first = ImageLoading.thumbnail(source, index: 0, maxPixel: maxPixel) else { return nil }

        // Shrink so that count * w * h * 4 fits the budget.
        let bytesPerFrame = first.width * first.height * 4
        var pixel = maxPixel
        if bytesPerFrame * count > Self.memoryBudget {
            let scale = (Double(Self.memoryBudget) / Double(bytesPerFrame * count)).squareRoot()
            pixel = max(256, Int(Double(maxPixel) * scale))
        }

        var frames: [CGImage] = []
        var delays: [Double] = []
        for i in 0..<count {
            guard let frame = ImageLoading.thumbnail(source, index: i, maxPixel: pixel) else { continue }
            frames.append(frame)
            delays.append(ImageLoading.frameDelay(source, index: i))
        }
        guard frames.count > 1 else { return nil }
        self.frames = frames
        self.delays = delays
        self.scaling = settings.scaling
        self.speed = settings.speed
        self.maxFPS = settings.effectiveMaxFPS
    }

    /// The animation actually played: frames resampled to respect the frame-rate cap.
    private func makeAnimation() -> CAKeyframeAnimation {
        let plan = FrameRateLimiter.reduce(delays: delays, maxFPS: maxFPS)
        let total = plan.reduce(0) { $0 + $1.delay }
        var times: [NSNumber] = [0]
        var acc = 0.0
        for f in plan { acc += f.delay; times.append(NSNumber(value: acc / total)) }
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = plan.map { frames[$0.source] }
        animation.keyTimes = times
        animation.calculationMode = .discrete
        animation.duration = total
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        return animation
    }

    func makeLayer() -> CALayer {
        let layer = CALayer.wallpaperContentLayer()
        layer.contents = frames[0]
        layer.contentsGravity = contentsGravity(scaling)
        layer.add(makeAnimation(), forKey: "frames")
        layers.add(layer)
        if paused { freeze(layer) } else { layer.speed = speed }
        return layer
    }

    func apply(_ settings: RenderSettings) {
        let capChanged = settings.effectiveMaxFPS != maxFPS
        scaling = settings.scaling
        speed = settings.speed
        maxFPS = settings.effectiveMaxFPS
        for layer in layers.layers {
            layer.contentsGravity = contentsGravity(scaling)
            if capChanged { layer.add(makeAnimation(), forKey: "frames") }   // replaces the running animation
            if !paused { retime(layer) }
        }
    }

    /// Number of distinct frames in the animation as currently capped (for tests and diagnostics).
    var effectiveFrameCount: Int { FrameRateLimiter.reduce(delays: delays, maxFPS: maxFPS).count }

    func play() {
        guard paused else { return }
        paused = false
        layers.layers.forEach { resume($0) }
    }

    func pause() {
        guard !paused else { return }
        paused = true
        layers.layers.forEach { freeze($0) }
    }

    func refreshLayers() {
        for layer in layers.layers where layer.animation(forKey: "frames") == nil {
            layer.add(makeAnimation(), forKey: "frames")
        }
    }

    func snapshot() -> CGImage? { frames.first }

    func teardown() {
        layers.layers.forEach { $0.removeAllAnimations(); $0.contents = nil }
        layers.removeAll()
    }

    // MARK: Core Animation pause/resume (https://developer.apple.com/library/archive/qa/qa1673)

    private func freeze(_ layer: CALayer) {
        let time = layer.convertTime(CACurrentMediaTime(), from: nil)
        layer.speed = 0
        layer.timeOffset = time
    }

    private func resume(_ layer: CALayer) {
        let pausedTime = layer.timeOffset
        layer.speed = speed
        layer.timeOffset = 0
        layer.beginTime = 0
        layer.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) - pausedTime
    }

    /// Change speed without a visible jump.
    private func retime(_ layer: CALayer) {
        let now = layer.convertTime(CACurrentMediaTime(), from: nil)
        layer.timeOffset = now
        layer.beginTime = CACurrentMediaTime()
        layer.speed = speed
    }
}
