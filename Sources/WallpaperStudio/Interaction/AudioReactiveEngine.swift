import Foundation
import StudioCore

enum AudioStatus: Equatable {
    case off                       // no source chosen
    case idle                      // a source is chosen but no wallpaper is using audio right now
    case needsPermission(String)
    case starting
    case running
    case failed(String)

    var text: String {
        switch self {
        case .off: "Audio reactions are off."
        case .idle: "Ready. Audio is only captured while an audio-reactive wallpaper is playing."
        case .needsPermission(let m): m
        case .starting: "Starting…"
        case .running: "Listening."
        case .failed(let m): "Stopped: \(m)"
        }
    }
}

/// What the interaction hub needs from the audio side.
protocol AudioFeed: AnyObject {
    var isRunning: Bool { get }
    /// Set by the feed so the hub can retry after a permission was granted.
    var onNeedsReconcile: (() -> Void)? { get set }
    func start()
    func stop()
    func latest(now: Double) -> AudioFrame
}

/// Captures audio (only the source the user picked, only while something needs it), analyses it and keeps the newest frame.
///
/// Consent rules, all enforced here and covered by tests:
///  * with the mode `.off` nothing is ever created or started;
///  * `start()` never shows a system prompt: if the permission is missing the status says so and nothing runs;
///  * the prompt appears only from `chooseMode(_:)`, i.e. the user's explicit choice in Settings.
final class AudioReactiveEngine: ObservableObject, AudioFeed {
    @Published private(set) var status = AudioStatus.off
    @Published private(set) var mode: AudioMode

    var onNeedsReconcile: (() -> Void)?
    private let makeCapture: (AudioMode) -> AudioCaptureSource?
    private let clock: () -> Double
    private var capture: AudioCaptureSource?
    private var generation = 0
    private var wanted = false

    // Written on the audio queue, read from the render loop.
    private let lock = NSLock()
    private var analyzer: AudioAnalyzer?
    private var frame = AudioFrame.silent
    private var frameTime = -Double.infinity
    private var tuningStorage = AudioTuning()

    /// How long a frame stays valid; after silence from the source the visuals fall back to a still, quiet state.
    static let staleSeconds = 0.4

    init(mode: AudioMode = .off, clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
         makeCapture: @escaping (AudioMode) -> AudioCaptureSource? = AudioReactiveEngine.systemCapture) {
        self.mode = mode
        self.clock = clock
        self.makeCapture = makeCapture
        status = mode == .off ? .off : .idle
    }

    static func systemCapture(_ mode: AudioMode) -> AudioCaptureSource? {
        switch mode { case .off: nil; case .system: SystemAudioCapture(); case .microphone: MicrophoneCapture() }
    }

    var isRunning: Bool { capture != nil && status == .running }

    var tuning: AudioTuning {
        get { lock.lock(); defer { lock.unlock() }; return tuningStorage }
        set { lock.lock(); tuningStorage = newValue; analyzer?.tuning = newValue; lock.unlock() }
    }

    // MARK: User choice

    /// The user picked a source in Settings. This is the only path that can trigger a system permission prompt.
    func chooseMode(_ newMode: AudioMode) {
        guard newMode != mode else { return }
        stop()
        mode = newMode
        guard newMode != .off, let probe = makeCapture(newMode) else { status = .off; return }
        status = .idle
        switch probe.permission {
        case .granted: onNeedsReconcile?()
        case .notDetermined:
            probe.requestPermission { [weak self] granted in
                guard let self, self.mode == newMode else { return }
                if granted { self.status = .idle; self.onNeedsReconcile?() }
                else { self.status = .needsPermission(Self.permissionText(newMode)) }
            }
        case .denied: status = .needsPermission(Self.permissionText(newMode))
        }
    }

    static func permissionText(_ mode: AudioMode) -> String {
        switch mode {
        case .system: "macOS has not allowed system audio. Open System Settings → Privacy & Security → Screen & System Audio Recording, allow Wallpaper Studio, then restart the app."
        case .microphone: "macOS has not allowed the microphone. Open System Settings → Privacy & Security → Microphone and allow Wallpaper Studio."
        case .off: ""
        }
    }

    // MARK: Hub-driven lifecycle

    func start() {
        guard mode != .off, capture == nil else { return }
        guard let cap = makeCapture(mode) else { return }
        guard cap.permission == .granted else {                  // never prompts from here
            status = .needsPermission(Self.permissionText(mode))
            return
        }
        generation += 1
        let mine = generation
        capture = cap
        status = .starting
        cap.onSamples = { [weak self] samples, rate in self?.ingest(samples, rate: rate, generation: mine) }
        cap.onFailure = { [weak self] message in
            DispatchQueue.main.async { self?.captureFailed(message, generation: mine) }
        }
        Task { @MainActor [weak self] in
            do {
                try await cap.start()
                guard let self, self.generation == mine else { await cap.stop(); return }
                self.status = .running
            } catch {
                guard let self, self.generation == mine else { return }
                self.capture = nil
                self.status = (error as? AudioCaptureError).map { e -> AudioStatus in
                    if case .permissionDenied(let m) = e { return .needsPermission(m) } else { return .failed(e.localizedDescription) }
                } ?? .failed(error.localizedDescription)
            }
        }
    }

    func stop() {
        generation += 1                                          // late callbacks from the old capture are ignored
        if let cap = capture {
            capture = nil
            cap.onSamples = nil; cap.onFailure = nil
            Task { await cap.stop() }
        }
        lock.lock()
        analyzer = nil
        frame = .silent
        frameTime = -.infinity
        lock.unlock()
        if mode != .off, status != .needsPermission(Self.permissionText(mode)) { status = .idle }
    }

    private func captureFailed(_ message: String, generation g: Int) {
        guard g == generation else { return }
        capture = nil
        status = .failed(message)
    }

    // MARK: Audio thread

    private func ingest(_ samples: [Float], rate: Double, generation g: Int) {
        lock.lock(); defer { lock.unlock() }
        guard g == generation else { return }
        if analyzer == nil || analyzer?.sampleRate != rate {
            analyzer = AudioAnalyzer(sampleRate: rate)
            analyzer?.tuning = tuningStorage
        }
        if let f = analyzer?.process(samples) {
            frame = f
            frameTime = clock()
        }
    }

    func latest(now: Double) -> AudioFrame {
        lock.lock(); defer { lock.unlock() }
        return now - frameTime > Self.staleSeconds ? .silent : frame
    }
}
