import Testing
import AppKit
import StudioCore
import StudioRender
@testable import WallpaperStudio

@MainActor
@Suite struct MetalRendererTests {
    init() { MetalSceneRenderer.pacingMode = .timer }

    func sceneFile(_ scene: StudioCore.Scene, name: String = UUID().uuidString) throws -> URL {
        let url = Fixtures.dir.appendingPathComponent("\(name).wsscene")
        try SceneCodec.encode(scene).write(to: url)
        return url
    }

    /// Alternates short run-loop slices (display links, `RunLoop.perform`) with yields (main-queue work from other tests).
    func spin(_ seconds: Double) async {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func attached(_ r: MetalSceneRenderer, size: CGSize = CGSize(width: 400, height: 200)) -> StudioMetalLayer {
        let layer = r.makeLayer() as! StudioMetalLayer
        layer.contentsScale = 2
        layer.bounds = CGRect(origin: .zero, size: size)
        return layer
    }

    @Test func routingKeepsPlainMediaOnCoreAnimation() {
        func uses(_ kind: WallpaperKind, _ s: RenderSettings) -> Bool { RendererFactory.usesMetal(kind: kind, settings: s) }
        #expect(!uses(.image, RenderSettings()) && !uses(.video, RenderSettings()) && !uses(.animatedImage, RenderSettings()))
        #expect(uses(.scene, RenderSettings()))
        #expect(uses(.image, RenderSettings(effect: .ripple)) && uses(.video, RenderSettings(effect: .glow)))
        #expect(uses(.video, RenderSettings(maxFPS: 30)))
        #expect(!uses(.image, RenderSettings(maxFPS: 30)))                      // nothing to throttle in a still
        #expect(!uses(.animatedImage, RenderSettings(maxFPS: 15, effect: .ripple)))
    }

    @Test func factoryBuildsTheRightRenderers() throws {
        let png = Fixtures.png(64, 64)
        #expect(RendererFactory.make(url: try sceneFile(BuiltInScenes.plasma), loops: true, settings: RenderSettings(), maxPixel: 800) is MetalSceneRenderer)
        #expect(RendererFactory.make(url: png, loops: true, settings: RenderSettings(effect: .vignette), maxPixel: 800) is MetalSceneRenderer)
        #expect(RendererFactory.make(url: png, loops: true, settings: RenderSettings(), maxPixel: 800) is StaticImageRenderer)
        #expect(RendererFactory.make(url: Fixtures.mp4(), loops: true, settings: RenderSettings(maxFPS: 15), maxPixel: 800) is MetalSceneRenderer)
        #expect(RendererFactory.make(url: Fixtures.gif(frames: 3, delay: 0.1), loops: true, settings: RenderSettings(effect: .ripple), maxPixel: 800) is AnimatedImageRenderer)
        let broken = Fixtures.dir.appendingPathComponent("broken.wsscene")
        try Data("{}".utf8).write(to: broken)
        #expect(RendererFactory.make(url: broken, loops: true, settings: RenderSettings(), maxPixel: 800) == nil)
    }

    @Test func drawableSizeFollowsLayerSizeAndRenderResolution() async throws {
        let r = try #require(MetalSceneRenderer(scene: BuiltInScenes.plasma, assetBase: nil, kind: .scene, wrapsMedia: false, settings: RenderSettings(), loops: true))
        let layer = attached(r)
        r.play(); await spin(0.3)
        #expect(layer.drawableSize == CGSize(width: 800, height: 400))
        r.apply(RenderSettings(resolutionScale: 0.5)); await spin(0.3)
        #expect(layer.drawableSize == CGSize(width: 400, height: 200))
        layer.bounds = CGRect(x: 0, y: 0, width: 200, height: 400)                       // e.g. display rotated
        await spin(0.3)
        #expect(layer.drawableSize == CGSize(width: 200, height: 400))
        r.teardown()
    }

    @Test func frameLimitIsReallyEnforced() async throws {
        guard NSScreen.main != nil else { return }
        let r = try #require(MetalSceneRenderer(scene: BuiltInScenes.plasma, assetBase: nil, kind: .scene, wrapsMedia: false, settings: RenderSettings(maxFPS: 10), loops: true))
        let layer = attached(r)
        r.play(); await spin(0.3)
        let start = r.stats.frames
        await spin(2.0)
        let at10 = r.stats.frames - start
        print("PERF frames in 2 s at 10 fps cap: \(at10)")
        #expect((13...26).contains(at10), "got \(at10) frames in 2 s at a 10 fps cap")

        r.apply(RenderSettings(maxFPS: 30)); await spin(0.3)
        let mid = r.stats.frames
        await spin(2.0)
        let at30 = r.stats.frames - mid
        print("PERF frames in 2 s at 30 fps cap: \(at30)")
        #expect((48...70).contains(at30), "got \(at30) frames in 2 s at a 30 fps cap")
        r.teardown()
        withExtendedLifetime(layer) {}
    }

    @Test func pausingStopsRenderingAndResumingContinues() async throws {
        guard NSScreen.main != nil else { return }
        let r = try #require(MetalSceneRenderer(scene: BuiltInScenes.plasma, assetBase: nil, kind: .scene, wrapsMedia: false, settings: RenderSettings(maxFPS: 30), loops: true))
        let layer = attached(r)
        r.play(); await spin(0.5)
        r.pause(); await spin(0.2)
        let frozen = r.stats.frames
        await spin(0.6)
        #expect(r.stats.frames == frozen)
        r.play(); await spin(0.6)
        #expect(r.stats.frames > frozen + 5)
        r.teardown()
        withExtendedLifetime(layer) {}
    }

    @Test func staticScenesRenderOnDemandOnly() async throws {
        var layerVignette = SceneLayer(id: "m", content: .image(Fixtures.png(64, 64).lastPathComponent))
        EffectPreset.vignette.apply(to: &layerVignette)
        let scene = StudioCore.Scene(name: "still", layers: [layerVignette])
        let r = try #require(MetalSceneRenderer(scene: scene, assetBase: Fixtures.dir, kind: .image, wrapsMedia: true, settings: RenderSettings(effect: .vignette), loops: true))
        let layer = attached(r)
        r.play(); await spin(0.6)
        let after = r.stats.frames
        #expect(after >= 1 && after <= 4, "a still scene should draw a handful of times, drew \(after)")
        #expect(r.framesTicked == 0)                                                    // no display link running
        layer.bounds = CGRect(x: 0, y: 0, width: 300, height: 300)                      // resizing triggers one redraw
        await spin(0.4)
        #expect(r.stats.frames > after)
        r.teardown()
    }

    @Test func videoWithAFrameCapGoesThroughMetalAndReportsEnd() async throws {
        let r = try #require(RendererFactory.make(url: Fixtures.mp4(seconds: 1), loops: false, settings: RenderSettings(speed: 2, maxFPS: 15), maxPixel: 800))
        #expect(r is MetalSceneRenderer)
        _ = r.makeLayer()
        var finished = false
        r.onFinished = { finished = true }
        r.play()
        for _ in 0..<80 where !finished { await spin(0.1) }
        #expect(finished)
        r.teardown()
    }

    @Test func snapshotCapturesTheCurrentPicture() throws {
        let r = try #require(MetalSceneRenderer(scene: BuiltInScenes.plasma, assetBase: nil, kind: .scene, wrapsMedia: false, settings: RenderSettings(), loops: true))
        let image = try #require(r.snapshot())
        // Sized like the main display, so the picture keeps the screen's proportions.
        let screen = NSScreen.main?.frame.size ?? CGSize(width: 1920, height: 1080)
        #expect(image.width >= 640 && image.height >= 360)
        #expect(abs(Double(image.width) / Double(image.height) - Double(screen.width / screen.height)) < 0.02)
        r.teardown()
    }

    @Test func effectChangeRebuildsTheDisplayContent() throws {
        _ = NSApplication.shared
        let m = DesktopWindowManager()
        m.presentsWindows = false
        m.pauseWhenCovered = false
        let display = DisplayDescriptor(id: 9, uuid: "u", name: "D", frame: CGRect(x: 0, y: 0, width: 800, height: 600), scale: 2, maxFPS: 60, isMain: true)
        m.reconcile(displays: [display])
        let png = Fixtures.png(64, 64)
        func content(_ effect: EffectPreset) -> DesktopContent {
            DesktopContent(mode: .mirror, mainURL: png, mainSettings: RenderSettings(effect: effect), loopsMain: true, configs: [:], maxPixel: 800)
        }
        m.apply(content(.none))
        #expect(!(m.sessions[9]?.window.contentLayer is CAMetalLayer))
        m.apply(content(.colorCycle))
        #expect(m.sessions[9]?.window.contentLayer is CAMetalLayer)
        m.apply(content(.none))
        #expect(!(m.sessions[9]?.window.contentLayer is CAMetalLayer))
    }
}

@MainActor
@Suite struct SceneLibraryTests {
    func makeModel() -> LibraryModel {
        let name = UUID().uuidString
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ws-scene-\(name)/LiveWallpaper/Library")
        let defaults = UserDefaults(suiteName: "ws-scene-\(name)")!
        defaults.removePersistentDomain(forName: "ws-scene-\(name)")
        return LibraryModel(storage: LibraryStorage(root: root), defaults: defaults)
    }

    @Test func builtInScenesInstallOnceAndGetThumbnails() async throws {
        let model = makeModel()
        let a = try #require(await model.installBuiltIn(BuiltInScenes.aurora))
        let b = try #require(await model.installBuiltIn(BuiltInScenes.aurora))
        #expect(a.id == b.id && model.records.count == 1)
        #expect(a.kind == .scene && a.category == "Generated" && a.tags.contains("gpu"))
        let thumb = try #require(await model.thumbnail(for: a))
        #expect(thumb.size.width > 100)
        #expect(FileManager.default.fileExists(atPath: model.storage.thumbURL(id: a.id).path))
    }

    @Test func scenesThatNeedExternalMediaAreRejectedForNow() async throws {
        let model = makeModel()
        let scene = StudioCore.Scene(name: "needs media", layers: [SceneLayer(id: "a", content: .image("photo.png"))])
        let file = Fixtures.dir.appendingPathComponent("needs-\(UUID().uuidString).wsscene")
        try SceneCodec.encode(scene).write(to: file)
        await #expect(throws: LibraryError.self) { try await model.importFile(file) }
        #expect(model.records.isEmpty)
    }

    @Test func tamperedSceneFilesAreRejected() async throws {
        let model = makeModel()
        let file = Fixtures.dir.appendingPathComponent("bad-\(UUID().uuidString).wsscene")
        try Data(#"{"version":1,"name":"x","background":{"r":9,"g":0,"b":0,"a":1},"layers":[]}"#.utf8).write(to: file)
        await #expect(throws: LibraryError.self) { try await model.importFile(file) }
    }

    @Test func playingAGeneratedWallpaperCallsThePlayer() async throws {
        let model = makeModel()
        var played: URL?
        model.onPlay = { played = $0 }
        let r = try #require(await model.installBuiltIn(BuiltInScenes.nightWaves))
        await model.play(r)
        #expect(played?.pathExtension == "wsscene")
    }
}
