import Foundation
import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import StudioCore
@testable import StudioRender

struct Pixel: Equatable, CustomStringConvertible {
    var r: Int, g: Int, b: Int, a: Int
    var description: String { "rgba(\(r),\(g),\(b),\(a))" }
    func near(_ o: Pixel, tolerance: Int = 3) -> Bool {
        abs(r - o.r) <= tolerance && abs(g - o.g) <= tolerance && abs(b - o.b) <= tolerance
    }
}

struct Frame {
    let width: Int, height: Int
    let bytes: [UInt8]
    func pixel(_ x: Int, _ y: Int) -> Pixel {
        let i = (y * width + x) * 4
        return Pixel(r: Int(bytes[i + 2]), g: Int(bytes[i + 1]), b: Int(bytes[i]), a: Int(bytes[i + 3]))
    }
}

/// Renders on the real GPU. Returns nil only if the machine has no Metal device.
func render(_ scene: Scene, base: URL? = nil, size: Int = 64, width: Int? = nil, time: Double = 0, input: SceneInput = SceneInput()) -> Frame? {
    guard let context = MetalContext.shared else { return nil }
    let w = width ?? size
    guard let bytes = OffscreenRenderer(context: context).pixels(scene: scene, assetBase: base, width: w, height: size, time: time, input: input) else { return nil }
    return Frame(width: w, height: size, bytes: bytes)
}

enum Media {
    static let dir: URL = {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("gpu-fixtures-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    /// PNG from a grid of colours (row-major, top row first).
    @discardableResult
    static func png(_ name: String, columns: Int, rows: Int, colors: [(UInt8, UInt8, UInt8)]) -> URL {
        let url = dir.appendingPathComponent(name)
        var data = [UInt8]()
        for c in colors { data += [c.0, c.1, c.2, 255] }
        let provider = CGDataProvider(data: Data(data) as CFData)!
        let image = CGImage(width: columns, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: columns * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return url
    }

    static func solidMP4(_ name: String, r: UInt8, g: UInt8, b: UInt8, seconds: Int = 2) -> URL {
        let url = dir.appendingPathComponent(name)
        let writer = try! AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 128, AVVideoHeightKey: 72])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 128, kCVPixelBufferHeightKey as String: 72])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for i in 0..<(seconds * 10) {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 128, 72, kCVPixelFormatType_32BGRA, nil, &buffer)
            CVPixelBufferLockBaseAddress(buffer!, [])
            let base = CVPixelBufferGetBaseAddress(buffer!)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer!)
            for y in 0..<72 { for x in 0..<128 { let p = base + y * stride + x * 4; p[0] = b; p[1] = g; p[2] = r; p[3] = 255 } }
            CVPixelBufferUnlockBaseAddress(buffer!, [])
            adaptor.append(buffer!, withPresentationTime: CMTime(value: Int64(i), timescale: 10))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        return url
    }
}

func scene(background: RGBA = .black, _ layers: [SceneLayer]) -> Scene { Scene(name: "t", background: background, layers: layers) }
func red(_ a: Float = 1) -> RGBA { RGBA(1, 0, 0, a) }
