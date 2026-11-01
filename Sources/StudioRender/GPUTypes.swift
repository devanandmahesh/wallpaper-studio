import simd
import StudioCore

/// Mirror of `LayerUniforms` in the shader. Field order and types must match exactly; `GPUTypesTests` checks the layout.
struct LayerUniforms {
    var color = SIMD4<Float>(0, 0, 0, 1)
    var color2 = SIMD4<Float>(0, 0, 0, 1)
    var lightColor = SIMD4<Float>(1, 1, 1, 1)
    var axis0 = SIMD2<Float>(1, 0)
    var axis1 = SIMD2<Float>(0, 1)
    var translate = SIMD2<Float>(0, 0)
    var light = SIMD2<Float>(0.5, 0.5)
    var depthShift = SIMD2<Float>(0, 0)
    var canvas = SIMD2<Float>(1, 1)
    var opacity: Float = 1
    var kind: Int32 = 1
    var time: Float = 0
    var speed: Float = 1
    var scale: Float = 1
    var hueShift: Float = 0
    var brightness: Float = 0
    var contrast: Float = 1
    var saturation: Float = 1
    var vignette: Float = 0
    var vignetteRadius: Float = 0.8
    var rippleAmp: Float = 0
    var rippleFreq: Float = 12
    var rippleSpeed: Float = 1
    var lightRadius: Float = 0.35
    var lightIntensity: Float = 0
    var lightFlicker: Float = 0
    var hasDepth: Int32 = 0
    var vizBars: Float = 32
    var vizThickness: Float = 0.01
    var vizGap: Float = 0.25
    var vizGlow: Float = 0.6
    var vizMirror: Float = 0
    var vizSize: Float = 0.22
}

extension LayerUniforms {
    static func shaderKind(_ content: LayerContent) -> Int32 {
        switch content.kind {
        case .image, .video: return 0
        case .color, .particles: return 1
        case .visualizer:
            switch content.visualizer?.style ?? .bars { case .bars, .mirrorBars: return 6; case .circular: return 7; case .wave: return 8 }
        case .gradient: return 2
        case .procedural:
            switch content.procedural ?? .plasma { case .plasma: return 3; case .aurora: return 4; case .waves: return 5 }
        }
    }

    /// Builds the uniforms for one resolved layer on a canvas of `canvasSize` pixels.
    init(layer: ResolvedLayer, contentAspect: Double?, canvasSize: SIMD2<Float>, time: Double, hasDepth: Bool, audioLevel: Float = 0) {
        self.init()
        let aspect = Double(canvasSize.x / max(canvasSize.y, 1))
        let m = LayerGeometry.affine(canvasAspect: aspect, contentAspect: contentAspect,
                                     scaling: layer.content.isMedia ? layer.scaling : .stretch,
                                     positionX: layer.positionX, positionY: layer.positionY,
                                     scale: layer.scale, rotationDegrees: layer.rotation)
        axis0 = SIMD2(Float(m.a), Float(m.b))
        axis1 = SIMD2(Float(m.c), Float(m.d))
        translate = SIMD2(Float(m.tx), Float(m.ty))
        canvas = canvasSize
        opacity = Float(layer.opacity)
        kind = Self.shaderKind(layer.content)
        color = SIMD4(layer.content.color.r, layer.content.color.g, layer.content.color.b, layer.content.color.a)
        color2 = SIMD4(layer.content.color2.r, layer.content.color2.g, layer.content.color2.b, layer.content.color2.a)
        self.time = Float(time)
        speed = Float(layer.content.speed)
        scale = Float(layer.content.scale)
        let e = layer.effects
        hueShift = Float((e.hueShift + e.hueCycle * 360 * time) * .pi / 180)
        brightness = Float(e.brightness); contrast = Float(e.contrast); saturation = Float(e.saturation)
        vignette = Float(e.vignette); vignetteRadius = Float(e.vignetteRadius)
        rippleAmp = Float(e.rippleAmplitude); rippleFreq = Float(e.rippleFrequency); rippleSpeed = Float(e.rippleSpeed)
        light = SIMD2(Float(e.lightX), Float(e.lightY))
        lightRadius = Float(e.lightRadius); lightIntensity = Float(e.lightIntensity); lightFlicker = Float(e.lightFlicker)
        lightColor = SIMD4(e.lightColor.r, e.lightColor.g, e.lightColor.b, 1)
        depthShift = SIMD2(Float(layer.depthShiftX), Float(layer.depthShiftY))
        self.hasDepth = hasDepth ? 1 : 0
        if let v = layer.content.visualizer {
            color = SIMD4(v.color.r, v.color.g, v.color.b, 1)
            color2 = SIMD4(v.color2.r, v.color2.g, v.color2.b, 1)
            scale = Float(v.amplitude)
            speed = Float(v.rotationSpeed)
            vizBars = Float(v.bandCount); vizThickness = Float(v.thickness); vizGap = Float(v.gap)
            vizGlow = Float(v.glow); vizSize = Float(v.size)
            vizMirror = v.style == .mirrorBars ? 1 : 0
            // Music-reactive colour: the palette drifts around the hue wheel as the music gets louder.
            hueShift += Float(v.hueReactivity) * audioLevel * 2 * .pi
        }
    }
}

/// Mirror of `ParticleParams` in the shader (192 bytes).
struct ParticleParams {
    var colorStart = SIMD4<Float>(1, 1, 1, 1)
    var colorEnd = SIMD4<Float>(1, 1, 1, 0)
    var emitterCenter = SIMD2<Float>(0, 0)
    var emitterHalf = SIMD2<Float>(1, 1)
    var gravity = SIMD2<Float>(0, 0)
    var pointer = SIMD2<Float>(0, 0)
    var burstPosition = SIMD2<Float>(0, 0)
    var canvas = SIMD2<Float>(1, 1)
    var dt: Float = 0
    var time: Float = 0
    var lifeMin: Float = 1
    var lifeMax: Float = 1
    var speedMin: Float = 0
    var speedMax: Float = 0
    var direction: Float = 0
    var spread: Float = 0
    var drag: Float = 0
    var turbulence: Float = 0
    var sizeStart: Float = 0.01
    var sizeEnd: Float = 0.01
    var sizeJitter: Float = 0
    var pointerStrength: Float = 0
    var pointerRadius: Float = 0.5
    var burstSpeed: Float = 0.5
    var simAspect: Float = ParticleSpec.simAspect
    var keyBoost: Float = 0
    var opacity: Float = 1
    var count: UInt32 = 0
    var seed: UInt32 = 1
    var shape: UInt32 = 0
    var pointerMode: UInt32 = 0
    var pointerActive: UInt32 = 0
    var burstStart: UInt32 = 0
    var burstCount: UInt32 = 0
    var initialize: UInt32 = 0
    var prewarm: UInt32 = 0

    init() {}

    init(spec s: ParticleSpec) {
        colorStart = SIMD4(s.colorStart.r, s.colorStart.g, s.colorStart.b, s.colorStart.a)
        colorEnd = SIMD4(s.colorEnd.r, s.colorEnd.g, s.colorEnd.b, s.colorEnd.a)
        emitterCenter = SIMD2(Float(s.emitterX), Float(s.emitterY))
        emitterHalf = SIMD2(Float(s.emitterHalfWidth), Float(s.emitterHalfHeight))
        gravity = SIMD2(Float(s.gravityX), Float(s.gravityY))
        lifeMin = Float(s.lifetimeMin); lifeMax = Float(s.lifetimeMax)
        speedMin = Float(s.speedMin); speedMax = Float(s.speedMax)
        direction = Float(s.directionDegrees) * .pi / 180
        spread = Float(s.spreadDegrees) * .pi / 180
        drag = Float(s.drag); turbulence = Float(s.turbulence)
        sizeStart = Float(s.sizeStart); sizeEnd = Float(s.sizeEnd); sizeJitter = Float(s.sizeJitter)
        pointerStrength = Float(s.pointerStrength); pointerRadius = Float(s.pointerRadius)
        burstSpeed = Float(s.burstSpeed)
        count = UInt32(s.count); seed = s.seed
        switch s.shape { case .point: shape = 0; case .box: shape = 1; case .pointer: shape = 2 }
        switch s.pointerMode { case .none: pointerMode = 0; case .attract: pointerMode = 1; case .repel: pointerMode = 2; case .swirl: pointerMode = 3 }
        prewarm = s.prewarm ? 1 : 0
    }
}
