import Foundation

/// One-tap visual effects that can be laid over any image or video.
public enum EffectPreset: String, Codable, Sendable, CaseIterable {
    case none, colorCycle, ripple, vignette, glow, dreamy

    public var label: String {
        switch self {
        case .none: "None"
        case .colorCycle: "Color cycle"
        case .ripple: "Water ripple"
        case .vignette: "Vignette"
        case .glow: "Moving light"
        case .dreamy: "Dreamy"
        }
    }

    /// Applies the preset to a media layer.
    public func apply(to layer: inout SceneLayer) {
        switch self {
        case .none: break
        case .colorCycle:
            layer.effects.hueCycle = 0.04
        case .ripple:
            layer.effects.rippleAmplitude = 0.004; layer.effects.rippleFrequency = 18; layer.effects.rippleSpeed = 1.2
        case .vignette:
            layer.effects.vignette = 0.6; layer.effects.vignetteRadius = 0.7
        case .glow:
            layer.effects.lightIntensity = 0.55; layer.effects.lightRadius = 0.45; layer.effects.lightY = 0.4
            layer.effects.lightColor = RGBA(1, 0.85, 0.6); layer.effects.lightFlicker = 0.1
            layer.tracks.append(Track(property: .lightX, keyframes: [Keyframe(time: 0, value: 0.15, easing: .easeInOut),
                                                                    Keyframe(time: 12, value: 0.85, easing: .easeInOut)], loop: .pingPong, duration: 12))
        case .dreamy:
            layer.effects.hueCycle = 0.015; layer.effects.rippleAmplitude = 0.002; layer.effects.rippleFrequency = 10
            layer.effects.vignette = 0.35; layer.effects.saturation = 1.15
        }
    }
}

extension Scene {
    /// A one-layer scene showing a media file with an effect preset. `asset` is the file name next to the scene.
    public static func wrapping(media kind: ContentKind, asset: String, scaling: ScalingMode, preset: EffectPreset) -> Scene {
        var layer = SceneLayer(id: "media", name: "Media", content: kind == .video ? .video(asset) : .image(asset), scaling: scaling)
        preset.apply(to: &layer)
        return Scene(name: preset.label, layers: [layer])
    }
}

/// Wallpapers that need no media at all: they are drawn entirely by the GPU.
public enum BuiltInScenes {
    public static let plasma = Scene(name: "Plasma", layers: [
        SceneLayer(id: "plasma", content: .procedural(.plasma, RGBA(0.10, 0.05, 0.45), RGBA(0.95, 0.25, 0.55), speed: 0.6, scale: 1.2),
                   effects: { var e = LayerEffects(); e.vignette = 0.45; e.hueCycle = 0.01; return e }())
    ])

    public static let aurora = Scene(name: "Aurora", background: RGBA(0.01, 0.02, 0.06), layers: [
        SceneLayer(id: "sky", content: .gradient(top: RGBA(0.01, 0.03, 0.10), bottom: RGBA(0.02, 0.10, 0.14))),
        SceneLayer(id: "aurora", content: .procedural(.aurora, RGBA(0.1, 0.9, 0.55), RGBA(0.45, 0.25, 0.9), speed: 0.5, scale: 1),
                   blend: .add, opacity: 0.9),
        SceneLayer(id: "vignette", content: .solid(RGBA(0, 0, 0, 0)), effects: { var e = LayerEffects(); e.vignette = 0.55; return e }(), tracks: [])
    ])

    public static let nightWaves = Scene(name: "Night Waves", background: RGBA(0.0, 0.0, 0.05), layers: [
        SceneLayer(id: "sky", content: .gradient(top: RGBA(0.02, 0.03, 0.12), bottom: RGBA(0.10, 0.12, 0.30))),
        SceneLayer(id: "waves", content: .procedural(.waves, RGBA(0.15, 0.35, 0.85), RGBA(0.02, 0.05, 0.25), speed: 0.7, scale: 1), blend: .screen, opacity: 0.85),
        SceneLayer(id: "moon", content: .solid(RGBA(0.1, 0.1, 0.12)), blend: .add,
                   effects: { var e = LayerEffects(); e.lightIntensity = 0.5; e.lightX = 0.75; e.lightY = 0.25; e.lightRadius = 0.5
                              e.lightColor = RGBA(0.75, 0.85, 1); e.lightFlicker = 0.05; return e }(),
                   tracks: [Track(property: .lightX, keyframes: [Keyframe(time: 0, value: 0.7, easing: .easeInOut), Keyframe(time: 30, value: 0.8, easing: .easeInOut)], loop: .pingPong, duration: 30)])
    ])

    /// Glowing motes drift around, are drawn towards the cursor, and scatter outward when you click the desktop.
    public static let fireflies: Scene = {
        var p = ParticleSpec()
        p.count = 260; p.lifetimeMin = 5; p.lifetimeMax = 11; p.speedMin = 0.01; p.speedMax = 0.05; p.turbulence = 0.06; p.drag = 0.35
        p.sizeStart = 0.012; p.sizeEnd = 0.004; p.sizeJitter = 0.5
        p.colorStart = RGBA(1, 0.92, 0.45, 0.95); p.colorEnd = RGBA(0.6, 1, 0.3, 0)
        p.pointerMode = .attract; p.pointerStrength = 1.2; p.pointerRadius = 0.7; p.burstCount = 40; p.burstSpeed = 0.7; p.seed = 21
        return Scene(name: "Fireflies", background: RGBA(0.01, 0.03, 0.02), layers: [
            SceneLayer(id: "night", content: .gradient(top: RGBA(0.01, 0.04, 0.05), bottom: RGBA(0.03, 0.09, 0.05))),
            SceneLayer(id: "flies", content: .particles(p), blend: .add),
        ])
    }()

    /// Snow that parts around the cursor.
    public static let snowfall: Scene = {
        var p = ParticleSpec()
        p.count = 900; p.lifetimeMin = 9; p.lifetimeMax = 15; p.shape = .box; p.emitterY = 1.08; p.emitterHalfWidth = 1.1; p.emitterHalfHeight = 0.04
        p.directionDegrees = -90; p.spreadDegrees = 40; p.speedMin = 0.04; p.speedMax = 0.12; p.gravityY = -0.02; p.turbulence = 0.03
        p.sizeStart = 0.008; p.sizeEnd = 0.007; p.sizeJitter = 0.6; p.colorStart = RGBA(1, 1, 1, 0.9); p.colorEnd = RGBA(0.8, 0.9, 1, 0.7)
        p.pointerMode = .repel; p.pointerStrength = 2.5; p.pointerRadius = 0.45; p.seed = 8
        return Scene(name: "Snowfall", background: RGBA(0.02, 0.03, 0.08), layers: [
            SceneLayer(id: "sky", content: .gradient(top: RGBA(0.03, 0.05, 0.13), bottom: RGBA(0.12, 0.16, 0.26))),
            SceneLayer(id: "snow", content: .particles(p), blend: .normal),
        ])
    }()

    /// Sparkles shed from the cursor as it moves; clicks make a burst.
    public static let stardustTrail: Scene = {
        var p = ParticleSpec()
        p.count = 1400; p.lifetimeMin = 0.8; p.lifetimeMax = 2.2; p.shape = .pointer; p.speedMin = 0.01; p.speedMax = 0.12; p.drag = 1.2
        p.gravityY = -0.05; p.sizeStart = 0.012; p.sizeEnd = 0.0; p.sizeJitter = 0.5
        p.colorStart = RGBA(0.7, 0.85, 1, 1); p.colorEnd = RGBA(0.8, 0.4, 1, 0)
        p.burstCount = 120; p.burstSpeed = 0.9; p.seed = 3; p.keyGain = 1.5
        return Scene(name: "Stardust Trail", background: RGBA(0.02, 0.01, 0.05), layers: [
            SceneLayer(id: "space", content: .gradient(top: RGBA(0.02, 0.01, 0.07), bottom: RGBA(0.06, 0.03, 0.14))),
            SceneLayer(id: "dust", content: .particles(p), blend: .add),
        ])
    }()

    /// A soft light that follows the cursor across a slowly moving background; typing and clicks make it flare.
    public static let cursorLight: Scene = {
        var light = LayerEffects()
        light.lightIntensity = 0.9; light.lightRadius = 0.4; light.lightX = 0.5; light.lightY = 0.5
        light.lightColor = RGBA(0.55, 0.75, 1); light.lightFlicker = 0.05
        return Scene(name: "Cursor Light", background: RGBA(0.01, 0.01, 0.03), layers: [
            SceneLayer(id: "base", content: .procedural(.plasma, RGBA(0.02, 0.03, 0.12), RGBA(0.08, 0.04, 0.2), speed: 0.15, scale: 0.8)),
            SceneLayer(id: "light", content: .solid(RGBA(0, 0, 0, 0)), blend: .add, effects: light, bindings: [
                InputBinding(source: .pointerX, target: .lightX, gain: 0.5),
                InputBinding(source: .pointerY, target: .lightY, gain: -0.5),          // y is up for input, down for the light
                InputBinding(source: .clickPulse, target: .lightRadius, gain: 0.25),
                InputBinding(source: .keyPulse, target: .lightIntensity, gain: 0.8),
            ]),
        ])
    }()

    /// Classic spectrum bars with a glowing halo.
    public static let spectrum: Scene = {
        var v = VisualizerSpec()
        v.style = .bars; v.bandCount = 32; v.amplitude = 0.62; v.gap = 0.3; v.glow = 1.4
        v.color = RGBA(0.1, 0.85, 1); v.color2 = RGBA(1, 0.25, 0.7)
        var vignette = LayerEffects(); vignette.vignette = 0.55
        return Scene(name: "Spectrum", background: RGBA(0.02, 0.01, 0.05), layers: [
            SceneLayer(id: "bg", content: .gradient(top: RGBA(0.03, 0.02, 0.09), bottom: RGBA(0.01, 0.01, 0.03))),
            SceneLayer(id: "bars", content: .visualizer(v), blend: .add),
            SceneLayer(id: "vignette", content: .solid(RGBA(0, 0, 0, 0)), effects: vignette),
        ])
    }()

    /// A ring that breathes with the music, kicks out particles on every beat and drifts through colours.
    public static let pulseRing: Scene = {
        var v = VisualizerSpec()
        v.style = .circular; v.bandCount = 32; v.size = 0.2; v.amplitude = 0.3; v.gap = 0.35; v.glow = 1.2
        v.rotationSpeed = 0.04; v.hueReactivity = 0.35; v.color = RGBA(0.3, 0.9, 1); v.color2 = RGBA(1, 0.4, 0.8)
        var p = ParticleSpec()
        p.count = 700; p.shape = .point; p.lifetimeMin = 1.2; p.lifetimeMax = 2.6; p.speedMin = 0.02; p.speedMax = 0.1
        p.drag = 0.8; p.sizeStart = 0.01; p.sizeEnd = 0.002; p.audioSizeGain = 1.2; p.beatBurstCount = 90; p.burstSpeed = 0.75
        p.colorStart = RGBA(1, 0.85, 0.6, 0.9); p.colorEnd = RGBA(1, 0.3, 0.6, 0); p.seed = 14
        var glow = LayerEffects(); glow.lightIntensity = 0.25; glow.lightRadius = 0.5
        return Scene(name: "Pulse Ring", background: RGBA(0.01, 0.01, 0.04), layers: [
            SceneLayer(id: "bg", content: .gradient(top: RGBA(0.02, 0.02, 0.08), bottom: RGBA(0.04, 0.02, 0.1))),
            SceneLayer(id: "glow", content: .solid(RGBA(0, 0, 0, 0)), blend: .add, effects: glow,
                       bindings: [InputBinding(source: .audioBass, target: .lightIntensity, gain: 1.2)]),
            SceneLayer(id: "ring", content: .visualizer(v), blend: .add),
            SceneLayer(id: "sparks", content: .particles(p), blend: .add),
        ])
    }()

    /// A luminous waveform line whose colours shift with the loudness.
    public static let waveformGlow: Scene = {
        var v = VisualizerSpec()
        v.style = .wave; v.amplitude = 0.7; v.thickness = 0.006; v.glow = 2; v.hueReactivity = 0.5
        v.color = RGBA(0.2, 1, 0.7); v.color2 = RGBA(0.5, 0.4, 1)
        return Scene(name: "Waveform Glow", background: RGBA(0.01, 0.02, 0.03), layers: [
            SceneLayer(id: "bg", content: .gradient(top: RGBA(0.02, 0.03, 0.06), bottom: RGBA(0.01, 0.01, 0.03))),
            SceneLayer(id: "wave", content: .visualizer(v), blend: .add),
        ])
    }()

    /// A slow plasma whose hue and brightness follow the level and the bass, with faint mirrored bars below.
    public static let bassBloom: Scene = {
        var v = VisualizerSpec()
        v.style = .mirrorBars; v.bandCount = 24; v.amplitude = 0.35; v.gap = 0.4; v.glow = 0.8
        v.color = RGBA(1, 0.7, 0.5); v.color2 = RGBA(0.6, 0.5, 1)
        var vignette = LayerEffects(); vignette.vignette = 0.5
        return Scene(name: "Bass Bloom", background: RGBA(0.01, 0, 0.03), layers: [
            SceneLayer(id: "plasma", content: .procedural(.plasma, RGBA(0.12, 0.04, 0.35), RGBA(0.75, 0.2, 0.45), speed: 0.3, scale: 1),
                       bindings: [InputBinding(source: .audioLevel, target: .hueShift, gain: 140),
                                  InputBinding(source: .audioBass, target: .brightness, gain: 0.22),
                                  InputBinding(source: .audioBeat, target: .scale, gain: 0.04)]),
            SceneLayer(id: "bars", content: .visualizer(v), blend: .add, opacity: 0.55),
            SceneLayer(id: "vignette", content: .solid(RGBA(0, 0, 0, 0)), effects: vignette),
        ])
    }()

    public static let all: [Scene] = [plasma, aurora, nightWaves, fireflies, snowfall, stardustTrail, cursorLight,
                                      spectrum, pulseRing, waveformGlow, bassBloom]
}

/// Render-resolution and frame-rate rules shared by every GPU renderer.
public enum RenderQuality {
    public static let resolutionChoices: [Float] = [1, 0.75, 0.5, 0.25]

    /// Pixel size of the drawable for a layer of `size` points on a display with `scale`, reduced by `resolutionScale`.
    public static func drawableSize(points: CGSize, scale: CGFloat, resolutionScale: Float, maxDimension: Int = 8192) -> (width: Int, height: Int) {
        let k = Double(scale) * Double(min(max(resolutionScale, 0.1), 1))
        let w = Int((Double(points.width) * k).rounded()), h = Int((Double(points.height) * k).rounded())
        return (min(max(w, 1), maxDimension), min(max(h, 1), maxDimension))
    }

    /// Frame rate to render at: the user's cap, never above what the display can show, never below 1.
    public static func effectiveFPS(maxFPS: Int?, displayMax: Int) -> Int {
        let display = max(displayMax, 1)
        guard let cap = maxFPS, cap > 0 else { return display }
        return min(cap, display)
    }
}
