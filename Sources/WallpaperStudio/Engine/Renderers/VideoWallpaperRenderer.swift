import AppKit
import AVFoundation
import StudioCore

/// Hardware-decoded video through AVFoundation. Frames go straight from the media engine to the
/// display via `AVPlayerLayer`; no CPU frame handling. Looping uses `AVPlayerLooper` (gapless).
final class VideoWallpaperRenderer: WallpaperRenderer {
    let kind = WallpaperKind.video
    var onFinished: (() -> Void)?

    private let url: URL
    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private var endObserver: NSObjectProtocol?
    private let layers = LayerRegistry<AVPlayerLayer>()
    private var gravity: AVLayerVideoGravity = .resizeAspectFill

    init(url: URL, loops: Bool, settings: RenderSettings) {
        self.url = url
        let item = AVPlayerItem(url: url)
        if loops {
            looper = AVPlayerLooper(player: player, templateItem: item)
        } else {
            player.insert(item, after: nil)
            endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                self?.onFinished?()
            }
        }
        apply(settings)
    }

    func makeLayer() -> CALayer {
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = gravity
        layer.backgroundColor = NSColor.black.cgColor
        layers.add(layer)
        return layer
    }

    func apply(_ settings: RenderSettings) {
        player.isMuted = settings.muted
        player.volume = settings.volume
        player.defaultRate = settings.speed
        gravity = videoGravity(settings.scaling)
        layers.layers.forEach { $0.videoGravity = gravity }
        // Changing speed while playing must take effect immediately.
        if player.rate != 0 { player.rate = settings.speed }
    }

    func play() { player.play() }
    func pause() { player.pause() }

    func refreshLayers() {
        for layer in layers.layers {
            layer.player = nil
            layer.player = player
        }
    }

    func snapshot() -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        // Any nearby frame will do; exact-time requests fail at loop boundaries or before the item is ready.
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        let now = player.currentTime()
        for time in [now.isNumeric ? now : .zero, .zero] {
            if let image = try? generator.copyCGImage(at: time, actualTime: nil) { return image }
        }
        return nil
    }

    func teardown() {
        player.pause()
        looper?.disableLooping()
        looper = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player.removeAllItems()
        layers.layers.forEach { $0.player = nil }
        layers.removeAll()
        onFinished = nil
    }
}
