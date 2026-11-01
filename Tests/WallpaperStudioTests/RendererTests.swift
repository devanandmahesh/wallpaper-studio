import Testing
import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import StudioCore
@testable import WallpaperStudio

@Suite struct RendererTests {
    let settings = RenderSettings()

    @Test func factoryPicksRendererByKind() {
        #expect(RendererFactory.make(url: Fixtures.png(100, 50), loops: true, settings: settings, maxPixel: 200)?.kind == .image)
        #expect(RendererFactory.make(url: Fixtures.gif(frames: 4, delay: 0.1), loops: true, settings: settings, maxPixel: 200)?.kind == .animatedImage)
        #expect(RendererFactory.make(url: Fixtures.mp4(), loops: true, settings: settings, maxPixel: 200)?.kind == .video)
    }

    @Test func unsupportedFileGetsNoRenderer() {
        let url = Fixtures.dir.appendingPathComponent("movie.mkv")
        #expect(RendererFactory.make(url: url, loops: true, settings: settings, maxPixel: 200) == nil)
    }

    @Test func staticImageIsDownsampledToDisplaySize() throws {
        let renderer = try #require(StaticImageRenderer(url: Fixtures.png(4000, 2000), maxPixel: 500, settings: settings))
        let snap = try #require(renderer.snapshot())
        #expect(max(snap.width, snap.height) == 500)
        #expect(renderer.makeLayer().contents != nil)
    }

    @Test func corruptImageFailsInsteadOfCrashing() {
        let url = Fixtures.dir.appendingPathComponent("broken.png")
        try? Data("not an image".utf8).write(to: url)
        #expect(StaticImageRenderer(url: url, maxPixel: 500, settings: settings) == nil)
        #expect(!AppDelegate.canDisplay(url))
    }

    @Test func gifAnimatesAndPausesAndResumes() throws {
        let renderer = try #require(AnimatedImageRenderer(url: Fixtures.gif(frames: 5, delay: 0.1), maxPixel: 200, settings: settings))
        let layer = renderer.makeLayer()
        let animation = try #require(layer.animation(forKey: "frames") as? CAKeyframeAnimation)
        #expect(animation.values?.count == 5)
        #expect(animation.keyTimes?.count == 6)
        #expect(abs(animation.duration - 0.5) < 0.001)
        #expect(layer.speed == 0)              // starts paused until play()
        renderer.play()
        #expect(layer.speed == 1)
        renderer.pause()
        #expect(layer.speed == 0)
        renderer.apply(RenderSettings(speed: 2))
        renderer.play()
        #expect(layer.speed == 2)
    }

    @Test func singleFrameGifFallsBackToStatic() {
        let url = Fixtures.gif(frames: 1, delay: 0.1)
        #expect(AnimatedImageRenderer(url: url, maxPixel: 200, settings: settings) == nil)
        #expect(RendererFactory.make(url: url, loops: true, settings: settings, maxPixel: 200)?.kind == .image)
    }

    @Test func videoRendererVendsLayersAndSnapshots() throws {
        let renderer = try #require(VideoWallpaperRenderer(url: Fixtures.mp4(), loops: true, settings: settings))
        let layer = try #require(renderer.makeLayer() as? AVPlayerLayer)
        #expect(layer.videoGravity == .resizeAspectFill)
        renderer.apply(RenderSettings(scaling: .fit))
        #expect(layer.videoGravity == .resizeAspect)
        #expect(renderer.snapshot() != nil)
        renderer.teardown()
        #expect(layer.player == nil)
    }

    @Test func videoPlaylistModeReportsFinish() async throws {
        let renderer = try #require(VideoWallpaperRenderer(url: Fixtures.mp4(seconds: 1), loops: false, settings: RenderSettings(speed: 2)))
        _ = renderer.makeLayer()
        var finished = false
        renderer.onFinished = { finished = true }
        renderer.play()
        for _ in 0..<60 where !finished { try await Task.sleep(nanoseconds: 100_000_000) }
        #expect(finished)
        renderer.teardown()
    }
}

@Suite struct ScalingAndFrameCapTests {
    @Test func scalingModesMapToLayerGravity() throws {
        let still = try #require(StaticImageRenderer(url: Fixtures.png(40, 20), maxPixel: 100, settings: RenderSettings()))
        let layer = still.makeLayer()
        #expect(layer.contentsGravity == .resizeAspectFill)
        still.apply(RenderSettings(scaling: .fit)); #expect(layer.contentsGravity == .resizeAspect)
        still.apply(RenderSettings(scaling: .stretch)); #expect(layer.contentsGravity == .resize)
        let video = try #require(VideoWallpaperRenderer(url: Fixtures.mp4(), loops: true, settings: RenderSettings(scaling: .stretch)))
        #expect((video.makeLayer() as? AVPlayerLayer)?.videoGravity == .resize)
        video.teardown()
    }

    @Test func gifFrameCapResamplesTheRunningAnimation() throws {
        // 10 frames at 25 fps.
        let renderer = try #require(AnimatedImageRenderer(url: Fixtures.gif(frames: 10, delay: 0.04), maxPixel: 100, settings: RenderSettings()))
        let layer = renderer.makeLayer()
        func frames() -> Int { (layer.animation(forKey: "frames") as? CAKeyframeAnimation)?.values?.count ?? -1 }
        func duration() -> Double { (layer.animation(forKey: "frames") as? CAKeyframeAnimation)?.duration ?? -1 }
        #expect(frames() == 10)
        renderer.apply(RenderSettings(maxFPS: 10))
        #expect(frames() == 4 && renderer.effectiveFrameCount == 4)
        #expect(abs(duration() - 0.4) < 1e-9)                      // total duration is unchanged
        renderer.apply(RenderSettings(maxFPS: nil))
        #expect(frames() == 10)
    }
}
