import Testing
import AppKit
import StudioCore
@testable import WallpaperStudio

final class FakeSystem {
    var power = PowerState()
    var thermal = ThermalLevel.nominal
    var memory = MemoryPressureLevel.normal
    var cpu = 1.0
    var displayFPS = 120
    var now = 0.0
    var readers: ConditionReaders {
        ConditionReaders(power: { self.power }, thermal: { self.thermal }, memory: { self.memory }, cpuPercent: { _ in self.cpu },
                         displayMaxFPS: { self.displayFPS }, now: { self.now })
    }
}

@MainActor
@Suite struct PerformanceControllerTests {
    func make(_ sys: FakeSystem, profile: PerformanceProfile? = nil) -> PerformanceController {
        let name = "perf-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let c = PerformanceController(readers: sys.readers, defaults: defaults)
        if let profile { c.profile = profile }
        return c
    }

    @Test func balancedIsTheDefaultAndPublishesItsLimits() {
        let c = make(FakeSystem())
        #expect(c.profile == .balanced && c.decision.fpsCap == 30 && !c.decision.paused)
    }

    @Test func theChosenProfileIsRememberedAndChangesTheLimitsImmediately() {
        let name = "perf-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let sys = FakeSystem()
        let c = PerformanceController(readers: sys.readers, defaults: defaults)
        var changes = 0
        c.onDecisionChange = { changes += 1 }
        c.profile = .batterySaver
        #expect(c.decision.fpsCap == 15 && changes == 1)
        let again = PerformanceController(readers: sys.readers, defaults: defaults)
        #expect(again.profile == .batterySaver)
    }

    @Test func conditionsFeedTheDecisionAndOnlyRealChangesAreAnnounced() {
        let sys = FakeSystem()
        let c = make(sys, profile: .performance)
        var changes = 0
        c.onDecisionChange = { changes += 1 }
        c.evaluate(); c.evaluate()
        #expect(changes == 0)                                       // nothing changed → nobody is bothered
        sys.power = PowerState(onBattery: true, batteryFraction: 0.5, lowPowerMode: false)
        c.poke()
        #expect(c.decision.fpsCap == 30 && changes == 1 && c.conditions.onBattery)
        sys.thermal = .critical
        c.poke()
        #expect(c.decision.paused && changes == 2)
        sys.thermal = .nominal
        c.poke()
        #expect(!c.decision.paused && changes == 3)
    }

    @Test func memoryPressureAsksTheAppToTrimOnceNotRepeatedly() {
        let sys = FakeSystem()
        let c = make(sys)
        var trims = 0
        c.onTrimMemory = { trims += 1 }
        sys.memory = .warning
        c.poke(); c.poke(); c.poke()
        #expect(trims == 1)
        sys.memory = .normal
        c.poke()
        sys.memory = .critical
        c.poke()
        #expect(trims == 2)
    }

    @Test func theAdaptiveProfileRespondsToSustainedLoadOverTime() {
        let sys = FakeSystem()
        let c = make(sys, profile: .adaptive)
        #expect(c.decision.fpsCap == 60)
        sys.cpu = 50
        for step in 0..<10 { sys.now = Double(step) * 3; c.evaluate() }
        #expect(c.decision.fpsCap < 60 && c.decision.reasons.contains("adapting to load"), "\(c.decision.summary)")
        sys.cpu = 1
        for step in 0..<150 { sys.now = 30 + Double(step) * 3; c.evaluate() }
        #expect(c.decision.fpsCap == 60)                            // recovers after a long calm
    }

    @Test func displayCapsLimitTheDecision() {
        let sys = FakeSystem()
        sys.displayFPS = 24
        let c = make(sys, profile: .performance)
        #expect(c.decision.fpsCap == 24)
    }

    @Test func evaluatingIsCheap() {
        let sys = FakeSystem()
        let c = make(sys, profile: .adaptive)
        let start = ProcessInfo.processInfo.systemUptime
        for i in 0..<2000 { sys.now = Double(i); c.evaluate() }
        let perCall = (ProcessInfo.processInfo.systemUptime - start) / 2000 * 1_000_000
        print("PERF controller evaluate: \(perCall) µs per call")
        #expect(perCall < 500)
    }

    @Test func realMonitorsReturnPlausibleValues() {
        let power = PowerMonitor()
        #expect((power.state.batteryFraction ?? 0.5) >= 0 && (power.state.batteryFraction ?? 0.5) <= 1)
        let cpu = CPUMonitor()
        _ = cpu.sample(now: 0)
        var x = 0.0
        for i in 0..<3_000_000 { x += Double(i).squareRoot() }              // burn a little CPU
        let percent = cpu.sample(now: ProcessInfo.processInfo.systemUptime + 0.0001)
        #expect(percent >= 0 && x > 0)
        #expect(ThermalMonitor().level >= .nominal)
        #expect(MemoryPressureMonitor().level == .normal)
    }
}

@MainActor
@Suite struct PerformanceIntegrationTests {
    init() { MetalSceneRenderer.pacingMode = .timer }

    func display(_ id: UInt32 = 5) -> DisplayDescriptor {
        DisplayDescriptor(id: id, uuid: "u\(id)", name: "D", frame: CGRect(x: 0, y: 0, width: 800, height: 600), scale: 2, maxFPS: 120, isMain: true)
    }

    func manager() -> DesktopWindowManager {
        _ = NSApplication.shared
        let m = DesktopWindowManager()
        m.presentsWindows = false
        m.pauseWhenCovered = false
        m.reconcile(displays: [display()])
        return m
    }

    func spin(_ s: Double) async {
        let end = Date().addingTimeInterval(s)
        while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)); try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    @Test func thePolicyCapReachesTheRunningGPURendererWithoutRebuildingIt() async throws {
        guard NSScreen.main != nil else { return }
        let m = manager()
        let scene = BuiltInScenes.plasma
        let url = Fixtures.dir.appendingPathComponent("plasma-\(UUID().uuidString).wsscene")
        try SceneCodec.encode(scene).write(to: url)
        func content(_ cap: Int?) -> DesktopContent {
            DesktopContent(mode: .mirror, mainURL: url, mainSettings: RenderSettings(), loopsMain: true, configs: [:], maxPixel: 800,
                           performance: cap.map { PerformanceDecision(fpsCap: $0, resolutionScale: 1, paused: false, trimMemory: false, reasons: []) })
        }
        m.apply(content(nil))
        let layer = try #require(m.sessions[5]?.window.contentLayer as? StudioMetalLayer)
        layer.contentsScale = 2
        m.setPlaying(true)
        await spin(0.4)
        m.apply(content(10))
        #expect(m.sessions[5]?.window.contentLayer === layer)       // same renderer, new limit
        let renderer = try #require(m.sharedRenderer as? MetalSceneRenderer)
        #expect(renderer.currentFPSTarget == 10)
        let before = renderer.stats.frames
        await spin(1.5)
        let frames = renderer.stats.frames - before
        #expect((8...22).contains(frames), "frames in 1.5 s at a 10 fps policy cap: \(frames)")
        m.setPlaying(false)
    }

    @Test func aPolicyCapNeverPullsAPlainVideoOntoTheGPUPath() {
        let capped = RenderSettings(performanceFPSCap: 15)
        #expect(!RendererFactory.usesMetal(kind: .video, settings: capped) && !RendererFactory.usesMetal(kind: .image, settings: capped))
        #expect(RendererFactory.usesMetal(kind: .video, settings: RenderSettings(maxFPS: 15)))       // an explicit user limit still does
    }

    @Test func gifFrameCapsFollowThePolicy() throws {
        let r = try #require(AnimatedImageRenderer(url: Fixtures.gif(frames: 10, delay: 0.04), maxPixel: 100, settings: RenderSettings()))
        #expect(r.effectiveFrameCount == 10)
        r.apply(RenderSettings(performanceFPSCap: 10))
        #expect(r.effectiveFrameCount == 4)
        r.apply(RenderSettings(maxFPS: 5, performanceFPSCap: 10))        // the stricter limit wins
        #expect(r.effectiveFrameCount == 2)
    }

    @Test func hiddenRenderersAreReleasedUnderMemoryPressureAndComeBackWhenVisible() throws {
        let m = manager()
        let png = Fixtures.png(64, 64)
        let content = DesktopContent(mode: .independent, mainURL: png, mainSettings: RenderSettings(effect: .vignette), loopsMain: true,
                                     configs: [:], maxPixel: 800)
        m.apply(content)
        let session = try #require(m.sessions[5])
        #expect(session.ownRendererIsSet && session.window.contentLayer != nil)
        // Windows that are never shown count as hidden.
        #expect(m.trimMemory() == 1)
        #expect(!session.ownRendererIsSet && session.window.contentLayer == nil)
        m.apply(content)                                                  // the next apply rebuilds what was released
        #expect(session.ownRendererIsSet && session.window.contentLayer != nil)
    }

    @Test func nothingVisibleMeansASharedRendererCanBeReleasedToo() throws {
        let m = manager()
        let content = DesktopContent(mode: .mirror, mainURL: Fixtures.png(64, 64), mainSettings: RenderSettings(effect: .vignette), loopsMain: true,
                                     configs: [:], maxPixel: 800)
        m.apply(content)
        #expect(m.sharedKind != nil)
        #expect(m.trimMemory() == 1 && m.sharedKind == nil)
        m.apply(content)
        #expect(m.sharedKind != nil)
    }
}
