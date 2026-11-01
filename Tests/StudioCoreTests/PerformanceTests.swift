import Testing
import Foundation
@testable import StudioCore

@Suite struct PerformancePolicyTests {
    func cond(_ edit: (inout SystemConditions) -> Void = { _ in }) -> SystemConditions { var c = SystemConditions(); c.displayMaxFPS = 120; edit(&c); return c }

    @Test func profilesStartAtTheirDocumentedFrameRates() {
        #expect(PerformancePolicy.decide(profile: .batterySaver, conditions: cond()).fpsCap == 15)
        #expect(PerformancePolicy.decide(profile: .balanced, conditions: cond()).fpsCap == 30)
        #expect(PerformancePolicy.decide(profile: .performance, conditions: cond()).fpsCap == 60)
        #expect(PerformancePolicy.decide(profile: .adaptive, conditions: cond()).fpsCap == 60)
        #expect(PerformancePolicy.decide(profile: .batterySaver, conditions: cond()).resolutionScale == 0.75)
        #expect(PerformancePolicy.decide(profile: .balanced, conditions: cond()).resolutionScale == 1)
    }

    @Test func neverAboveWhatTheDisplayCanShow() {
        #expect(PerformancePolicy.decide(profile: .performance, conditions: cond { $0.displayMaxFPS = 30 }).fpsCap == 30)
        #expect(PerformancePolicy.decide(profile: .performance, conditions: cond { $0.displayMaxFPS = 0 }).fpsCap == 1)
    }

    @Test func batteryReducesActivity() {
        let plugged = PerformancePolicy.decide(profile: .performance, conditions: cond())
        let battery = PerformancePolicy.decide(profile: .performance, conditions: cond { $0.onBattery = true })
        #expect(plugged.fpsCap == 60 && battery.fpsCap == 30 && battery.reasons.contains("on battery"))
        let low = PerformancePolicy.decide(profile: .balanced, conditions: cond { $0.onBattery = true; $0.batteryFraction = 0.15 })
        #expect(low.fpsCap == 15 && low.reasons.contains("battery low"))
        let fine = PerformancePolicy.decide(profile: .balanced, conditions: cond { $0.onBattery = true; $0.batteryFraction = 0.8 })
        #expect(fine.fpsCap == 30)
        #expect(PerformancePolicy.decide(profile: .performance, conditions: cond { $0.lowPowerMode = true }).fpsCap == 15)
    }

    @Test func heatLowersQualityThenPauses() {
        let fair = PerformancePolicy.decide(profile: .balanced, conditions: cond { $0.thermal = .fair })
        #expect(fair.resolutionScale == 0.85 && fair.fpsCap == 30 && !fair.paused)
        let serious = PerformancePolicy.decide(profile: .balanced, conditions: cond { $0.thermal = .serious })
        #expect(serious.fpsCap == 15 && serious.resolutionScale == 0.6 && !serious.paused)
        let critical = PerformancePolicy.decide(profile: .balanced, conditions: cond { $0.thermal = .critical })
        #expect(critical.paused && critical.summary.contains("Paused"))
    }

    @Test func memoryPressureTrimsAndShrinks() {
        let warning = PerformancePolicy.decide(profile: .balanced, conditions: cond { $0.memoryPressure = .warning })
        #expect(warning.trimMemory && warning.resolutionScale == 1)
        let critical = PerformancePolicy.decide(profile: .balanced, conditions: cond { $0.memoryPressure = .critical })
        #expect(critical.trimMemory && critical.resolutionScale == 0.5)
        #expect(!PerformancePolicy.decide(profile: .balanced, conditions: cond()).trimMemory)
    }

    @Test func manyWallpapersShareTheBudget() {
        #expect(PerformancePolicy.decide(profile: .performance, conditions: cond { $0.activeGPURenderers = 3 }).fpsCap == 30)
        #expect(PerformancePolicy.decide(profile: .performance, conditions: cond { $0.activeGPURenderers = 2 }).fpsCap == 60)
    }

    @Test func effectsStackAndResolutionNeverDropsBelowAQuarter() {
        let d = PerformancePolicy.decide(profile: .batterySaver, conditions: cond { $0.thermal = .serious; $0.memoryPressure = .critical })
        #expect(d.resolutionScale == 0.25 && d.fpsCap == 15)           // 0.75 × 0.6 × 0.5 = 0.225 → floored at 0.25
        #expect(d.reasons.count == 2)
    }

    @Test func settingsCombineUserLimitsWithThePolicy() {
        let decision = PerformanceDecision(fpsCap: 24, resolutionScale: 0.6, paused: false, trimMemory: false, reasons: [])
        var user = RenderSettings(maxFPS: 30, resolutionScale: 0.8)
        var s = user.applying(decision, displayMaxFPS: 60)
        #expect(s.effectiveMaxFPS == 24 && s.maxFPS == 30 && s.resolutionScale == 0.6)
        user = RenderSettings(maxFPS: 15, resolutionScale: 0.5)
        s = user.applying(decision, displayMaxFPS: 60)
        #expect(s.effectiveMaxFPS == 15 && s.resolutionScale == 0.5)
        s = RenderSettings().applying(decision, displayMaxFPS: 24)
        #expect(s.performanceFPSCap == nil && s.effectiveMaxFPS == nil)           // a cap at the display rate changes nothing
        #expect(s.maxFPS == nil)                                                   // and never turns on the user-level limit
    }
}

@Suite struct AdaptiveGovernorTests {
    func busy() -> SystemConditions { var c = SystemConditions(); c.appCPUPercent = 40; return c }
    func calm() -> SystemConditions { var c = SystemConditions(); c.appCPUPercent = 2; return c }

    @Test func startsAtFullQuality() {
        let g = AdaptiveGovernor()
        #expect(g.tier == 0 && g.current.fps == 60 && g.current.resolution == 1)
    }

    @Test func sustainedLoadStepsDownOneTierAtATime() {
        var g = AdaptiveGovernor()
        g.update(busy(), now: 0); g.update(busy(), now: 3)
        #expect(g.tier == 0)                                       // pressure has to last
        g.update(busy(), now: 7)
        #expect(g.tier == 1)
        g.update(busy(), now: 9)
        #expect(g.tier == 1)                                       // dwell time between steps
        g.update(busy(), now: 14); g.update(busy(), now: 21)
        #expect(g.tier >= 2)
        for t in stride(from: 30.0, through: 200, by: 2) { g.update(busy(), now: t) }
        #expect(g.tier == AdaptiveGovernor.tiers.count - 1 && g.current.fps == 15)    // bottoms out, does not run off the end
    }

    @Test func aBriefSpikeIsIgnored() {
        var g = AdaptiveGovernor()
        g.update(busy(), now: 0); g.update(calm(), now: 2); g.update(busy(), now: 4); g.update(calm(), now: 6); g.update(busy(), now: 8)
        #expect(g.tier == 0)
    }

    @Test func calmReturnsQualityOnlyAfterTheHoldPeriod() {
        var g = AdaptiveGovernor()
        for t in stride(from: 0.0, through: 14, by: 1) { g.update(busy(), now: t) }
        let low = g.tier
        #expect(low >= 1)
        for t in stride(from: 15.0, through: 100, by: 5) { g.update(calm(), now: t) }
        #expect(g.tier == low)                                     // still held: avoids flip-flopping
        for t in stride(from: 105.0, through: 400, by: 5) { g.update(calm(), now: t) }
        #expect(g.tier == 0)
    }

    @Test func heatCountsAsPressureEvenWithLowCPU() {
        var g = AdaptiveGovernor()
        var c = calm(); c.thermal = .fair
        for t in stride(from: 0.0, through: 20, by: 1) { g.update(c, now: t) }
        #expect(g.tier >= 1)
    }

    @Test func batteryAndLowPowerModeNeverAllowTheTopTiers() {
        var g = AdaptiveGovernor()
        var c = calm(); c.onBattery = true
        g.update(c, now: 0)
        #expect(g.tier == 2 && g.current.fps == 30)
        for t in stride(from: 1.0, through: 600, by: 5) { g.update(c, now: t) }
        #expect(g.tier == 2)                                       // calm never climbs above the battery floor
        c.onBattery = false
        for t in stride(from: 605.0, through: 1000, by: 5) { g.update(c, now: t) }
        #expect(g.tier == 0)                                       // back on AC it recovers
    }

    @Test func theAdaptiveProfileUsesTheGovernorsTier() {
        var g = AdaptiveGovernor()
        for t in stride(from: 0.0, through: 14, by: 1) { g.update(busy(), now: t) }
        var c = SystemConditions(); c.displayMaxFPS = 144
        let d = PerformancePolicy.decide(profile: .adaptive, conditions: c, governor: g)
        #expect(d.fpsCap < 60 && d.reasons.contains("adapting to load"))
    }
}
