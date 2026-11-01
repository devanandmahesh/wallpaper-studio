import Foundation

extension SceneLayer {
    /// The stored (un-animated) value of an animatable property.
    public func baseValue(_ property: AnimatableProperty) -> Double {
        switch property {
        case .positionX: positionX
        case .positionY: positionY
        case .scale: scale
        case .rotation: rotation
        case .opacity: opacity
        case .hueShift: effects.hueShift
        case .brightness: effects.brightness
        case .saturation: effects.saturation
        case .vignette: effects.vignette
        case .rippleAmplitude: effects.rippleAmplitude
        case .lightX: effects.lightX
        case .lightY: effects.lightY
        case .lightIntensity: effects.lightIntensity
        case .lightRadius: effects.lightRadius
        }
    }

    public mutating func setBase(_ property: AnimatableProperty, _ v: Double) {
        switch property {
        case .positionX: positionX = v
        case .positionY: positionY = v
        case .scale: scale = v
        case .rotation: rotation = v
        case .opacity: opacity = v
        case .hueShift: effects.hueShift = v
        case .brightness: effects.brightness = v
        case .saturation: effects.saturation = v
        case .vignette: effects.vignette = v
        case .rippleAmplitude: effects.rippleAmplitude = v
        case .lightX: effects.lightX = v
        case .lightY: effects.lightY = v
        case .lightIntensity: effects.lightIntensity = v
        case .lightRadius: effects.lightRadius = v
        }
    }
}

extension AnimatableProperty {
    public var label: String {
        switch self {
        case .positionX: "Position X"
        case .positionY: "Position Y"
        case .scale: "Scale"
        case .rotation: "Rotation"
        case .opacity: "Opacity"
        case .hueShift: "Hue shift"
        case .brightness: "Brightness"
        case .saturation: "Saturation"
        case .vignette: "Vignette"
        case .rippleAmplitude: "Ripple"
        case .lightX: "Light X"
        case .lightY: "Light Y"
        case .lightIntensity: "Light intensity"
        case .lightRadius: "Light radius"
        }
    }
}

extension InputSource {
    public var label: String {
        switch self {
        case .pointerX: "Mouse X"
        case .pointerY: "Mouse Y"
        case .pointerSpeed: "Mouse speed"
        case .clickPulse: "Click pulse"
        case .keyPulse: "Typing"
        case .audioLevel: "Audio level"
        case .audioBass: "Bass"
        case .audioMid: "Mid"
        case .audioTreble: "Treble"
        case .audioBeat: "Beat"
        }
    }
}

public enum EditorError: Error, Equatable, LocalizedError, Sendable {
    case noSuchLayer(String)
    case invalid(String)
    public var errorDescription: String? {
        switch self {
        case .noSuchLayer(let id): "There is no layer “\(id)”."
        case .invalid(let m): m
        }
    }
}

/// The scene being edited plus every editing operation. Pure value type: the editor UI calls these, history snapshots it,
/// and nothing here touches the GPU or the file system, so all of it is testable.
public struct EditorDocument: Equatable, Sendable {
    public static let minimumDuration = 1.0
    public static let maximumDuration = 600.0

    public var scene: Scene
    /// Length of the timeline in seconds.
    public var duration: Double

    public init(scene: Scene, duration: Double = 10) {
        self.scene = scene
        self.duration = min(max(duration, Self.minimumDuration), Self.maximumDuration)
    }

    public static func blank(name: String = "Untitled") -> EditorDocument {
        EditorDocument(scene: Scene(name: name, background: RGBA(0.02, 0.02, 0.05), layers: [
            SceneLayer(id: "background", name: "Background", content: .gradient(top: RGBA(0.05, 0.08, 0.2), bottom: RGBA(0.02, 0.02, 0.06))),
        ]))
    }

    // MARK: Layers

    public func layer(_ id: String) -> SceneLayer? { scene.layers.first { $0.id == id } }
    public func index(of id: String) -> Int? { scene.layers.firstIndex { $0.id == id } }

    public static func uniqueID(prefix: String, in existing: Set<String>) -> String {
        var n = 1
        while existing.contains("\(prefix)-\(n)") { n += 1 }
        return "\(prefix)-\(n)"
    }

    private var layerIDs: Set<String> { Set(scene.layers.map(\.id)) }

    @discardableResult
    public mutating func addLayer(_ content: LayerContent, name: String? = nil, blend: BlendMode = .normal, at index: Int? = nil) -> String {
        let prefix: String
        switch content.kind {
        case .color: prefix = "color"
        case .gradient: prefix = "gradient"
        case .image: prefix = "image"
        case .video: prefix = "video"
        case .procedural: prefix = "pattern"
        case .particles: prefix = "particles"
        case .visualizer: prefix = "audio"
        }
        let id = Self.uniqueID(prefix: prefix, in: layerIDs)
        let layer = SceneLayer(id: id, name: name ?? id, content: content, blend: blend)
        scene.layers.insert(layer, at: min(max(index ?? scene.layers.count, 0), scene.layers.count))
        return id
    }

    public mutating func removeLayer(_ id: String) {
        scene.layers.removeAll { $0.id == id }
        scene.zones.removeAll { $0.layerID == id }          // zones cannot outlive their layer
    }

    @discardableResult
    public mutating func duplicateLayer(_ id: String) -> String? {
        guard let i = index(of: id) else { return nil }
        var copy = scene.layers[i]
        let base = id.replacingOccurrences(of: #"-\d+$"#, with: "", options: .regularExpression)
        copy.id = Self.uniqueID(prefix: base, in: layerIDs)
        copy.name = scene.layers[i].name + " copy"
        scene.layers.insert(copy, at: i + 1)
        return copy.id
    }

    /// Moves a layer to `newIndex` in drawing order (0 = bottom).
    public mutating func moveLayer(_ id: String, to newIndex: Int) {
        guard let i = index(of: id) else { return }
        let layer = scene.layers.remove(at: i)
        scene.layers.insert(layer, at: min(max(newIndex, 0), scene.layers.count))
    }

    public mutating func update(_ id: String, _ change: (inout SceneLayer) -> Void) {
        guard let i = index(of: id) else { return }
        change(&scene.layers[i])
        scene.layers[i].scale = max(scene.layers[i].scale, 0.001)          // the codec rejects non-positive scales
    }

    public mutating func setBase(layer id: String, _ property: AnimatableProperty, _ value: Double) {
        update(id) { $0.setBase(property, value) }
    }

    // MARK: Keyframes

    private static func trackIndex(_ layer: SceneLayer, _ property: AnimatableProperty) -> Int? { layer.tracks.firstIndex { $0.property == property } }

    /// Adds a keyframe, or replaces the one at (almost) the same time.
    public mutating func setKeyframe(layer id: String, property: AnimatableProperty, time: Double, value: Double, easing: Easing = .linear) {
        let t = min(max(time, 0), duration), length = duration
        update(id) { layer in
            if let ti = Self.trackIndex(layer, property) {
                var track = layer.tracks[ti]
                if let ki = track.keyframes.firstIndex(where: { abs($0.time - t) < 0.0005 }) {
                    track.keyframes[ki] = Keyframe(time: t, value: value, easing: track.keyframes[ki].easing)
                } else {
                    track.keyframes.append(Keyframe(time: t, value: value, easing: easing))
                    track.keyframes.sort { $0.time < $1.time }
                }
                layer.tracks[ti] = track
            } else {
                layer.tracks.append(Track(property: property, keyframes: [Keyframe(time: t, value: value, easing: easing)], loop: .loop, duration: length))
            }
        }
    }

    /// The value of a property at a time, as the player would show it (animation included, inputs excluded).
    public func value(layer id: String, property: AnimatableProperty, at time: Double) -> Double? {
        guard let l = layer(id) else { return nil }
        return l.tracks.first { $0.property == property }?.value(at: time) ?? l.baseValue(property)
    }

    public mutating func removeKeyframe(layer id: String, property: AnimatableProperty, index ki: Int) {
        update(id) { layer in
            guard let ti = Self.trackIndex(layer, property), layer.tracks[ti].keyframes.indices.contains(ki) else { return }
            layer.tracks[ti].keyframes.remove(at: ki)
            if layer.tracks[ti].keyframes.isEmpty { layer.tracks.remove(at: ti) }        // an empty track would be meaningless
        }
    }

    /// Moves a keyframe in time; returns its new index (the list stays sorted).
    @discardableResult
    public mutating func moveKeyframe(layer id: String, property: AnimatableProperty, index ki: Int, to time: Double) -> Int? {
        var newIndex: Int?
        let t = min(max(time, 0), duration)
        update(id) { layer in
            guard let ti = Self.trackIndex(layer, property), layer.tracks[ti].keyframes.indices.contains(ki) else { return }
            var key = layer.tracks[ti].keyframes.remove(at: ki)
            key.time = t
            layer.tracks[ti].keyframes.append(key)
            layer.tracks[ti].keyframes.sort { $0.time < $1.time }
            newIndex = layer.tracks[ti].keyframes.firstIndex { $0.time == t && $0.value == key.value }
        }
        return newIndex
    }

    public mutating func setKeyframeValue(layer id: String, property: AnimatableProperty, index ki: Int, value: Double) {
        update(id) { layer in
            guard let ti = Self.trackIndex(layer, property), layer.tracks[ti].keyframes.indices.contains(ki) else { return }
            layer.tracks[ti].keyframes[ki].value = value
        }
    }

    public mutating func setEasing(layer id: String, property: AnimatableProperty, index ki: Int, easing: Easing) {
        update(id) { layer in
            guard let ti = Self.trackIndex(layer, property), layer.tracks[ti].keyframes.indices.contains(ki) else { return }
            layer.tracks[ti].keyframes[ki].easing = easing
        }
    }

    public mutating func setLoop(layer id: String, property: AnimatableProperty, loop: LoopMode) {
        update(id) { layer in
            guard let ti = Self.trackIndex(layer, property) else { return }
            layer.tracks[ti].loop = loop
        }
    }

    /// Changes the timeline length. Tracks that cycle over the whole timeline follow it.
    public mutating func setDuration(_ seconds: Double) {
        let old = duration
        duration = min(max(seconds, Self.minimumDuration), Self.maximumDuration)
        for i in scene.layers.indices {
            for t in scene.layers[i].tracks.indices where abs(scene.layers[i].tracks[t].duration - old) < 0.0005 {
                scene.layers[i].tracks[t].duration = duration
            }
        }
    }

    // MARK: Bindings and zones

    public mutating func addBinding(layer id: String, _ binding: InputBinding) {
        update(id) { if $0.bindings.count < 16 { $0.bindings.append(binding) } }
    }

    public mutating func removeBinding(layer id: String, index: Int) {
        update(id) { if $0.bindings.indices.contains(index) { $0.bindings.remove(at: index) } }
    }

    @discardableResult
    public mutating func addZone(layerID: String, property: AnimatableProperty = .lightIntensity, amount: Double = 0.5) -> String? {
        guard layer(layerID) != nil, scene.zones.count < 32 else { return nil }
        let id = Self.uniqueID(prefix: "zone", in: Set(scene.zones.map(\.id)))
        scene.zones.append(InteractionZone(id: id, x: 0.35, y: 0.35, width: 0.3, height: 0.3, layerID: layerID, property: property, amount: amount))
        return id
    }

    public mutating func updateZone(_ id: String, _ change: (inout InteractionZone) -> Void) {
        guard let i = scene.zones.firstIndex(where: { $0.id == id }) else { return }
        change(&scene.zones[i])
        var z = scene.zones[i]                                   // keep the rectangle on the canvas
        z.width = min(max(z.width, 0.01), 1); z.height = min(max(z.height, 0.01), 1)
        z.x = min(max(z.x, 0), 1 - z.width); z.y = min(max(z.y, 0), 1 - z.height)
        scene.zones[i] = z
    }

    public mutating func removeZone(_ id: String) { scene.zones.removeAll { $0.id == id } }

    public func validate() throws { try SceneCodec.validate(scene) }
}

/// Undo/redo over any equatable state. Rapid edits of the same kind (dragging a slider) share a `coalescingKey` and
/// become one undo step.
public struct EditorHistory<State: Equatable & Sendable>: Sendable {
    public var limit = 100
    public private(set) var undoStack: [State] = []
    public private(set) var redoStack: [State] = []
    private var lastKey: String?
    private var lastTime = -Double.infinity
    public static var coalescingWindow: Double { 1.0 }

    public init() {}

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// Call before applying a change, passing the state as it is *now*.
    public mutating func willChange(from state: State, key: String? = nil, at time: Double = 0) {
        if let key, key == lastKey, time - lastTime < Self.coalescingWindow, !undoStack.isEmpty {
            lastTime = time                                       // same drag continues: keep the earlier snapshot
            return
        }
        undoStack.append(state)
        if undoStack.count > limit { undoStack.removeFirst(undoStack.count - limit) }
        redoStack.removeAll()
        lastKey = key
        lastTime = time
    }

    public mutating func undo(current: State) -> State? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(current)
        lastKey = nil
        return previous
    }

    public mutating func redo(current: State) -> State? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(next == current ? current : current)
        lastKey = nil
        return next
    }

    public mutating func clear() { undoStack.removeAll(); redoStack.removeAll(); lastKey = nil }
}

/// A fake but lively audio signal, so audio-reactive scenes can be previewed in the editor without capturing anything.
public enum SyntheticAudio {
    public static func frame(at t: Double) -> AudioFrame {
        let bands = (0..<AudioFrame.bandCount).map { i -> Float in
            let phase = Double(i) * 0.45 - t * 2.2
            let tilt = 1 - Double(i) / Double(AudioFrame.bandCount) * 0.6
            return Float(max(0, min(1, (0.5 + 0.5 * sin(phase)) * tilt * (0.6 + 0.4 * sin(t * 0.7 + Double(i) * 0.2)))))
        }
        let wave = (0..<AudioFrame.waveformCount).map { Float(0.6 * sin(t * 6 + Double($0) * 0.35) * (0.5 + 0.5 * sin(t * 1.3))) }
        let kick = max(0, cos(t * 2 * .pi * 2))                      // 120 bpm
        let pulse = Float(pow(kick, 6))
        return AudioFrame(bands: bands, waveform: wave, bass: 0.35 + 0.5 * pulse, mid: Float(0.3 + 0.2 * sin(t)), treble: Float(0.25 + 0.15 * sin(t * 2.3)),
                          level: 0.4 + 0.35 * pulse, beat: pulse, beatSerial: Int(floor(t * 2)))
    }
}

/// Starting points for the particle layer.
public enum ParticlePreset: String, CaseIterable, Sendable {
    case fireflies, snow, sparks, bubbles, dust

    public var label: String {
        switch self { case .fireflies: "Fireflies"; case .snow: "Snow"; case .sparks: "Sparks"; case .bubbles: "Bubbles"; case .dust: "Dust" }
    }

    public var spec: ParticleSpec {
        var p = ParticleSpec()
        switch self {
        case .fireflies:
            p.count = 220; p.lifetimeMin = 5; p.lifetimeMax = 11; p.speedMin = 0.01; p.speedMax = 0.05; p.turbulence = 0.06; p.drag = 0.35
            p.sizeStart = 0.012; p.sizeEnd = 0.004; p.colorStart = RGBA(1, 0.92, 0.45, 0.95); p.colorEnd = RGBA(0.6, 1, 0.3, 0)
            p.pointerMode = .attract; p.pointerRadius = 0.7; p.burstCount = 30
        case .snow:
            p.count = 700; p.lifetimeMin = 9; p.lifetimeMax = 15; p.emitterY = 1.08; p.emitterHalfWidth = 1.1; p.emitterHalfHeight = 0.04
            p.directionDegrees = -90; p.spreadDegrees = 40; p.speedMin = 0.04; p.speedMax = 0.12; p.turbulence = 0.03
            p.sizeStart = 0.008; p.sizeEnd = 0.007; p.colorStart = RGBA(1, 1, 1, 0.9); p.colorEnd = RGBA(0.8, 0.9, 1, 0.7)
            p.pointerMode = .repel; p.pointerRadius = 0.45
        case .sparks:
            p.count = 500; p.shape = .point; p.emitterY = -0.9; p.lifetimeMin = 0.8; p.lifetimeMax = 2; p.directionDegrees = 90; p.spreadDegrees = 50
            p.speedMin = 0.3; p.speedMax = 0.8; p.gravityY = -0.5; p.drag = 0.4; p.sizeStart = 0.01; p.sizeEnd = 0
            p.colorStart = RGBA(1, 0.8, 0.3, 1); p.colorEnd = RGBA(1, 0.2, 0.05, 0)
        case .bubbles:
            p.count = 120; p.lifetimeMin = 6; p.lifetimeMax = 12; p.emitterY = -1.05; p.emitterHalfHeight = 0.03; p.directionDegrees = 90; p.spreadDegrees = 20
            p.speedMin = 0.06; p.speedMax = 0.16; p.turbulence = 0.05; p.sizeStart = 0.025; p.sizeEnd = 0.03; p.sizeJitter = 0.6
            p.colorStart = RGBA(0.7, 0.9, 1, 0.35); p.colorEnd = RGBA(0.8, 0.95, 1, 0.1); p.pointerMode = .repel; p.pointerRadius = 0.35
        case .dust:
            p.count = 400; p.lifetimeMin = 8; p.lifetimeMax = 16; p.speedMin = 0.003; p.speedMax = 0.02; p.turbulence = 0.02
            p.sizeStart = 0.006; p.sizeEnd = 0.004; p.colorStart = RGBA(1, 0.95, 0.85, 0.5); p.colorEnd = RGBA(1, 0.95, 0.85, 0.1)
        }
        return p
    }
}
