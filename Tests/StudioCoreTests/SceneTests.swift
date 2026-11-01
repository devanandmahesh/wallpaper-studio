import Testing
import Foundation
@testable import StudioCore

@Suite struct TrackTests {
    func track(_ loop: LoopMode, duration: Double = 2, easing: Easing = .linear) -> Track {
        Track(property: .opacity, keyframes: [Keyframe(time: 0, value: 0, easing: easing), Keyframe(time: duration, value: 1)], loop: loop, duration: duration)
    }

    @Test func interpolatesLinearly() {
        let t = track(.once)
        #expect(t.value(at: 0) == 0)
        #expect(abs(t.value(at: 1)! - 0.5) < 1e-9)
        #expect(t.value(at: 2) == 1)
    }

    @Test func clampsBeforeFirstAndAfterLastForOnce() {
        let t = track(.once)
        #expect(t.value(at: -5) == 0 && t.value(at: 99) == 1)
    }

    @Test func loopWrapsAround() {
        let t = track(.loop)
        #expect(abs(t.value(at: 3)! - 0.5) < 1e-9)          // 3 s → 1 s into the second cycle
        #expect(abs(t.value(at: -1)! - 0.5) < 1e-9)         // negative times wrap too
    }

    @Test func pingPongReflects() {
        let t = track(.pingPong)
        #expect(abs(t.value(at: 3)! - 0.5) < 1e-9)          // going back down
        #expect(abs(t.value(at: 2)! - 1) < 1e-9)
        #expect(abs(t.value(at: 4)! - 0) < 1e-9)
    }

    @Test func easingShapesTheCurve() {
        #expect(track(.once, easing: .easeIn).value(at: 1)! < 0.5)
        #expect(track(.once, easing: .easeOut).value(at: 1)! > 0.5)
        #expect(abs(track(.once, easing: .easeInOut).value(at: 1)! - 0.5) < 1e-9)
        #expect(track(.once, easing: .step).value(at: 1.99)! == 0)
    }

    @Test func degenerateTracks() {
        #expect(Track(property: .scale, keyframes: []).value(at: 1) == nil)
        #expect(Track(property: .scale, keyframes: [Keyframe(time: 5, value: 7)]).value(at: 0) == 7)
        let unsorted = Track(property: .scale, keyframes: [Keyframe(time: 2, value: 2), Keyframe(time: 0, value: 0)], loop: .once)
        #expect(abs(unsorted.value(at: 1)! - 1) < 1e-9)
        #expect(!Track(property: .scale, keyframes: [Keyframe(time: 0, value: 1), Keyframe(time: 1, value: 1)]).isAnimated)
    }
}

@Suite struct SceneEvaluatorTests {
    @Test func tracksOverrideBaseValuesAndOpacityIsClamped() {
        let layer = SceneLayer(id: "a", content: .solid(.white), opacity: 0.2, tracks: [
            Track(property: .opacity, keyframes: [Keyframe(time: 0, value: 0), Keyframe(time: 1, value: 3)], loop: .once),
            Track(property: .lightX, keyframes: [Keyframe(time: 0, value: 0.1), Keyframe(time: 1, value: 0.9)], loop: .once),
        ])
        let r = SceneEvaluator.resolve(layer, time: 1)
        #expect(r.opacity == 1)
        #expect(abs(r.effects.lightX - 0.9) < 1e-9)
        #expect(SceneEvaluator.resolve(layer, time: 0).opacity == 0)
    }

    @Test func parallaxMovesNearLayersAgainstThePointer() {
        let far = SceneLayer(id: "far", content: .solid(.white), parallaxDepth: 0)
        let near = SceneLayer(id: "near", content: .solid(.white), parallaxDepth: 1)
        let input = SceneInput(pointerX: 1, pointerY: -1)
        #expect(SceneEvaluator.resolve(far, time: 0, input: input).positionX == 0)
        let n = SceneEvaluator.resolve(near, time: 0, input: input)
        #expect(n.positionX < 0 && n.positionY > 0)          // pointer right and down → picture left and up
        #expect(abs(n.positionX + SceneEvaluator.parallaxStrength * 2) < 1e-9)
        #expect(SceneEvaluator.resolve(near, time: 0).positionX == 0)                       // pointer at centre = no shift
    }

    @Test func depthMappedLayersKeepTheirShiftForTheShader() {
        let layer = SceneLayer(id: "d", content: .image("a.png"), depthAsset: "d.png", parallaxDepth: 1)
        let r = SceneEvaluator.resolve(layer, time: 0, input: SceneInput(pointerX: 0.5, pointerY: 0))
        #expect(r.positionX == 0 && r.depthShiftX < 0)
    }
}

@Suite struct LayerGeometryTests {
    func corners(_ m: Affine2D) -> [(x: Double, y: Double)] { [(-0.5, -0.5), (0.5, 0.5)].map { m.apply($0.0, $0.1) } }

    @Test func coverLayerFillsNDC() {
        let m = LayerGeometry.affine(canvasAspect: 16.0 / 9, contentAspect: nil, scaling: .stretch, positionX: 0, positionY: 0, scale: 1, rotationDegrees: 0)
        let c = corners(m)
        #expect(abs(c[0].x + 1) < 1e-9 && abs(c[1].x - 1) < 1e-9 && abs(c[0].y + 1) < 1e-9 && abs(c[1].y - 1) < 1e-9)
    }

    @Test func fillCropsWideContentAndFitLetterboxesIt() {
        // 2:1 media on a square canvas.
        let fill = LayerGeometry.affine(canvasAspect: 1, contentAspect: 2, scaling: .fill, positionX: 0, positionY: 0, scale: 1, rotationDegrees: 0)
        #expect(abs(fill.apply(0.5, 0.5).x - 2) < 1e-9 && abs(fill.apply(0.5, 0.5).y - 1) < 1e-9)    // overflows horizontally
        let fit = LayerGeometry.affine(canvasAspect: 1, contentAspect: 2, scaling: .fit, positionX: 0, positionY: 0, scale: 1, rotationDegrees: 0)
        #expect(abs(fit.apply(0.5, 0.5).x - 1) < 1e-9 && abs(fit.apply(0.5, 0.5).y - 0.5) < 1e-9)     // bars top and bottom
    }

    @Test func tallContentOnWideCanvas() {
        let fit = LayerGeometry.affine(canvasAspect: 2, contentAspect: 0.5, scaling: .fit, positionX: 0, positionY: 0, scale: 1, rotationDegrees: 0)
        #expect(abs(fit.apply(0.5, 0.5).y - 1) < 1e-9 && abs(fit.apply(0.5, 0.5).x - 0.25) < 1e-9)
    }

    @Test func quarterTurnRotatesClockwiseWithoutDistortion() {
        let m = LayerGeometry.affine(canvasAspect: 1, contentAspect: 2, scaling: .fit, positionX: 0, positionY: 0, scale: 1, rotationDegrees: 90)
        // Fit 2:1 into the square: local +x edge (1,0 of aspect space) after a clockwise quarter turn points down.
        let p = m.apply(0.5, 0)
        #expect(abs(p.x) < 1e-9 && abs(p.y + 1) < 1e-9)
    }

    @Test func positionAndScaleMoveAndGrow() {
        let m = LayerGeometry.affine(canvasAspect: 2, contentAspect: nil, scaling: .stretch, positionX: 0.5, positionY: -0.25, scale: 0.5, rotationDegrees: 0)
        let centre = m.apply(0, 0)
        #expect(abs(centre.x - 0.5) < 1e-9 && abs(centre.y + 0.25) < 1e-9)
        #expect(abs(m.apply(0.5, 0).x - 0.5 - 0.5) < 1e-9)       // half-size layer: right edge is 0.5 NDC from its centre
    }
}

@Suite struct SceneCodecTests {
    @Test func roundTripsEveryBuiltInScene() throws {
        for scene in BuiltInScenes.all {
            let back = try SceneCodec.decode(try SceneCodec.encode(scene))
            #expect(back == scene, "\(scene.name)")
        }
    }

    @Test func minimalHandWrittenJSONUsesDefaults() throws {
        let json = #"{"version":1,"name":"Min","background":{"r":0,"g":0,"b":0,"a":1},"layers":[{"id":"c","content":{"kind":"color","color":{"r":1,"g":0,"b":0,"a":1},"color2":{"r":0,"g":0,"b":0,"a":1},"speed":1,"scale":1}}]}"#
        let scene = try SceneCodec.decode(Data(json.utf8))
        #expect(scene.layers[0].opacity == 1 && scene.layers[0].effects.isNeutral && scene.layers[0].blend == .normal)
    }

    @Test func rejectsBadScenes() throws {
        func scene(_ edit: (inout Scene) -> Void) -> Scene { var s = BuiltInScenes.plasma; edit(&s); return s }
        func reject(_ s: Scene) { #expect(throws: SceneError.self) { try SceneCodec.validate(s) } }
        reject(scene { $0.version = 99 })
        reject(scene { $0.background = RGBA(2, 0, 0) })
        reject(scene { $0.layers.append($0.layers[0]) })                                              // duplicate id
        reject(scene { $0.layers[0].content = .image("../../etc/passwd") })                           // path traversal
        reject(scene { $0.layers[0].content = LayerContent(kind: .procedural) })                      // no procedural kind
        reject(scene { $0.layers[0].scale = 0 })
        reject(scene { $0.layers[0].opacity = .nan })
        reject(scene { $0.layers[0].depthAsset = "a/b.png" })
        reject(scene { $0.layers[0].tracks = [Track(property: .scale, keyframes: [Keyframe(time: 0, value: .infinity)])] })
        reject(scene { s in s.layers = (0..<100).map { SceneLayer(id: "l\($0)", content: .solid(.black)) } })
    }

    @Test func rejectsGarbageAndOversizedData() {
        #expect(throws: SceneError.self) { try SceneCodec.decode(Data("nope".utf8)) }
        #expect(throws: SceneError.tooLarge) { try SceneCodec.decode(Data(count: SceneCodec.maxBytes + 1)) }
    }

    @Test func animatedAndPointerDetection() {
        #expect(BuiltInScenes.plasma.isAnimated)
        let still = Scene(name: "s", layers: [SceneLayer(id: "a", content: .image("a.png"))])
        #expect(!still.isAnimated && !still.reactsToPointer)
        #expect(Scene(name: "v", layers: [SceneLayer(id: "a", content: .video("a.mp4"))]).isAnimated)
        var vignetteOnly = SceneLayer(id: "a", content: .image("a.png")); EffectPreset.vignette.apply(to: &vignetteOnly)
        #expect(!Scene(name: "x", layers: [vignetteOnly]).isAnimated)               // static effect → draw once
        var cycle = SceneLayer(id: "a", content: .image("a.png")); EffectPreset.colorCycle.apply(to: &cycle)
        #expect(Scene(name: "x", layers: [cycle]).isAnimated)
        #expect(Scene(name: "p", layers: [SceneLayer(id: "a", content: .image("a.png"), parallaxDepth: 0.5)]).reactsToPointer)
        #expect(still.referencedAssets == ["a.png"])
    }

    @Test func presetsBuildWrappedScenes() throws {
        for preset in EffectPreset.allCases {
            let scene = Scene.wrapping(media: .image, asset: "m.png", scaling: .fit, preset: preset)
            try SceneCodec.validate(scene)
            #expect(scene.layers[0].scaling == .fit)
            #expect(scene.layers[0].effects.isNeutral == (preset == .none))
        }
    }
}

@Suite struct RenderQualityTests {
    @Test func drawableSizeAppliesScaleAndResolution() {
        let s = RenderQuality.drawableSize(points: CGSize(width: 1920, height: 1080), scale: 2, resolutionScale: 0.5)
        #expect(s.width == 1920 && s.height == 1080)
        let full = RenderQuality.drawableSize(points: CGSize(width: 1920, height: 1080), scale: 2, resolutionScale: 1)
        #expect(full.width == 3840)
        let tiny = RenderQuality.drawableSize(points: CGSize(width: 0, height: 0), scale: 2, resolutionScale: 1)
        #expect(tiny.width == 1 && tiny.height == 1)                                    // never zero
        let huge = RenderQuality.drawableSize(points: CGSize(width: 50_000, height: 100), scale: 2, resolutionScale: 1)
        #expect(huge.width == 8192)
        let low = RenderQuality.drawableSize(points: CGSize(width: 1000, height: 1000), scale: 1, resolutionScale: 0.01)
        #expect(low.width == 100)                                                       // floor at 10 %
    }

    @Test func effectiveFPSRespectsCapAndDisplay() {
        #expect(RenderQuality.effectiveFPS(maxFPS: nil, displayMax: 120) == 120)
        #expect(RenderQuality.effectiveFPS(maxFPS: 30, displayMax: 120) == 30)
        #expect(RenderQuality.effectiveFPS(maxFPS: 144, displayMax: 60) == 60)
        #expect(RenderQuality.effectiveFPS(maxFPS: 0, displayMax: 60) == 60)
        #expect(RenderQuality.effectiveFPS(maxFPS: 30, displayMax: 0) == 1)
    }
}

@Suite struct LegacyLayoutCompatibilityTests {
    @Test func oldDisplaysJSONWithoutNewFieldsStillLoads() throws {
        let json = #"{"version":1,"configs":{"U":{"wallpaperPath":"/a.mp4","scaling":"fit","rotation":90,"speed":2,"volume":0.3,"muted":false,"paused":true}},"modes":{},"knownNames":{}}"#
        let state = try JSONDecoder().decode(DisplayLayoutState.self, from: Data(json.utf8))
        let c = try #require(state.configs["U"])
        #expect(c.rotation == .r90 && c.effect == .none && c.resolutionScale == 1 && c.paused)
    }

    @Test func sceneFilesAreRecognised() {
        #expect(WallpaperKind.detect(pathExtension: "wsscene") == .scene)
    }
}
