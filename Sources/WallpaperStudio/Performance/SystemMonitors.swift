import Foundation
import IOKit.ps
import StudioCore

struct PowerState: Equatable {
    var onBattery = false
    var batteryFraction: Double?
    var lowPowerMode = false
}

/// Power source and battery level, from IOKit's change notification (no polling) plus Low Power Mode.
final class PowerMonitor {
    private(set) var state = PowerState()
    var onChange: (() -> Void)?
    private var source: CFRunLoopSource?
    private var token: NSObjectProtocol?

    init() {
        refresh()
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let me = Unmanaged<PowerMonitor>.fromOpaque(ctx).takeUnretainedValue()
            me.refresh(); me.onChange?()
        }, context)?.takeRetainedValue() {
            source = src
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
        }
        token = NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.refresh(); self?.onChange?()
        }
    }

    deinit {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode) }
        if let token { NotificationCenter.default.removeObserver(token) }
    }

    func refresh() {
        var s = PowerState()
        s.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        s.onBattery = (IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?) == kIOPSBatteryPowerValue
        if let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for ps in list {
                guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                      let current = d[kIOPSCurrentCapacityKey] as? Double ?? (d[kIOPSCurrentCapacityKey] as? Int).map(Double.init),
                      let max = d[kIOPSMaxCapacityKey] as? Double ?? (d[kIOPSMaxCapacityKey] as? Int).map(Double.init), max > 0 else { continue }
                s.batteryFraction = current / max
                break
            }
        }
        state = s
    }
}

/// `ProcessInfo.thermalState` as a `ThermalLevel`, with change notifications.
final class ThermalMonitor {
    var onChange: (() -> Void)?
    private var token: NSObjectProtocol?

    init() {
        token = NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.onChange?()
        }
    }

    deinit { if let token { NotificationCenter.default.removeObserver(token) } }

    var level: ThermalLevel {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .nominal
        }
    }
}

/// Memory-pressure events from the kernel (via a dispatch source: no polling).
final class MemoryPressureMonitor {
    private(set) var level = MemoryPressureLevel.normal
    var onChange: (() -> Void)?
    private let source: DispatchSourceMemoryPressure

    init() {
        source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let e = self.source.data
            self.level = e.contains(.critical) ? .critical : e.contains(.warning) ? .warning : .normal
            self.onChange?()
        }
        source.resume()
    }

    deinit { source.cancel() }
}

/// This process's CPU use between two readings, as a percentage of one core.
final class CPUMonitor {
    private var lastCPU: Double?
    private var lastWall: Double?

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    func sample(now: Double) -> Double {
        let cpu = Self.cpuSeconds()
        defer { lastCPU = cpu; lastWall = now }
        guard let lastCPU, let lastWall, now > lastWall else { return 0 }
        return max(0, (cpu - lastCPU) / (now - lastWall) * 100)
    }
}
