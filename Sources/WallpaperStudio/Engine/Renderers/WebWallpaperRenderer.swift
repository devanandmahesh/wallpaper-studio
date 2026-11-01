import AppKit
import WebKit
import StudioCore

/// HTML/JavaScript wallpapers in a locked-down `WKWebView`, one per display.
///
/// Sandbox:
///  * runs in WebKit's separate, OS-sandboxed web-content process; no native bridge exists except `window.studio`;
///  * the page is loaded from the unpacked package with read access limited to that folder;
///  * navigation anywhere else (other files, web pages, new windows, frames) is cancelled;
///  * http(s)/ws(s) requests are blocked by a content rule list, so a wallpaper cannot phone home;
///  * an ephemeral data store (no cookies/storage kept), no autoplay of audio;
///  * pointer and audio data are delivered **only** if the manifest asks for them *and* the user has enabled that input.
final class WebWallpaperRenderer: NSObject, WallpaperRenderer, WKNavigationDelegate, WKUIDelegate {
    let kind = WallpaperKind.package
    var onFinished: (() -> Void)?

    private let package: ResolvedPackage
    private let interaction: InteractionHub?
    private let views = NSHashTable<WKWebView>.weakObjects()
    private var playing = false
    private var timer: Timer?
    private var token: InteractionHub.Token?
    private(set) var blockedNavigations = 0
    private(set) var framesSent = 0

    static let blockNetworkRules = """
    [{"trigger":{"url-filter":"^https?://.*"},"action":{"type":"block"}},
     {"trigger":{"url-filter":"^wss?://.*"},"action":{"type":"block"}}]
    """

    init?(package: ResolvedPackage, interaction: InteractionHub?) {
        guard package.manifest.type == .web, FileManager.default.fileExists(atPath: package.entryURL.path) else { return nil }
        self.package = package
        self.interaction = interaction
    }

    // MARK: WallpaperRenderer

    func makeLayer() -> CALayer { CALayer() }

    func makeContentView() -> NSView? {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.mediaTypesRequiringUserActionForPlayback = [.audio]
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.userContentController.addUserScript(WKUserScript(source: bootstrapScript(), injectionTime: .atDocumentStart, forMainFrameOnly: true))
        for script in package.manifest.scripts {
            if let source = try? String(contentsOf: package.directory.appendingPathComponent(script), encoding: .utf8) {
                config.userContentController.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
            }
        }
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.autoresizingMask = [.width, .height]
        web.allowsMagnification = false
        views.add(web)

        let package = self.package
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "wsp-block-network", encodedContentRuleList: Self.blockNetworkRules) { [weak web] list, error in
            guard let web else { return }
            if let list { web.configuration.userContentController.add(list) }
            else { Log.engine.error("Could not install the network block list: \(error?.localizedDescription ?? "unknown")") }
            web.loadFileURL(package.entryURL, allowingReadAccessTo: package.directory)
        }
        return web
    }

    func apply(_ settings: RenderSettings) {}

    func play() {
        guard !playing else { return }
        playing = true
        setPaused(false)
        startFrames()
    }

    func pause() {
        guard playing else { return }
        playing = false
        setPaused(true)
        stopFrames()
    }

    func refreshLayers() {}

    func snapshot() -> CGImage? {
        guard let url = package.previewURL, let source = ImageLoading.source(url) else { return nil }
        return ImageLoading.thumbnail(source, index: 0, maxPixel: 1280)
    }

    func teardown() {
        playing = false
        stopFrames()
        for web in views.allObjects {
            web.stopLoading()
            web.navigationDelegate = nil
            web.uiDelegate = nil
            web.configuration.userContentController.removeAllUserScripts()
            web.removeFromSuperview()
        }
        views.removeAllObjects()
    }

    // MARK: Page API

    private func bootstrapScript() -> String {
        let config = (try? JSONSerialization.data(withJSONObject: package.manifest.config)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return """
        (function () {
          var listeners = [];
          window.studio = {
            version: 1, paused: false, config: \(config),
            onFrame: function (cb) { if (typeof cb === 'function') listeners.push(cb); },
            _frame: function (f) { if (window.studio.paused) return; for (var i = 0; i < listeners.length; i++) { try { listeners[i](f); } catch (e) {} } },
            _pause: function (p) { window.studio.paused = !!p; document.dispatchEvent(new CustomEvent(p ? 'studio-pause' : 'studio-resume')); }
          };
        })();
        """
    }

    private func setPaused(_ paused: Bool) {
        for web in views.allObjects {
            web.evaluateJavaScript("window.studio && window.studio._pause(\(paused))", completionHandler: nil)
            web.setAllMediaPlaybackSuspended(paused, completionHandler: nil)
        }
    }

    private var wantsPointer: Bool { package.manifest.permissions.contains(.pointer) }
    private var wantsAudio: Bool { package.manifest.permissions.contains(.audio) }

    private func startFrames() {
        guard wantsPointer || wantsAudio else { return }
        if let interaction, token == nil { token = interaction.acquire(pointer: wantsPointer, keys: false, audio: wantsAudio) }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.sendFrame() }
        timer?.tolerance = 0.01
    }

    private func stopFrames() {
        timer?.invalidate(); timer = nil
        if let token, let interaction { interaction.release(token) }
        token = nil
    }

    /// Pushes the current pointer/audio to every page (only the signals the package asked for, and only if enabled).
    func sendFrame() {
        let snapshot = interaction?.snapshot() ?? .idle
        for web in views.allObjects {
            var payload: [String: Any] = [:]
            if wantsPointer, let sample = snapshot.pointer, let frame = web.window?.frame,
               let p = PointerMapper.normalize(location: sample.location, screen: frame, rotation: .r0) {
                payload["pointer"] = ["x": p.x, "y": p.y, "active": true, "speed": min(sample.speed / max(Double(frame.height), 1), 1)]
            }
            if wantsAudio, snapshot.audio != .silent {
                let a = snapshot.audio
                payload["audio"] = ["bands": a.bands.map { (Double($0) * 1000).rounded() / 1000 }, "bass": a.bass, "mid": a.mid,
                                    "treble": a.treble, "level": a.level, "beat": a.beat, "waveform": a.waveform.map { (Double($0) * 1000).rounded() / 1000 }]
            }
            guard !payload.isEmpty, let data = try? JSONSerialization.data(withJSONObject: payload), let json = String(data: data, encoding: .utf8) else { continue }
            web.evaluateJavaScript("window.studio && window.studio._frame(\(json))", completionHandler: nil)
            framesSent += 1
        }
    }

    // MARK: Navigation policy

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { blockedNavigations += 1; decisionHandler(.cancel); return }
        if url.scheme == "about" { decisionHandler(.allow); return }
        let root = package.directory.resolvingSymlinksInPath().path
        if url.isFileURL, url.resolvingSymlinksInPath().path.hasPrefix(root + "/") { decisionHandler(.allow); return }
        blockedNavigations += 1
        Log.engine.notice("Blocked web wallpaper navigation to \(url.scheme ?? "?")")
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        blockedNavigations += 1
        return nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Log.engine.error("Web wallpaper process ended; reloading")
        webView.loadFileURL(package.entryURL, allowingReadAccessTo: package.directory)
    }
}
