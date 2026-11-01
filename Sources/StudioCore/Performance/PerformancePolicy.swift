import Foundation

/// How hard the wallpaper engine is allowed to work.
public enum PerformanceProfile: String, Codable, Sendable, CaseIterable {
    case batterySaver, balanced, performance, adaptive

    public var label: String {
        switch self {
        case .batterySaver: "Battery Saver"
        case .balanced: "Balanced"
        case .performance: "Performance"
        case .adaptive: "Adaptive"
        }
    }

    public var summary: String {
        switch self {
        case .batterySaver: "15 fps at 75 % resolution. Longest battery life."
        case .balanced: "30 fps. Smooth enough for a wallpaper at a fraction of the cost."
        case .performance: "60 fps (30 fps on battery). Smoothest."
        case .adaptive: "Starts at 60 fps and steps frame rate and resolution down when the Mac is busy or warm, and back up when it is not."
        }
    }

    /// Nominal frame-rate ceiling before conditions are considered.
    public var baseFPS: Int {
        switch self { case .batterySaver: 15; case .balanced: 30; case .performance, .adaptive: 60 }
    }
}

public enum ThermalLevel: Int, Comparable, Sendable { case nominal, fair, serious, critical
    public static func < (a: ThermalLevel, b: ThermalLevel) -> Bool { a.rawValue < b.rawValue }
}

public enum MemoryPressureLevel: Int, Comparable, Sendable { case normal, warning, critical
    public static func < (a: MemoryPressureLevel, b: MemoryPressureLevel) -> Bool { a.rawValue < b.rawValue }
}

/// A snapshot of everything the performance policy looks at.
public struct SystemConditions: Equatable, Sendable {
    public var onBattery = false
    public var batteryFraction: Double?          // 0...1, nil on desktop Macs
    public var lowPowerMode = false
    public var thermal = ThermalLevel.nominal
    public var memoryPressure = MemoryPressureLevel.normal
    /// This app's CPU use as a percentage of one core (100 = one full core).
    public var appCPUPercent = 0.0
    public var displayMaxFPS = 60
    public var activeGPURenderers = 0
    public init() {}
}

public struct PerformanceDecision: Equatable, Sendable {
    public var fpsCap: Int
    public var resolutionScale: Float
    public var paused: Bool
    /// Ask the app to release caches and hidden renderers.
    public var trimMemory: Bool
    public var reasons: [String]

    public init(fpsCap: Int, resolutionScale: Float, paused: Bool, trimMemory: Bool, reasons: [String]) {
        self.fpsCap = fpsCap; self.resolutionScale = resolutionScale; self.paused = paused; self.trimMemory = trimMemory; self.reasons = reasons
    }

    public var summary: String {
        paused ? "Paused (\(reasons.joined(separator: ", ")))"
               : "\(fpsCap) fps · \(Int((resolutionScale * 100).rounded())) % resolution" + (reasons.isEmpty ? "" : " — \(reasons.joined(separator: ", "))")
    }
}

/// Steps frame rate and resolution down while the Mac is under load or warm, and back up after a calm period.
/// Pure state machine: time is passed in, so it is deterministic to test.
public struct AdaptiveGovernor: Sendable {
    public static let tiers: [(fps: Int, resolution: Float)] = [(60, 1), (40, 1), (30, 0.85), (24, 0.75), (15, 0.5)]
    public static let busyCPUPercent = 20.0       // sustained use above this counts as pressure
    public static let calmCPUPercent = 6.0
    public static let stepDownAfter = 6.0         // seconds of pressure before one step down
    public static let stepUpAfter = 25.0          // seconds of calm before one step up
    public static let holdAfterPressure = 120.0   // after a pressure step, do not climb back for this long (prevents oscillation)

    public private(set) var tier = 0
    private var lastChange = -Double.infinity
    private var holdUntil = -Double.infinity
    private var pressureSince: Double?
    private var calmSince: Double?

    public init() {}

    public var current: (fps: Int, resolution: Float) { Self.tiers[tier] }

    public mutating func update(_ c: SystemConditions, now: Double) {
        let floorTier = (c.onBattery || c.lowPowerMode) ? 2 : 0           // never above 30 fps on battery
        if tier < floorTier { tier = floorTier; lastChange = now }

        let pressure = c.appCPUPercent > Self.busyCPUPercent || c.thermal >= .fair
        let calm = c.appCPUPercent < Self.calmCPUPercent && c.thermal == .nominal && !c.lowPowerMode

        if pressure {
            pressureSince = pressureSince ?? now
            calmSince = nil
            if now - (pressureSince ?? now) >= Self.stepDownAfter, now - lastChange >= Self.stepDownAfter, tier < Self.tiers.count - 1 {
                tier += 1
                lastChange = now
                holdUntil = now + Self.holdAfterPressure
                pressureSince = now
            }
        } else if calm {
            pressureSince = nil
            calmSince = calmSince ?? now
            if now - (calmSince ?? now) >= Self.stepUpAfter, now >= holdUntil, now - lastChange >= Self.stepUpAfter, tier > floorTier {
                tier -= 1
                lastChange = now
                calmSince = now
            }
        } else {
            pressureSince = nil
            calmSince = nil
        }
    }
}

public enum PerformancePolicy {
    /// Combines the chosen profile with the current conditions into the limits the renderers must respect.
    public static func decide(profile: PerformanceProfile, conditions c: SystemConditions, governor: AdaptiveGovernor = AdaptiveGovernor()) -> PerformanceDecision {
        var fps = profile.baseFPS
        var resolution: Float = 1
        var reasons: [String] = []
        var paused = false
        var trim = false

        switch profile {
        case .batterySaver: resolution = 0.75
        case .adaptive:
            fps = governor.current.fps
            resolution = governor.current.resolution
            if governor.tier > 0 { reasons.append("adapting to load") }
        case .balanced, .performance: break
        }

        if c.onBattery && profile == .performance { fps = min(fps, 30); reasons.append("on battery") }
        if c.lowPowerMode { fps = min(fps, 15); reasons.append("Low Power Mode") }
        if c.onBattery, let level = c.batteryFraction, level <= 0.2 { fps = min(fps, 15); reasons.append("battery low") }
        if c.activeGPURenderers >= 3 { fps = min(fps, 30); reasons.append("\(c.activeGPURenderers) wallpapers running") }

        switch c.thermal {
        case .nominal: break
        case .fair: resolution *= 0.85; reasons.append("Mac is warm")
        case .serious: fps = min(fps, 15); resolution *= 0.6; reasons.append("Mac is hot")
        case .critical: paused = true; reasons.append("Mac is overheating")
        }

        switch c.memoryPressure {
        case .normal: break
        case .warning: trim = true; reasons.append("low memory")
        case .critical: trim = true; resolution *= 0.5; reasons.append("very low memory")
        }

        fps = max(1, min(fps, max(c.displayMaxFPS, 1)))
        resolution = (min(max(resolution, 0.25), 1) * 100).rounded() / 100
        return PerformanceDecision(fpsCap: fps, resolutionScale: resolution, paused: paused, trimMemory: trim, reasons: reasons)
    }
}

extension RenderSettings {
    /// The frame limit actually used: the stricter of the user's own limit and the performance policy's.
    public var effectiveMaxFPS: Int? {
        switch (maxFPS, performanceFPSCap) {
        case let (a?, b?): min(a, b)
        case let (a?, nil): a
        case let (nil, b?): b
        case (nil, nil): nil
        }
    }

    public func applying(_ decision: PerformanceDecision, displayMaxFPS: Int) -> RenderSettings {
        var s = self
        s.performanceFPSCap = decision.fpsCap < displayMaxFPS ? decision.fpsCap : nil
        s.resolutionScale = min(resolutionScale, decision.resolutionScale)
        return s
    }
}
