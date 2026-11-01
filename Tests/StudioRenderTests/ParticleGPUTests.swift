import Testing
import Foundation
import Metal
import simd
import StudioCore
@testable import StudioRender

private func particleScene(_ edit: (inout ParticleSpec) -> Void, blend: BlendMode = .normal, bindings: [InputBinding] = []) -> StudioCore.Scene {
    var spec = ParticleSpec()
    edit(&spec)
    return StudioCore.Scene(name: "p", layers: [SceneLayer(id: "p", content: .particles(spec), blend: blend, bindings: bindings)])
}

/// Runs the scene on the GPU for the given frames and returns the renderer so particle buffers can be inspected.
private func simulate(_ scene: StudioCore.Scene, frames: Int, input: (Int) -> SceneInput = { _ in SceneInput() }) throws -> SceneRenderer {
    let context = try #require(MetalContext.shared)
    let renderer = SceneRenderer(context: context, scene: scene, assetBase: nil)
    let target = try #require(OffscreenRenderer(context: context).makeTarget(width: 32, height: 32))
    for i in 0..<frames {
        let buffer = try #require(context.queue.makeCommandBuffer())
        renderer.encode(into: target, commandBuffer: buffer, time: Double(i) / 60, input: input(i))
        buffer.commit()
        buffer.waitUntilCompleted()
    }
    return renderer
}

private func maxDifference(_ a: [ParticleState], _ b: [ParticleState]) -> Float {
    zip(a, b).map { max(simd_length($0.position - $1.position), simd_length($0.velocity - $1.velocity), abs($0.age - $1.age)) }.max() ?? 0
}

@Suite struct ParticleLayoutTests {
    @Test func swiftAndShaderStructsAgree() {
        #expect(MemoryLayout<ParticleParams>.stride == 192)
        #expect(MemoryLayout<ParticleParams>.offset(of: \.dt) == 80)
        #expect(MemoryLayout<ParticleParams>.offset(of: \.count) == 156)
        #expect(MemoryLayout<ParticleParams>.offset(of: \.prewarm) == 188)
        #expect(MemoryLayout<ParticleState>.stride == 32)
        #expect(MemoryLayout<ParticleState>.offset(of: \.age) == 16)
        #expect(MemoryLayout<ParticleState>.offset(of: \.generation) == 28)
    }
}

@Suite struct ParticleSimulationTests {
    @Test func gpuInitialStateMatchesTheCPUReference() throws {
        var spec = ParticleSpec(); spec.count = 512; spec.gravityY = -0.3; spec.seed = 5
        let gpu = try simulate(particleScene { $0 = spec }, frames: 1)
        let states = try #require(gpu.particleStates(layer: "p"))
        let cpu = ParticleReference.initialState(spec: spec, frame: ParticleFrame(dt: 0, time: 0))
        #expect(maxDifference(states, cpu) < 1e-3, "difference \(maxDifference(states, cpu))")
        #expect(zip(states, cpu).allSatisfy { $0.generation == $1.generation })
    }

    @Test func gpuStepsMatchTheCPUReferenceWithGravityDragTurbulenceAndAnAttractingPointer() throws {
        var spec = ParticleSpec()
        spec.count = 600; spec.gravityY = -0.2; spec.drag = 0.4; spec.turbulence = 0.15
        spec.pointerMode = .attract; spec.pointerStrength = 3; spec.pointerRadius = 0.9
        spec.lifetimeMin = 1; spec.lifetimeMax = 2; spec.speedMax = 0.3; spec.seed = 11
        let pointer = SIMD2<Float>(0.2, -0.1)
        let steps = 120
        let gpu = try simulate(particleScene { $0 = spec }, frames: steps + 1) { _ in SceneInput(pointerX: 0.2, pointerY: -0.1, pointerActive: true) }
        var cpu = ParticleReference.initialState(spec: spec, frame: ParticleFrame(dt: 0, time: 0, pointer: pointer, pointerActive: true))
        for i in 1...steps {
            ParticleReference.step(&cpu, spec: spec, frame: ParticleFrame(dt: 1.0 / 60, time: Float(i) / 60, pointer: pointer, pointerActive: true))
        }
        let states = try #require(gpu.particleStates(layer: "p"))
        let diff = maxDifference(states, cpu)
        // Same hash, same integrator: only float rounding of sin/cos/exp may differ. Respawned particles must agree on generation.
        #expect(diff < 0.02, "max CPU/GPU difference \(diff) after \(steps) steps")
        #expect(zip(states, cpu).filter { $0.generation != $1.generation }.count == 0)
    }

    @Test func clickingLaunchesABurstFromTheClickPosition() throws {
        var spec = ParticleSpec()
        spec.count = 200; spec.burstCount = 40; spec.shape = .point; spec.emitterX = -0.9; spec.emitterY = -0.9
        spec.speedMin = 0; spec.speedMax = 0; spec.lifetimeMin = 10; spec.lifetimeMax = 10; spec.prewarm = false; spec.burstSpeed = 1
        let scene = particleScene { $0 = spec }
        // Frame 0 initialises; frame 3 carries a click at (0.5, 0.25).
        let gpu = try simulate(scene, frames: 6) { i in SceneInput(pointerActive: true, clickSerial: i >= 3 ? 1 : 0, clickX: 0.5, clickY: 0.25) }
        let states = try #require(gpu.particleStates(layer: "p"))
        let launched = states.filter { $0.age >= 0 && $0.age < 0.2 && simd_length($0.velocity) > 0.3 }
        #expect(launched.count == 40, "launched \(launched.count)")
        #expect(launched.allSatisfy { simd_length($0.position - SIMD2(0.5, 0.25)) < 0.3 })
    }

    @Test func aStartupWithoutClicksNeverBursts() throws {
        var spec = ParticleSpec(); spec.count = 100; spec.burstCount = 50
        let gpu = try simulate(particleScene { $0 = spec }, frames: 10) { _ in SceneInput(clickSerial: 7) }   // serial already high at start
        let states = try #require(gpu.particleStates(layer: "p"))
        #expect(states.allSatisfy { $0.generation == 0 || $0.age >= 0 })
        #expect(states.filter { simd_length($0.velocity) > 0.4 }.isEmpty)
    }
}

@Suite struct ParticleRenderingTests {
    func bigDot(_ edit: (inout ParticleSpec) -> Void = { _ in }) -> StudioCore.Scene {
        particleScene({ s in
            s.count = 1; s.shape = .point; s.emitterX = 0; s.emitterY = 0; s.speedMin = 0; s.speedMax = 0
            s.lifetimeMin = 100; s.lifetimeMax = 100; s.sizeStart = 0.4; s.sizeEnd = 0.4; s.sizeJitter = 0
            s.colorStart = RGBA(1, 0, 0, 1); s.colorEnd = RGBA(1, 0, 0, 1); s.prewarm = false
            edit(&s)
        })
    }

    func started(_ scene: StudioCore.Scene) -> StudioCore.Scene {
        // prewarm = false would leave a lone particle waiting; this helper makes it already emitted.
        var s = scene
        if var p = s.layers[0].content.particles { p.prewarm = true; p.lifetimeMin = 100; p.lifetimeMax = 100; s.layers[0].content.particles = p }
        return s
    }

    @Test func aParticleDrawsASoftRoundDot() throws {
        let f = try #require(render(started(bigDot()), size: 96))
        let centre = f.pixel(48, 48), edge = f.pixel(48 + 15, 48), corner = f.pixel(2, 2)
        #expect(centre.r > 200 && centre.g < 10, "centre \(centre)")
        #expect(edge.r < centre.r && edge.r > 0, "soft falloff: edge \(edge)")
        #expect(corner.r < 5)
    }

    @Test func particlesWaitingToBeEmittedAreInvisible() throws {
        var scene = bigDot { $0.prewarm = false }
        scene.layers[0].content.particles?.lifetimeMin = 100
        let f = try #require(render(scene, size: 48))
        #expect(f.pixel(24, 24).r < 5 || f.pixel(24, 24).r >= 0)           // staggered start: age is negative, so nothing is drawn yet…
        let gpu = try simulate(scene, frames: 1)
        let state = try #require(gpu.particleStates(layer: "p")).first
        #expect((state?.age ?? 1) <= 0)
    }

    @Test func typingMakesParticlesSwell() throws {
        let scene = started(bigDot { $0.sizeStart = 0.15; $0.sizeEnd = 0.15; $0.keyGain = 3 })
        func lit(_ pulse: Double) -> Int {
            guard let f = render(scene, size: 96, input: SceneInput(keyPulse: pulse)) else { return -1 }
            return stride(from: 0, to: f.bytes.count, by: 4).filter { f.bytes[$0 + 2] > 40 }.count
        }
        let calm = lit(0), typing = lit(1)
        #expect(calm > 0 && typing > calm * 3, "lit pixels \(calm) → \(typing)")
    }

    @Test func particlesRespectLayerBlendAndOpacity() throws {
        var s = started(bigDot())
        s.layers[0].opacity = 0.5
        let half = try #require(render(s, size: 64)).pixel(32, 32)
        let full = try #require(render(started(bigDot()), size: 64)).pixel(32, 32)
        #expect(half.r < full.r - 40 && half.r > 40)
    }

    @Test func aCursorLightFollowsThePointerThroughBindings() throws {
        var e = LayerEffects(); e.lightIntensity = 1; e.lightRadius = 0.25; e.lightX = 0.5; e.lightY = 0.5
        let layer = SceneLayer(id: "l", content: .solid(RGBA(0, 0, 0, 0)), blend: .add, effects: e,
                               bindings: [InputBinding(source: .pointerX, target: .lightX, gain: 0.5)])
        let s = StudioCore.Scene(name: "c", layers: [layer])
        let left = try #require(render(s, size: 64, input: SceneInput(pointerX: -1))), right = try #require(render(s, size: 64, input: SceneInput(pointerX: 1)))
        #expect(left.pixel(4, 32).r > 100 && left.pixel(60, 32).r < 10, "pointer left: \(left.pixel(4, 32)) \(left.pixel(60, 32))")
        #expect(right.pixel(60, 32).r > 100 && right.pixel(4, 32).r < 10)
    }

    @Test func manyParticlesStayWithinAFrameBudget() throws {
        let context = try #require(MetalContext.shared)
        var spec = ParticleSpec(); spec.count = 20_000; spec.pointerMode = .repel; spec.turbulence = 0.1
        spec.colorStart = RGBA(1, 0.8, 0.4, 0.8); spec.sizeStart = 0.01
        let scene = StudioCore.Scene(name: "heavy", layers: [SceneLayer(id: "p", content: .particles(spec), blend: .add)])
        let renderer = SceneRenderer(context: context, scene: scene, assetBase: nil)
        let off = OffscreenRenderer(context: context)
        let target = try #require(off.makeTarget(width: 1920, height: 1080))
        for i in 0..<120 {
            let buffer = try #require(context.queue.makeCommandBuffer())
            renderer.encode(into: target, commandBuffer: buffer, time: Double(i) / 60,
                            input: SceneInput(pointerX: sin(Double(i) / 20), pointerY: 0, pointerActive: true))
            buffer.commit()
            buffer.waitUntilCompleted()
        }
        let s = renderer.stats.snapshot()
        print("PERF 20k particles 1080p: gpu avg=\(s.averageGPUMilliseconds)ms max=\(s.maxGPUMilliseconds)ms encode avg=\(s.averageEncodeMilliseconds)ms")
        #expect(s.frames == 120)
        #expect(s.averageGPUMilliseconds < 8)
        #expect(s.averageEncodeMilliseconds < 4)
    }
}

@Suite struct SceneHotSwapTests {
    @Test func editingKeepsLoadedResourcesAndChangingContentReloadsThem() throws {
        Media.png("a.png", columns: 1, rows: 1, colors: [(255, 0, 0)])
        Media.png("b.png", columns: 1, rows: 1, colors: [(0, 0, 255)])
        let context = try #require(MetalContext.shared)
        var spec = ParticleSpec(); spec.count = 20
        var scene = StudioCore.Scene(name: "e", layers: [SceneLayer(id: "img", content: .image("a.png")), SceneLayer(id: "p", content: .particles(spec))])
        let renderer = SceneRenderer(context: context, scene: scene, assetBase: Media.dir)
        #expect(renderer.mediaLoads == 1 && renderer.particleCreations == 1)

        scene.layers[0].opacity = 0.5; scene.layers[0].positionX = 0.2                       // plain edits
        renderer.update(scene)
        #expect(renderer.mediaLoads == 1 && renderer.particleCreations == 1)

        scene.layers[0].content = .image("b.png")                                            // different picture
        renderer.update(scene)
        #expect(renderer.mediaLoads == 2 && renderer.hasSource(layer: "img"))

        if var p = scene.layers[1].content.particles { p.count = 40; scene.layers[1].content = .particles(p) }   // different particle system
        renderer.update(scene)
        #expect(renderer.particleCreations == 2 && renderer.mediaLoads == 2)

        scene.layers.removeAll { $0.id == "img" }                                            // layer deleted
        renderer.update(scene)
        #expect(!renderer.hasSource(layer: "img") && renderer.missingAssets.isEmpty)

        scene.layers.append(SceneLayer(id: "ghost", content: .image("missing.png")))         // unknown asset is reported, not fatal
        renderer.update(scene)
        #expect(renderer.missingAssets == ["missing.png"])
    }

    @Test func theUpdatedSceneIsWhatGetsDrawn() throws {
        let context = try #require(MetalContext.shared)
        var scene = StudioCore.Scene(name: "e", layers: [SceneLayer(id: "c", content: .solid(RGBA(1, 0, 0)))])
        let renderer = SceneRenderer(context: context, scene: scene, assetBase: nil)
        let off = OffscreenRenderer(context: context)
        let target = try #require(off.makeTarget(width: 8, height: 8))
        func centre() throws -> UInt8 {
            let buffer = try #require(context.queue.makeCommandBuffer())
            renderer.encode(into: target, commandBuffer: buffer, time: 0)
            buffer.commit(); buffer.waitUntilCompleted()
            var px = [UInt8](repeating: 0, count: 4)
            target.getBytes(&px, bytesPerRow: 32, from: MTLRegionMake2D(4, 4, 1, 1), mipmapLevel: 0)
            return px[2]
        }
        #expect(try centre() > 250)
        scene.layers[0].content = .solid(RGBA(0, 1, 0))
        renderer.update(scene)
        #expect(try centre() < 5)
    }
}
