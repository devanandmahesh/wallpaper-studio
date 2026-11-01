// Draws the app icon and writes AppIcon.icns. Usage: swiftc -o /tmp/make-icon Tools/make-icon.swift && /tmp/make-icon Resources
import AppKit

func render(size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let inset = s * 0.06
    let rect = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = CGPath(roundedRect: rect, cornerWidth: s * 0.22, cornerHeight: s * 0.22, transform: nil)
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let gradient = CGGradient(colorsSpace: space, colors: [NSColor(srgbRed: 0.10, green: 0.12, blue: 0.42, alpha: 1).cgColor,
                                                           NSColor(srgbRed: 0.55, green: 0.18, blue: 0.62, alpha: 1).cgColor,
                                                           NSColor(srgbRed: 0.98, green: 0.42, blue: 0.45, alpha: 1).cgColor] as CFArray, locations: [0, 0.6, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])
    // Soft rings.
    for (i, alpha) in [0.10, 0.16, 0.24].enumerated() {
        let r = s * (0.20 + 0.11 * CGFloat(i))
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(alpha).cgColor)
        ctx.setLineWidth(s * 0.012)
        ctx.strokeEllipse(in: CGRect(x: s / 2 - r, y: s / 2 - r, width: 2 * r, height: 2 * r))
    }
    // Spectrum bars.
    let heights: [CGFloat] = [0.16, 0.30, 0.48, 0.36, 0.56, 0.40, 0.26, 0.14]
    let barW = s * 0.05, gap = s * 0.028
    let total = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
    var x = (s - total) / 2
    for h in heights {
        let bar = CGRect(x: x, y: s * 0.5 - h * s * 0.5 / 1.0 * 0.5, width: barW, height: h * s * 0.5)
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.95).cgColor)
        ctx.addPath(CGPath(roundedRect: bar, cornerWidth: barW / 2, cornerHeight: barW / 2, transform: nil)); ctx.fillPath()
        x += barW + gap
    }
    ctx.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let iconset = out.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.appendingPathComponent("AppIcon.icns").path]
try p.run(); p.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print("wrote", out.appendingPathComponent("AppIcon.icns").path, "status", p.terminationStatus)
