import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import StudioCore

/// Builds real media files so the renderers are exercised against actual decoders.
enum Fixtures {
    static let dir: URL = {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("ws-fixtures-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    static func frame(_ w: Int, _ h: Int, hue: CGFloat) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        ctx.setFillColor(NSColor(hue: hue, saturation: 1, brightness: 1, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    static func png(_ w: Int, _ h: Int) -> URL {
        let url = dir.appendingPathComponent("still-\(w)x\(h).png")
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, frame(w, h, hue: 0.6), nil)
        CGImageDestinationFinalize(dest)
        return url
    }

    static func gif(frames: Int, delay: Double) -> URL {
        let url = dir.appendingPathComponent("anim-\(frames).gif")
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames, nil)!
        for i in 0..<frames {
            let props = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary
            CGImageDestinationAddImage(dest, frame(64, 36, hue: CGFloat(i) / CGFloat(frames)), props)
        }
        CGImageDestinationFinalize(dest)
        return url
    }

    static func mp4(seconds: Int = 1) -> URL {
        let url = dir.appendingPathComponent("clip-\(UUID().uuidString).mp4")
        let writer = try! AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for i in 0..<(seconds * 10) {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.01) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 320, 180, kCVPixelFormatType_32ARGB, nil, &buffer)
            adaptor.append(buffer!, withPresentationTime: CMTime(value: Int64(i), timescale: 10))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        return url
    }
}


extension Fixtures {
    /// A minimal valid zip (stored, not compressed) holding one empty file with an arbitrary entry name.
    static func zipWithEmptyEntry(named name: String) -> Data {
        let n = Array(name.utf8)
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)] }
        func le32(_ v: Int) -> [UInt8] { le16(v & 0xffff) + le16((v >> 16) & 0xffff) }
        var local: [UInt8] = le32(0x04034b50) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0)
        local += le32(0) + le32(0) + le32(0) + le16(n.count) + le16(0) + n
        var central: [UInt8] = le32(0x02014b50) + le16(20) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0)
        central += le32(0) + le32(0) + le32(0) + le16(n.count) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0) + le32(0) + n
        let end: [UInt8] = le32(0x06054b50) + le16(0) + le16(0) + le16(1) + le16(1) + le32(central.count) + le32(local.count) + le16(0)
        return Data(local + central + end)
    }
}

// MARK: - Hand-built zip archives (so hostile ones can be made)

extension Fixtures {
    struct ZipItem {
        var name: String
        var data: Data
        var isSymlink = false
        var declaredSize: UInt32?          // lie about the size in the central directory (zip-bomb test)
    }

    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for b in data { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFFFFFF
    }

    /// A valid zip (entries stored uncompressed) with full control over names, symlink flags and declared sizes.
    static func storedZip(_ items: [ZipItem]) -> Data {
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)] }
        func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)] }
        var out = Data(), central = Data()
        for item in items {
            let name = Array(item.name.utf8)
            let crc = crc32(item.data)
            let offset = UInt32(out.count)
            out += Data(le32(0x04034b50) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0x21) + le32(crc) + le32(UInt32(item.data.count)) + le32(UInt32(item.data.count)) + le16(name.count) + le16(0) + name)
            out += item.data
            let mode: UInt32 = item.isSymlink ? 0xA1FF : (item.name.hasSuffix("/") ? 0x41ED : 0x81A4)
            let external = mode << 16
            central += Data(le32(0x02014b50) + le16(0x031E) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0x21) + le32(crc)
                            + le32(UInt32(item.data.count)) + le32(item.declaredSize ?? UInt32(item.data.count)) + le16(name.count) + le16(0) + le16(0) + le16(0) + le16(0)
                            + le32(external) + le32(offset) + name)
        }
        let start = UInt32(out.count)
        out += central
        out += Data(le32(0x06054b50) + le16(0) + le16(0) + le16(items.count) + le16(items.count) + le32(UInt32(central.count)) + le32(start) + le16(0))
        return out
    }

    static func manifestData(_ m: PackageManifestLike) -> Data {
        try! JSONSerialization.data(withJSONObject: m.dictionary)
    }

    struct PackageManifestLike {
        var type = "scene", entry = "scene.json", format = "wsp", formatVersion = 1, id = "com.test.pkg", name = "Test Package"
        var extra: [String: Any] = [:]
        var dictionary: [String: Any] {
            var d: [String: Any] = ["format": format, "formatVersion": formatVersion, "id": id, "name": name, "type": type, "entry": entry]
            for (k, v) in extra { d[k] = v }
            return d
        }
    }

    static func zipFile(_ items: [ZipItem], name: String = "pkg-\(UUID().uuidString).wsp") -> URL {
        let url = dir.appendingPathComponent(name)
        try! storedZip(items).write(to: url)
        return url
    }
}
