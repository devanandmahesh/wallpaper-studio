import Testing
import AppKit
import StudioCore
import StudioRender
@testable import WallpaperStudio

final class ManualPointerSource: PointerSource {
    var onEvent: (() -> Void)?
    private(set) var isRunning = false
    var location = CGPoint.zero
    var speed = 0.0
    var clickSerial = 0
    var clickLocation = CGPoint.zero
    private(set) var starts = 0, stops = 0
    func start() { if !isRunning { isRunning = true; starts += 1 } }
    func stop() { if isRunning { isRunning = false; stops += 1 } }
    func sample(now: Double) -> PointerSample {
        PointerSample(location: location, speed: speed, clickSerial: clickSerial, clickLocation: clickLocation, clickPulse: 0)
    }
    func move(to p: CGPoint) { location = p; if isRunning { onEvent?() } }
    func click(at p: CGPoint) { clickSerial += 1; clickLocation = p; location = p; if isRunning { onEvent?() } }
}

final class ManualKeySource: KeyActivitySource {
    var onEvent: (() -> Void)?
    private(set) var isRunning = false
    var isAuthorized = true
    var level = 0.0
    private(set) var authorizationRequests = 0
    func requestAuthorization() { authorizationRequests += 1 }
    func start() { if isAuthorized { isRunning = true } }
    func stop() { isRunning = false }
    func pulse(now: Double) -> Double { level }
    func type() { level = min(1, level + 0.3); if isRunning { onEvent?() } }
}

@MainActor
@Suite struct InteractionHubTests {
    func hub() -> (InteractionHub, ManualPointerSource, ManualKeySource) {
        let p = ManualPointerSource(), k = ManualKeySource()
        return (InteractionHub(pointer: p, keys: k), p, k)
    }

    @Test func monitorsOnlyRunWhileAClientNeedsThem() {
        let (hub, p, k) = hub()
        #expect(!p.isRunning && !k.isRunning)
        let t1 = hub.acquire(pointer: true, keys: false)
        #expect(p.isRunning && !k.isRunning)
        let t2 = hub.acquire(pointer: true, keys: false)
        hub.release(t1)
        #expect(p.isRunning)                         // still one client
        hub.release(t2)
        #expect(!p.isRunning && p.starts == 1 && p.stops == 1)
    }

    @Test func keyboardNeedsBothTheSettingAndThePermission() {
        let (hub, _, k) = hub()
        let token = hub.acquire(pointer: false, keys: true)
        #expect(!k.isRunning)                        // setting is off by default
        hub.keysEnabled = true
        #expect(k.isRunning)
        hub.keysEnabled = false
        #expect(!k.isRunning)
        k.isAuthorized = false
        hub.keysEnabled = true
        #expect(!k.isRunning && !hub.keysAuthorized) // no permission → never starts
        hub.release(token)
    }

    @Test func switchingPointerReactionsOffStopsWatchingAndHidesTheCursor() {
        let (hub, p, _) = hub()
        let token = hub.acquire(pointer: true, keys: false)
        p.location = CGPoint(x: 5, y: 5)
        #expect(hub.snapshot().pointer?.location == CGPoint(x: 5, y: 5))
        hub.pointerEnabled = false
        #expect(!p.isRunning && hub.snapshot().pointer == nil)
        hub.pointerEnabled = true
        #expect(p.isRunning)
        hub.release(token)
    }

    @Test func subscribersHearAboutInputAndSettingChanges() {
        let (hub, p, k) = hub()
        let token = hub.acquire(pointer: true, keys: true)
        hub.keysEnabled = true
        var heard = 0
        let id = hub.subscribe { heard += 1 }
        p.move(to: CGPoint(x: 1, y: 1)); k.type(); p.click(at: .zero)
        #expect(heard == 3)
        hub.unsubscribe(id)
        p.move(to: CGPoint(x: 2, y: 2))
        #expect(heard == 3)
        hub.release(token)
    }

    @Test func snapshotsCarryKeyPulsesOnlyWhileEnabled() {
        let (hub, _, k) = hub()
        let token = hub.acquire(pointer: false, keys: true)
        k.level = 0.7
        #expect(hub.snapshot().keyPulse == 0)        // disabled
        hub.keysEnabled = true
        #expect(hub.snapshot().keyPulse == 0.7)
        hub.release(token)
    }
}

@MainActor
@Suite struct InteractiveRendererTests {
    init() { MetalSceneRenderer.pacingMode = .timer }

    func spin(_ seconds: Double) async {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)); try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    let screen = CGRect(x: 0, y: 0, width: 400, height: 200)

    func hubWithManual() -> (InteractionHub, ManualPointerSource, ManualKeySource) {
        let p = ManualPointerSource(), k = ManualKeySource()
        return (InteractionHub(pointer: p, keys: k), p, k)
    }

    func layer(for r: MetalSceneRenderer, frame: CGRect? = nil) -> StudioMetalLayer {
        let layer = r.makeLayer() as! StudioMetalLayer
        layer.contentsScale = 2
        layer.screenFrame = frame ?? screen
        layer.bounds = CGRect(origin: .zero, size: CGSize(width: 400, height: 200))
        return layer
    }

    @Test func aStaticParallaxSceneStartsMonitoringAndRedrawsOnlyWhenTheMouseMoves() async throws {
        let (hub, pointer, _) = hubWithManual()
        let scene = StudioCore.Scene(name: "par", layers: [SceneLayer(id: "i", content: .image(Fixtures.png(32, 32).lastPathComponent), scale: 1.3, parallaxDepth: 1)])
        let r = try #require(MetalSceneRenderer(scene: scene, assetBase: Fixtures.dir, kind: .image, wrapsMedia: true,
                                                settings: RenderSettings(effect: .vignette), loops: true, interaction: hub))
        let l = layer(for: r)
        #expect(!pointer.isRunning)
        r.play(); await spin(0.3)
        #expect(pointer.isRunning)
        let idle = r.stats.frames
        await spin(0.4)
        #expect(r.stats.frames == idle)                           // nothing moves → nothing is drawn
        pointer.move(to: CGPoint(x: 300, y: 100)); await spin(0.3)
        #expect(r.stats.frames > idle)
        #expect(r.lastSimInput.pointerActive && r.lastSimInput.pointerX > 0.4)
        r.pause()
        #expect(!pointer.isRunning)                               // monitors stop with the wallpaper
        r.teardown()
        withExtendedLifetime(l) {}
    }

    @Test func sceneInputIsMappedOntoTheLayersDisplay() async throws {
        guard NSScreen.main != nil else { return }
        let (hub, pointer, _) = hubWithManual()
        var spec = ParticleSpec(); spec.count = 50; spec.pointerMode = .attract
        let scene = StudioCore.Scene(name: "p", layers: [SceneLayer(id: "p", content: .particles(spec))])
        let r = try #require(MetalSceneRenderer(scene: scene, assetBase: nil, kind: .scene, wrapsMedia: false, settings: RenderSettings(maxFPS: 30), loops: true, interaction: hub))
        let second = CGRect(x: 1000, y: 0, width: 400, height: 200)
        let l = layer(for: r, frame: second)
        r.play(); await spin(0.3)
        pointer.location = CGPoint(x: 1100, y: 150); pointer.speed = 400; await spin(0.3)
        let input = r.lastSimInput
        #expect(input.pointerActive)
        #expect(abs(input.pointerX + 0.5) < 0.01 && abs(input.pointerY - 0.5) < 0.01, "\(input.pointerX), \(input.pointerY)")
        #expect(abs(input.pointerSpeed - 1) < 0.01)               // 400 pt/s on a 200 pt tall screen → clamped to 1
        pointer.location = CGPoint(x: 100, y: 100); await spin(0.3)   // cursor on another display
        #expect(!r.lastSimInput.pointerActive)
        r.teardown()
        withExtendedLifetime(l) {}
    }

    @Test func clicksReachTheSimulationAndLaunchParticles() async throws {
        guard NSScreen.main != nil else { return }
        let (hub, pointer, _) = hubWithManual()
        var spec = ParticleSpec(); spec.count = 100; spec.burstCount = 30
        let scene = StudioCore.Scene(name: "b", layers: [SceneLayer(id: "p", content: .particles(spec))])
        let r = try #require(MetalSceneRenderer(scene: scene, assetBase: nil, kind: .scene, wrapsMedia: false, settings: RenderSettings(maxFPS: 30), loops: true, interaction: hub))
        let l = layer(for: r)
        r.play(); await spin(0.4)
        let before = r.lastSimInput.clickSerial
        pointer.click(at: CGPoint(x: 200, y: 100)); await spin(0.3)
        #expect(r.lastSimInput.clickSerial == before + 1)
        #expect(abs(r.lastSimInput.clickX) < 0.02 && abs(r.lastSimInput.clickY) < 0.02)
        r.teardown()
        withExtendedLifetime(l) {}
    }

    @Test func rotatedDisplaysMapThePointerBackIntoContentSpace() async throws {
        guard NSScreen.main != nil else { return }
        let (hub, pointer, _) = hubWithManual()
        var spec = ParticleSpec(); spec.count = 20; spec.pointerMode = .attract
        let scene = StudioCore.Scene(name: "r", layers: [SceneLayer(id: "p", content: .particles(spec))])
        let r = try #require(MetalSceneRenderer(scene: scene, assetBase: nil, kind: .scene, wrapsMedia: false, settings: RenderSettings(maxFPS: 30), loops: true, interaction: hub))
        let l = layer(for: r)
        l.contentRotation = .r90
        r.play(); await spin(0.2)
        pointer.location = CGPoint(x: 399, y: 100); await spin(0.3)        // right edge of the screen
        #expect(r.lastSimInput.pointerY > 0.98 && abs(r.lastSimInput.pointerX) < 0.02, "\(r.lastSimInput.pointerX), \(r.lastSimInput.pointerY)")
        r.teardown()
        withExtendedLifetime(l) {}
    }

    @Test func nothingIsMonitoredForScenesThatIgnoreInput() async throws {
        let (hub, pointer, keys) = hubWithManual()
        hub.keysEnabled = true
        let r = try #require(MetalSceneRenderer(scene: BuiltInScenes.plasma, assetBase: nil, kind: .scene, wrapsMedia: false, settings: RenderSettings(maxFPS: 30), loops: true, interaction: hub))
        let l = layer(for: r)
        r.play(); await spin(0.3)
        #expect(!pointer.isRunning && !keys.isRunning)
        r.teardown()
        withExtendedLifetime(l) {}
    }

    @Test func typingOnlyMattersToScenesThatAskForIt() async throws {
        let (hub, pointer, keys) = hubWithManual()
        hub.keysEnabled = true
        let r = try #require(MetalSceneRenderer(scene: BuiltInScenes.stardustTrail, assetBase: nil, kind: .scene, wrapsMedia: false, settings: RenderSettings(maxFPS: 30), loops: true, interaction: hub))
        let l = layer(for: r)
        r.play(); await spin(0.3)
        #expect(pointer.isRunning && keys.isRunning)               // this scene reacts to both
        keys.level = 0.9; await spin(0.3)
        #expect(r.lastSimInput.keyPulse == 0.9)
        r.pause()
        #expect(!pointer.isRunning && !keys.isRunning)
        r.teardown()
        withExtendedLifetime(l) {}
    }
}
