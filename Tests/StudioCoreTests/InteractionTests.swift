import Testing
import Foundation
import CoreGraphics
import simd
@testable import StudioCore

@Suite struct PointerMathTests {
    let screen = CGRect(x: 100, y: 50, width: 200, height: 100)

    @Test func mapsCornersAndCentreWithYUp() throws {
        let c = try #require(PointerMapper.normalize(location: CGPoint(x: 200, y: 100), screen: screen, rotation: .r0))
        #expect(abs(c.x) < 1e-9 && abs(c.y) < 1e-9)
        let topRight = try #require(PointerMapper.normalize(location: CGPoint(x: 299.999, y: 149.999), screen: screen, rotation: .r0))
        #expect(topRight.x > 0.99 && topRight.y > 0.99)
        let bottomLeft = try #require(PointerMapper.normalize(location: CGPoint(x: 100, y: 50), screen: screen, rotation: .r0))
        #expect(abs(bottomLeft.x + 1) < 1e-9 && abs(bottomLeft.y + 1) < 1e-9)
    }

    @Test func cursorOutsideTheDisplayIsNil() {
        #expect(PointerMapper.normalize(location: CGPoint(x: 0, y: 0), screen: screen, rotation: .r0) == nil)
        #expect(PointerMapper.normalize(location: CGPoint(x: 300, y: 100), screen: screen, rotation: .r0) == nil)   // max edge is exclusive
    }

    @Test func rotatedDisplaysMapTheCursorBackIntoContentSpace() throws {
        // Content turned 90° clockwise: the cursor at the screen's right edge is at the content's top.
        let right = CGPoint(x: 299, y: 100)
        let m = try #require(PointerMapper.normalize(location: right, screen: screen, rotation: .r90))
        #expect(abs(m.x) < 0.02 && m.y > 0.98, "\(m)")
        let half = try #require(PointerMapper.normalize(location: right, screen: screen, rotation: .r180))
        #expect(half.x < -0.98)
    }
}

@Suite struct PointerFilterTests {
    @Test func smoothingLagsBehindThenCatchesUp() {
        var f = PointerFilter()
        f.update(location: CGPoint(x: 0, y: 0), time: 0)
        f.update(location: CGPoint(x: 100, y: 0), time: 0.016)
        #expect(f.smoothed.x > 0 && f.smoothed.x < 100)
        for i in 2..<200 { f.update(location: CGPoint(x: 100, y: 0), time: Double(i) * 0.016) }
        #expect(abs(f.smoothed.x - 100) < 0.5)
        #expect(f.speed < 1)                           // stopped → speed decays to ~0
    }

    @Test func speedMeasuresMovementInPointsPerSecond() {
        var f = PointerFilter()
        for i in 0..<120 { f.update(location: CGPoint(x: Double(i) * 10, y: 0), time: Double(i) * 0.01) }   // 1000 pt/s
        #expect(abs(f.speed - 1000) < 60, "\(f.speed)")
    }

    @Test func clicksCountAndFade() {
        var f = PointerFilter()
        #expect(f.clickSerial == 0 && f.clickPulse(at: 0) == 0)
        f.registerClick(at: CGPoint(x: 5, y: 6), time: 10)
        #expect(f.clickSerial == 1 && f.clickLocation == CGPoint(x: 5, y: 6))
        #expect(f.clickPulse(at: 10) == 1)
        #expect(f.clickPulse(at: 10.45) < 0.4 && f.clickPulse(at: 12) < 0.02)
    }

    @Test func pulseMeterRisesWithEventsAndDecays() {
        var m = PulseMeter()
        #expect(m.value(at: 0) == 0)
        for i in 0..<10 { m.add(at: Double(i) * 0.05) }
        #expect(m.value(at: 0.5) > 0.5 && m.value(at: 0.5) <= 1)
        #expect(m.value(at: 5) < 0.01)
    }
}

@Suite struct BindingTests {
    @Test func bindingsAddInputsToTheAnimatedValue() {
        let layer = SceneLayer(id: "l", content: .solid(.white),
                               effects: { var e = LayerEffects(); e.lightX = 0.5; e.lightIntensity = 1; return e }(),
                               bindings: [InputBinding(source: .pointerX, target: .lightX, gain: 0.5),
                                          InputBinding(source: .keyPulse, target: .brightness, gain: 0.2),
                                          InputBinding(source: .clickPulse, target: .scale, gain: 0.1)])
        let none = SceneEvaluator.resolve(layer, time: 0)
        #expect(none.effects.lightX == 0.5 && none.scale == 1)
        let r = SceneEvaluator.resolve(layer, time: 0, input: SceneInput(pointerX: 1, clickPulse: 1, keyPulse: 1))
        #expect(abs(r.effects.lightX - 1.0) < 1e-9 && abs(r.effects.brightness - 0.2) < 1e-9 && abs(r.scale - 1.1) < 1e-9)
    }

    @Test func bindingsStackOnTopOfTracks() {
        let layer = SceneLayer(id: "l", content: .solid(.white), tracks: [
            Track(property: .opacity, keyframes: [Keyframe(time: 0, value: 0.5), Keyframe(time: 1, value: 0.5)], loop: .once)],
            bindings: [InputBinding(source: .pointerSpeed, target: .opacity, gain: 0.4)])
        #expect(abs(SceneEvaluator.resolve(layer, time: 0, input: SceneInput(pointerSpeed: 1)).opacity - 0.9) < 1e-9)
    }

    @Test func sceneFlagsDetectWhatNeedsTheMouseAndKeyboard() {
        func scene(_ layer: SceneLayer) -> Scene { Scene(name: "s", layers: [layer]) }
        #expect(!scene(SceneLayer(id: "a", content: .solid(.white))).reactsToPointer)
        #expect(scene(SceneLayer(id: "a", content: .solid(.white), bindings: [InputBinding(source: .pointerY, target: .positionY, gain: 0.1)])).reactsToPointer)
        #expect(scene(SceneLayer(id: "a", content: .solid(.white), bindings: [InputBinding(source: .keyPulse, target: .scale, gain: 0.1)])).reactsToKeys)
        var attract = ParticleSpec(); attract.pointerMode = .attract
        #expect(scene(SceneLayer(id: "p", content: .particles(attract))).reactsToPointer)
        var plain = ParticleSpec()
        #expect(!scene(SceneLayer(id: "p", content: .particles(plain))).reactsToPointer)
        plain.keyGain = 0.5
        #expect(scene(SceneLayer(id: "p", content: .particles(plain))).reactsToKeys)
        #expect(scene(SceneLayer(id: "p", content: .particles(ParticleSpec()))).isAnimated)
    }
}

@Suite struct ParticleReferenceTests {
    func frame(dt: Float = 1.0 / 60, time: Float = 0, pointer: SIMD2<Float> = .zero, active: Bool = false) -> ParticleFrame {
        ParticleFrame(dt: dt, time: time, pointer: pointer, pointerActive: active)
    }

    func run(_ spec: ParticleSpec, steps: Int, pointer: SIMD2<Float> = .zero, active: Bool = false) -> [ParticleState] {
        var s = ParticleReference.initialState(spec: spec, frame: frame(pointer: pointer, active: active))
        for i in 0..<steps { ParticleReference.step(&s, spec: spec, frame: frame(time: Float(i) / 60, pointer: pointer, active: active)) }
        return s
    }

    @Test func randomNumbersAreDeterministicAndUniformish() {
        #expect(ParticleReference.rand(1, 2, 3, 4) == ParticleReference.rand(1, 2, 3, 4))
        #expect(ParticleReference.rand(1, 2, 3, 4) != ParticleReference.rand(2, 2, 3, 4))
        let values = (0..<4000).map { ParticleReference.rand(UInt32($0), 0, 7, 0) }
        #expect(values.allSatisfy { $0 >= 0 && $0 < 1 })
        let mean = values.reduce(0, +) / Float(values.count)
        #expect(abs(mean - 0.5) < 0.03)
    }

    @Test func sameSpecAndSeedGiveTheSameParticles() {
        var spec = ParticleSpec(); spec.count = 200
        #expect(run(spec, steps: 30) == run(spec, steps: 30))
        var other = spec; other.seed = 99
        #expect(run(spec, steps: 30) != run(other, steps: 30))
    }

    @Test func gravityPullsParticlesDown() {
        var spec = ParticleSpec(); spec.count = 100; spec.gravityY = -1; spec.speedMin = 0; spec.speedMax = 0
        spec.shape = .point; spec.emitterX = 0; spec.emitterY = 0; spec.lifetimeMin = 10; spec.lifetimeMax = 10; spec.prewarm = false
        var s = ParticleReference.initialState(spec: spec, frame: frame())
        for p in s.indices { s[p].age = 0 }                        // all emitted now
        for _ in 0..<60 { ParticleReference.step(&s, spec: spec, frame: frame()) }
        #expect(s.allSatisfy { $0.position.y < -0.4 && abs($0.position.x) < 0.001 })      // ½·g·t² = 0.5 after one second
    }

    @Test func dragSlowsParticlesDown() {
        var spec = ParticleSpec(); spec.count = 50; spec.shape = .point; spec.speedMin = 1; spec.speedMax = 1; spec.drag = 3
        spec.lifetimeMin = 20; spec.lifetimeMax = 20; spec.prewarm = false
        var s = ParticleReference.initialState(spec: spec, frame: frame())
        for p in s.indices { s[p].age = 0 }
        for _ in 0..<120 { ParticleReference.step(&s, spec: spec, frame: frame()) }
        #expect(s.allSatisfy { simd_length($0.velocity) < 0.1 })
    }

    @Test func staggeredStartKeepsParticlesWaitingAndPrewarmDoesNot() {
        var spec = ParticleSpec(); spec.count = 300
        spec.prewarm = false
        let waiting = ParticleReference.initialState(spec: spec, frame: frame())
        #expect(waiting.allSatisfy { $0.age <= 0 })
        spec.prewarm = true
        let warm = ParticleReference.initialState(spec: spec, frame: frame())
        #expect(warm.allSatisfy { $0.age >= 0 && $0.age <= $0.life })
    }

    @Test func particlesRespawnAfterTheirLifetime() {
        var spec = ParticleSpec(); spec.count = 50; spec.lifetimeMin = 0.5; spec.lifetimeMax = 0.5
        var s = ParticleReference.initialState(spec: spec, frame: frame())
        for _ in 0..<120 { ParticleReference.step(&s, spec: spec, frame: frame()) }
        #expect(s.allSatisfy { $0.generation >= 3 && $0.age < 0.5 + 1e-3 })
    }

    @Test func attractPullsAndRepelPushesAndSwirlCurves() {
        func meanDistanceToPointer(_ mode: PointerMode) -> Float {
            var spec = ParticleSpec(); spec.count = 400; spec.speedMin = 0; spec.speedMax = 0; spec.pointerMode = mode
            spec.pointerStrength = 4; spec.pointerRadius = 0.8; spec.lifetimeMin = 100; spec.lifetimeMax = 100; spec.drag = 1
            spec.shape = .box; spec.emitterHalfWidth = 0.3; spec.emitterHalfHeight = 0.3; spec.prewarm = false
            var s = ParticleReference.initialState(spec: spec, frame: frame())
            for p in s.indices { s[p].age = 0 }
            for _ in 0..<90 { ParticleReference.step(&s, spec: spec, frame: frame(pointer: .zero, active: true)) }
            return s.map { simd_length($0.position * SIMD2(ParticleSpec.simAspect, 1)) }.reduce(0, +) / Float(s.count)
        }
        let none = meanDistanceToPointer(.none), attract = meanDistanceToPointer(.attract), repel = meanDistanceToPointer(.repel)
        #expect(attract < none - 0.03 && repel > none + 0.03, "none \(none) attract \(attract) repel \(repel)")
    }

    @Test func pointerIsIgnoredWhenInactive() {
        var spec = ParticleSpec(); spec.count = 100; spec.pointerMode = .repel
        #expect(run(spec, steps: 30, active: false) == run({ var s = spec; s.pointerMode = .none; return s }(), steps: 30, active: false))
    }

    @Test func pointerEmitterFollowsThePointerAndParksWhenAbsent() {
        var spec = ParticleSpec(); spec.count = 100; spec.shape = .pointer; spec.lifetimeMin = 0.2; spec.lifetimeMax = 0.2
        spec.speedMin = 0; spec.speedMax = 0; spec.prewarm = false
        var s = ParticleReference.initialState(spec: spec, frame: frame(pointer: SIMD2(0.5, -0.25), active: true))
        for p in s.indices { s[p].age = 0 }
        for _ in 0..<30 { ParticleReference.step(&s, spec: spec, frame: frame(pointer: SIMD2(0.5, -0.25), active: true)) }
        #expect(s.allSatisfy { abs($0.position.x - 0.5) < 0.01 && abs($0.position.y + 0.25) < 0.01 })
        for _ in 0..<30 { ParticleReference.step(&s, spec: spec, frame: frame(active: false)) }
        #expect(s.allSatisfy { $0.position.x > 5 })               // parked off-canvas
    }

    @Test func clickBurstLaunchesExactlyTheRequestedWindowOfParticles() {
        var spec = ParticleSpec(); spec.count = 100; spec.burstSpeed = 1; spec.lifetimeMin = 5; spec.lifetimeMax = 5
        spec.shape = .point; spec.emitterX = -0.9; spec.emitterY = -0.9; spec.speedMin = 0; spec.speedMax = 0; spec.prewarm = false
        var s = ParticleReference.initialState(spec: spec, frame: frame())
        for p in s.indices { s[p].age = 0; s[p].position = SIMD2(-0.9, -0.9); s[p].velocity = .zero }
        var f = frame(); f.burstPosition = SIMD2(0.3, 0.4); f.burstStart = 90; f.burstCount = 20     // wraps around the end of the buffer
        f.dt = 0.0001
        ParticleReference.step(&s, spec: spec, frame: f)
        let burst = Set(((90..<110).map { $0 % 100 }))
        for i in 0..<100 {
            let moved = abs(s[i].position.x - 0.3) < 0.01 && abs(s[i].position.y - 0.4) < 0.01
            #expect(moved == burst.contains(i), "particle \(i)")
        }
        #expect(burst.allSatisfy { simd_length(s[$0].velocity) > 0.3 })
    }
}

@Suite struct ParticleCodecTests {
    @Test func specSurvivesJSONAndHandWrittenPartialsUseDefaults() throws {
        var spec = ParticleSpec(); spec.count = 777; spec.pointerMode = .swirl; spec.colorEnd = RGBA(0, 1, 0, 0.5); spec.seed = 42
        let data = try JSONEncoder().encode(spec)
        #expect(try JSONDecoder().decode(ParticleSpec.self, from: data) == spec)
        let partial = try JSONDecoder().decode(ParticleSpec.self, from: Data(#"{"count":10,"pointerMode":"repel"}"#.utf8))
        #expect(partial.count == 10 && partial.pointerMode == .repel && partial.lifetimeMax == ParticleSpec().lifetimeMax)
    }

    @Test func validationRejectsBrokenParticleLayers() {
        func scene(_ edit: (inout ParticleSpec) -> Void) -> Scene {
            var p = ParticleSpec(); edit(&p)
            return Scene(name: "p", layers: [SceneLayer(id: "p", content: .particles(p))])
        }
        #expect(throws: Never.self) { try SceneCodec.validate(scene { _ in }) }
        for bad in [scene { $0.count = 0 }, scene { $0.count = ParticleSpec.maxCount + 1 }, scene { $0.lifetimeMin = 0 },
                    scene { $0.lifetimeMax = 0.1; $0.lifetimeMin = 1 }, scene { $0.pointerRadius = 0 }, scene { $0.gravityY = .nan },
                    scene { $0.colorStart = RGBA(3, 0, 0) }, scene { $0.burstCount = 99_999 }] {
            #expect(throws: SceneError.self) { try SceneCodec.validate(bad) }
        }
        var noSpec = LayerContent(kind: .particles)
        noSpec.particles = nil
        #expect(throws: SceneError.self) { try SceneCodec.validate(Scene(name: "n", layers: [SceneLayer(id: "n", content: noSpec)])) }
    }

    @Test func bindingsRoundTripThroughScenes() throws {
        let scene = Scene(name: "b", layers: [SceneLayer(id: "l", content: .solid(.white),
                          bindings: [InputBinding(source: .pointerX, target: .lightX, gain: 0.5)])])
        #expect(try SceneCodec.decode(try SceneCodec.encode(scene)) == scene)
    }
}
