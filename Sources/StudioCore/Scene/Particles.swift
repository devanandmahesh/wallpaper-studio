import Foundation
import simd

public enum EmitterShape: String, Codable, Sendable, CaseIterable { case point, box, pointer }
public enum PointerMode: String, Codable, Sendable, CaseIterable { case none, attract, repel, swirl }

extension KeyedDecodingContainer {
    /// Decodes a value or falls back to a default, so hand-written files and older files keep working.
    func value<T: Decodable>(_ key: Key, _ fallback: T) throws -> T { try decodeIfPresent(T.self, forKey: key) ?? fallback }
}

/// A GPU particle system. Positions are in normalised canvas coordinates: x and y run -1...1, y up.
/// Sizes and the pointer radius are fractions of half the canvas height.
public struct ParticleSpec: Codable, Equatable, Sendable {
    public static let maxCount = 50_000
    public static let simAspect: Float = 16.0 / 9.0       // distances are measured as on a 16:9 canvas on every display

    public var count = 1500
    public var lifetimeMin = 3.0
    public var lifetimeMax = 6.0
    public var shape = EmitterShape.box
    public var emitterX = 0.0
    public var emitterY = 0.0
    public var emitterHalfWidth = 1.0
    public var emitterHalfHeight = 1.0
    public var directionDegrees = 90.0            // 0 = right, 90 = up (counter-clockwise)
    public var spreadDegrees = 360.0
    public var speedMin = 0.02
    public var speedMax = 0.10
    public var gravityX = 0.0
    public var gravityY = 0.0
    public var drag = 0.0                         // fraction of velocity lost per second
    public var turbulence = 0.0
    public var sizeStart = 0.012
    public var sizeEnd = 0.012
    public var sizeJitter = 0.3
    public var colorStart = RGBA(1, 0.9, 0.5, 1)
    public var colorEnd = RGBA(1, 0.5, 0.2, 0)
    public var pointerMode = PointerMode.none
    public var pointerStrength = 1.5
    public var pointerRadius = 0.5
    public var burstCount = 0                     // particles launched by each mouse click
    public var burstSpeed = 0.6
    public var keyGain = 0.0                      // typing makes particles swell by this factor
    public var audioSizeGain = 0.0                // bass makes particles swell by this factor
    public var beatBurstCount = 0                 // particles launched from the emitter on every detected beat
    public var seed: UInt32 = 1
    public var prewarm = true                     // start in a steady state instead of emitting from nothing

    public init() {}

    /// Does this system react to the pointer (so the app has to track it)?
    public var reactsToPointer: Bool { pointerMode != .none || shape == .pointer || burstCount > 0 }

    enum CodingKeys: String, CodingKey {
        case count, lifetimeMin, lifetimeMax, shape, emitterX, emitterY, emitterHalfWidth, emitterHalfHeight
        case directionDegrees, spreadDegrees, speedMin, speedMax, gravityX, gravityY, drag, turbulence
        case sizeStart, sizeEnd, sizeJitter, colorStart, colorEnd, pointerMode, pointerStrength, pointerRadius
        case burstCount, burstSpeed, keyGain, audioSizeGain, beatBurstCount, seed, prewarm
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ParticleSpec()
        count = try c.value(.count, d.count); lifetimeMin = try c.value(.lifetimeMin, d.lifetimeMin); lifetimeMax = try c.value(.lifetimeMax, d.lifetimeMax)
        shape = try c.value(.shape, d.shape); emitterX = try c.value(.emitterX, d.emitterX); emitterY = try c.value(.emitterY, d.emitterY)
        emitterHalfWidth = try c.value(.emitterHalfWidth, d.emitterHalfWidth); emitterHalfHeight = try c.value(.emitterHalfHeight, d.emitterHalfHeight)
        directionDegrees = try c.value(.directionDegrees, d.directionDegrees); spreadDegrees = try c.value(.spreadDegrees, d.spreadDegrees)
        speedMin = try c.value(.speedMin, d.speedMin); speedMax = try c.value(.speedMax, d.speedMax)
        gravityX = try c.value(.gravityX, d.gravityX); gravityY = try c.value(.gravityY, d.gravityY)
        drag = try c.value(.drag, d.drag); turbulence = try c.value(.turbulence, d.turbulence)
        sizeStart = try c.value(.sizeStart, d.sizeStart); sizeEnd = try c.value(.sizeEnd, d.sizeEnd); sizeJitter = try c.value(.sizeJitter, d.sizeJitter)
        colorStart = try c.value(.colorStart, d.colorStart); colorEnd = try c.value(.colorEnd, d.colorEnd)
        pointerMode = try c.value(.pointerMode, d.pointerMode); pointerStrength = try c.value(.pointerStrength, d.pointerStrength)
        pointerRadius = try c.value(.pointerRadius, d.pointerRadius)
        burstCount = try c.value(.burstCount, d.burstCount); burstSpeed = try c.value(.burstSpeed, d.burstSpeed)
        keyGain = try c.value(.keyGain, d.keyGain); audioSizeGain = try c.value(.audioSizeGain, d.audioSizeGain)
        beatBurstCount = try c.value(.beatBurstCount, d.beatBurstCount); seed = try c.value(.seed, d.seed); prewarm = try c.value(.prewarm, d.prewarm)
    }

    var allNumbers: [Double] {
        [lifetimeMin, lifetimeMax, emitterX, emitterY, emitterHalfWidth, emitterHalfHeight, directionDegrees, spreadDegrees,
         speedMin, speedMax, gravityX, gravityY, drag, turbulence, sizeStart, sizeEnd, sizeJitter,
         pointerStrength, pointerRadius, burstSpeed, keyGain, audioSizeGain]
    }
}

/// One particle as stored in the GPU buffer (32 bytes). A negative `age` means "not emitted yet".
public struct ParticleState: Equatable, Sendable {
    public var position: SIMD2<Float> = .zero
    public var velocity: SIMD2<Float> = .zero
    public var age: Float = 0
    public var life: Float = 1
    public var size: Float = 1
    public var generation: UInt32 = 0
    public init() {}
}

public struct ParticleFrame: Sendable {
    public var dt: Float
    public var time: Float
    public var pointer: SIMD2<Float>
    public var pointerActive: Bool
    public var burstPosition: SIMD2<Float>
    public var burstStart: UInt32
    public var burstCount: UInt32
    public var initialize: Bool
    public init(dt: Float, time: Float, pointer: SIMD2<Float> = .zero, pointerActive: Bool = false,
                burstPosition: SIMD2<Float> = .zero, burstStart: UInt32 = 0, burstCount: UInt32 = 0, initialize: Bool = false) {
        self.dt = dt; self.time = time; self.pointer = pointer; self.pointerActive = pointerActive
        self.burstPosition = burstPosition; self.burstStart = burstStart; self.burstCount = burstCount; self.initialize = initialize
    }
}

/// CPU twin of the GPU particle kernel. It is the readable specification of the physics, the fallback for tests,
/// and the reference the GPU output is checked against. Keep it line-for-line equal to `particleUpdate` in the shader.
public enum ParticleReference {
    // Integer hash (PCG): identical on CPU and GPU, so both draw the same "random" numbers.
    static func pcg(_ v: UInt32) -> UInt32 {
        let state = v &* 747796405 &+ 2891336453
        let word = ((state >> ((state >> 28) &+ 4)) ^ state) &* 277803737
        return (word >> 22) ^ word
    }

    public static func rand(_ id: UInt32, _ gen: UInt32, _ seed: UInt32, _ k: UInt32) -> Float {
        let h = pcg(seed &+ pcg(id &+ pcg(gen &* 16 &+ k)))
        return Float(h >> 8) * (1.0 / 16777216.0)
    }

    private static func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }

    static func spawn(_ p: inout ParticleState, id: UInt32, spec s: ParticleSpec, frame f: ParticleFrame) {
        let seed = s.seed, gen = p.generation
        p.life = lerp(Float(s.lifetimeMin), Float(s.lifetimeMax), rand(id, gen, seed, 0))
        switch s.shape {
        case .point:
            p.position = SIMD2(Float(s.emitterX), Float(s.emitterY))
        case .box:
            p.position = SIMD2(Float(s.emitterX) + (rand(id, gen, seed, 1) * 2 - 1) * Float(s.emitterHalfWidth),
                               Float(s.emitterY) + (rand(id, gen, seed, 2) * 2 - 1) * Float(s.emitterHalfHeight))
        case .pointer:
            p.position = f.pointerActive ? f.pointer : SIMD2(9, 9)             // parked off-canvas until there is a pointer
        }
        let angle = (Float(s.directionDegrees) + (rand(id, gen, seed, 3) - 0.5) * Float(s.spreadDegrees)) * Float.pi / 180
        let speed = lerp(Float(s.speedMin), Float(s.speedMax), rand(id, gen, seed, 4))
        p.velocity = speed * SIMD2(cos(angle), sin(angle))
        p.size = 1 + (rand(id, gen, seed, 5) * 2 - 1) * Float(s.sizeJitter)
    }

    static func burstSpawn(_ p: inout ParticleState, id: UInt32, spec s: ParticleSpec, frame f: ParticleFrame) {
        let seed = s.seed, gen = p.generation
        p.life = lerp(Float(s.lifetimeMin), Float(s.lifetimeMax), rand(id, gen, seed, 0))
        p.position = f.burstPosition
        let angle = rand(id, gen, seed, 3) * 2 * Float.pi
        let speed = Float(s.burstSpeed) * (0.4 + 0.6 * rand(id, gen, seed, 4))
        p.velocity = speed * SIMD2(cos(angle), sin(angle))
        p.size = 1 + (rand(id, gen, seed, 5) * 2 - 1) * Float(s.sizeJitter)
        p.age = 0
    }

    public static func initialState(spec s: ParticleSpec, frame f: ParticleFrame) -> [ParticleState] {
        (0..<UInt32(s.count)).map { id in
            var p = ParticleState()
            spawn(&p, id: id, spec: s, frame: f)
            let r = rand(id, 0, s.seed, 6)
            if s.prewarm {
                p.age = r * p.life
                let g = SIMD2(Float(s.gravityX), Float(s.gravityY))
                p.position += p.velocity * p.age + 0.5 * g * p.age * p.age        // as if it had already been flying
            } else {
                p.age = -r * p.life                                                // staggered start
            }
            return p
        }
    }

    public static func step(_ states: inout [ParticleState], spec s: ParticleSpec, frame f: ParticleFrame) {
        let n = UInt32(states.count)
        let aspect = ParticleSpec.simAspect
        let gravity = SIMD2(Float(s.gravityX), Float(s.gravityY))
        for i in 0..<states.count {
            let id = UInt32(i)
            var p = states[i]
            if f.burstCount > 0 && ((id &- f.burstStart &+ n) % n) < f.burstCount {
                p.generation &+= 1
                burstSpawn(&p, id: id, spec: s, frame: f)
            }
            p.age += f.dt
            if p.age < 0 { states[i] = p; continue }
            if p.age >= p.life {
                p.generation &+= 1
                spawn(&p, id: id, spec: s, frame: f)
                p.age = 0
            }
            var a = gravity
            if s.turbulence != 0 {
                let phase = Float(pcg(id)) * (1.0 / 4294967296.0) * 6.2831853
                a += Float(s.turbulence) * SIMD2(sin(p.position.y * 7 + f.time * 1.3 + phase), cos(p.position.x * 7 + f.time * 1.1 + phase))
            }
            if s.pointerMode != .none && f.pointerActive {
                let d = (p.position - f.pointer) * SIMD2(aspect, 1)
                let r = simd_length(d)
                let radius = Float(s.pointerRadius)
                if r < radius && r > 0.0001 {
                    let k = (1 - r / radius) * (1 - r / radius) * Float(s.pointerStrength)
                    let dir = d / r
                    switch s.pointerMode {
                    case .attract: a -= dir * k
                    case .repel: a += dir * k
                    case .swirl: a += SIMD2(-dir.y, dir.x) * k
                    case .none: break
                    }
                }
            }
            p.velocity += a * f.dt
            p.velocity *= exp(-Float(s.drag) * f.dt)
            p.position += p.velocity * f.dt
            states[i] = p
        }
    }
}
