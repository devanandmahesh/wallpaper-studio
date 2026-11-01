import Foundation

public enum Rotation: Int, Codable, Sendable, CaseIterable {
    case r0 = 0, r90 = 90, r180 = 180, r270 = 270
    public var label: String { self == .r0 ? "None" : "\(rawValue)° clockwise" }
}

/// How wallpapers are distributed across displays.
public enum DisplayMode: String, Codable, Sendable, CaseIterable {
    case mirror        // the main wallpaper on every display
    case independent   // each display has its own wallpaper and settings
    case span          // the main wallpaper stretched across the whole desktop

    public var label: String {
        switch self { case .mirror: "Same on all"; case .independent: "Different per display"; case .span: "Span across displays" }
    }

    public var summary: String {
        switch self {
        case .mirror: "Every display shows the main wallpaper."
        case .independent: "Each display has its own wallpaper, scaling, rotation, volume and frame-rate limit."
        case .span: "One wallpaper is stretched across all displays as if they were a single screen."
        }
    }
}

/// Everything remembered about one physical display (used in `.independent` mode).
public struct DisplayConfig: Codable, Equatable, Sendable {
    /// Absolute path of the wallpaper file; nil means "use the main wallpaper".
    public var wallpaperPath: String?
    public var scaling: ScalingMode
    public var rotation: Rotation
    public var maxFPS: Int?
    public var speed: Float
    public var volume: Float
    public var muted: Bool
    public var paused: Bool
    public var effect: EffectPreset
    public var resolutionScale: Float

    public init(wallpaperPath: String? = nil, scaling: ScalingMode = .fill, rotation: Rotation = .r0, maxFPS: Int? = nil,
                speed: Float = 1, volume: Float = 0.5, muted: Bool = true, paused: Bool = false,
                effect: EffectPreset = .none, resolutionScale: Float = 1) {
        self.wallpaperPath = wallpaperPath; self.scaling = scaling; self.rotation = rotation; self.maxFPS = maxFPS
        self.speed = speed; self.volume = volume; self.muted = muted; self.paused = paused
        self.effect = effect; self.resolutionScale = resolutionScale
    }

    public var renderSettings: RenderSettings {
        RenderSettings(scaling: scaling, speed: speed, volume: volume, muted: muted, maxFPS: maxFPS,
                       effect: effect, resolutionScale: resolutionScale)
    }

    // Fields added after the first release decode with defaults, so older displays.json files keep working.
    enum CodingKeys: String, CodingKey {
        case wallpaperPath, scaling, rotation, maxFPS, speed, volume, muted, paused, effect, resolutionScale
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(wallpaperPath: try c.decodeIfPresent(String.self, forKey: .wallpaperPath),
                  scaling: try c.decodeIfPresent(ScalingMode.self, forKey: .scaling) ?? .fill,
                  rotation: try c.decodeIfPresent(Rotation.self, forKey: .rotation) ?? .r0,
                  maxFPS: try c.decodeIfPresent(Int.self, forKey: .maxFPS),
                  speed: try c.decodeIfPresent(Float.self, forKey: .speed) ?? 1,
                  volume: try c.decodeIfPresent(Float.self, forKey: .volume) ?? 0.5,
                  muted: try c.decodeIfPresent(Bool.self, forKey: .muted) ?? true,
                  paused: try c.decodeIfPresent(Bool.self, forKey: .paused) ?? false,
                  effect: try c.decodeIfPresent(EffectPreset.self, forKey: .effect) ?? .none,
                  resolutionScale: try c.decodeIfPresent(Float.self, forKey: .resolutionScale) ?? 1)
    }
}

/// Persisted multi-display state. Configs are keyed by display UUID, so a monitor that is unplugged and later
/// reconnected (possibly with a different `CGDirectDisplayID`) gets its old settings back. The chosen mode is
/// remembered per *set* of displays, so docking/undocking a laptop switches layouts automatically.
public struct DisplayLayoutState: Codable, Equatable, Sendable {
    public var version = 1
    public var configs: [String: DisplayConfig] = [:]
    public var modes: [String: DisplayMode] = [:]
    public var knownNames: [String: String] = [:]

    public init() {}

    public static func signature(of uuids: [String]) -> String { uuids.sorted().joined(separator: "|") }

    public func mode(for uuids: [String]) -> DisplayMode { modes[Self.signature(of: uuids)] ?? .mirror }
    public mutating func setMode(_ mode: DisplayMode, for uuids: [String]) { modes[Self.signature(of: uuids)] = mode }
    public mutating func remember(name: String, uuid: String) { knownNames[uuid] = name }
    public mutating func forget(uuid: String) { configs[uuid] = nil; knownNames[uuid] = nil }
}

/// JSON persistence for `DisplayLayoutState`. Never throws on load: a missing or damaged file yields defaults
/// (a damaged file is kept next to the original as `*.corrupt` so nothing is silently lost).
public struct DisplayLayoutStore: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }

    public func load() -> DisplayLayoutState {
        guard let data = try? Data(contentsOf: url) else { return DisplayLayoutState() }
        if let state = try? JSONDecoder().decode(DisplayLayoutState.self, from: data), state.version <= 1 { return state }
        let backup = url.appendingPathExtension("corrupt")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: url, to: backup)
        return DisplayLayoutState()
    }

    public func save(_ state: DisplayLayoutState) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: url, options: .atomic)
    }
}
