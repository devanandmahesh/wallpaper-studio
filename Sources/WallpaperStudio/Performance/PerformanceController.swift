import Foundation
import StudioCore

/// Everything the controller reads, as closures, so tests can drive it without touching the real system.
struct ConditionReaders {
    var power: () -> PowerState
    var thermal: () -> ThermalLevel
    var memory: () -> MemoryPressureLevel
    var cpuPercent: (Double) -> Double
    var displayMaxFPS: () -> Int
    var now: () -> Double
}

/// Chooses how hard to work. It reads the system (power, heat, memory, CPU, displays), runs the policy for the user's
/// profile and publishes the resulting limits. The engine applies them through `onDecisionChange`.
final class PerformanceController: ObservableObject {
    @Published var profile: PerformanceProfile {
        didSet { if profile != oldValue { defaults.set(profile.rawValue, forKey: "performanceProfile"); governor = AdaptiveGovernor(); reconfigureTimer(); evaluate() } }
    }
    @Published private(set) var conditions = SystemConditions()
    @Published private(set) var decision: PerformanceDecision

    var onDecisionChange: (() -> Void)?
    /// How many GPU renderers are on screen (set by the engine).
    var activeRenderers: () -> Int = { 0 }
    /// Called when memory is tight: release caches and hidden renderers.
    var onTrimMemory: (() -> Void)?

    private let readers: ConditionReaders
    private let defaults: UserDefaults
    private var governor = AdaptiveGovernor()
    private var timer: Timer?

    init(readers: ConditionReaders, defaults: UserDefaults = .standard) {
        self.readers = readers
        self.defaults = defaults
        let initial = PerformanceProfile(rawValue: defaults.string(forKey: "performanceProfile") ?? "") ?? .balanced
        profile = initial
        decision = PerformancePolicy.decide(profile: initial, conditions: SystemConditions())
        evaluate()
    }

    /// Power, heat and memory arrive as events (`poke()`), so only the Adaptive profile, which watches CPU load over time,
    /// needs a timer. Every other profile costs no periodic wake-ups at all.
    func start(interval: TimeInterval = 3) {
        pollInterval = interval
        started = true
        reconfigureTimer()
    }

    func stop() { started = false; reconfigureTimer() }

    /// True while the controller is polling on a timer (Adaptive profile only).
    var isPolling: Bool { timer != nil }

    private var started = false
    private var pollInterval: TimeInterval = 3

    private func reconfigureTimer() {
        timer?.invalidate()
        timer = nil
        guard started, profile == .adaptive else { return }
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in self?.evaluate() }
        timer?.tolerance = pollInterval / 2
    }

    func poke() { evaluate() }

    func evaluate() {
        let now = readers.now()
        var c = SystemConditions()
        let power = readers.power()
        c.onBattery = power.onBattery; c.batteryFraction = power.batteryFraction; c.lowPowerMode = power.lowPowerMode
        c.thermal = readers.thermal()
        c.memoryPressure = readers.memory()
        c.appCPUPercent = readers.cpuPercent(now)
        c.displayMaxFPS = readers.displayMaxFPS()
        c.activeGPURenderers = activeRenderers()

        if profile == .adaptive { governor.update(c, now: now) }
        let next = PerformancePolicy.decide(profile: profile, conditions: c, governor: governor)
        if c != conditions { conditions = c }
        guard next != decision else { return }
        let wasTrimming = decision.trimMemory
        decision = next
        if next.trimMemory && !wasTrimming { onTrimMemory?() }
        onDecisionChange?()
    }

    static func system() -> (PerformanceController, [AnyObject]) {
        let power = PowerMonitor(), thermal = ThermalMonitor(), memory = MemoryPressureMonitor(), cpu = CPUMonitor()
        let readers = ConditionReaders(
            power: { power.state }, thermal: { thermal.level }, memory: { memory.level },
            cpuPercent: { cpu.sample(now: $0) },
            displayMaxFPS: { DisplayManager.snapshot().map(\.maxFPS).max() ?? 60 },
            now: { ProcessInfo.processInfo.systemUptime })
        let controller = PerformanceController(readers: readers)
        power.onChange = { [weak controller] in controller?.poke() }
        thermal.onChange = { [weak controller] in controller?.poke() }
        memory.onChange = { [weak controller] in controller?.poke() }
        return (controller, [power, thermal, memory, cpu])
    }
}
