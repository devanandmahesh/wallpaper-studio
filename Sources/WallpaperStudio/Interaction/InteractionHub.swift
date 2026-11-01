import AppKit
import StudioCore

/// What the cursor did, in global screen coordinates (points, y up).
struct PointerSample: Equatable {
    var location: CGPoint
    var speed: Double                 // points per second
    var clickSerial: Int
    var clickLocation: CGPoint
    var clickPulse: Double
}

/// Where cursor information comes from. The real source watches the system; tests inject a manual one.
protocol PointerSource: AnyObject {
    var onEvent: (() -> Void)? { get set }
    var isRunning: Bool { get }
    func start()
    func stop()
    func sample(now: Double) -> PointerSample
}

/// Typing activity (never the keys themselves). Needs the user's Input Monitoring permission.
protocol KeyActivitySource: AnyObject {
    var onEvent: (() -> Void)? { get set }
    var isRunning: Bool { get }
    var isAuthorized: Bool { get }
    func requestAuthorization()
    func start()
    func stop()
    func pulse(now: Double) -> Double
}

/// Watches the cursor with `NSEvent` monitors. Mouse monitors need no permission. Monitors only run while some
/// interactive wallpaper is actually playing (`InteractionHub` starts and stops them), so an idle wallpaper costs nothing.
final class SystemPointerSource: PointerSource {
    var onEvent: (() -> Void)?
    private(set) var isRunning = false
    private var global: Any?
    private var local: Any?
    private var filter = PointerFilter()

    func start() {
        guard !isRunning else { return }
        isRunning = true
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        let handler: (NSEvent) -> Void = { [weak self] event in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if event.type == .leftMouseDown || event.type == .rightMouseDown {
                self.filter.registerClick(at: NSEvent.mouseLocation, time: now)
            }
            self.onEvent?()
        }
        // Global monitors see events going to other apps (e.g. Finder's desktop); local ones see events inside our own windows.
        global = NSEvent.addGlobalMonitorForEvents(matching: moves.union(clicks), handler: handler)
        local = NSEvent.addLocalMonitorForEvents(matching: moves.union(clicks)) { event in handler(event); return event }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        if let global { NSEvent.removeMonitor(global) }
        if let local { NSEvent.removeMonitor(local) }
        global = nil; local = nil
    }

    func sample(now: Double) -> PointerSample {
        filter.update(location: NSEvent.mouseLocation, time: now)
        return PointerSample(location: filter.raw, speed: filter.speed, clickSerial: filter.clickSerial,
                             clickLocation: filter.clickLocation, clickPulse: filter.clickPulse(at: now))
    }
}

/// Counts key presses (and nothing else: the event's contents are never read) to drive "typing" reactions.
/// macOS only delivers global key events to apps with Input Monitoring permission; without it this source never starts.
final class SystemKeySource: KeyActivitySource {
    var onEvent: (() -> Void)?
    private(set) var isRunning = false
    private var monitor: Any?
    private var meter = PulseMeter()

    var isAuthorized: Bool { CGPreflightListenEventAccess() }
    func requestAuthorization() { _ = CGRequestListenEventAccess() }

    func start() {
        guard !isRunning, isAuthorized else { return }
        isRunning = true
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] _ in      // the event itself is ignored on purpose
            self?.meter.add(at: ProcessInfo.processInfo.systemUptime)
            self?.onEvent?()
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    func pulse(now: Double) -> Double { meter.value(at: now) }
}

/// Everything the renderers know about the user's input at one instant.
struct InteractionSnapshot: Equatable {
    var pointer: PointerSample?       // nil when pointer reactions are off
    var keyPulse: Double
    var audio: AudioFrame
    static let idle = InteractionSnapshot(pointer: nil, keyPulse: 0, audio: .silent)
}

/// Shares one set of input monitors between all interactive renderers. Monitors run only while at least one renderer
/// that needs them is playing *and* the user has the matching switch on.
final class InteractionHub {
    struct Token { fileprivate let id: Int; fileprivate let pointer: Bool; fileprivate let keys: Bool; fileprivate let audio: Bool }

    private let pointerSource: PointerSource
    private let keySource: KeyActivitySource
    private let audioFeed: AudioFeed?
    private var pointerClients = 0
    private var keyClients = 0
    private var audioClients = 0
    private var nextID = 0
    private var subscribers: [Int: () -> Void] = [:]

    var pointerEnabled = true { didSet { if pointerEnabled != oldValue { reconcile(); notify() } } }
    var keysEnabled = false { didSet { if keysEnabled != oldValue { reconcile(); notify() } } }
    /// Set when the user has chosen an audio source in Settings.
    var audioEnabled = false { didSet { if audioEnabled != oldValue { reconcile(); notify() } } }

    init(pointer: PointerSource, keys: KeyActivitySource, audio: AudioFeed? = nil) {
        pointerSource = pointer
        keySource = keys
        audioFeed = audio
        audio?.onNeedsReconcile = { [weak self] in self?.reconcile() }
        pointer.onEvent = { [weak self] in self?.notify() }
        keys.onEvent = { [weak self] in self?.notify() }
    }

    var keysAuthorized: Bool { keySource.isAuthorized }
    func requestKeyAuthorization() { keySource.requestAuthorization() }
    var pointerRunning: Bool { pointerSource.isRunning }
    var keysRunning: Bool { keySource.isRunning }

    var audioRunning: Bool { audioFeed?.isRunning ?? false }

    func acquire(pointer: Bool, keys: Bool, audio: Bool = false) -> Token {
        nextID += 1
        if pointer { pointerClients += 1 }
        if keys { keyClients += 1 }
        if audio { audioClients += 1 }
        reconcile()
        return Token(id: nextID, pointer: pointer, keys: keys, audio: audio)
    }

    func release(_ token: Token) {
        if token.pointer { pointerClients = max(0, pointerClients - 1) }
        if token.keys { keyClients = max(0, keyClients - 1) }
        if token.audio { audioClients = max(0, audioClients - 1) }
        reconcile()
    }

    /// Called whenever the pointer moved/clicked, a key was pressed, or a setting changed.
    @discardableResult
    func subscribe(_ f: @escaping () -> Void) -> Int {
        nextID += 1
        subscribers[nextID] = f
        return nextID
    }

    func unsubscribe(_ id: Int) { subscribers[id] = nil }

    func snapshot(now: Double = ProcessInfo.processInfo.systemUptime) -> InteractionSnapshot {
        InteractionSnapshot(pointer: pointerEnabled && pointerClients > 0 ? pointerSource.sample(now: now) : nil,
                            keyPulse: keysEnabled && keyClients > 0 ? keySource.pulse(now: now) : 0,
                            audio: audioEnabled && audioClients > 0 ? (audioFeed?.latest(now: now) ?? .silent) : .silent)
    }

    private func reconcile() {
        if pointerEnabled && pointerClients > 0 { pointerSource.start() } else { pointerSource.stop() }
        if keysEnabled && keyClients > 0 { keySource.start() } else { keySource.stop() }
        if audioEnabled && audioClients > 0 { audioFeed?.start() } else { audioFeed?.stop() }
    }

    private func notify() { subscribers.values.forEach { $0() } }
}
