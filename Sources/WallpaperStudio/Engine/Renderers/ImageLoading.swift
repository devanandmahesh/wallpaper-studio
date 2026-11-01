import Foundation
import ImageIO
import CoreGraphics

/// Decodes images at the size they will be shown, so a 100-megapixel photo does not sit in memory at full size.
enum ImageLoading {
    static func source(_ url: URL) -> CGImageSource? { CGImageSourceCreateWithURL(url as CFURL, nil) }

    static func thumbnail(_ source: CGImageSource, index: Int, maxPixel: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // honour EXIF orientation
            kCGImageSourceShouldCacheImmediately: true,         // decode now, not on the render thread
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
    }

    /// Per-frame delay in seconds for GIF/APNG frames (browser-like minimum of 20 ms).
    static func frameDelay(_ source: CGImageSource, index: Int) -> Double {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else { return 0.1 }
        let candidates: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
        ]
        for (dictKey, unclamped, clamped) in candidates {
            if let dict = props[dictKey] as? [CFString: Any] {
                let value = (dict[unclamped] as? Double) ?? (dict[clamped] as? Double) ?? 0.1
                return max(value, 0.02)
            }
        }
        return 0.1
    }
}
