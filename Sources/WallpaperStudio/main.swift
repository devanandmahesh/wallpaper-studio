import AppKit
import SwiftUI
import StudioCore
import StudioRender
import AVFoundation
import IOKit.ps
import ServiceManagement
import Combine

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate, ObservableObject {
    static let speeds: [Float] = [0.25, 0.5, 0.75, 1, 1.5, 2]
    static let volumes: [Float] = [0.25, 0.5, 0.75, 1]
    static let intervals: [(String, Int)] = [("Off", 0), ("1 minute", 60), ("5 minutes", 300), ("15 minutes", 900), ("1 hour", 3600)]

    let defaults = UserDefaults.standard
    var statusItem: NSStatusItem!
    let layout = DisplayLayoutController()
    let schedule = ScheduleController()
    /// Keeps the lock screen's picture equal to a still of the current wallpaper (opt-in; macOS cannot play video there).
    lazy var lockSync = LockScreenSync(directory: LockScreenSync.defaultDirectory(), snapshot: { [weak self] in self?.desktop.snapshot() })
    var scheduler: SchedulerService?
    private var router: AutomationRouter?
    /// Views listen to this to switch pages when a link or the menu asks for one.
    let sectionRequests = PassthroughSubject<SidebarSection, Never>()
    private let performanceParts = PerformanceController.system()
    var performance: PerformanceController { performanceParts.0 }
    let audio = AudioReactiveEngine(mode: AudioMode(rawValue: UserDefaults.standard.string(forKey: "audioMode") ?? "") ?? .off)
    lazy var interaction = InteractionHub(pointer: SystemPointerSource(), keys: SystemKeySource(), audio: audio)
    /// Where audio-reactive wallpapers hear sound from. Off by default; choosing a source is the consent step that
    /// triggers the macOS permission prompt. Audio is only captured while an audio-reactive wallpaper is playing.
    var audioMode: AudioMode {
        get { audio.mode }
        set {
            defaults.set(newValue.rawValue, forKey: "audioMode")
            audio.chooseMode(newValue)
            interaction.audioEnabled = newValue != .off
            objectWillChange.send()
        }
    }
    var audioSensitivity: Float {
        get { defaults.object(forKey: "audioSensitivity") as? Float ?? 1 }
        set { defaults.set(newValue, forKey: "audioSensitivity"); audio.tuning.sensitivity = newValue; objectWillChange.send() }
    }
    var audioSmoothing: Float {
        get { defaults.object(forKey: "audioSmoothing") as? Float ?? 0.5 }
        set { defaults.set(newValue, forKey: "audioSmoothing"); audio.tuning.smoothing = newValue; objectWillChange.send() }
    }
    /// Wallpapers may react to the mouse (parallax, particles, clicks). On by default; watching only happens while such a wallpaper plays.
    var pointerReactions: Bool {
        get { defaults.object(forKey: "pointerReactions") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "pointerReactions"); interaction.pointerEnabled = newValue; objectWillChange.send() }
    }
    /// Wallpapers may react to typing. Off by default: needs Input Monitoring permission, and only the *number* of key presses is used.
    var keyboardReactions: Bool {
        get { defaults.bool(forKey: "keyboardReactions") }
        set {
            defaults.set(newValue, forKey: "keyboardReactions")
            if newValue && !interaction.keysAuthorized { interaction.requestKeyAuthorization() }
            interaction.keysEnabled = newValue
            objectWillChange.send()
        }
    }
    let desktop = DesktopWindowManager()
    let systemEvents = SystemEventMonitor()
    var rotationTimer: Timer?
    var powerTimer: Timer?

    var playlist: [URL] = [] { didSet { objectWillChange.send() } }
    var index = 0 { didSet { objectWillChange.send() } }
    var current: URL? { playlist.indices.contains(index) ? playlist[index] : nil }

    var userPaused = false { didSet { objectWillChange.send() } }
    var onBattery = false

    // Persisted settings
    var muted: Bool { get { defaults.object(forKey: "muted") as? Bool ?? true } set { defaults.set(newValue, forKey: "muted"); objectWillChange.send() } }
    var fill: Bool { get { defaults.object(forKey: "fill") as? Bool ?? true } set { defaults.set(newValue, forKey: "fill"); objectWillChange.send() } }
    var shuffle: Bool { get { defaults.bool(forKey: "shuffle") } set { defaults.set(newValue, forKey: "shuffle"); objectWillChange.send() } }
    var pauseOnBattery: Bool { get { defaults.object(forKey: "pauseOnBattery") as? Bool ?? false } set { defaults.set(newValue, forKey: "pauseOnBattery"); objectWillChange.send() } }
    var pauseWhenCovered: Bool { get { defaults.object(forKey: "pauseWhenCovered") as? Bool ?? true } set { defaults.set(newValue, forKey: "pauseWhenCovered"); objectWillChange.send() } }
    var speed: Float { get { defaults.object(forKey: "speed") as? Float ?? 1 } set { defaults.set(newValue, forKey: "speed"); objectWillChange.send() } }
    var volume: Float { get { defaults.object(forKey: "volume") as? Float ?? 0.5 } set { defaults.set(newValue, forKey: "volume"); objectWillChange.send() } }
    var interval: Int { get { defaults.integer(forKey: "interval") } set { defaults.set(newValue, forKey: "interval"); objectWillChange.send() } }
    var recents: [String] { get { defaults.stringArray(forKey: "recents") ?? [] } set { defaults.set(Array(newValue.prefix(8)), forKey: "recents") } }
    var source: String? { get { defaults.string(forKey: "source") } set { defaults.set(newValue, forKey: "source"); objectWillChange.send() } }

    var effect: EffectPreset {
        get { EffectPreset(rawValue: defaults.string(forKey: "effect") ?? "") ?? .none }
        set { defaults.set(newValue.rawValue, forKey: "effect"); objectWillChange.send(); refreshDesktop() }
    }
    var resolutionScale: Float {
        get { defaults.object(forKey: "resolutionScale") as? Float ?? 1 }
        set { defaults.set(newValue, forKey: "resolutionScale"); objectWillChange.send(); refreshDesktop() }
    }
    /// 0 = unlimited.
    var frameLimit: Int {
        get { defaults.integer(forKey: "frameLimit") }
        set { defaults.set(newValue, forKey: "frameLimit"); objectWillChange.send(); refreshDesktop() }
    }
    var renderSettings: RenderSettings {
        RenderSettings(scaling: fill ? .fill : .fit, speed: speed, volume: volume, muted: muted,
                       maxFPS: frameLimit > 0 ? frameLimit : nil, effect: effect, resolutionScale: resolutionScale)
    }
    var displays: [DisplayDescriptor] { DisplayManager.snapshot() }

    /// Tells the desktop what should be showing. Cheap when nothing changed: unchanged content is not rebuilt.
    func refreshDesktop() {
        desktop.pauseWhenCovered = pauseWhenCovered
        desktop.apply(DesktopContent(mode: layout.mode(for: displays), mainURL: current, mainSettings: renderSettings,
                                     loopsMain: playlist.count == 1, configs: layout.state.configs, maxPixel: maxPixel,
                                     performance: performance.decision))
        performance.poke()                      // the number of GPU wallpapers may have changed
    }

    func pushSettings() { refreshDesktop() }
    var currentKind: WallpaperKind? { current.flatMap { WallpaperKind.detect(pathExtension: $0.pathExtension) } }

    /// Longest edge, in pixels, of the largest connected display; images are decoded no larger than this.
    var maxPixel: Int {
        let edges = NSScreen.screens.map { Int(max($0.frame.width, $0.frame.height) * $0.backingScaleFactor) }
        return edges.max() ?? 3840
    }

    // MARK: Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        applyAppearance()
        setupMenu()

        if let src = source, FileManager.default.fileExists(atPath: src) {
            loadSource(URL(fileURLWithPath: src))
        }
        desktop.interaction = interaction
        performance.onDecisionChange = { [weak self] in self?.refreshDesktop(); self?.applyPlayback() }
        performance.onTrimMemory = { [weak self] in
            self?.desktop.trimMemory()
            self?.container.library.trimCaches()
        }
        DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.lockSync.screenLocked()
        }
        performance.activeRenderers = { [weak self] in self?.desktop.activeGPURenderers ?? 0 }
        performance.start()
        interaction.pointerEnabled = pointerReactions
        audio.tuning = AudioTuning(sensitivity: audioSensitivity, smoothing: audioSmoothing)
        interaction.audioEnabled = audio.mode != .off
        interaction.keysEnabled = keyboardReactions
        desktop.onMainFinished = { [weak self] in self?.advance() }
        layout.onChange = { [weak self] in self?.refreshDesktop(); self?.applyPlayback() }
        layout.noteConnected(displays)
        desktop.reconcile(displays: displays)
        refreshDesktop()
        systemEvents.handler = { [weak self] event in self?.handle(event) }

        powerTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.checkPower() }
        checkPower()

        setupMainMenu()
        showMainWindow()
        startAutomation()
    }

    // MARK: Automation

    private func startAutomation() {
        let library = container.library
        scheduler = SchedulerService(controller: schedule) { rule in
            Task { @MainActor in
                if let record = library.record(id: rule.wallpaperID), !record.isTrashed { await library.play(record) }
                else { Log.app.notice("Schedule rule “\(rule.name)” points at a wallpaper that is no longer in the library") }
            }
        }
        Task { @MainActor in
            self.router = AutomationRouter(target: self)
            await library.start()               // the schedule needs the library loaded before it can pick a wallpaper
            self.scheduler?.start()
        }
    }

    /// Links (`wallpaperstudio://…`) and files (.wsp, .wsscene, media) handed to the app by Finder, Shortcuts or Terminal.
    func application(_ application: NSApplication, open urls: [URL]) {
        let links = urls.filter { $0.scheme?.lowercased() == URLCommand.scheme }
        let files = urls.filter { $0.isFileURL }
        Task { @MainActor in
            for link in links { await router?.handle(link) }
            guard !files.isEmpty else { return }
            let library = container.library
            await library.importMany(files)
            // Opening a single file means "use this": play it.
            if files.count == 1, let first = files.first, let record = library.records.first(where: { $0.title == first.deletingPathExtension().lastPathComponent }) ?? library.records.first {
                await library.play(record)
            }
            sectionRequests.send(.library)
            showMainWindow()
        }
    }

    // MARK: Main window

    var mainWindow: NSWindow?
    lazy var container: AppContainer = MainActor.assumeIsolated { AppContainer(engine: self) }
    var appearance: String {
        get { defaults.string(forKey: "appearance") ?? "dark" }
        set { defaults.set(newValue, forKey: "appearance"); applyAppearance(); objectWillChange.send() }
    }
    var loginEnabled: Bool { SMAppService.mainApp.status == .enabled }

    func applyAppearance() {
        switch appearance {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "system": NSApp.appearance = nil
        default: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    @objc func showMainWindow() {
        if mainWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 680),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "Live Wallpaper"
            w.contentView = NSHostingView(rootView: RootView(container: container))
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            mainWindow = w
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func setupMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit Live Wallpaper", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)
        let winItem = NSMenuItem()
        let winMenu = NSMenu(title: "Window")
        winMenu.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        winMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        winItem.submenu = winMenu
        main.addItem(winItem)
        NSApp.mainMenu = main
    }

    // MARK: Menu

    func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "play.rectangle.on.rectangle", accessibilityDescription: "Live Wallpaper")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let title = current.map { playlist.count > 1 ? "\($0.lastPathComponent)  (\(index + 1)/\(playlist.count))" : $0.lastPathComponent } ?? "No video selected"
        let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        add(menu, "Open Window…", #selector(showMainWindow), ",")
        add(menu, "Choose Wallpaper…", #selector(chooseVideo), "o")
        add(menu, "Choose Folder (Playlist)…", #selector(chooseFolder), "")

        let recent = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu()
        for path in recents {
            let item = NSMenuItem(title: URL(fileURLWithPath: path).lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = path
            recentMenu.addItem(item)
        }
        if recents.isEmpty { recentMenu.addItem(NSMenuItem(title: "None", action: nil, keyEquivalent: "")) }
        recent.submenu = recentMenu
        menu.addItem(recent)
        menu.addItem(.separator())

        add(menu, userPaused ? "Resume" : "Pause", #selector(togglePause), "p")
        if playlist.count > 1 {
            add(menu, "Next Video", #selector(nextVideo), "n")
            add(menu, "Shuffle", #selector(toggleShuffle), "").state = shuffle ? .on : .off
            menu.addItem(submenu("Switch Every", Self.intervals.map { ($0.0, $0.1, interval == $0.1) }, #selector(pickInterval(_:))))
        }
        menu.addItem(.separator())

        menu.addItem(submenu("Speed", Self.speeds.map { (($0 == 1 ? "Normal" : "\($0)x"), Int($0 * 100), $0 == speed) }, #selector(pickSpeed(_:))))
        add(menu, "Mute", #selector(toggleMute), "m").state = muted ? .on : .off
        menu.addItem(submenu("Volume", Self.volumes.map { ("\(Int($0 * 100))%", Int($0 * 100), $0 == volume) }, #selector(pickVolume(_:))))
        add(menu, "Fill Screen (crop)", #selector(toggleFill), "f").state = fill ? .on : .off
        menu.addItem(.separator())

        add(menu, "Pause When Desktop Is Covered", #selector(toggleCovered), "").state = pauseWhenCovered ? .on : .off
        add(menu, "Pause on Battery", #selector(toggleBattery), "").state = pauseOnBattery ? .on : .off
        add(menu, "Use Current Frame as Static Wallpaper", #selector(setStaticWallpaper), "")
        menu.addItem(.separator())

        add(menu, "Launch at Login", #selector(toggleLogin), "").state = SMAppService.mainApp.status == .enabled ? .on : .off
        let quit = NSMenuItem(title: "Quit Live Wallpaper", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    @discardableResult
    func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    func submenu(_ title: String, _ options: [(String, Int, Bool)], _ action: Selector) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (label, value, selected) in options {
            let item = NSMenuItem(title: label, action: action, keyEquivalent: "")
            item.target = self
            item.tag = value
            item.state = selected ? .on : .off
            sub.addItem(item)
        }
        parent.submenu = sub
        return parent
    }

    // MARK: Actions

    @objc func chooseVideo() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "Choose a wallpaper (video, image or GIF)"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { loadSource(url) }
    }

    @objc func chooseFolder() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "Choose a folder of wallpapers"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        if panel.runModal() == .OK, let url = panel.url { loadSource(url) }
    }

    @objc func openRecent(_ sender: NSMenuItem) {
        if let path = sender.representedObject as? String { loadSource(URL(fileURLWithPath: path)) }
    }

    @objc func togglePause() { userPaused.toggle(); applyPlayback() }
    @objc func toggleMute() { muted.toggle(); pushSettings() }
    @objc func toggleShuffle() { shuffle.toggle() }
    @objc func toggleCovered() { pauseWhenCovered.toggle(); updateOcclusion() }
    @objc func toggleBattery() { pauseOnBattery.toggle(); checkPower() }
    @objc func toggleFill() { fill.toggle(); pushSettings() }
    @objc func pickSpeed(_ s: NSMenuItem) { speed = Float(s.tag) / 100; pushSettings() }
    @objc func pickVolume(_ s: NSMenuItem) { volume = Float(s.tag) / 100; pushSettings() }
    @objc func pickInterval(_ s: NSMenuItem) { interval = s.tag; scheduleRotation() }
    @objc func nextVideo() { advance() }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            Log.app.error("Login item change failed: \(error.localizedDescription)")
            NSAlert(error: error).runModal()
        }
        objectWillChange.send()
    }

    @objc func setStaticWallpaper() {
        guard let cg = desktop.snapshot() else { return }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let png = rep.representation(using: .png, properties: [:]),
              let dir = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("LiveWallpaper", isDirectory: true) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("frame-\(Int(Date().timeIntervalSince1970)).png")
        do {
            try png.write(to: file)
            for screen in NSScreen.screens {
                try NSWorkspace.shared.setDesktopImageURL(file, for: screen, options: [:])
            }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    // MARK: Loading

    /// Accepts a single wallpaper file (video, image, GIF) or a folder of them.
    func loadSource(_ url: URL) {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        var files: [URL]
        if isDir.boolValue {
            let contents = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
            files = contents.filter { WallpaperKind.detect(pathExtension: $0.pathExtension) != nil }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        } else {
            files = [url]
        }
        files = files.filter(Self.canDisplay)
        guard !files.isEmpty else {
            let alert = NSAlert()
            alert.messageText = isDir.boolValue ? "No usable wallpapers in that folder" : "Can't display \(url.lastPathComponent)"
            alert.informativeText = "Supported: videos (.mp4 .mov .m4v), images (.jpg .png .heic .tiff .bmp .webp) and animated .gif. Convert other formats first."
            alert.runModal()
            return
        }
        playlist = files
        index = shuffle ? Int.random(in: 0..<files.count) : 0
        source = url.path
        Log.engine.info("Loaded \(files.count) wallpaper(s) from \(url.lastPathComponent)")
        recents = [url.path] + recents.filter { $0 != url.path }
        startCurrent()
        scheduleRotation()
    }

    /// Cheap check that the file can really be decoded, so bad files are rejected before they replace the current wallpaper.
    static func canDisplay(_ url: URL) -> Bool { MediaInspector.canDisplay(url) }

    func startCurrent() {
        refreshDesktop()
        applyPlayback()
        lockSync.wallpaperChanged()
    }

    func advance() {
        guard playlist.count > 1 else { return }
        if shuffle {
            var next = index
            while next == index { next = Int.random(in: 0..<playlist.count) }
            index = next
        } else {
            index = (index + 1) % playlist.count
        }
        startCurrent()
        scheduleRotation()
    }

    func scheduleRotation() {
        rotationTimer?.invalidate()
        rotationTimer = nil
        // Images never "finish", so in a playlist they rotate on a timer even when "Switch every" is Off.
        let seconds = interval > 0 ? interval : (currentKind != .video ? 30 : 0)
        guard seconds > 0, playlist.count > 1 else { return }
        rotationTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(seconds), repeats: false) { [weak self] _ in
            self?.advance()
        }
    }

    // MARK: Playback state

    func applyPlayback() {
        desktop.setPlaying(!(userPaused || (pauseOnBattery && onBattery) || performance.decision.paused))
    }

    func checkPower() {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        let battery = type == kIOPSBatteryPowerValue
        if battery != onBattery { onBattery = battery; applyPlayback() }
    }

    func updateOcclusion() {
        desktop.pauseWhenCovered = pauseWhenCovered
        desktop.refreshPlayback()
    }

    // MARK: Windows / system events

    func handle(_ event: SystemEventMonitor.Event) {
        switch event {
        case .sleep:
            desktop.setPlaying(false)
        case .wake:
            restoreDesktop()
            // Displays often finish waking after the notification; a second pass catches late reconfiguration.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.restoreDesktop() }
        case .screensChanged:
            layout.noteConnected(displays)
            desktop.reconcile(displays: displays)
            refreshDesktop()
            applyPlayback()
        case .spaceChanged:
            desktop.reassert()
        }
    }

    func restoreDesktop() {
        desktop.reconcile(displays: displays)
        desktop.reassert()
        refreshDesktop()
        applyPlayback()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

// MARK: - Automation target

extension AppDelegate: AutomationTarget {
    func nextWallpaper() { nextVideo() }
    func setPaused(_ paused: Bool) { userPaused = paused; applyPlayback() }
    var isPaused: Bool { userPaused }
    func setDisplayMode(_ mode: DisplayMode) { layout.setMode(mode, for: displays) }
    func setPerformanceProfile(_ profile: PerformanceProfile) { performance.profile = profile }
    func show(_ section: SidebarSection) { showMainWindow(); sectionRequests.send(section) }

    func playLibraryItem(titled title: String) async -> Bool {
        let library = container.library
        guard let record = library.records.first(where: { !$0.isTrashed && $0.title.caseInsensitiveCompare(title) == .orderedSame }) else { return false }
        await library.play(record)
        return true
    }

    /// Plays a list of files (for example the wallpapers of a collection) as a playlist.
    func loadPlaylist(files: [URL]) {
        let playable = files.filter { MediaInspector.canDisplay($0) }
        guard !playable.isEmpty else { return }
        playlist = playable
        index = shuffle ? Int.random(in: 0..<playable.count) : 0
        source = playable[0].path
        startCurrent()
        scheduleRotation()
    }
}
