import AppKit
import StudioCore

/// The user's schedule rules, saved to disk.
final class ScheduleController: ObservableObject {
    @Published private(set) var rules: [ScheduleRule]
    var onChange: (() -> Void)?
    private let store: ScheduleStore

    init(store: ScheduleStore = ScheduleController.defaultStore()) {
        self.store = store
        rules = store.load().rules
    }

    static func defaultStore() -> ScheduleStore {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? FileManager.default.temporaryDirectory
        return ScheduleStore(url: base.appendingPathComponent("LiveWallpaper/schedule.json"))
    }

    @discardableResult
    func add(_ rule: ScheduleRule) -> Bool {
        guard rule.isValid, rules.count < 50 else { return false }
        rules.append(rule)
        commit()
        return true
    }

    func update(_ id: String, _ change: (inout ScheduleRule) -> Void) {
        guard let i = rules.firstIndex(where: { $0.id == id }) else { return }
        var copy = rules[i]
        change(&copy)
        guard copy.isValid, copy != rules[i] else { return }
        rules[i] = copy
        commit()
    }

    func remove(_ id: String) {
        rules.removeAll { $0.id == id }
        commit()
    }

    private func commit() {
        var state = ScheduleState()
        state.rules = rules
        do { try store.save(state) } catch { Log.app.error("Could not save the schedule: \(error.localizedDescription)") }
        onChange?()
    }
}

/// Applies the right wallpaper at the right time: once at start-up, and at every rule boundary after that.
/// It only acts at those moments, so choosing a different wallpaper by hand sticks until the next boundary.
final class SchedulerService {
    private let controller: ScheduleController
    private let now: () -> Date
    private let calendar: Calendar
    private let apply: (ScheduleRule) -> Void
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var lastApplied: String?
    private(set) var nextFire: Date?

    init(controller: ScheduleController, now: @escaping () -> Date = { Date() }, calendar: Calendar = .current, apply: @escaping (ScheduleRule) -> Void) {
        self.controller = controller
        self.now = now
        self.calendar = calendar
        self.apply = apply
    }

    func start() {
        controller.onChange = { [weak self] in self?.evaluate() }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: .main) { [weak self] _ in self?.evaluate() })
        observers.append(center.addObserver(forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main) { [weak self] _ in self?.evaluate() })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.evaluate() })
        evaluate()
    }

    func stop() {
        timer?.invalidate(); timer = nil
        observers.forEach { NotificationCenter.default.removeObserver($0); NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers = []
    }

    /// Applies the active rule if it differs from the last one applied, then arms the timer for the next boundary.
    func evaluate() {
        let date = now()
        let active = ScheduleEvaluator.activeRule(in: controller.rules, at: date, calendar: calendar)
        let signature = active.map { "\($0.id)|\($0.wallpaperID)" }
        if signature != lastApplied {
            lastApplied = signature
            if let active { apply(active) }
        }
        timer?.invalidate()
        nextFire = ScheduleEvaluator.nextChange(in: controller.rules, after: date, calendar: calendar)
        guard let nextFire else { return }
        timer = Timer(fire: nextFire.addingTimeInterval(0.5), interval: 0, repeats: false) { [weak self] _ in self?.evaluate() }
        timer?.tolerance = 1
        RunLoop.main.add(timer!, forMode: .common)
    }
}
