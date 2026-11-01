import Foundation

public enum SceneError: Error, Equatable, LocalizedError, Sendable {
    case tooLarge
    case malformed(String)
    case unsupportedVersion(Int)
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .tooLarge: "The scene file is too large."
        case .malformed(let m): "The scene file is not valid JSON: \(m)"
        case .unsupportedVersion(let v): "Scene version \(v) is not supported by this app."
        case .invalid(let m): "Invalid scene: \(m)"
        }
    }
}

public enum SceneCodec {
    public static let maxBytes = 1_000_000
    public static let maxLayers = 64
    public static let fileExtension = "wsscene"

    public static func encode(_ scene: Scene) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(scene)
    }

    /// Decodes and validates untrusted scene data.
    public static func decode(_ data: Data) throws -> Scene {
        guard data.count <= maxBytes else { throw SceneError.tooLarge }
        let scene: Scene
        do { scene = try JSONDecoder().decode(Scene.self, from: data) }
        catch { throw SceneError.malformed(String(describing: error).prefix(160).description) }
        try validate(scene)
        return scene
    }

    public static func validate(_ scene: Scene) throws {
        guard scene.version == Scene.currentVersion else { throw SceneError.unsupportedVersion(scene.version) }
        guard scene.background.isValid else { throw SceneError.invalid("background colour out of range") }
        guard scene.layers.count <= maxLayers else { throw SceneError.invalid("more than \(maxLayers) layers") }
        guard scene.totalParticles <= 2 * ParticleSpec.maxCount else { throw SceneError.invalid("too many particles in total") }
        guard scene.zones.count <= 32 else { throw SceneError.invalid("more than 32 interaction zones") }
        let layerIDs = Set(scene.layers.map(\.id))
        var zoneIDs = Set<String>()
        for z in scene.zones {
            guard !z.id.isEmpty, zoneIDs.insert(z.id).inserted else { throw SceneError.invalid("duplicate or empty zone id “\(z.id)”") }
            guard layerIDs.contains(z.layerID) else { throw SceneError.invalid("zone “\(z.id)” points at a layer that does not exist") }
            guard [z.x, z.y, z.width, z.height, z.amount].allSatisfy(\.isFinite), z.width > 0, z.height > 0,
                  z.x >= 0, z.y >= 0, z.x + z.width <= 1.0001, z.y + z.height <= 1.0001 else {
                throw SceneError.invalid("zone “\(z.id)” has an invalid rectangle")
            }
        }
        var ids = Set<String>()
        for l in scene.layers {
            guard !l.id.isEmpty, ids.insert(l.id).inserted else { throw SceneError.invalid("duplicate or empty layer id “\(l.id)”") }
            guard l.content.color.isValid, l.content.color2.isValid, l.effects.lightColor.isValid else {
                throw SceneError.invalid("layer “\(l.id)” has a colour out of range")
            }
            switch l.content.kind {
            case .image, .video:
                guard let asset = l.content.asset, SafeFileName.isSafe(asset) else {
                    throw SceneError.invalid("layer “\(l.id)” needs a plain asset file name")
                }
            case .procedural:
                guard l.content.procedural != nil else { throw SceneError.invalid("layer “\(l.id)” has no procedural kind") }
            case .visualizer:
                guard let v = l.content.visualizer, v.isValid else { throw SceneError.invalid("layer “\(l.id)” has invalid visualizer settings") }
            case .particles:
                guard let p = l.content.particles else { throw SceneError.invalid("layer “\(l.id)” has no particle settings") }
                guard (1...ParticleSpec.maxCount).contains(p.count), p.allNumbers.allSatisfy(\.isFinite),
                      p.lifetimeMin > 0, p.lifetimeMax >= p.lifetimeMin, p.speedMax >= p.speedMin, p.pointerRadius > 0,
                      p.colorStart.isValid, p.colorEnd.isValid, p.burstCount >= 0, p.burstCount <= p.count, p.beatBurstCount >= 0, p.beatBurstCount <= p.count else {
                    throw SceneError.invalid("layer “\(l.id)” has invalid particle settings")
                }
            case .color, .gradient: break
            }
            if let depth = l.depthAsset, !SafeFileName.isSafe(depth) { throw SceneError.invalid("layer “\(l.id)” has an unsafe depth map name") }
            let numbers: [Double] = [l.opacity, l.positionX, l.positionY, l.scale, l.rotation, l.parallaxDepth, l.content.speed, l.content.scale,
                                     l.effects.hueShift, l.effects.hueCycle, l.effects.brightness, l.effects.contrast, l.effects.saturation,
                                     l.effects.vignette, l.effects.vignetteRadius, l.effects.rippleAmplitude, l.effects.rippleFrequency,
                                     l.effects.rippleSpeed, l.effects.lightIntensity, l.effects.lightX, l.effects.lightY,
                                     l.effects.lightRadius, l.effects.lightFlicker]
            guard numbers.allSatisfy(\.isFinite) else { throw SceneError.invalid("layer “\(l.id)” has a non-finite number") }
            guard l.bindings.count <= 16, l.bindings.allSatisfy({ $0.gain.isFinite }) else {
                throw SceneError.invalid("layer “\(l.id)” has invalid input bindings")
            }
            guard l.scale > 0 else { throw SceneError.invalid("layer “\(l.id)” needs a positive scale") }
            guard l.tracks.count <= 32 else { throw SceneError.invalid("layer “\(l.id)” has too many tracks") }
            for t in l.tracks {
                guard t.keyframes.count <= 1000, t.duration.isFinite, t.duration >= 0,
                      t.keyframes.allSatisfy({ $0.time.isFinite && $0.value.isFinite && $0.time >= 0 }) else {
                    throw SceneError.invalid("layer “\(l.id)” has an invalid animation track")
                }
            }
        }
    }
}
