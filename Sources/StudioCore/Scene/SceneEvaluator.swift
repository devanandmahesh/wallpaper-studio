import Foundation
import CoreGraphics

/// Live inputs that can drive a scene. Pointer coordinates are -1...1 across the display with **y up**.
public struct SceneInput: Equatable, Sendable {
    public var pointerX: Double
    public var pointerY: Double
    /// False when the cursor is not on this display (particles then ignore the pointer).
    public var pointerActive: Bool
    public var pointerSpeed: Double       // 0...1
    public var clickSerial: Int           // increases with every click
    public var clickX: Double
    public var clickY: Double
    public var clickPulse: Double         // 1 at a click, fading to 0
    public var keyPulse: Double           // typing activity, 0...1
    public var audio: AudioFrame          // latest analysed sound (silent when audio is off)

    public init(pointerX: Double = 0, pointerY: Double = 0, pointerActive: Bool = false, pointerSpeed: Double = 0,
                clickSerial: Int = 0, clickX: Double = 0, clickY: Double = 0, clickPulse: Double = 0, keyPulse: Double = 0,
                audio: AudioFrame = .silent) {
        self.pointerX = pointerX; self.pointerY = pointerY; self.pointerActive = pointerActive; self.pointerSpeed = pointerSpeed
        self.clickSerial = clickSerial; self.clickX = clickX; self.clickY = clickY; self.clickPulse = clickPulse; self.keyPulse = keyPulse; self.audio = audio
    }

    func value(of source: InputSource) -> Double {
        switch source {
        case .pointerX: pointerX
        case .pointerY: pointerY
        case .pointerSpeed: pointerSpeed
        case .clickPulse: clickPulse
        case .keyPulse: keyPulse
        case .audioLevel: Double(audio.level)
        case .audioBass: Double(audio.bass)
        case .audioMid: Double(audio.mid)
        case .audioTreble: Double(audio.treble)
        case .audioBeat: Double(audio.beat)
        }
    }
}

/// A layer with every animation track and input applied for one instant. This is what the renderer draws.
public struct ResolvedLayer: Equatable, Sendable {
    public var id: String
    public var content: LayerContent
    public var blend: BlendMode
    public var opacity: Double
    public var positionX: Double
    public var positionY: Double
    public var scale: Double
    public var rotation: Double
    public var scaling: ScalingMode
    public var effects: LayerEffects
    public var depthAsset: String?
    /// For layers with a depth map: how far (canvas fraction) the nearest pixels shift. Others fold it into position.
    public var depthShiftX: Double
    public var depthShiftY: Double
}

extension ResolvedLayer {
    mutating func set(_ property: AnimatableProperty, _ v: Double, additive: Bool) {
        func apply(_ old: Double) -> Double { additive ? old + v : v }
        switch property {
        case .positionX: positionX = apply(positionX)
        case .positionY: positionY = apply(positionY)
        case .scale: scale = apply(scale)
        case .rotation: rotation = apply(rotation)
        case .opacity: opacity = apply(opacity)
        case .hueShift: effects.hueShift = apply(effects.hueShift)
        case .brightness: effects.brightness = apply(effects.brightness)
        case .saturation: effects.saturation = apply(effects.saturation)
        case .vignette: effects.vignette = apply(effects.vignette)
        case .rippleAmplitude: effects.rippleAmplitude = apply(effects.rippleAmplitude)
        case .lightX: effects.lightX = apply(effects.lightX)
        case .lightY: effects.lightY = apply(effects.lightY)
        case .lightIntensity: effects.lightIntensity = apply(effects.lightIntensity)
        case .lightRadius: effects.lightRadius = apply(effects.lightRadius)
        }
    }
}

public enum SceneEvaluator {
    /// Largest parallax shift (fraction of the canvas) for a layer with `parallaxDepth == 1` at full pointer deflection.
    public static let parallaxStrength = 0.05

    public static func resolve(_ scene: Scene, time: Double, input: SceneInput = SceneInput()) -> [ResolvedLayer] {
        scene.layers.map { resolve($0, time: time, input: input, zones: scene.zones) }
    }

    /// How strongly a zone is active right now (0...1).
    public static func activation(of zone: InteractionZone, input: SceneInput) -> Double {
        switch zone.trigger {
        case .hover:
            guard input.pointerActive else { return 0 }
            return zone.contains(canvasX: (input.pointerX + 1) / 2, canvasY: (1 - input.pointerY) / 2) ? 1 : 0
        case .click:
            return zone.contains(canvasX: (input.clickX + 1) / 2, canvasY: (1 - input.clickY) / 2) ? min(max(input.clickPulse, 0), 1) : 0
        }
    }

    public static func resolve(_ layer: SceneLayer, time: Double, input: SceneInput = SceneInput(), zones: [InteractionZone] = []) -> ResolvedLayer {
        var r = ResolvedLayer(id: layer.id, content: layer.content, blend: layer.blend, opacity: layer.opacity,
                              positionX: layer.positionX, positionY: layer.positionY, scale: layer.scale,
                              rotation: layer.rotation, scaling: layer.scaling, effects: layer.effects,
                              depthAsset: layer.depthAsset, depthShiftX: 0, depthShiftY: 0)
        for track in layer.tracks {
            if let v = track.value(at: time) { r.set(track.property, v, additive: false) }
        }
        for binding in layer.bindings {
            r.set(binding.target, binding.gain * input.value(of: binding.source), additive: true)
        }
        for zone in zones where zone.layerID == layer.id {
            let a = activation(of: zone, input: input)
            if a > 0 { r.set(zone.property, zone.amount * a, additive: true) }
        }
        r.opacity = min(max(r.opacity, 0), 1)
        r.scale = max(r.scale, 0.0001)

        // Parallax: near layers slide against the pointer's direction (pointer right → picture left, pointer up → picture down).
        let dx = -input.pointerX * layer.parallaxDepth * parallaxStrength * 2
        let dy = -input.pointerY * layer.parallaxDepth * parallaxStrength * 2
        if layer.depthAsset == nil {
            r.positionX += dx
            r.positionY += dy
        } else {
            r.depthShiftX = dx
            r.depthShiftY = dy
        }
        return r
    }
}

/// 2×3 affine map from a layer's unit quad (-0.5...0.5) to normalised device coordinates.
public struct Affine2D: Equatable, Sendable {
    public var a, b, c, d, tx, ty: Double       // x' = a·x + c·y + tx,  y' = b·x + d·y + ty
    public func apply(_ x: Double, _ y: Double) -> (x: Double, y: Double) { (a * x + c * y + tx, b * x + d * y + ty) }
}

public enum LayerGeometry {
    /// - Parameters:
    ///   - canvasAspect: target width / height.
    ///   - contentAspect: media width / height, or nil for layers that cover the canvas.
    public static func affine(canvasAspect: Double, contentAspect: Double?, scaling: ScalingMode,
                              positionX: Double, positionY: Double, scale: Double, rotationDegrees: Double) -> Affine2D {
        // Work in "aspect space": canvas height = 2, width = 2·canvasAspect, so rotation stays undistorted.
        let canvasW = 2 * canvasAspect, canvasH = 2.0
        var w = canvasW, h = canvasH
        if let ca = contentAspect, ca > 0, scaling != .stretch {
            let wider = ca > canvasAspect
            switch scaling {
            case .fill: // cover: the long side overflows
                if wider { h = canvasH; w = canvasH * ca } else { w = canvasW; h = canvasW / ca }
            case .fit:  // contain: the short side leaves bars
                if wider { w = canvasW; h = canvasW / ca } else { h = canvasH; w = canvasH * ca }
            case .stretch: break
            }
        }
        w *= scale; h *= scale
        let theta = -rotationDegrees * .pi / 180            // clockwise
        let cosT = cos(theta), sinT = sin(theta)
        // local → aspect space (scale, rotate, translate) → NDC (divide x by canvasAspect)
        let ax = positionX * canvasAspect, ay = positionY
        return Affine2D(a: w * cosT / canvasAspect, b: w * sinT,
                        c: -h * sinT / canvasAspect, d: h * cosT,
                        tx: ax / canvasAspect, ty: ay)
    }
}
