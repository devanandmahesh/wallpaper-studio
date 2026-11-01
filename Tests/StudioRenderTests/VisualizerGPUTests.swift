import Testing
import Foundation
import simd
import StudioCore
@testable import StudioRender

private func frame(bands: [Float] = [], wave: [Float] = [], bass: Float = 0, mid: Float = 0, treble: Float = 0,
                   level: Float = 0, beat: Float = 0, serial: Int = 0) -> AudioFrame {
    AudioFrame(bands: bands, waveform: wave, bass: bass, mid: mid, treble: treble, level: level, beat: beat, beatSerial: serial)
}

private func viz(_ edit: (inout VisualizerSpec) -> Void) -> StudioCore.Scene {
    var v = VisualizerSpec()
    v.glow = 0; v.gap = 0; v.amplitude = 1
    v.color = RGBA(0, 1, 0); v.color2 = RGBA(1, 0, 0)
    edit(&v)
    return StudioCore.Scene(name: "viz", layers: [SceneLayer(id: "v", content: .visualizer(v))])
}

private func lit(_ p: Pixel) -> Bool { p.r + p.g + p.b > 120 }

@Suite struct VisualizerRenderingTests {
    @Test func barsRiseFromTheBottomInProportionToTheirBand() throws {
        var bands = [Float](repeating: 0, count: 32)
        bands[0] = 1; bands[31] = 0.5
        let f = try #require(render(viz { _ in }, size: 64, input: SceneInput(audio: frame(bands: bands))))
        #expect(lit(f.pixel(0, 1)) && lit(f.pixel(0, 62)), "loudest bar spans the full height")
        #expect(!lit(f.pixel(63, 10)) && lit(f.pixel(63, 50)), "half-level bar: top empty, bottom lit")
        #expect(!lit(f.pixel(32, 20)), "silent bars stay down")
    }

    @Test func colourRunsFromTheLowEndColourToTheHighEndColour() throws {
        let bands = [Float](repeating: 1, count: 32)
        let f = try #require(render(viz { _ in }, size: 64, input: SceneInput(audio: frame(bands: bands))))
        let low = f.pixel(1, 60), high = f.pixel(62, 60)
        #expect(low.g > 150 && low.r < 80, "low end \(low)")
        #expect(high.r > 150 && high.g < 80, "high end \(high)")
    }

    @Test func mirroredBarsPutTheBassInTheMiddleAndGrowBothWays() throws {
        var bands = [Float](repeating: 0, count: 32)
        bands[0] = 1; bands[1] = 1
        let f = try #require(render(viz { $0.style = .mirrorBars; $0.amplitude = 0.4 }, size: 64, input: SceneInput(audio: frame(bands: bands))))
        #expect(lit(f.pixel(32, 20)) && lit(f.pixel(32, 44)), "bar grows up and down from the centre line")
        #expect(!lit(f.pixel(4, 32 - 18)) && !lit(f.pixel(60, 32 - 18)), "treble edges are quiet")
        #expect(f.pixel(31, 18).g > 0 || f.pixel(32, 18).g > 0)
    }

    @Test func theRingGrowsOutwardWhereTheBandIsLoud() throws {
        var bands = [Float](repeating: 0, count: 32)
        bands[0] = 1
        let f = try #require(render(viz { $0.style = .circular; $0.size = 0.2; $0.amplitude = 0.3 }, size: 64, input: SceneInput(audio: frame(bands: bands))))
        #expect(lit(f.pixel(32 - 20, 32)), "bass spike on the left side of the ring: \(f.pixel(12, 32))")
        #expect(!lit(f.pixel(32 + 20, 32)), "quiet side of the ring stays short")
        #expect(!lit(f.pixel(32, 32)), "inside the ring is empty")
    }

    @Test func theWaveLineFollowsTheWaveform() throws {
        let flat = try #require(render(viz { $0.style = .wave; $0.amplitude = 0.5; $0.thickness = 0.02 }, size: 64, input: SceneInput(audio: frame(wave: Array(repeating: 0, count: 64)))))
        #expect(lit(flat.pixel(32, 32)) && !lit(flat.pixel(32, 12)))
        let high = try #require(render(viz { $0.style = .wave; $0.amplitude = 0.5; $0.thickness = 0.02 }, size: 64, input: SceneInput(audio: frame(wave: Array(repeating: 1, count: 64)))))
        #expect(lit(high.pixel(32, 16)) && !lit(high.pixel(32, 32)), "full-scale waveform sits at the top quarter")
    }

    @Test func glowAddsAHaloAroundLoudBars() throws {
        var bands = [Float](repeating: 0, count: 32)
        bands[15] = 1
        let input = SceneInput(audio: frame(bands: bands))
        let dry = try #require(render(viz { $0.amplitude = 0.4; $0.glow = 0 }, size: 64, input: input))
        let wet = try #require(render(viz { $0.amplitude = 0.4; $0.glow = 3 }, size: 64, input: input))
        let above = (32 - 40 / 3 * 0 ) // column in the middle of band 15
        #expect(wet.pixel(30, 64 - Int(0.4 * 64) - 3).g > dry.pixel(30, 64 - Int(0.4 * 64) - 3).g)
        _ = above
    }

    @Test func colourDriftsWithLoudnessWhenHueReactivityIsOn() throws {
        let bands = [Float](repeating: 1, count: 32)
        let scene = viz { $0.hueReactivity = 0.5 }
        let quiet = try #require(render(scene, size: 64, input: SceneInput(audio: frame(bands: bands, level: 0))))
        let loud = try #require(render(scene, size: 64, input: SceneInput(audio: frame(bands: bands, level: 1))))
        let a = quiet.pixel(5, 60), b = loud.pixel(5, 60)
        #expect(abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b) > 100, "\(a) vs \(b)")
        let still = try #require(render(viz { _ in }, size: 64, input: SceneInput(audio: frame(bands: bands, level: 1))))
        #expect(still.pixel(5, 60).near(a, tolerance: 6))        // without hue reactivity the palette never moves
    }

    @Test func silenceIsAQuietBaselineNotAnError() throws {
        for style in VisualizerStyle.allCases {
            let f = try #require(render(viz { $0.style = style }, size: 48))
            let litPixels = stride(from: 0, to: f.bytes.count, by: 4).filter { Int(f.bytes[$0]) + Int(f.bytes[$0 + 1]) + Int(f.bytes[$0 + 2]) > 120 }.count
            #expect(litPixels < 48 * 48 / 4, "\(style): \(litPixels) lit pixels with no sound")
        }
    }
}

@Suite struct AudioReactiveEffectTests {
    @Test func audioBindingsDriveLightsAndColour() throws {
        var e = LayerEffects(); e.lightIntensity = 0; e.lightRadius = 0.6; e.lightX = 0.5; e.lightY = 0.5
        let layer = SceneLayer(id: "l", content: .solid(RGBA(0, 0, 0, 0)), blend: .add, effects: e,
                               bindings: [InputBinding(source: .audioBass, target: .lightIntensity, gain: 1.5)])
        let scene = StudioCore.Scene(name: "b", layers: [layer])
        let silent = try #require(render(scene, size: 48)), thump = try #require(render(scene, size: 48, input: SceneInput(audio: frame(bass: 1))))
        #expect(silent.pixel(24, 24).r < 5 && thump.pixel(24, 24).r > 150, "\(silent.pixel(24, 24)) → \(thump.pixel(24, 24))")
    }

    @Test func bassMakesParticlesSwell() throws {
        var p = ParticleSpec()
        p.count = 1; p.shape = .point; p.speedMin = 0; p.speedMax = 0; p.lifetimeMin = 100; p.lifetimeMax = 100
        p.sizeStart = 0.12; p.sizeEnd = 0.12; p.sizeJitter = 0; p.audioSizeGain = 3
        p.colorStart = RGBA(1, 1, 1, 1); p.colorEnd = RGBA(1, 1, 1, 1)
        let scene = StudioCore.Scene(name: "p", layers: [SceneLayer(id: "p", content: .particles(p))])
        func count(_ bass: Float) -> Int {
            guard let f = render(scene, size: 96, input: SceneInput(audio: frame(bass: bass))) else { return -1 }
            return stride(from: 0, to: f.bytes.count, by: 4).filter { f.bytes[$0] > 40 }.count
        }
        #expect(count(1) > count(0) * 4)
    }

    @Test func eachBeatLaunchesABurstOfParticlesFromTheEmitter() throws {
        let context = try #require(MetalContext.shared)
        var spec = ParticleSpec()
        spec.count = 200; spec.beatBurstCount = 40; spec.shape = .point; spec.emitterX = -0.5; spec.emitterY = 0.5
        spec.speedMin = 0; spec.speedMax = 0; spec.lifetimeMin = 20; spec.lifetimeMax = 20; spec.prewarm = false; spec.burstSpeed = 1
        let scene = StudioCore.Scene(name: "beat", layers: [SceneLayer(id: "p", content: .particles(spec))])
        let renderer = SceneRenderer(context: context, scene: scene, assetBase: nil)
        let target = try #require(OffscreenRenderer(context: context).makeTarget(width: 32, height: 32))
        for i in 0..<8 {
            let buffer = try #require(context.queue.makeCommandBuffer())
            renderer.encode(into: target, commandBuffer: buffer, time: Double(i) / 60,
                            input: SceneInput(audio: frame(beat: i >= 4 ? 1 : 0, serial: i >= 4 ? 1 : 0)))
            buffer.commit(); buffer.waitUntilCompleted()
        }
        let states = try #require(renderer.particleStates(layer: "p"))
        let launched = states.filter { simd_length($0.velocity) > 0.3 }
        #expect(launched.count == 40, "launched \(launched.count)")
        #expect(launched.allSatisfy { simd_length($0.position - SIMD2(-0.5, 0.5)) < 0.3 })
    }

    @Test func noBurstWhenTheAudioCounterAlreadyStartedHigh() throws {
        let context = try #require(MetalContext.shared)
        var spec = ParticleSpec(); spec.count = 100; spec.beatBurstCount = 50; spec.speedMin = 0; spec.speedMax = 0
        let scene = StudioCore.Scene(name: "b", layers: [SceneLayer(id: "p", content: .particles(spec))])
        let renderer = SceneRenderer(context: context, scene: scene, assetBase: nil)
        let target = try #require(OffscreenRenderer(context: context).makeTarget(width: 16, height: 16))
        for i in 0..<6 {
            let buffer = try #require(context.queue.makeCommandBuffer())
            renderer.encode(into: target, commandBuffer: buffer, time: Double(i) / 60, input: SceneInput(audio: frame(serial: 9)))
            buffer.commit(); buffer.waitUntilCompleted()
        }
        let states = try #require(renderer.particleStates(layer: "p"))
        #expect(states.filter { simd_length($0.velocity) > 0.3 }.isEmpty)
    }

    @Test func audioScenesStayCheap() throws {
        let context = try #require(MetalContext.shared)
        var v = VisualizerSpec(); v.style = .circular
        let scene = StudioCore.Scene(name: "perf", layers: [
            SceneLayer(id: "bars", content: .visualizer(VisualizerSpec()), blend: .add),
            SceneLayer(id: "ring", content: .visualizer(v), blend: .add),
        ])
        let renderer = SceneRenderer(context: context, scene: scene, assetBase: nil)
        let target = try #require(OffscreenRenderer(context: context).makeTarget(width: 1920, height: 1080))
        let loud = frame(bands: (0..<32).map { Float($0 % 7) / 7 }, wave: (0..<64).map { sin(Float($0) / 5) }, bass: 0.8, level: 0.6)
        for i in 0..<60 {
            let buffer = try #require(context.queue.makeCommandBuffer())
            renderer.encode(into: target, commandBuffer: buffer, time: Double(i) / 60, input: SceneInput(audio: loud))
            buffer.commit(); buffer.waitUntilCompleted()
        }
        let s = renderer.stats.snapshot()
        print("PERF 2 visualisers 1080p: gpu avg=\(s.averageGPUMilliseconds)ms max=\(s.maxGPUMilliseconds)ms")
        #expect(s.averageGPUMilliseconds < 6)
    }
}
