import AppKit
import StudioCore
import StudioRender

/// What should currently be on the desktop. The engine builds one of these; the manager makes it so.
struct DesktopContent {
    var mode: DisplayMode
    var mainURL: URL?
    var mainSettings: RenderSettings
    var loopsMain: Bool
    var configs: [String: DisplayConfig]
    var maxPixel: Int
    /// Limits from the performance policy, applied on top of every wallpaper's own settings.
    var performance: PerformanceDecision?
}

/// Identifies what a renderer was built from, so unchanged content is never rebuilt.
private struct RendererKey: Hashable {
    let path: String
    let loops: Bool
    let maxPixel: Int
    let effect: EffectPreset
    let fpsCap: Int?          // only part of the identity where it changes the renderer (video / scenes)

    init(url: URL, loops: Bool, maxPixel: Int, settings: RenderSettings) {
        path = url.path
        self.loops = loops
        self.maxPixel = maxPixel
        let kind = WallpaperKind.detect(pathExtension: url.pathExtension)
        effect = (kind == .image || kind == .video || kind == .package) ? settings.effect : .none
        fpsCap = (kind == .video || kind == .scene || kind == .package) ? settings.maxFPS : nil
    }
}

private enum Source: Equatable {
    case shared(RendererKey)
    case own(RendererKey)
    case none
    case stale      // the shared renderer was replaced; this session must re-install
}

/// One display's window plus its own playback state.
final class DisplaySession {
    let displayID: UInt32
    private(set) var uuid: String
    let window: WallpaperWindow
    fileprivate var source: Source = .none
    fileprivate var ownRenderer: WallpaperRenderer?
    fileprivate var settings = RenderSettings()
    fileprivate var userPaused = false

    init(display: DisplayDescriptor) {
        displayID = display.id
        uuid = display.uuid
        window = WallpaperWindow(displayID: display.id, frame: display.frame)
    }

    var hasContent: Bool { window.hasContent }
    /// Kind of the renderer owned by this session (nil when it uses the shared renderer or has none).
    var ownKind: WallpaperKind? { ownRenderer?.kind }
    var usesSharedRenderer: Bool { if case .shared = source { return true } else { return false } }
    var ownRendererIsSet: Bool { ownRenderer != nil }
    var isVisible: Bool { window.occlusionState.contains(.visible) }
    fileprivate func update(uuid: String) { self.uuid = uuid }
}

/// Owns one session per connected display and makes them match the requested `DesktopContent`.
///
/// * mirror / span: one shared renderer feeds a layer in every window (a single decoder, however many displays).
/// * independent: every display gets its own renderer, settings, rotation and pause state.
/// Sessions are reused across display changes (no flicker); a session is only created or destroyed when its display
/// appears or disappears. Settings are remembered per physical display (UUID), so a reconnected monitor looks as before.
final class DesktopWindowManager {
    private(set) var sessions: [UInt32: DisplaySession] = [:]
    private(set) var displays: [DisplayDescriptor] = []
    private var tokens: [UInt32: NSObjectProtocol] = [:]
    private var content: DesktopContent?
    private var shared: WallpaperRenderer?
    private var sharedKey: RendererKey?

    /// Tests set this to false so synthetic displays never put windows on the real screen.
    var presentsWindows = true
    var pauseWhenCovered = true
    /// Shared cursor/typing input for interactive wallpapers (nil = wallpapers do not react).
    var interaction: InteractionHub?
    private(set) var globalPlaying = true

    /// Called when any window's visibility changes (covered by a fullscreen app, Space switch, ...).
    var onVisibilityChange: (() -> Void)?
    /// Called when the renderer showing the *main* wallpaper reaches its end (playlist advance).
    var onMainFinished: (() -> Void)?

    var displayIDs: [UInt32] { sessions.keys.sorted() }
    var sharedKind: WallpaperKind? { shared?.kind }
    var sharedRenderer: WallpaperRenderer? { shared }

    /// Measured GPU cost of every Metal renderer currently on screen (nil if none is).
    var gpuStats: RenderStats.Snapshot? {
        let renderers = ([shared] + sessions.values.map(\.ownRenderer)).compactMap { $0 as? MetalSceneRenderer }
        let snaps = renderers.map(\.stats).filter { $0.frames > 0 }
        guard !snaps.isEmpty else { return renderers.isEmpty ? nil : RenderStats.Snapshot() }
        var total = RenderStats.Snapshot()
        total.frames = snaps.map(\.frames).reduce(0, +)
        total.averageGPUMilliseconds = snaps.map(\.averageGPUMilliseconds).reduce(0, +) / Double(snaps.count)
        total.averageEncodeMilliseconds = snaps.map(\.averageEncodeMilliseconds).reduce(0, +) / Double(snaps.count)
        total.maxGPUMilliseconds = snaps.map(\.maxGPUMilliseconds).max() ?? 0
        return total
    }
    /// How many renderers will report "finished" (must be at most one, or playlists would skip ahead).
    var finishedBindingCount: Int {
        (shared?.onFinished != nil ? 1 : 0) + sessions.values.filter { $0.ownRenderer?.onFinished != nil }.count
    }

    /// True when every wallpaper window is fully hidden.
    var allOccluded: Bool { !sessions.isEmpty && sessions.values.allSatisfy { !$0.isVisible } }

    // MARK: Displays

    func reconcile(displays newDisplays: [DisplayDescriptor]) {
        displays = newDisplays
        let byID = Dictionary(newDisplays.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let plan = DisplayReconciler.plan(existing: Set(sessions.keys), desired: newDisplays.map(\.id))

        for id in plan.removed { tearDown(id) }
        for id in plan.added {
            guard let display = byID[id] else { continue }
            let session = DisplaySession(display: display)
            sessions[id] = session
            tokens[id] = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: session.window, queue: .main
            ) { [weak self] _ in self?.visibilityChanged() }
            if presentsWindows { session.window.orderBack(nil) }
        }
        for id in plan.kept {
            if let display = byID[id], let session = sessions[id] {
                session.update(uuid: display.uuid)
                session.window.realign(to: display.frame)
            }
        }
        if !plan.added.isEmpty || !plan.removed.isEmpty {
            Log.engine.info("Displays reconciled: +\(plan.added.count) -\(plan.removed.count) =\(plan.kept.count)")
        }
        if let content { apply(content) }
    }

    // MARK: Content

    /// Puts a renderer's picture into a window: a view for web pages, a layer for everything else.
    static func install(_ renderer: WallpaperRenderer?, in window: WallpaperWindow, animated: Bool) {
        if let renderer, let view = renderer.makeContentView() {
            window.setContent(nil, animated: false)
            window.setEmbeddedView(view)
        } else {
            window.setEmbeddedView(nil)
            window.setContent(renderer?.makeLayer(), animated: animated)
        }
    }

    func apply(_ newContent: DesktopContent) {
        content = newContent
        let independent = newContent.mode == .independent
        let displayFPS = displays.map(\.maxFPS).max() ?? 60
        var newContent = newContent
        if let decision = newContent.performance {
            newContent.mainSettings = newContent.mainSettings.applying(decision, displayMaxFPS: displayFPS)
        }
        let mainKey = newContent.mainURL.map { RendererKey(url: $0, loops: newContent.loopsMain, maxPixel: newContent.maxPixel, settings: newContent.mainSettings) }

        // 1. Shared renderer (mirror / span).
        let wantShared = independent ? nil : mainKey
        var retiredShared: WallpaperRenderer?
        if wantShared != sharedKey {
            retiredShared = shared
            shared = wantShared.flatMap { _ in newContent.mainURL }.flatMap {
                RendererFactory.make(url: $0, loops: newContent.loopsMain, settings: newContent.mainSettings, maxPixel: newContent.maxPixel, interaction: interaction)
            }
            sharedKey = shared == nil ? nil : wantShared
            for session in sessions.values {
                if case .shared = session.source { session.source = .stale }
            }
        }
        shared?.apply(newContent.mainSettings)

        // 2. Per display.
        let union = SpanLayout.union(of: displays.map(\.frame))
        for display in displays {
            guard let session = sessions[display.id] else { continue }
            let config = independent ? newContent.configs[display.uuid] : nil
            let ownURL = config?.wallpaperPath.map { URL(fileURLWithPath: $0) }.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            let url = independent ? (ownURL ?? newContent.mainURL) : nil
            var settings = config?.renderSettings ?? newContent.mainSettings
            if config != nil, let decision = newContent.performance { settings = settings.applying(decision, displayMaxFPS: display.maxFPS) }
            session.settings = settings
            session.userPaused = config?.paused ?? false

            let desired: Source
            if independent {
                desired = url.map { .own(RendererKey(url: $0, loops: ownURL == nil ? newContent.loopsMain : true, maxPixel: newContent.maxPixel, settings: settings)) } ?? .none
            } else {
                desired = sharedKey.map { shared == nil ? .none : .shared($0) } ?? .none
            }

            if session.source != desired {
                let hadContent = session.hasContent
                let previousOwn = session.ownRenderer
                session.ownRenderer = nil
                switch desired {
                case .shared:
                    DesktopWindowManager.install(shared, in: session.window, animated: hadContent)
                case .own(let key):
                    let renderer = url.flatMap {
                        RendererFactory.make(url: $0, loops: key.loops, settings: settings, maxPixel: newContent.maxPixel, interaction: interaction)
                    }
                    session.ownRenderer = renderer
                    DesktopWindowManager.install(renderer, in: session.window, animated: hadContent)
                case .none, .stale:
                    session.window.setEmbeddedView(nil); session.window.setContent(nil, animated: false)
                }
                session.source = session.window.hasContent ? desired : .none
                previousOwn?.teardown()
            }
            session.ownRenderer?.apply(settings)

            switch newContent.mode {
            case .span: session.window.setPlacement(.span(union: union))
            case .mirror: session.window.setPlacement(.cover(.r0))
            case .independent: session.window.setPlacement(.cover(config?.rotation ?? .r0))
            }
            // Interactive layers map the cursor onto the area their picture covers.
            if let metal = session.window.contentLayer as? StudioMetalLayer {
                metal.screenFrame = newContent.mode == .span ? union : display.frame
                metal.contentRotation = newContent.mode == .independent ? (config?.rotation ?? .r0) : .r0
            }
        }
        retiredShared?.teardown()

        bindMainFinished(mainKey: mainKey, independent: independent)
        refreshPlayback()
    }

    /// Only the renderer that shows the main wallpaper reports "finished", and only one of them does.
    private func bindMainFinished(mainKey: RendererKey?, independent: Bool) {
        shared?.onFinished = nil
        sessions.values.forEach { $0.ownRenderer?.onFinished = nil }
        let finished: () -> Void = { [weak self] in self?.onMainFinished?() }
        if !independent {
            shared?.onFinished = finished
        } else if let mainKey {
            for id in displayIDs {
                if let s = sessions[id], s.source == .own(mainKey), s.ownRenderer != nil {
                    s.ownRenderer?.onFinished = finished
                    break
                }
            }
        }
    }

    // MARK: Playback

    func setPlaying(_ playing: Bool) {
        globalPlaying = playing
        refreshPlayback()
    }

    func refreshPlayback() {
        let covered = pauseWhenCovered
        if let shared {
            if globalPlaying && !(covered && allOccluded) { shared.play() } else { shared.pause() }
        }
        for session in sessions.values {
            guard let renderer = session.ownRenderer else { continue }
            let hidden = covered && !session.isVisible
            if globalPlaying && !session.userPaused && !hidden { renderer.play() } else { renderer.pause() }
        }
    }

    private func visibilityChanged() {
        rebuildTrimmedContent()
        refreshPlayback()
        onVisibilityChange?()
    }

    /// Releases the renderers (textures, decoders, particle buffers) of wallpapers nobody can see. They are rebuilt
    /// automatically when their display becomes visible again.
    @discardableResult
    func trimMemory() -> Int {
        var released = 0
        for session in sessions.values where !session.isVisible {
            if let own = session.ownRenderer {
                own.teardown()
                session.ownRenderer = nil
                session.window.setEmbeddedView(nil); session.window.setContent(nil, animated: false)
                session.source = .stale
                released += 1
            } else if case .shared = session.source, allOccluded, let shared {
                shared.teardown()
                self.shared = nil
                sharedKey = nil
                for s in sessions.values { if case .shared = s.source { s.window.setEmbeddedView(nil); s.window.setContent(nil, animated: false); s.source = .stale } }
                released += 1
                break
            }
        }
        if released > 0 { Log.engine.info("Released \(released) hidden renderer(s) under memory pressure") }
        return released
    }

    private func rebuildTrimmedContent() {
        guard let content, sessions.values.contains(where: { $0.source == .stale && $0.isVisible }) else { return }
        apply(content)
    }

    /// Number of renderers drawing on the GPU right now (used by the performance policy).
    var activeGPURenderers: Int {
        (([shared] + sessions.values.map(\.ownRenderer)).compactMap { $0 as? MetalSceneRenderer }).count
    }

    /// Re-establish level, order and content; used after wake and Space changes.
    func reassert() {
        for session in sessions.values {
            session.window.applyDesktopLevel()
            if presentsWindows { session.window.orderBack(nil) }
            session.window.layoutContent()
        }
        shared?.refreshLayers()
        sessions.values.forEach { $0.ownRenderer?.refreshLayers() }
        refreshPlayback()
        onVisibilityChange?()
    }

    /// Picture of the main display's wallpaper (falls back to any display).
    func snapshot() -> CGImage? {
        if let image = shared?.snapshot() { return image }
        let order = displays.sorted { $0.isMain && !$1.isMain }
        for d in order { if let image = sessions[d.id]?.ownRenderer?.snapshot() { return image } }
        return nil
    }

    func session(forUUID uuid: String) -> DisplaySession? { sessions.values.first { $0.uuid == uuid } }

    private func tearDown(_ id: UInt32) {
        if let token = tokens.removeValue(forKey: id) { NotificationCenter.default.removeObserver(token) }
        if let session = sessions.removeValue(forKey: id) {
            session.window.orderOut(nil)
            session.window.setEmbeddedView(nil); session.window.setContent(nil, animated: false)
            session.ownRenderer?.teardown()
        }
    }
}
