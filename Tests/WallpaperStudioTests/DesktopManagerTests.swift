import Testing
import AppKit
import StudioCore
@testable import WallpaperStudio

/// Synthetic multi-display setups: windows are created but never shown, so nothing appears on the real screen.
@MainActor
@Suite struct DesktopManagerTests {
    let left = DisplayDescriptor(id: 101, uuid: "uuid-left", name: "Left", frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080), scale: 2, maxFPS: 60, isMain: false)
    let main = DisplayDescriptor(id: 102, uuid: "uuid-main", name: "Main", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), scale: 2, maxFPS: 120, isMain: true)

    func manager(_ displays: [DisplayDescriptor]) -> DesktopWindowManager {
        _ = NSApplication.shared
        let m = DesktopWindowManager()
        m.presentsWindows = false
        m.pauseWhenCovered = false           // windows that are never shown count as hidden
        m.reconcile(displays: displays)
        return m
    }

    func content(_ mode: DisplayMode, main url: URL?, configs: [String: DisplayConfig] = [:], settings: RenderSettings = RenderSettings()) -> DesktopContent {
        DesktopContent(mode: mode, mainURL: url, mainSettings: settings, loopsMain: true, configs: configs, maxPixel: 800)
    }

    @Test func oneSessionPerDisplayAndHotPlugReconciles() {
        let m = manager([left, main])
        #expect(m.displayIDs == [101, 102])
        m.reconcile(displays: [main])
        #expect(m.displayIDs == [102])
        m.reconcile(displays: [left, main])
        #expect(m.displayIDs == [101, 102])
    }

    @Test func mirrorSharesOneRendererAcrossDisplays() {
        let m = manager([left, main])
        m.apply(content(.mirror, main: Fixtures.gif(frames: 4, delay: 0.1)))
        #expect(m.sharedKind == .animatedImage)
        #expect(m.sessions.values.allSatisfy { $0.usesSharedRenderer && $0.window.contentLayer != nil })
        #expect(m.sessions.values.allSatisfy { $0.window.placement == .cover(.r0) })
    }

    @Test func unchangedContentIsNotRebuilt() {
        let m = manager([main])
        let c = content(.mirror, main: Fixtures.png(100, 50))
        m.apply(c)
        let layer = m.sessions[102]?.window.contentLayer
        m.apply(c)
        #expect(layer != nil && m.sessions[102]?.window.contentLayer === layer)
    }

    @Test func spanPlacesEachDisplaysSliceOfOneBigPicture() throws {
        let m = manager([left, main])
        m.apply(content(.span, main: Fixtures.png(400, 100)))
        let union = CGRect(x: -1920, y: 0, width: 3840, height: 1080)
        #expect(m.sessions[101]?.window.placement == .span(union: union))
        let leftLayer = try #require(m.sessions[101]?.window.contentLayer)
        let mainLayer = try #require(m.sessions[102]?.window.contentLayer)
        #expect(leftLayer.bounds.size == CGSize(width: 3840, height: 1080) && mainLayer.bounds.size == leftLayer.bounds.size)
        // The left window's slice starts at the picture's left edge; the main window is shifted by one display width.
        #expect(leftLayer.frame.minX == 0)
        #expect(mainLayer.frame.minX == -1920)
    }

    @Test func independentGivesEachDisplayItsOwnWallpaperAndSettings() throws {
        let m = manager([left, main])
        let still = Fixtures.png(64, 64)
        let configs = ["uuid-left": DisplayConfig(wallpaperPath: still.path, scaling: .fit, rotation: .r90)]
        m.apply(content(.independent, main: Fixtures.gif(frames: 4, delay: 0.1), configs: configs))
        let l = try #require(m.sessions[101]), r = try #require(m.sessions[102])
        #expect(l.ownKind == .image && r.ownKind == .animatedImage)
        #expect(l.window.contentLayer?.contentsGravity == .resizeAspect)
        #expect(r.window.contentLayer?.contentsGravity == .resizeAspectFill)
        #expect(l.window.placement == .cover(.r90))
        #expect(l.window.contentLayer?.bounds.size == CGSize(width: 1080, height: 1920))      // swapped for a quarter turn
        #expect(r.window.contentLayer?.bounds.size == CGSize(width: 1920, height: 1080))
        #expect(m.sharedKind == nil)
    }

    @Test func perDisplayPauseIsIndependent() throws {
        let m = manager([left, main])
        let gif = Fixtures.gif(frames: 4, delay: 0.1)
        let configs = ["uuid-left": DisplayConfig(paused: true)]
        m.apply(content(.independent, main: gif, configs: configs))
        m.setPlaying(true)
        #expect(m.sessions[101]?.window.contentLayer?.speed == 0)       // paused display
        #expect(m.sessions[102]?.window.contentLayer?.speed == 1)       // neighbour keeps playing
        m.setPlaying(false)
        #expect(m.sessions[102]?.window.contentLayer?.speed == 0)       // global pause stops everything
    }

    @Test func missingPerDisplayFileFallsBackToMainWallpaper() {
        let m = manager([main])
        let configs = ["uuid-main": DisplayConfig(wallpaperPath: "/nonexistent/file.mp4")]
        m.apply(content(.independent, main: Fixtures.png(32, 32), configs: configs))
        #expect(m.sessions[102]?.ownKind == .image)
    }

    @Test func switchingModesTearsDownAndRebuildsRenderers() {
        let m = manager([left, main])
        let gif = Fixtures.gif(frames: 4, delay: 0.1)
        m.apply(content(.independent, main: gif))
        #expect(m.sessions.values.allSatisfy { $0.ownRendererIsSet } && m.sharedKind == nil)
        m.apply(content(.mirror, main: gif))
        #expect(m.sessions.values.allSatisfy { !$0.ownRendererIsSet && $0.usesSharedRenderer } && m.sharedKind == .animatedImage)
        m.apply(content(.independent, main: gif))
        #expect(m.sharedKind == nil && m.sessions.values.allSatisfy { $0.ownRendererIsSet })
    }

    @Test func removingTheMainWallpaperClearsSharedContent() {
        let m = manager([main])
        m.apply(content(.mirror, main: Fixtures.png(32, 32)))
        m.apply(content(.mirror, main: nil))
        #expect(m.sharedKind == nil && m.sessions[102]?.window.contentLayer == nil)
    }

    @Test func reconnectedDisplayRestoresItsSettingsByUUIDEvenWithANewDisplayID() throws {
        let m = manager([left, main])
        let configs = ["uuid-left": DisplayConfig(rotation: .r180)]
        let c = content(.independent, main: Fixtures.png(32, 32), configs: configs)
        m.apply(c)
        m.reconcile(displays: [main])
        #expect(m.sessions[101] == nil)
        let leftAgain = DisplayDescriptor(id: 777, uuid: "uuid-left", name: "Left", frame: left.frame, scale: 2, maxFPS: 60, isMain: false)
        m.reconcile(displays: [leftAgain, main])             // reconcile re-applies the last content
        let session = try #require(m.sessions[777])
        #expect(session.window.placement == .cover(.r180))
        #expect(session.window.contentLayer != nil)
    }

    @Test func resolutionChangeResizesWindowAndKeepsContent() throws {
        let m = manager([main])
        m.apply(content(.mirror, main: Fixtures.png(32, 32)))
        let layer = try #require(m.sessions[102]?.window.contentLayer)
        let bigger = DisplayDescriptor(id: 102, uuid: "uuid-main", name: "Main", frame: CGRect(x: 0, y: 0, width: 2560, height: 1440), scale: 2, maxFPS: 120, isMain: true)
        m.reconcile(displays: [bigger])
        #expect(m.sessions[102]?.window.frame.size == CGSize(width: 2560, height: 1440))
        #expect(m.sessions[102]?.window.contentLayer === layer && layer.bounds.size == CGSize(width: 2560, height: 1440))
    }

    @Test func exactlyOneRendererReportsFinished() {
        let gif = Fixtures.gif(frames: 3, delay: 0.1)
        for mode in DisplayMode.allCases {
            let m = manager([left, main])
            m.apply(content(mode, main: gif))
            #expect(m.finishedBindingCount == 1, "\(mode)")
        }
    }
}

@MainActor
@Suite struct DisplayLayoutControllerTests {
    func controller() -> (DisplayLayoutController, DisplayLayoutStore) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ctl-\(UUID().uuidString)/displays.json")
        let store = DisplayLayoutStore(url: url)
        return (DisplayLayoutController(store: store), store)
    }

    let a = DisplayDescriptor(id: 1, uuid: "A", name: "Alpha", frame: CGRect(x: 0, y: 0, width: 100, height: 100), scale: 1, maxFPS: 60, isMain: true)
    let b = DisplayDescriptor(id: 2, uuid: "B", name: "Beta", frame: CGRect(x: 100, y: 0, width: 100, height: 100), scale: 1, maxFPS: 60, isMain: false)

    @Test func changesPersistAndNotify() {
        let (c, store) = controller()
        var notified = 0
        c.onChange = { notified += 1 }
        c.setMode(.independent, for: [a, b])
        c.setMode(.independent, for: [a, b])                        // no change → no notification
        c.update(a, defaults: DisplayConfig(speed: 2)) { $0.rotation = .r90 }
        #expect(notified == 2)
        let reloaded = DisplayLayoutController(store: store)
        #expect(reloaded.mode(for: [b, a]) == .independent)
        #expect(reloaded.config(for: "A")?.rotation == .r90 && reloaded.config(for: "A")?.speed == 2)   // seeded from defaults
        #expect(reloaded.state.knownNames["A"] == "Alpha")
    }

    @Test func forgettingADisplayRemovesItsConfig() {
        let (c, _) = controller()
        c.update(a, defaults: DisplayConfig()) { $0.paused = true }
        c.forget(uuid: "A")
        #expect(c.config(for: "A") == nil)
    }

    @Test func connectedDisplaysAreNamedForLaterListing() {
        let (c, _) = controller()
        c.noteConnected([a, b])
        #expect(c.state.knownNames == ["A": "Alpha", "B": "Beta"])
    }
}
