import AppKit
import AVFoundation
import StudioCore
import StudioRender

/// A source of wallpaper content. One renderer per loaded wallpaper; it vends one layer per display
/// so every display shows the same underlying decoder/image without duplicating work.
protocol WallpaperRenderer: AnyObject {
    var kind: WallpaperKind { get }
    /// Fired when non-looping content finishes (used to advance playlists).
    var onFinished: (() -> Void)? { get set }

    func makeLayer() -> CALayer
    /// Renderers that draw with a view (web pages) return it here; the window then shows the view instead of the layer.
    func makeContentView() -> NSView?
    func apply(_ settings: RenderSettings)
    func play()
    func pause()
    /// Re-attach layers to their source after wake / Space change / display reconfiguration.
    func refreshLayers()
    /// Current picture, used for the static-wallpaper fallback.
    func snapshot() -> CGImage?
    func teardown()
}

extension WallpaperRenderer {
    func makeContentView() -> NSView? { nil }
}

/// Weak registry of the layers a renderer has handed out.
final class LayerRegistry<Layer: CALayer> {
    private let table = NSHashTable<Layer>.weakObjects()
    var layers: [Layer] { table.allObjects }
    func add(_ layer: Layer) { table.add(layer) }
    func removeAll() { table.removeAllObjects() }
}

enum RendererFactory {
    /// Which renderer a file/settings combination needs. Plain media stays on Core Animation (cheapest);
    /// the GPU path is used for scenes, effects, and videos with a frame-rate cap.
    static func usesMetal(kind: WallpaperKind, settings: RenderSettings) -> Bool {
        switch kind {
        case .scene: return true
        case .image: return settings.effect != .none
        case .video: return settings.effect != .none || settings.maxFPS != nil
        case .animatedImage: return false           // GIF frames are played by Core Animation (frame cap applied there)
        case .package: return false                 // decided by what is inside the package
        }
    }

    static func make(url: URL, loops: Bool, settings: RenderSettings, maxPixel: Int, interaction: InteractionHub? = nil) -> WallpaperRenderer? {
        guard let kind = WallpaperKind.detect(pathExtension: url.pathExtension) else { return nil }
        if kind == .package { return makePackage(url: url, loops: loops, settings: settings, maxPixel: maxPixel, interaction: interaction) }
        if usesMetal(kind: kind, settings: settings), let metal = makeMetal(url: url, kind: kind, loops: loops, settings: settings, interaction: interaction) { return metal }
        switch kind {
        case .scene, .package: return nil            // scenes need the GPU; packages are handled above
        case .video: return VideoWallpaperRenderer(url: url, loops: loops, settings: settings)
        case .image: return StaticImageRenderer(url: url, maxPixel: maxPixel, settings: settings)
        case .animatedImage:
            return AnimatedImageRenderer(url: url, maxPixel: maxPixel, settings: settings)
                ?? StaticImageRenderer(url: url, maxPixel: maxPixel, settings: settings)
        }
    }

    private static func makePackage(url: URL, loops: Bool, settings: RenderSettings, maxPixel: Int, interaction: InteractionHub?) -> WallpaperRenderer? {
        guard let package = try? PackageService.resolve(url) else {
            Log.engine.error("Cannot open package \(url.lastPathComponent)")
            return nil
        }
        switch package.manifest.type {
        case .scene:
            guard let scene = package.scene else { return nil }
            return MetalSceneRenderer(scene: scene, assetBase: package.directory, kind: .package, wrapsMedia: false, settings: settings, loops: loops, interaction: interaction)
        case .video, .image:
            return make(url: package.entryURL, loops: loops, settings: settings, maxPixel: maxPixel, interaction: interaction)
        case .web:
            return WebWallpaperRenderer(package: package, interaction: interaction)
        }
    }

    private static func makeMetal(url: URL, kind: WallpaperKind, loops: Bool, settings: RenderSettings, interaction: InteractionHub?) -> MetalSceneRenderer? {
        let base = url.deletingLastPathComponent()
        if kind == .scene {
            guard let data = try? Data(contentsOf: url), let scene = try? SceneCodec.decode(data) else {
                Log.engine.error("Unreadable scene \(url.lastPathComponent)")
                return nil
            }
            return MetalSceneRenderer(scene: scene, assetBase: base, kind: .scene, wrapsMedia: false, settings: settings, loops: loops, interaction: interaction)
        }
        let scene = Scene.wrapping(media: kind == .video ? .video : .image, asset: url.lastPathComponent,
                                   scaling: settings.scaling, preset: settings.effect)
        return MetalSceneRenderer(scene: scene, assetBase: base, kind: kind, wrapsMedia: true, settings: settings, loops: loops, interaction: interaction)
    }
}

extension CALayer {
    static func wallpaperContentLayer() -> CALayer {
        let layer = CALayer()
        layer.backgroundColor = NSColor.black.cgColor
        layer.masksToBounds = true
        return layer
    }
}

func contentsGravity(_ scaling: ScalingMode) -> CALayerContentsGravity {
    switch scaling { case .fill: .resizeAspectFill; case .fit: .resizeAspect; case .stretch: .resize }
}

func videoGravity(_ scaling: ScalingMode) -> AVLayerVideoGravity {
    switch scaling { case .fill: .resizeAspectFill; case .fit: .resizeAspect; case .stretch: .resize }
}
