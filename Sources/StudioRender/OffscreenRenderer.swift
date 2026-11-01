import Metal
import CoreGraphics
import QuartzCore
import StudioCore

/// Renders a scene into an ordinary texture and reads it back. Used for library thumbnails and for tests.
public final class OffscreenRenderer {
    public let context: MetalContext

    public init(context: MetalContext) { self.context = context }

    public func makeTarget(width: Int, height: Int) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: MetalContext.pixelFormat, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        return context.device.makeTexture(descriptor: d)
    }

    /// Draws `scene` once and returns BGRA bytes (row-major, top row first), or nil on failure.
    public func pixels(scene: Scene, assetBase: URL?, width: Int, height: Int, time: Double = 0,
                       input: SceneInput = SceneInput(), waitForVideoSeconds: Double = 2) -> [UInt8]? {
        guard let target = makeTarget(width: width, height: height) else { return nil }
        let renderer = SceneRenderer(context: context, scene: scene, assetBase: assetBase, loops: true)
        defer { renderer.teardown() }
        if scene.hasVideo {
            // Give the decoder a moment to deliver a first frame.
            renderer.play()
            let deadline = Date().addingTimeInterval(waitForVideoSeconds)
            while Date() < deadline {
                if renderer.hasVideoFrame { break }
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
        }
        guard let buffer = context.queue.makeCommandBuffer() else { return nil }
        renderer.encode(into: target, commandBuffer: buffer, time: time, input: input)
        buffer.commit()
        buffer.waitUntilCompleted()
        guard buffer.status == .completed else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        target.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return bytes
    }

    public func image(scene: Scene, assetBase: URL?, width: Int, height: Int, time: Double = 0) -> CGImage? {
        guard let bytes = pixels(scene: scene, assetBase: assetBase, width: width, height: height, time: time) else { return nil }
        return Self.cgImage(bgra: bytes, width: width, height: height)
    }

    /// Draws one frame of an existing (possibly live) renderer into an image, e.g. for the static-wallpaper fallback.
    public func capture(_ renderer: SceneRenderer, width: Int, height: Int, time: Double, input: SceneInput = SceneInput()) -> CGImage? {
        guard let target = makeTarget(width: width, height: height), let buffer = context.queue.makeCommandBuffer() else { return nil }
        renderer.encode(into: target, commandBuffer: buffer, time: time, input: input)
        buffer.commit()
        buffer.waitUntilCompleted()
        guard buffer.status == .completed else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        target.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return Self.cgImage(bgra: bytes, width: width, height: height)
    }

    static func cgImage(bgra: [UInt8], width: Int, height: Int) -> CGImage? {
        var bytes = bgra
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
        return bytes.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: info)?.makeImage()
        }
    }
}

extension SceneRenderer {
    /// True once every video layer has delivered at least one frame (polls the decoders).
    public var hasVideoFrame: Bool {
        let now = CACurrentMediaTime()
        return videoSources.values.allSatisfy { $0.texture(at: now) != nil }
    }
}
