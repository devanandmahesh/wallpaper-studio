import CoreGraphics
import Foundation

/// Placement of one shared picture across several displays ("span" mode).
public enum SpanLayout {
    /// Bounding rectangle of all displays, in global desktop coordinates.
    public static func union(of frames: [CGRect]) -> CGRect {
        frames.dropFirst().reduce(frames.first ?? .zero) { $0.union($1) }
    }

    /// Where the full-desktop picture sits inside one display's window (window coordinates, same axis direction).
    /// The window clips whatever falls outside it, so each display shows exactly its slice.
    public static func contentFrame(union: CGRect, screen: CGRect) -> CGRect {
        CGRect(x: union.minX - screen.minX, y: union.minY - screen.minY, width: union.width, height: union.height)
    }
}

/// Layer size and angle needed to show content rotated on a display.
public enum RotationGeometry {
    /// For 90°/270° the layer is created with swapped width/height and then turned, so after turning it covers the screen.
    /// `angle` is in radians for a Core Animation z-rotation (positive = counter-clockwise), so clockwise degrees are negated.
    public static func layerGeometry(screen: CGSize, rotation: Rotation) -> (size: CGSize, angle: CGFloat) {
        let swapped = rotation == .r90 || rotation == .r270
        let size = swapped ? CGSize(width: screen.height, height: screen.width) : screen
        return (size, -CGFloat(rotation.rawValue) * .pi / 180)
    }
}

/// Reduces an animation's frame rate by resampling it on a fixed time grid.
public enum FrameRateLimiter {
    public struct Frame: Equatable, Sendable {
        public let source: Int       // index of the original frame to show
        public let delay: Double     // seconds it stays on screen
    }

    /// Returns the frames to show so that no frame lasts less than `1/maxFPS`. Total duration is preserved exactly.
    /// If the animation is already slow enough (or no cap is set), the frames are returned unchanged.
    public static func reduce(delays: [Double], maxFPS: Int?) -> [Frame] {
        let identity = delays.enumerated().map { Frame(source: $0.offset, delay: $0.element) }
        guard let fps = maxFPS, fps > 0, delays.count > 1 else { return identity }
        let interval = 1.0 / Double(fps)
        if delays.min() ?? 0 >= interval - 1e-9 { return identity }

        var boundaries: [Double] = [0]               // boundaries[i] = start time of frame i
        for d in delays { boundaries.append(boundaries.last! + d) }
        let total = boundaries.last!

        func frame(at t: Double) -> Int {
            var i = 0
            while i + 1 < delays.count && boundaries[i + 1] <= t + 1e-9 { i += 1 }
            return i
        }

        var picks: [Int] = []
        var t = 0.0
        while t < total - 1e-9 {
            picks.append(frame(at: t))
            t += interval
        }
        // Merge neighbours that picked the same source frame, then fix durations so they sum to `total`.
        var merged: [(source: Int, ticks: Int)] = []
        for p in picks {
            if let last = merged.last, last.source == p { merged[merged.count - 1].ticks += 1 }
            else { merged.append((p, 1)) }
        }
        var out = merged.map { Frame(source: $0.source, delay: Double($0.ticks) * interval) }
        let sum = out.dropLast().reduce(0) { $0 + $1.delay }
        if let last = out.last { out[out.count - 1] = Frame(source: last.source, delay: max(total - sum, 0.001)) }
        return out
    }
}
