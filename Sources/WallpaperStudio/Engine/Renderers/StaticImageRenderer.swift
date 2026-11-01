import AppKit
import StudioCore

final class StaticImageRenderer: WallpaperRenderer {
    let kind = WallpaperKind.image
    var onFinished: (() -> Void)?

    private let image: CGImage
    private let layers = LayerRegistry<CALayer>()
    private var scaling = ScalingMode.fill

    /// Fails (nil) if the file cannot be decoded.
    init?(url: URL, maxPixel: Int, settings: RenderSettings) {
        guard let source = ImageLoading.source(url), let image = ImageLoading.thumbnail(source, index: 0, maxPixel: maxPixel) else { return nil }
        self.image = image
        self.scaling = settings.scaling
    }

    func makeLayer() -> CALayer {
        let layer = CALayer.wallpaperContentLayer()
        layer.contents = image
        layer.contentsGravity = contentsGravity(scaling)
        layers.add(layer)
        return layer
    }

    func apply(_ settings: RenderSettings) {
        scaling = settings.scaling
        layers.layers.forEach { $0.contentsGravity = contentsGravity(scaling) }
    }

    func play() {}
    func pause() {}
    func refreshLayers() { layers.layers.forEach { $0.contents = image } }
    func snapshot() -> CGImage? { image }

    func teardown() {
        layers.layers.forEach { $0.contents = nil }
        layers.removeAll()
    }
}
