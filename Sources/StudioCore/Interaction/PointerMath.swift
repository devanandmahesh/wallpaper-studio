import Foundation
import CoreGraphics

/// Maps a global cursor position to the normalised coordinates scenes use.
public enum PointerMapper {
    /// - Returns: x, y in -1...1 (y up) relative to the display, in the *content's* orientation after undoing the display
    ///   rotation, or nil if the cursor is not on this display.
    public static func normalize(location: CGPoint, screen: CGRect, rotation: Rotation) -> (x: Double, y: Double)? {
        guard screen.width > 0, screen.height > 0, screen.contains(location) else { return nil }
        let nx = (Double(location.x - screen.minX) / Double(screen.width)) * 2 - 1
        let ny = (Double(location.y - screen.minY) / Double(screen.height)) * 2 - 1
        // Content is rotated clockwise by `rotation` on screen, so the cursor maps back by rotating counter-clockwise.
        let theta = Double(rotation.rawValue) * .pi / 180
        return (nx * cos(theta) - ny * sin(theta), nx * sin(theta) + ny * cos(theta))
    }
}

/// Smooths the raw cursor, measures its speed and tracks click/typing pulses. Pure maths: time is passed in, so it is
/// deterministic to test.
public struct PointerFilter: Sendable {
    public var smoothingSeconds: Double = 0.06
    public var clickDecaySeconds: Double = 0.45

    public private(set) var raw = CGPoint.zero
    public private(set) var smoothed = CGPoint.zero
    /// Points per second, itself smoothed.
    public private(set) var speed = 0.0
    public private(set) var clickSerial = 0
    public private(set) var clickLocation = CGPoint.zero
    private var clickTime = -Double.infinity
    private var lastTime: Double?

    public init() {}

    public mutating func update(location: CGPoint, time: Double) {
        defer { raw = location; lastTime = time }
        guard let last = lastTime else { smoothed = location; return }
        let dt = max(time - last, 0.0001)
        let alpha = 1 - exp(-dt / max(smoothingSeconds, 0.0001))
        smoothed = CGPoint(x: smoothed.x + (location.x - smoothed.x) * alpha, y: smoothed.y + (location.y - smoothed.y) * alpha)
        let instant = hypot(location.x - raw.x, location.y - raw.y) / dt
        speed += (instant - speed) * (1 - exp(-dt / 0.1))
    }

    public mutating func registerClick(at location: CGPoint, time: Double) {
        clickSerial += 1
        clickLocation = location
        clickTime = time
    }

    public func clickPulse(at time: Double) -> Double { max(0, min(1, exp(-(time - clickTime) / clickDecaySeconds))) }
}

/// A value that jumps with every event and fades away: typing activity, for example.
public struct PulseMeter: Sendable {
    public var decaySeconds = 0.35
    public var perEvent = 0.25
    private var level = 0.0
    private var stamp = 0.0

    public init() {}

    public mutating func add(at time: Double) {
        level = min(1, value(at: time) + perEvent)
        stamp = time
    }

    public func value(at time: Double) -> Double { level * exp(-max(time - stamp, 0) / decaySeconds) }
}
