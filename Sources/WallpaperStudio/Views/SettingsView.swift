import SwiftUI
import AppKit
import StudioCore

/// Live spectrum for the Settings page. While Settings is open it holds an audio claim, so the meter moves
/// (only if the user already chose a source; it never turns anything on by itself).
final class AudioMeterModel: ObservableObject {
    @Published var bands = [Float](repeating: 0, count: 32)
    private var timer: Timer?
    private var token: InteractionHub.Token?

    func start(_ engine: AppDelegate) {
        stop()
        token = engine.interaction.acquire(pointer: false, keys: false, audio: true)
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { [weak self, weak engine] _ in
            guard let engine else { return }
            self?.bands = engine.interaction.snapshot().audio.bands
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
    }

    func release(_ engine: AppDelegate) {
        stop()
        if let token { engine.interaction.release(token) }
        token = nil
    }
}

final class RenderStatsPoller: ObservableObject {
    @Published var text = "No GPU renderer active"
    private var timer: Timer?
    func start(_ engine: AppDelegate) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self, weak engine] _ in
            guard let s = engine?.desktop.gpuStats else { self?.text = "No GPU renderer active"; return }
            self?.text = s.frames == 0 ? "GPU renderer active (no frames yet)"
                : String(format: "GPU %.2f ms/frame avg (max %.2f), encode %.2f ms, %d frames", s.averageGPUMilliseconds, s.maxGPUMilliseconds, s.averageEncodeMilliseconds, s.frames)
        }
    }
    deinit { timer?.invalidate() }
}

struct SettingsView: View {
    @StateObject private var poller = RenderStatsPoller()
    @StateObject private var meter = AudioMeterModel()
    @ObservedObject var engine: AppDelegate
    @ObservedObject var library: LibraryModel

    var body: some View {
        VStack(spacing: 0) {
            PageHeader("Settings", "Behaviour and appearance")
            Form {
                Section("General") {
                    Toggle("Launch at login", isOn: Binding(get: { engine.loginEnabled }, set: { _ in engine.toggleLogin() }))
                    Picker("Appearance", selection: Binding(get: { engine.appearance }, set: { engine.appearance = $0 })) {
                        Text("Dark").tag("dark")
                        Text("Light").tag("light")
                        Text("System").tag("system")
                    }
                }
                Section("Playback") {
                    Toggle("Pause when the desktop is covered", isOn: Binding(get: { engine.pauseWhenCovered }, set: { _ in engine.toggleCovered() }))
                    Toggle("Pause on battery power", isOn: Binding(get: { engine.pauseOnBattery }, set: { _ in engine.toggleBattery() }))
                    Toggle("Fill screen (crop)", isOn: Binding(get: { engine.fill }, set: { _ in engine.toggleFill() }))
                }
                Section("Performance") {
                    Picker("Profile", selection: Binding(get: { engine.performance.profile }, set: { engine.performance.profile = $0 })) {
                        ForEach(PerformanceProfile.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Text(engine.performance.profile.summary).font(.caption).foregroundColor(.secondary)
                    PerformanceReadout(controller: engine.performance)
                    Text("Limits apply to GPU wallpapers (scenes, effects) and GIFs. Plain videos already play on the media engine, which is the cheapest path (measured: ~1 % CPU for 1080p30), so they are never forced through the GPU by a profile.")
                        .font(.caption).foregroundColor(.secondary)
                }
                Section("Visual (GPU)") {
                    Picker("Effect on images & videos", selection: Binding(get: { engine.effect }, set: { engine.effect = $0 })) {
                        ForEach(EffectPreset.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Picker("Render resolution", selection: Binding(get: { engine.resolutionScale }, set: { engine.resolutionScale = $0 })) {
                        ForEach(RenderQuality.resolutionChoices, id: \.self) { Text("\(Int($0 * 100))%").tag($0) }
                    }
                    Picker("Frame limit", selection: Binding(get: { engine.frameLimit }, set: { engine.frameLimit = $0 })) {
                        Text("Display rate").tag(0)
                        ForEach([15, 24, 30, 60], id: \.self) { Text("\($0) fps").tag($0) }
                    }
                    Text("Effects, render resolution and frame limits use the GPU renderer. A frame limit on a video re-draws it through Metal, which costs more than playing it directly (measured on 1080p30: 1 % → 4-17 % CPU), so leave it at “Display rate” unless you need it.")
                        .font(.caption).foregroundColor(.secondary)
                    Text(poller.text).font(.caption.monospaced()).foregroundColor(.secondary)
                }
                Section("Interaction") {
                    Toggle("React to the mouse", isOn: Binding(get: { engine.pointerReactions }, set: { engine.pointerReactions = $0 }))
                    Text("Parallax, particles and cursor lights follow the pointer, and clicks on the desktop can launch bursts. Your clicks still go to Finder as usual. The mouse is only watched while such a wallpaper is playing.")
                        .font(.caption).foregroundColor(.secondary)
                    Toggle("React to typing", isOn: Binding(get: { engine.keyboardReactions }, set: { engine.keyboardReactions = $0 }))
                    Text(engine.interaction.keysAuthorized
                         ? "Only the number of key presses is used; what you type is never read or stored."
                         : "Needs permission: System Settings → Privacy & Security → Input Monitoring → allow Wallpaper Studio. Only the number of key presses is used; what you type is never read or stored.")
                        .font(.caption).foregroundColor(.secondary)
                }
                Section("Audio") {
                    Picker("Audio source", selection: Binding(get: { engine.audioMode }, set: { engine.audioMode = $0 })) {
                        ForEach(AudioMode.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    AudioStatusRow(audio: engine.audio)
                    if engine.audioMode != .off {
                        HStack {
                            Text("Sensitivity")
                            Slider(value: Binding(get: { Double(engine.audioSensitivity) }, set: { engine.audioSensitivity = Float($0) }), in: 0.25...4)
                            Text(String(format: "%.1f×", engine.audioSensitivity)).monospacedDigit().frame(width: 40)
                        }
                        HStack {
                            Text("Smoothing")
                            Slider(value: Binding(get: { Double(engine.audioSmoothing) }, set: { engine.audioSmoothing = Float($0) }), in: 0...1)
                        }
                        HStack(alignment: .bottom, spacing: 2) {
                            ForEach(0..<32, id: \.self) { i in
                                RoundedRectangle(cornerRadius: 1.5).fill(Color.accentColor)
                                    .frame(width: 6, height: 3 + 37 * CGFloat(meter.bands[i]))
                            }
                        }
                        .frame(height: 40, alignment: .bottom)
                        Button("Open Privacy Settings") { openPrivacySettings(engine.audioMode) }
                    }
                    Text("Audio-reactive wallpapers (Generated → Spectrum, Pulse Ring, Waveform Glow, Bass Bloom) draw the sound you choose here. Nothing is captured until you pick a source, and only while such a wallpaper is playing. Audio is analysed live and never recorded or stored. System audio shows macOS's recording indicator.")
                        .font(.caption).foregroundColor(.secondary)
                }
                Section("Lock screen") {
                    LockScreenRow(sync: engine.lockSync)
                }
                Section("Stock video keys") {
                    ForEach(StockProvider.allCases) { StockKeyField(provider: $0) }
                    Text("Free API keys for Discover → Pexels & Pixabay. They are stored on this Mac only and sent only to the site they belong to.")
                        .font(.caption).foregroundColor(.secondary)
                }
                Section("Storage") {
                    Text(library.storage.root.path).font(.caption).foregroundColor(.secondary).textSelection(.enabled)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([library.storage.root]) }
                    Button("Use Current Frame as Static Wallpaper") { engine.setStaticWallpaper() }
                        .disabled(engine.current == nil)
                }
            }
            .formStyle(.grouped)
            .onAppear { poller.start(engine); meter.start(engine) }
            .onDisappear { meter.release(engine) }
        }
    }
}

private struct AudioStatusRow: View {
    @ObservedObject var audio: AudioReactiveEngine
    var body: some View {
        Text(audio.status.text).font(.caption).foregroundColor(isProblem ? .orange : .secondary)
    }
    private var isProblem: Bool {
        switch audio.status { case .needsPermission, .failed: true; default: false }
    }
}

private func openPrivacySettings(_ mode: AudioMode) {
    let pane = mode == .microphone ? "Privacy_Microphone" : "Privacy_ScreenCapture"
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
}

private struct PerformanceReadout: View {
    @ObservedObject var controller: PerformanceController
    var body: some View {
        let c = controller.conditions
        VStack(alignment: .leading, spacing: 2) {
            Text("Now: \(controller.decision.summary)").font(.caption.monospaced())
            Text(String(format: "Power: %@%@ · Heat: %@ · Memory: %@ · App CPU: %.1f %%",
                        c.onBattery ? "battery" : "plugged in",
                        c.batteryFraction.map { String(format: " %d %%", Int($0 * 100)) } ?? "",
                        "\(c.thermal)", "\(c.memoryPressure)", c.appCPUPercent))
                .font(.caption.monospaced()).foregroundColor(.secondary)
        }
    }
}

private struct LockScreenRow: View {
    @ObservedObject var sync: LockScreenSync
    var body: some View {
        Toggle("Show the current wallpaper on the lock screen", isOn: Binding(get: { sync.isEnabled }, set: { sync.setEnabled($0) }))
        Text("macOS only lets the system itself play video on the lock screen and login window. With this on, the app keeps your desktop picture, which the lock screen shows, equal to a sharp still of the wallpaper you are using, refreshed whenever you change wallpaper and the moment the screen locks. Turning it off puts your previous picture back.")
            .font(.caption).foregroundColor(.secondary)
        if sync.isEnabled {
            HStack {
                Button("Update Now") { sync.sync() }
                if let when = sync.lastSync { Text("Last updated \(when.formatted(date: .omitted, time: .standard))").font(.caption).foregroundColor(.secondary) }
            }
            if let error = sync.lastError { Text(error).font(.caption).foregroundColor(.orange) }
        }
    }
}

private final class StockKeyDraft: ObservableObject {
    @Published var text: String
    @Published var saved: Bool
    let provider: StockProvider
    init(_ provider: StockProvider) {
        self.provider = provider
        let key = UserDefaults.standard.string(forKey: provider.defaultsKey) ?? ""
        text = key; saved = !key.isEmpty
    }
    func save() {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty { UserDefaults.standard.removeObject(forKey: provider.defaultsKey) }
        else { UserDefaults.standard.set(clean, forKey: provider.defaultsKey) }
        text = clean; saved = !clean.isEmpty
    }
    func remove() { text = ""; save() }
}

private struct StockKeyField: View {
    @StateObject private var draft: StockKeyDraft
    init(provider: StockProvider) { _draft = StateObject(wrappedValue: StockKeyDraft(provider)) }
    var body: some View {
        HStack {
            SecureField("\(draft.provider.name) API key", text: $draft.text).onSubmit { draft.save() }
            Button("Save") { draft.save() }
            if draft.saved { Button("Remove") { draft.remove() } }
            Link("Get key", destination: draft.provider.keyHelpURL)
        }
    }
}
