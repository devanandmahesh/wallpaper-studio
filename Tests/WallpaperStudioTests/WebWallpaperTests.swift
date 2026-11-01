import Testing
import AppKit
import Network
import WebKit
import StudioCore
@testable import WallpaperStudio

/// A local TCP listener that counts connections: if a sandboxed page could reach the network, it would show up here.
private final class ConnectionCounter {
    private let listener: NWListener
    private(set) var connections = 0
    private(set) var port: UInt16 = 0

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.newConnectionHandler = { [weak self] c in self?.connections += 1; c.cancel() }
        listener.stateUpdateHandler = { state in if case .ready = state { ready.signal() } }
        listener.start(queue: .global())
        _ = ready.wait(timeout: .now() + 3)
        port = listener.port?.rawValue ?? 0
    }
    deinit { listener.cancel() }
}

@MainActor
@Suite struct WebWallpaperTests {
    func spin(_ s: Double) async {
        let end = Date().addingTimeInterval(s)
        while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)); try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    func eval(_ web: WKWebView, _ js: String) async -> Any? {
        await withCheckedContinuation { c in web.evaluateJavaScript(js) { value, _ in c.resume(returning: value) } }
    }

    func waitFor(_ web: WKWebView, _ js: String, seconds: Double = 8) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if (await eval(web, js) as? Bool) == true { return true }
            await spin(0.1)
        }
        return false
    }

    func package(html: String, permissions: [String] = [], scripts: [String: String] = [:], config: [String: String] = [:]) throws -> ResolvedPackage {
        var items = [Z(name: "index.html", data: Data(html.utf8))]
        for (name, source) in scripts { items.append(Z(name: name, data: Data(source.utf8))) }
        var extra: [String: Any] = ["permissions": permissions, "config": config]
        if !scripts.isEmpty { extra["scripts"] = scripts.keys.sorted() }
        items.insert(Z(name: "manifest.json", data: Fixtures.manifestData(.init(type: "web", entry: "index.html", extra: extra))), at: 0)
        let zip = Fixtures.zipFile(items)
        return try PackageService.extract(zip, to: FileManager.default.temporaryDirectory.appendingPathComponent("web-\(UUID().uuidString)"))
    }

    func host(_ renderer: WebWallpaperRenderer) throws -> (WKWebView, NSWindow) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = try #require(renderer.makeContentView() as? WKWebView)
        window.contentView?.addSubview(view)
        view.frame = window.contentView!.bounds
        return (view, window)
    }

    @Test func aPageRunsItsOwnScriptsAndSeesTheStudioAPI() async throws {
        let pkg = try package(html: "<html><body><script>document.title='ready:'+window.studio.version+':'+window.studio.config.mood;</script></body></html>",
                              config: ["mood": "calm"])
        let renderer = try #require(WebWallpaperRenderer(package: pkg, interaction: nil))
        let (web, window) = try host(renderer)
        #expect(await waitFor(web, "document.title === 'ready:1:calm'"))
        renderer.teardown(); window.close()
    }

    @Test func packageScriptsRunInsideThePage() async throws {
        let pkg = try package(html: "<html><body></body></html>", scripts: ["main.js": "document.title = 'script-ran';"])
        let renderer = try #require(WebWallpaperRenderer(package: pkg, interaction: nil))
        let (web, window) = try host(renderer)
        #expect(await waitFor(web, "document.title === 'script-ran'"))
        renderer.teardown(); window.close()
    }

    @Test func thePageCannotReachTheNetworkOrLeaveItsFolder() async throws {
        let counter = try ConnectionCounter()
        #expect(counter.port != 0)
        let html = """
        <html><body><script>
        window.result = {net: 'pending'};
        fetch('http://127.0.0.1:\(counter.port)/fetch').then(function(){ window.result.net = 'reached'; }).catch(function(){ window.result.net = 'blocked'; });
        var img = new Image(); img.src = 'http://127.0.0.1:\(counter.port)/img.png';
        var xhr = new XMLHttpRequest(); xhr.open('GET', 'http://127.0.0.1:\(counter.port)/xhr'); try { xhr.send(); } catch (e) {}
        try { new WebSocket('ws://127.0.0.1:\(counter.port)/ws'); } catch (e) {}
        document.title = 'ready';
        </script>
        <iframe src="file:///etc/hosts"></iframe>
        <iframe src="http://127.0.0.1:\(counter.port)/frame"></iframe>
        <a id="out" href="https://example.com">x</a>
        </body></html>
        """
        let pkg = try package(html: html)
        let renderer = try #require(WebWallpaperRenderer(package: pkg, interaction: nil))
        let (web, window) = try host(renderer)
        #expect(await waitFor(web, "document.title === 'ready'"))
        await spin(2.0)
        #expect(counter.connections == 0, "the page opened \(counter.connections) connection(s)")
        let v1 = await eval(web, "window.result.net")
        #expect((v1 as? String) != "reached")
        #expect(renderer.blockedNavigations >= 1, "iframes to other files or sites must be cancelled")
        renderer.teardown(); window.close()
    }

    @Test func pointerAndAudioArriveOnlyWhenThePackageAsksAndTheUserAllows() async throws {
        let page = "<html><body><script>window.frames_ = []; studio.onFrame(function(f){ window.frames_.push(f); }); document.title='ready';</script></body></html>"
        let pointer = ManualPointerSource(), keys = ManualKeySource(), feed = FakeFeed()
        feed.frame = AudioFrame(bands: Array(repeating: 0.5, count: 32), bass: 0.9, level: 0.5)
        let hub = InteractionHub(pointer: pointer, keys: keys, audio: feed)
        hub.audioEnabled = true
        pointer.location = CGPoint(x: 100, y: 100)

        // A package that asks for audio gets audio, and no pointer.
        let asking = try package(html: page, permissions: ["audio"])
        let r1 = try #require(WebWallpaperRenderer(package: asking, interaction: hub))
        let (w1, win1) = try host(r1)
        #expect(await waitFor(w1, "document.title === 'ready'"))
        r1.play()
        #expect(feed.isRunning && !pointer.isRunning)               // only the requested input is switched on
        r1.sendFrame(); await spin(0.3)
        let v2 = await eval(w1, "window.frames_.length")
        #expect(((v2 as? Int) ?? 0) >= 1)
        let v3 = await eval(w1, "window.frames_[0].audio.bass")
        #expect(abs(((v3 as? Double) ?? 0) - 0.9) < 0.001)
        let v4 = await eval(w1, "'pointer' in window.frames_[0]")
        #expect((v4 as? Bool) == false)
        r1.pause()
        #expect(!feed.isRunning)                                    // released when paused
        let v5 = await eval(w1, "window.studio.paused")
        #expect((v5 as? Bool) == true)
        r1.teardown(); win1.close()

        // A package that asks for nothing gets nothing, even though audio is enabled and playing.
        let silent = try package(html: page)
        let r2 = try #require(WebWallpaperRenderer(package: silent, interaction: hub))
        let (w2, win2) = try host(r2)
        #expect(await waitFor(w2, "document.title === 'ready'"))
        r2.play(); r2.sendFrame(); await spin(0.3)
        let v6 = await eval(w2, "window.frames_.length")
        #expect(!feed.isRunning && (v6 as? Int) == 0)
        r2.teardown(); win2.close()
    }

    @Test func switchedOffInputsAreNotDeliveredEvenIfRequested() async throws {
        let page = "<html><body><script>window.frames_ = []; studio.onFrame(function(f){ window.frames_.push(f); }); document.title='ready';</script></body></html>"
        let feed = FakeFeed()
        feed.frame = AudioFrame(bass: 0.9)
        let hub = InteractionHub(pointer: ManualPointerSource(), keys: ManualKeySource(), audio: feed)    // audioEnabled stays false
        let pkg = try package(html: page, permissions: ["audio"])
        let r = try #require(WebWallpaperRenderer(package: pkg, interaction: hub))
        let (web, window) = try host(r)
        #expect(await waitFor(web, "document.title === 'ready'"))
        r.play(); r.sendFrame(); await spin(0.3)
        let v7 = await eval(web, "window.frames_.length")
        #expect(!feed.isRunning && (v7 as? Int) == 0)
        r.teardown(); window.close()
    }

    @Test func nonWebPackagesAndMissingEntriesAreRefused() throws {
        let scene = try PackageService.extract(goodScenePackage(), to: FileManager.default.temporaryDirectory.appendingPathComponent("w-\(UUID().uuidString)"))
        #expect(WebWallpaperRenderer(package: scene, interaction: nil) == nil)
    }

    @Test func theFactoryBuildsAWebRendererAndTheWindowShowsItsView() async throws {
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: "ws-web-\(name)")!
        let model = LibraryModel(storage: LibraryStorage(root: FileManager.default.temporaryDirectory.appendingPathComponent("ws-web-\(name)/LiveWallpaper/Library")), defaults: defaults)
        let items = [Z(name: "manifest.json", data: Fixtures.manifestData(.init(type: "web", entry: "index.html"))),
                     Z(name: "index.html", data: Data("<html><body>hello</body></html>".utf8))]
        let record = try await model.importFile(Fixtures.zipFile(items))
        let url = try #require(model.fileURL(record))
        #expect(RendererFactory.make(url: url, loops: true, settings: RenderSettings(), maxPixel: 400) is WebWallpaperRenderer)

        _ = NSApplication.shared
        let m = DesktopWindowManager()
        m.presentsWindows = false
        m.pauseWhenCovered = false
        m.reconcile(displays: [DisplayDescriptor(id: 3, uuid: "u3", name: "D", frame: CGRect(x: 0, y: 0, width: 400, height: 300), scale: 2, maxFPS: 60, isMain: true)])
        m.apply(DesktopContent(mode: .mirror, mainURL: url, mainSettings: RenderSettings(), loopsMain: true, configs: [:], maxPixel: 400))
        let window = try #require(m.sessions[3]?.window)
        #expect(window.embeddedView is WKWebView && window.contentLayer == nil && window.hasContent)
        m.apply(DesktopContent(mode: .mirror, mainURL: nil, mainSettings: RenderSettings(), loopsMain: true, configs: [:], maxPixel: 400))
        #expect(window.embeddedView == nil && !window.hasContent)
    }
}
