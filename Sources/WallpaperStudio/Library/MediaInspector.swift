import AppKit
import AVFoundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import StudioCore
import StudioRender

/// Reads facts about a media file without playing it.
enum MediaInspector {
    struct Probe: Equatable {
        var width = 0
        var height = 0
        var duration: Double?
    }

    /// True if macOS can really decode the file (not just that the extension looks right).
    static func canDisplay(_ url: URL) -> Bool {
        switch WallpaperKind.detect(pathExtension: url.pathExtension) {
        case .video: return isPlayable(url)
        case .image, .animatedImage: return ImageLoading.source(url).map { CGImageSourceGetCount($0) > 0 } ?? false
        case .scene: return loadScene(url) != nil && MetalContext.shared != nil
        case .package: return (try? PackageService.inspect(url)) != nil
        case nil: return false
        }
    }

    /// Decodes and validates a scene file. Scenes that need media next to them wait for the package format (.wsp).
    static func loadScene(_ url: URL) -> Scene? {
        guard let data = try? Data(contentsOf: url), let scene = try? SceneCodec.decode(data), scene.referencedAssets.isEmpty else { return nil }
        return scene
    }

    /// Whether AVFoundation can play the file.
    ///
    /// This deliberately uses the synchronous (deprecated) `isPlayable`. The async `load(.isPlayable)` cannot be waited for
    /// from synchronous code without parking a Swift-concurrency worker thread, and this function is called from such workers
    /// (library imports, tests): with every worker parked, the loader task could never run and the app would deadlock.
    /// (An earlier version did exactly that and hung the test suite.)
    static func isPlayable(_ url: URL) -> Bool { AVURLAsset(url: url).isPlayable }

    static func probe(_ url: URL, kind: WallpaperKind) async -> Probe {
        switch kind {
        case .scene:
            return Probe(width: 1920, height: 1080, duration: nil)
        case .package:
            return Probe()
        case .video:
            let asset = AVURLAsset(url: url)
            var probe = Probe()
            if let d = try? await asset.load(.duration), d.isNumeric, d.seconds.isFinite { probe.duration = d.seconds }
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) {
                let rect = CGRect(origin: .zero, size: size).applying(transform)
                probe.width = Int(abs(rect.width).rounded())
                probe.height = Int(abs(rect.height).rounded())
            }
            return probe
        case .image, .animatedImage:
            guard let source = ImageLoading.source(url),
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return Probe() }
            var probe = Probe(width: props[kCGImagePropertyPixelWidth] as? Int ?? 0, height: props[kCGImagePropertyPixelHeight] as? Int ?? 0)
            if kind == .animatedImage {
                let count = CGImageSourceGetCount(source)
                probe.duration = (0..<count).reduce(0) { $0 + ImageLoading.frameDelay(source, index: $1) }
            }
            return probe
        }
    }

    /// Streaming SHA-256, so multi-gigabyte videos are never loaded into memory.
    static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func thumbnail(_ url: URL, kind: WallpaperKind, maxPixel: Int = 640) -> CGImage? {
        switch kind {
        case .package:
            guard let package = try? PackageService.resolve(url) else { return nil }
            if let preview = package.previewURL, let image = ImageLoading.source(preview).flatMap({ ImageLoading.thumbnail($0, index: 0, maxPixel: maxPixel) }) { return image }
            switch package.manifest.type {
            case .scene:
                guard let scene = package.scene, let context = MetalContext.shared else { return nil }
                return OffscreenRenderer(context: context).image(scene: scene, assetBase: package.directory, width: maxPixel, height: maxPixel * 9 / 16, time: 2)
            case .video: return thumbnail(package.entryURL, kind: .video, maxPixel: maxPixel)
            case .image: return thumbnail(package.entryURL, kind: .image, maxPixel: maxPixel)
            case .web: return nil
            }
        case .scene:
            guard let scene = loadScene(url), let context = MetalContext.shared else { return nil }
            return OffscreenRenderer(context: context).image(scene: scene, assetBase: nil, width: maxPixel, height: maxPixel * 9 / 16, time: 2)
        case .image, .animatedImage:
            return ImageLoading.source(url).flatMap { ImageLoading.thumbnail($0, index: 0, maxPixel: maxPixel) }
        case .video:
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
            for seconds in [1.0, 0.0] {
                if let image = try? generator.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 600), actualTime: nil) { return image }
            }
            return nil
        }
    }

    static func jpegData(_ image: CGImage, quality: Double = 0.8) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}
