import Testing
import Foundation
import Metal
import StudioCore
@testable import StudioRender

@Suite struct GPUFoundationTests {
    @Test func shadersCompileAndAllBlendPipelinesExist() throws {
        let context = try #require(MetalContext.shared, "no Metal device")
        for blend in BlendMode.allCases { #expect(context.pipeline(for: blend) != nil, "\(blend)") }
    }

    @Test func swiftUniformsMatchTheShaderLayout() {
        // Mirrors the MSL struct: three float4, six float2, then 18 floats/ints → 96 + 72 = 168 bytes, 16-aligned → 176.
        #expect(MemoryLayout<LayerUniforms>.stride == 192)
        #expect(MemoryLayout<LayerUniforms>.offset(of: \.axis0) == 48)
        #expect(MemoryLayout<LayerUniforms>.offset(of: \.canvas) == 88)
        #expect(MemoryLayout<LayerUniforms>.offset(of: \.opacity) == 96)
        #expect(MemoryLayout<LayerUniforms>.offset(of: \.lightFlicker) == 160)
        #expect(MemoryLayout<LayerUniforms>.offset(of: \.hasDepth) == 164)
        #expect(MemoryLayout<LayerUniforms>.offset(of: \.vizSize) == 188)
    }
}

@Suite struct CompositingTests {
    @Test func solidColourFillsTheCanvas() throws {
        let f = try #require(render(scene([SceneLayer(id: "a", content: .solid(red()))])))
        #expect(f.pixel(32, 32) == Pixel(r: 255, g: 0, b: 0, a: 255), "\(f.pixel(32, 32))")
        #expect(f.pixel(0, 0).near(Pixel(r: 255, g: 0, b: 0, a: 255)) && f.pixel(63, 63).near(Pixel(r: 255, g: 0, b: 0, a: 255)))
    }

    @Test func backgroundShowsWhereNothingIsDrawn() throws {
        let f = try #require(render(scene(background: RGBA(0, 0, 1), [])))
        #expect(f.pixel(10, 10).near(Pixel(r: 0, g: 0, b: 255, a: 255)))
    }

    @Test func opacityBlendsWithTheBackground() throws {
        let f = try #require(render(scene([SceneLayer(id: "a", content: .solid(.white), opacity: 0.5)])))
        #expect(f.pixel(32, 32).near(Pixel(r: 128, g: 128, b: 128, a: 255), tolerance: 2), "\(f.pixel(32, 32))")
    }

    @Test func gradientRunsTopToBottom() throws {
        let f = try #require(render(scene([SceneLayer(id: "g", content: .gradient(top: red(), bottom: RGBA(0, 0, 1)))])))
        #expect(f.pixel(32, 1).r > 240 && f.pixel(32, 1).b < 15)
        #expect(f.pixel(32, 62).b > 240 && f.pixel(32, 62).r < 15)
        #expect(abs(f.pixel(32, 32).r - f.pixel(32, 32).b) < 12)
    }

    @Test func blendModesFollowTheirFormulas() throws {
        let gray = SceneLayer(id: "base", content: .solid(RGBA(0.5, 0.5, 0.5)))
        func result(_ mode: BlendMode, over value: Float) -> Pixel? {
            render(scene([gray, SceneLayer(id: "top", content: .solid(RGBA(value, value, value)), blend: mode)]))?.pixel(32, 32)
        }
        #expect(result(.add, over: 0.25)?.near(Pixel(r: 191, g: 191, b: 191, a: 255), tolerance: 3) == true)       // 0.5 + 0.25
        #expect(result(.multiply, over: 0.5)?.near(Pixel(r: 64, g: 64, b: 64, a: 255), tolerance: 3) == true)      // 0.5 × 0.5
        #expect(result(.screen, over: 0.5)?.near(Pixel(r: 191, g: 191, b: 191, a: 255), tolerance: 3) == true)     // 1-(0.5)(0.5)
        #expect(result(.normal, over: 1)?.near(Pixel(r: 255, g: 255, b: 255, a: 255)) == true)
    }

    @Test func keyframedOpacityFollowsTheTimeline() throws {
        let layer = SceneLayer(id: "a", content: .solid(.white), tracks: [
            Track(property: .opacity, keyframes: [Keyframe(time: 0, value: 0), Keyframe(time: 1, value: 1)], loop: .once)])
        let s = scene([layer])
        #expect(try #require(render(s, time: 0)).pixel(32, 32).r < 3)
        #expect(abs(try #require(render(s, time: 0.5)).pixel(32, 32).r - 128) <= 3)
        #expect(try #require(render(s, time: 2)).pixel(32, 32).r > 252)
    }

    @Test func positionAndScaleMoveTheLayer() throws {
        // A half-size white square moved to the right half.
        let s = scene([SceneLayer(id: "a", content: .solid(.white), positionX: 0.5, scale: 0.5)])
        let f = try #require(render(s))
        #expect(f.pixel(48, 32).r > 250)                       // inside the square (centre at x=48)
        #expect(f.pixel(16, 32).r < 5)                         // left of it
        #expect(f.pixel(48, 4).r < 5)                          // above it
    }
}

@Suite struct ImageSamplingTests {
    let quadrants = Media.png("quad.png", columns: 2, rows: 2, colors: [(255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 255)])

    func imageScene(_ name: String = "quad.png", scaling: ScalingMode = .fill, rotation: Double = 0) -> Scene {
        scene([SceneLayer(id: "img", content: .image(name), rotation: rotation, scaling: scaling)])
    }

    @Test func imagesAreUprightWithTopLeftOrigin() throws {
        let f = try #require(render(imageScene(), base: Media.dir))
        #expect(f.pixel(16, 16).near(Pixel(r: 255, g: 0, b: 0, a: 255), tolerance: 14), "TL \(f.pixel(16, 16))")
        #expect(f.pixel(48, 16).near(Pixel(r: 0, g: 255, b: 0, a: 255), tolerance: 14), "TR \(f.pixel(48, 16))")
        #expect(f.pixel(16, 48).near(Pixel(r: 0, g: 0, b: 255, a: 255), tolerance: 14), "BL \(f.pixel(16, 48))")
        #expect(f.pixel(48, 48).near(Pixel(r: 255, g: 255, b: 255, a: 255), tolerance: 14), "BR \(f.pixel(48, 48))")
    }

    @Test func clockwiseQuarterTurnMovesTopLeftToTopRight() throws {
        let f = try #require(render(imageScene(rotation: 90), base: Media.dir))
        #expect(f.pixel(48, 16).near(Pixel(r: 255, g: 0, b: 0, a: 255), tolerance: 14), "\(f.pixel(48, 16))")
        #expect(f.pixel(48, 48).near(Pixel(r: 0, g: 255, b: 0, a: 255), tolerance: 14), "\(f.pixel(48, 48))")
    }

    @Test func fitLeavesBarsAndFillCrops() throws {
        let wide = Media.png("wide.png", columns: 4, rows: 2, colors: [(255, 0, 0), (255, 0, 0), (0, 0, 255), (0, 0, 255),
                                                                         (255, 0, 0), (255, 0, 0), (0, 0, 255), (0, 0, 255)])
        let fit = try #require(render(imageScene("wide.png", scaling: .fit), base: Media.dir))
        #expect(fit.pixel(32, 2).r < 5 && fit.pixel(32, 61).b < 5)                       // letterbox bars are background
        #expect(fit.pixel(8, 32).near(Pixel(r: 255, g: 0, b: 0, a: 255), tolerance: 14))  // image spans full width
        #expect(fit.pixel(56, 32).near(Pixel(r: 0, g: 0, b: 255, a: 255), tolerance: 14))
        let fill = try #require(render(imageScene("wide.png", scaling: .fill), base: Media.dir))
        #expect(fill.pixel(32, 2).a == 255 && (fill.pixel(32, 2).r > 100 || fill.pixel(32, 2).b > 100))   // no bars: picture covers the top
        _ = wide
    }

    @Test func missingAssetsAreSkippedNotFatal() throws {
        let s = scene(background: RGBA(0, 0.5, 0), [SceneLayer(id: "img", content: .image("nope.png"))])
        let context = try #require(MetalContext.shared)
        let r = SceneRenderer(context: context, scene: s, assetBase: Media.dir)
        #expect(r.missingAssets == ["nope.png"])
        let f = try #require(render(s, base: Media.dir))
        #expect(f.pixel(10, 10).near(Pixel(r: 0, g: 128, b: 0, a: 255), tolerance: 3))
    }
}

@Suite struct EffectTests {
    @Test func hueShiftTurnsRedTowardsGreen() throws {
        var e = LayerEffects(); e.hueShift = 120
        let f = try #require(render(scene([SceneLayer(id: "a", content: .solid(red()), effects: e)])))
        let p = f.pixel(32, 32)
        #expect(p.g > p.r && p.g > p.b, "\(p)")
    }

    @Test func hueCycleChangesWithTime() throws {
        var e = LayerEffects(); e.hueCycle = 0.25
        let s = scene([SceneLayer(id: "a", content: .solid(red()), effects: e)])
        let a = try #require(render(s, time: 0)).pixel(32, 32), b = try #require(render(s, time: 1)).pixel(32, 32)
        #expect(a != b)
    }

    @Test func saturationZeroGivesGrey() throws {
        var e = LayerEffects(); e.saturation = 0
        let p = try #require(render(scene([SceneLayer(id: "a", content: .solid(red()), effects: e)]))).pixel(32, 32)
        #expect(abs(p.r - p.g) <= 2 && abs(p.g - p.b) <= 2, "\(p)")
    }

    @Test func brightnessAndContrast() throws {
        var e = LayerEffects(); e.brightness = 0.25
        let bright = try #require(render(scene([SceneLayer(id: "a", content: .solid(RGBA(0.5, 0.5, 0.5)), effects: e)]))).pixel(32, 32)
        #expect(abs(bright.r - 191) <= 3)
        e = LayerEffects(); e.contrast = 2
        let contrast = try #require(render(scene([SceneLayer(id: "a", content: .solid(RGBA(0.75, 0.75, 0.75)), effects: e)]))).pixel(32, 32)
        #expect(abs(contrast.r - 255) <= 3)                    // (0.75-0.5)*2+0.5 = 1.0
    }

    @Test func vignetteDarkensTheCornersOnlyAndWorksAsAnOverlay() throws {
        var e = LayerEffects(); e.vignette = 1; e.vignetteRadius = 0.6
        let s = scene([SceneLayer(id: "base", content: .solid(.white)),
                       SceneLayer(id: "v", content: .solid(RGBA(0, 0, 0, 0)), effects: e)])
        let f = try #require(render(s))
        #expect(f.pixel(32, 32).r > 245)
        #expect(f.pixel(1, 1).r < 40, "corner \(f.pixel(1, 1))")
    }

    @Test func animatedLightBrightensAroundItsCentreAndMovesWithTheTimeline() throws {
        var e = LayerEffects(); e.lightIntensity = 1; e.lightRadius = 0.3; e.lightX = 0.25; e.lightY = 0.5
        let layer = SceneLayer(id: "l", content: .solid(RGBA(0, 0, 0, 0)), blend: .add, effects: e, tracks: [
            Track(property: .lightX, keyframes: [Keyframe(time: 0, value: 0.25), Keyframe(time: 1, value: 0.75)], loop: .once)])
        let s = scene([layer])
        let t0 = try #require(render(s, time: 0)), t1 = try #require(render(s, time: 1))
        #expect(t0.pixel(16, 32).r > 200 && t0.pixel(48, 32).r < 10, "\(t0.pixel(16, 32)) \(t0.pixel(48, 32))")
        #expect(t1.pixel(48, 32).r > 200 && t1.pixel(16, 32).r < 10)
    }

    @Test func rippleDisplacesTheImage() throws {
        let stripes = Media.png("stripes.png", columns: 8, rows: 1, colors: (0..<8).map { $0 % 2 == 0 ? (255, 255, 255) : (0, 0, 0) })
        _ = stripes
        func frame(amp: Double) -> Frame? {
            var e = LayerEffects(); e.rippleAmplitude = amp; e.rippleFrequency = 12
            return render(scene([SceneLayer(id: "i", content: .image("stripes.png"), effects: e)]), base: Media.dir, time: 0.3)
        }
        let flat = try #require(frame(amp: 0)), wavy = try #require(frame(amp: 0.05))
        let differing = (0..<64).filter { flat.pixel($0, 20) != wavy.pixel($0, 20) }.count
        #expect(differing > 3)
    }

    @Test func proceduralScenesAnimateDeterministically() throws {
        let s = BuiltInScenes.plasma
        let a = try #require(render(s, size: 96, time: 0)), b = try #require(render(s, size: 96, time: 3)), a2 = try #require(render(s, size: 96, time: 0))
        #expect(a.bytes == a2.bytes)                          // same time → identical pixels
        #expect(a.bytes != b.bytes)                           // later time → different picture
        let colours = Set((0..<96).map { a.pixel($0, 48).g })
        #expect(colours.count > 20)                           // not a flat fill
    }

    @Test func everyBuiltInSceneRendersNonBlack() throws {
        for s in BuiltInScenes.all {
            let f = try #require(render(s, size: 64, time: 1.5), "\(s.name)")
            let brightness = stride(from: 0, to: f.bytes.count, by: 4).reduce(0) { $0 + Int(f.bytes[$1]) + Int(f.bytes[$1 + 1]) + Int(f.bytes[$1 + 2]) }
            #expect(brightness > 300, "\(s.name) looks black (\(brightness))")
        }
    }
}

@Suite struct ParallaxTests {
    // Left half white, right half black; the boundary sits at the canvas centre.
    let edge = Media.png("edge.png", columns: 64, rows: 64, colors: (0..<(64 * 64)).map { ($0 % 64) < 32 ? (255, 255, 255) : (0, 0, 0) })

    func scene(depth: Double, depthMap: String? = nil) -> Scene {
        StudioCore.Scene(name: "p", layers: [SceneLayer(id: "i", content: .image("edge.png"), scale: 1.3, depthAsset: depthMap, parallaxDepth: depth)])
    }

    @Test func nearLayersShiftAgainstThePointerAndFarLayersStay() throws {
        let centre = SceneInput(), right = SceneInput(pointerX: 1, pointerY: 0)
        let near0 = try #require(render(scene(depth: 1), base: Media.dir, input: centre))
        let near1 = try #require(render(scene(depth: 1), base: Media.dir, input: right))
        #expect(near0.bytes != near1.bytes)
        // Pointer right → picture slides left → the white/black boundary moves left: a pixel just left of centre turns black.
        #expect(near0.pixel(30, 32).r > 200 && near1.pixel(30, 32).r < 60, "\(near0.pixel(30, 32)) → \(near1.pixel(30, 32))")
        let far0 = try #require(render(scene(depth: 0), base: Media.dir, input: centre))
        let far1 = try #require(render(scene(depth: 0), base: Media.dir, input: right))
        #expect(far0.bytes == far1.bytes)
    }

    @Test func depthMapDecidesHowFarEachPixelMoves() throws {
        Media.png("near.png", columns: 1, rows: 1, colors: [(255, 255, 255)])
        Media.png("far.png", columns: 1, rows: 1, colors: [(0, 0, 0)])
        let right = SceneInput(pointerX: 1, pointerY: 0)
        let still = try #require(render(scene(depth: 1, depthMap: "far.png"), base: Media.dir, input: right))
        let reference = try #require(render(scene(depth: 1, depthMap: "far.png"), base: Media.dir, input: SceneInput()))
        let moved = try #require(render(scene(depth: 1, depthMap: "near.png"), base: Media.dir, input: right))
        #expect(still.bytes == reference.bytes)               // black (far) depth map: nothing moves
        #expect(moved.bytes != reference.bytes)               // white (near) depth map: picture shifts
        #expect(moved.pixel(30, 32).r < 100 && reference.pixel(30, 32).r > 200)
    }
}

@Suite struct VideoAndPerformanceTests {
    @Test func videoFramesReachTheGPUAsTextures() throws {
        let url = Media.solidMP4("red.mp4", r: 230, g: 20, b: 20)
        let s = scene([SceneLayer(id: "v", content: .video("red.mp4"), scaling: .stretch)])
        let f = try #require(render(s, base: url.deletingLastPathComponent(), size: 48))
        let p = f.pixel(24, 24)
        #expect(p.r > 180 && p.g < 90 && p.b < 90, "video pixel \(p)")           // H.264 is lossy; colour stays close
    }

    @Test func renderingIsFastAndMeasured() throws {
        let context = try #require(MetalContext.shared)
        let renderer = SceneRenderer(context: context, scene: BuiltInScenes.nightWaves, assetBase: nil)
        let off = OffscreenRenderer(context: context)
        let target = try #require(off.makeTarget(width: 1920, height: 1080))
        for i in 0..<60 {
            let buffer = try #require(context.queue.makeCommandBuffer())
            renderer.encode(into: target, commandBuffer: buffer, time: Double(i) / 60)
            buffer.commit()
            buffer.waitUntilCompleted()
        }
        let s = renderer.stats.snapshot()
        print("PERF 1080p nightWaves: frames=\(s.frames) gpu avg=\(s.averageGPUMilliseconds)ms max=\(s.maxGPUMilliseconds)ms encode avg=\(s.averageEncodeMilliseconds)ms")
        #expect(s.frames == 60)
        #expect(s.averageGPUMilliseconds >= 0 && s.averageGPUMilliseconds < 12)          // far below one 60 Hz frame (16.7 ms)
        #expect(s.averageEncodeMilliseconds < 4)
    }

    @Test func scenesTellTheDriverWhetherTheyNeedContinuousFrames() throws {
        let context = try #require(MetalContext.shared)
        let still = SceneRenderer(context: context, scene: scene([SceneLayer(id: "a", content: .solid(.white))]), assetBase: nil)
        #expect(!still.needsContinuousRendering)
        #expect(SceneRenderer(context: context, scene: BuiltInScenes.aurora, assetBase: nil).needsContinuousRendering)
    }
}
