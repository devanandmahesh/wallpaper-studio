import Foundation

/// Straight (non-premultiplied) sRGB colour, components 0...1.
public struct RGBA: Codable, Equatable, Sendable {
    public var r: Float, g: Float, b: Float, a: Float
    public init(_ r: Float, _ g: Float, _ b: Float, _ a: Float = 1) { self.r = r; self.g = g; self.b = b; self.a = a }
    public static let black = RGBA(0, 0, 0)
    public static let white = RGBA(1, 1, 1)
    public var isValid: Bool { [r, g, b, a].allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 } }
}

public enum BlendMode: String, Codable, Sendable, CaseIterable { case normal, add, multiply, screen }
public enum Easing: String, Codable, Sendable, CaseIterable { case linear, easeIn, easeOut, easeInOut, step }
public enum LoopMode: String, Codable, Sendable, CaseIterable { case once, loop, pingPong }
public enum ContentKind: String, Codable, Sendable { case color, gradient, image, video, procedural, particles, visualizer }
public enum ProceduralKind: String, Codable, Sendable, CaseIterable { case plasma, aurora, waves }

/// What a layer draws.
public struct LayerContent: Codable, Equatable, Sendable {
    public var kind: ContentKind
    public var color: RGBA            // solid colour / gradient top / procedural primary
    public var color2: RGBA           // gradient bottom / procedural secondary
    public var asset: String?         // file name (no directories) inside the scene's folder, for image/video
    public var procedural: ProceduralKind?
    public var speed: Double          // procedural animation speed
    public var scale: Double          // procedural pattern scale
    public var particles: ParticleSpec?
    public var visualizer: VisualizerSpec?

    public init(kind: ContentKind, color: RGBA = .black, color2: RGBA = .black, asset: String? = nil,
                procedural: ProceduralKind? = nil, speed: Double = 1, scale: Double = 1, particles: ParticleSpec? = nil, visualizer: VisualizerSpec? = nil) {
        self.kind = kind; self.color = color; self.color2 = color2; self.asset = asset
        self.procedural = procedural; self.speed = speed; self.scale = scale; self.particles = particles; self.visualizer = visualizer
    }

    public static func particles(_ spec: ParticleSpec) -> LayerContent { .init(kind: .particles, particles: spec) }
    public static func visualizer(_ spec: VisualizerSpec) -> LayerContent { .init(kind: .visualizer, visualizer: spec) }

    public static func solid(_ c: RGBA) -> LayerContent { .init(kind: .color, color: c) }
    public static func gradient(top: RGBA, bottom: RGBA) -> LayerContent { .init(kind: .gradient, color: top, color2: bottom) }
    public static func image(_ asset: String) -> LayerContent { .init(kind: .image, asset: asset) }
    public static func video(_ asset: String) -> LayerContent { .init(kind: .video, asset: asset) }
    public static func procedural(_ kind: ProceduralKind, _ a: RGBA, _ b: RGBA, speed: Double = 1, scale: Double = 1) -> LayerContent {
        .init(kind: .procedural, color: a, color2: b, procedural: kind, speed: speed, scale: scale)
    }

    /// Image and video layers have their own aspect ratio; everything else covers the canvas.
    public var isMedia: Bool { kind == .image || kind == .video }
}

/// Per-layer visual effects. All values have neutral defaults, so an empty `LayerEffects()` changes nothing.
public struct LayerEffects: Codable, Equatable, Sendable {
    public var hueShift = 0.0              // degrees
    public var hueCycle = 0.0              // full turns per second
    public var brightness = 0.0            // -1...1 added
    public var contrast = 1.0
    public var saturation = 1.0
    public var vignette = 0.0              // 0...1 darkening at the edges
    public var vignetteRadius = 0.8
    public var rippleAmplitude = 0.0       // fraction of the layer
    public var rippleFrequency = 12.0
    public var rippleSpeed = 1.0
    public var lightIntensity = 0.0        // animated light; 0 = off
    public var lightX = 0.5                // canvas fractions, origin top-left
    public var lightY = 0.5
    public var lightRadius = 0.35
    public var lightColor = RGBA(1, 0.9, 0.7)
    public var lightFlicker = 0.0          // 0...1 random-looking intensity wobble

    public init() {}

    public var isNeutral: Bool { self == LayerEffects() }

    /// True when the effects change over time on their own.
    public var animatesByItself: Bool {
        hueCycle != 0 || (rippleAmplitude != 0 && rippleSpeed != 0) || (lightIntensity != 0 && lightFlicker != 0)
    }

    enum CodingKeys: String, CodingKey {
        case hueShift, hueCycle, brightness, contrast, saturation, vignette, vignetteRadius
        case rippleAmplitude, rippleFrequency, rippleSpeed
        case lightIntensity, lightX, lightY, lightRadius, lightColor, lightFlicker
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func get<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T { try c.decodeIfPresent(T.self, forKey: key) ?? fallback }
        hueShift = try get(.hueShift, 0); hueCycle = try get(.hueCycle, 0)
        brightness = try get(.brightness, 0); contrast = try get(.contrast, 1); saturation = try get(.saturation, 1)
        vignette = try get(.vignette, 0); vignetteRadius = try get(.vignetteRadius, 0.8)
        rippleAmplitude = try get(.rippleAmplitude, 0); rippleFrequency = try get(.rippleFrequency, 12); rippleSpeed = try get(.rippleSpeed, 1)
        lightIntensity = try get(.lightIntensity, 0); lightX = try get(.lightX, 0.5); lightY = try get(.lightY, 0.5)
        lightRadius = try get(.lightRadius, 0.35); lightColor = try get(.lightColor, RGBA(1, 0.9, 0.7)); lightFlicker = try get(.lightFlicker, 0)
    }
}

public enum AnimatableProperty: String, Codable, Sendable, CaseIterable {
    case positionX, positionY, scale, rotation, opacity
    case hueShift, brightness, saturation, vignette, rippleAmplitude
    case lightX, lightY, lightIntensity, lightRadius
}

public struct Keyframe: Codable, Equatable, Sendable {
    public var time: Double
    public var value: Double
    public var easing: Easing        // easing used between this keyframe and the next
    public init(time: Double, value: Double, easing: Easing = .linear) { self.time = time; self.value = value; self.easing = easing }
}

/// Keyframes for one property. `duration` is the length of one cycle for `.loop` / `.pingPong`.
public struct Track: Codable, Equatable, Sendable {
    public var property: AnimatableProperty
    public var keyframes: [Keyframe]
    public var loop: LoopMode
    public var duration: Double

    public init(property: AnimatableProperty, keyframes: [Keyframe], loop: LoopMode = .loop, duration: Double? = nil) {
        self.property = property
        self.keyframes = keyframes.sorted { $0.time < $1.time }
        self.loop = loop
        self.duration = duration ?? (keyframes.map(\.time).max() ?? 0)
    }

    /// Value at scene time `t`, or nil if the track has no keyframes.
    public func value(at t: Double) -> Double? {
        guard let first = keyframes.first, let last = keyframes.last else { return nil }
        if keyframes.count == 1 { return first.value }
        var time = t
        if duration > 0 {
            switch loop {
            case .once: break
            case .loop: time = t.truncatingRemainder(dividingBy: duration); if time < 0 { time += duration }
            case .pingPong:
                let period = duration * 2
                var m = t.truncatingRemainder(dividingBy: period); if m < 0 { m += period }
                time = m <= duration ? m : period - m
            }
        }
        if time <= first.time { return first.value }
        if time >= last.time { return last.value }
        var i = 0
        while i + 1 < keyframes.count && keyframes[i + 1].time <= time { i += 1 }
        let a = keyframes[i], b = keyframes[i + 1]
        let span = b.time - a.time
        let f = span > 0 ? (time - a.time) / span : 1
        return a.value + (b.value - a.value) * Self.ease(f, a.easing)
    }

    static func ease(_ f: Double, _ e: Easing) -> Double {
        switch e {
        case .linear: return f
        case .easeIn: return f * f
        case .easeOut: return 1 - (1 - f) * (1 - f)
        case .easeInOut: return f < 0.5 ? 2 * f * f : 1 - 2 * (1 - f) * (1 - f)
        case .step: return 0
        }
    }

    /// Does this track change the picture over time?
    public var isAnimated: Bool { keyframes.count > 1 && Set(keyframes.map(\.value)).count > 1 }
}

public struct SceneLayer: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var content: LayerContent
    public var blend: BlendMode
    public var opacity: Double
    public var positionX: Double          // -1...1, fraction of half the canvas
    public var positionY: Double
    public var scale: Double
    public var rotation: Double           // degrees, clockwise
    public var scaling: ScalingMode       // how image/video layers fit the canvas
    public var effects: LayerEffects
    public var depthAsset: String?        // grey-scale depth map (white = near) for parallax
    public var parallaxDepth: Double      // 0 = far (doesn't move) ... 1 = near
    public var tracks: [Track]
    public var bindings: [InputBinding]   // live inputs (pointer, clicks, typing) added on top of the animation

    public init(id: String, name: String = "", content: LayerContent, blend: BlendMode = .normal, opacity: Double = 1,
                positionX: Double = 0, positionY: Double = 0, scale: Double = 1, rotation: Double = 0,
                scaling: ScalingMode = .fill, effects: LayerEffects = LayerEffects(), depthAsset: String? = nil,
                parallaxDepth: Double = 0, tracks: [Track] = [], bindings: [InputBinding] = []) {
        self.id = id; self.name = name.isEmpty ? id : name; self.content = content; self.blend = blend; self.opacity = opacity
        self.positionX = positionX; self.positionY = positionY; self.scale = scale; self.rotation = rotation
        self.scaling = scaling; self.effects = effects; self.depthAsset = depthAsset; self.parallaxDepth = parallaxDepth
        self.tracks = tracks; self.bindings = bindings
    }

    enum CodingKeys: String, CodingKey {
        case id, name, content, blend, opacity, positionX, positionY, scale, rotation, scaling, effects, depthAsset, parallaxDepth, tracks, bindings
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(String.self, forKey: .id)
        self.init(
            id: id,
            name: try c.decodeIfPresent(String.self, forKey: .name) ?? id,
            content: try c.decode(LayerContent.self, forKey: .content),
            blend: try c.decodeIfPresent(BlendMode.self, forKey: .blend) ?? .normal,
            opacity: try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1,
            positionX: try c.decodeIfPresent(Double.self, forKey: .positionX) ?? 0,
            positionY: try c.decodeIfPresent(Double.self, forKey: .positionY) ?? 0,
            scale: try c.decodeIfPresent(Double.self, forKey: .scale) ?? 1,
            rotation: try c.decodeIfPresent(Double.self, forKey: .rotation) ?? 0,
            scaling: try c.decodeIfPresent(ScalingMode.self, forKey: .scaling) ?? .fill,
            effects: try c.decodeIfPresent(LayerEffects.self, forKey: .effects) ?? LayerEffects(),
            depthAsset: try c.decodeIfPresent(String.self, forKey: .depthAsset),
            parallaxDepth: try c.decodeIfPresent(Double.self, forKey: .parallaxDepth) ?? 0,
            tracks: try c.decodeIfPresent([Track].self, forKey: .tracks) ?? [],
            bindings: try c.decodeIfPresent([InputBinding].self, forKey: .bindings) ?? [])
    }
}

/// A rectangle on the display that reacts to the mouse by nudging a layer property, e.g. "hovering the top-right corner
/// makes the moon glow". Rectangles use canvas fractions: 0...1, origin top-left (the same as light positions).
public struct InteractionZone: Codable, Equatable, Sendable, Identifiable {
    public enum Trigger: String, Codable, Sendable, CaseIterable { case hover, click }
    public var id: String
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var trigger: Trigger
    public var layerID: String
    public var property: AnimatableProperty
    /// Added to the property while the zone is active (hover: while the pointer is inside; click: fading after a click inside).
    public var amount: Double

    public init(id: String, x: Double, y: Double, width: Double, height: Double, trigger: Trigger = .hover,
                layerID: String, property: AnimatableProperty, amount: Double) {
        self.id = id; self.x = x; self.y = y; self.width = width; self.height = height
        self.trigger = trigger; self.layerID = layerID; self.property = property; self.amount = amount
    }

    public func contains(canvasX px: Double, canvasY py: Double) -> Bool { px >= x && px <= x + width && py >= y && py <= y + height }
}

/// A complete wallpaper scene: background colour plus layers drawn bottom-to-top.
/// Pure data: no GPU objects, so it can be saved, validated, diffed and tested without Metal.
public struct Scene: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var version: Int
    public var name: String
    public var background: RGBA
    public var layers: [SceneLayer]
    public var zones: [InteractionZone]

    public init(name: String, background: RGBA = .black, layers: [SceneLayer], zones: [InteractionZone] = []) {
        self.version = Self.currentVersion; self.name = name; self.background = background; self.layers = layers; self.zones = zones
    }

    enum CodingKeys: String, CodingKey { case version, name, background, layers, zones }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        name = try c.decode(String.self, forKey: .name)
        background = try c.decode(RGBA.self, forKey: .background)
        layers = try c.decode([SceneLayer].self, forKey: .layers)
        zones = try c.value(.zones, [])
    }

    /// File names the scene needs next to it.
    public var referencedAssets: [String] {
        layers.flatMap { [$0.content.asset, $0.depthAsset].compactMap { $0 } }
    }

    public var hasVideo: Bool { layers.contains { $0.content.kind == .video } }

    /// True if the picture can change without any user input. Static scenes only need to be drawn once.
    public var isAnimated: Bool {
        layers.contains { l in
            l.content.kind == .video || l.content.kind == .procedural || l.content.kind == .particles || l.content.kind == .visualizer
                || l.bindings.contains(where: \.usesAudio)
                || l.effects.animatesByItself || l.tracks.contains(where: \.isAnimated)
        }
    }

    /// True if the picture reacts to the pointer (parallax); such scenes redraw when the pointer moves.
    public var reactsToPointer: Bool {
        !zones.isEmpty || layers.contains { $0.parallaxDepth != 0 || $0.bindings.contains(where: \.usesPointer) || ($0.content.particles?.reactsToPointer ?? false) }
    }

    /// True if typing changes the picture, so the app needs (opt-in) keyboard activity.
    public var reactsToKeys: Bool {
        layers.contains { $0.bindings.contains(where: \.usesKeys) || (($0.content.particles?.keyGain ?? 0) != 0) }
    }

    /// True if sound changes the picture, so the app needs (opt-in) audio capture.
    public var reactsToAudio: Bool {
        layers.contains { $0.content.kind == .visualizer || $0.bindings.contains(where: \.usesAudio)
            || (($0.content.particles?.audioSizeGain ?? 0) != 0) || (($0.content.particles?.beatBurstCount ?? 0) > 0) }
    }

    public var totalParticles: Int { layers.reduce(0) { $0 + ($1.content.particles?.count ?? 0) } }
}
