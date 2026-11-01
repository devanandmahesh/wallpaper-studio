import Metal
import MetalKit
import ImageIO
import AVFoundation
import CoreVideo
import QuartzCore

/// Something that can supply a texture for a layer, possibly a different one every frame.
public protocol LayerTexture: AnyObject {
    /// Width / height of the picture, once known.
    var aspect: Double? { get }
    /// Called once per frame before drawing; returns the texture to sample.
    func texture(at hostTime: CFTimeInterval) -> MTLTexture?
    func play()
    func pause()
    func teardown()
}

public extension LayerTexture {
    func play() {}
    func pause() {}
    func teardown() {}
}

/// A still picture uploaded once. Large images are decoded at no more than `maxDimension`.
///
/// The pixels are redrawn into a known BGRA, premultiplied, sRGB layout before upload instead of trusting
/// `MTKTextureLoader`, which returned channel-swapped data for ImageIO thumbnails on current SDKs.
public final class ImageTexture: LayerTexture {
    private let metalTexture: MTLTexture
    public var aspect: Double? { Double(metalTexture.width) / Double(max(metalTexture.height, 1)) }

    public init(url: URL, device: MTLDevice, maxDimension: Int = 8192) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw RenderError.texture("cannot read \(url.lastPathComponent)") }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw RenderError.texture("cannot decode \(url.lastPathComponent)")
        }
        let w = image.width, h = image.height
        let bytesPerRow = w * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * h)
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: info) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { throw RenderError.texture("cannot convert \(url.lastPathComponent)") }

        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = .shaderRead
        #if arch(arm64)
        d.storageMode = .shared
        #else
        d.storageMode = .managed
        #endif
        guard let texture = device.makeTexture(descriptor: d) else { throw RenderError.texture("allocation \(w)x\(h)") }
        texture.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: pixels, bytesPerRow: bytesPerRow)
        metalTexture = texture
    }

    public func texture(at hostTime: CFTimeInterval) -> MTLTexture? { metalTexture }
}

/// Video frames delivered straight to the GPU: AVFoundation decodes on the media engine into IOSurface-backed
/// pixel buffers, and `CVMetalTextureCache` wraps them as textures without copying.
public final class VideoTexture: LayerTexture {
    public let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private var output: AVPlayerItemVideoOutput
    private var cache: CVMetalTextureCache?
    private var itemObservation: NSKeyValueObservation?
    private var recent: [CVMetalTexture] = []         // keep the last few alive until the GPU is done with them
    private var latest: MTLTexture?

    public private(set) var framesDelivered = 0
    /// Fired when a non-looping item finishes.
    public var onEnded: (() -> Void)?
    private var endObserver: NSObjectProtocol?
    private let loops: Bool

    public var aspect: Double? {
        if let t = latest { return Double(t.width) / Double(max(t.height, 1)) }
        if let size = player.currentItem?.presentationSize, size.height > 0 { return Double(size.width / size.height) }
        return nil
    }

    public init(url: URL, device: MTLDevice, loops: Bool = true) throws {
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess else {
            throw RenderError.texture("video texture cache")
        }
        output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        self.loops = loops
        let item = AVPlayerItem(url: url)
        if loops { looper = AVPlayerLooper(player: player, templateItem: item) } else { player.insert(item, after: nil) }
        // The looper swaps items; the output follows whichever item is current.
        itemObservation = player.observe(\.currentItem, options: [.initial, .new]) { [weak self] player, _ in
            self?.attachOutput(to: player.currentItem)
        }
        player.isMuted = true
        if !loops {
            endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] note in
                if let self, (note.object as? AVPlayerItem) === self.attachedItem { self.onEnded?() }
            }
        }
    }

    private var attachedItem: AVPlayerItem?
    private func attachOutput(to item: AVPlayerItem?) {
        guard item !== attachedItem else { return }
        attachedItem?.remove(output)
        attachedItem = item
        item?.add(output)
    }

    public func texture(at hostTime: CFTimeInterval) -> MTLTexture? {
        let itemTime = output.itemTime(forHostTime: hostTime)
        if output.hasNewPixelBuffer(forItemTime: itemTime),
           let buffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil),
           let cache {
            var cvTexture: CVMetalTexture?
            let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
            if CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, .bgra8Unorm, w, h, 0, &cvTexture) == kCVReturnSuccess,
               let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture) {
                recent.append(cvTexture)
                if recent.count > 4 { recent.removeFirst() }
                latest = texture
                framesDelivered += 1
            }
        }
        return latest
    }

    public func play() { player.play() }
    public func pause() { player.pause() }

    public func teardown() {
        player.pause()
        looper?.disableLooping()
        looper = nil
        itemObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        attachedItem?.remove(output)
        attachedItem = nil
        player.removeAllItems()
        recent.removeAll()
        latest = nil
    }

    deinit { teardown() }
}
