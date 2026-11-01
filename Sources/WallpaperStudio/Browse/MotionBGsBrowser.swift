import AppKit
import WebKit
import StudioCore

enum BrowserDecision: Equatable { case allow, external, block }

/// Which pages the in-app browser may show. Everything else either opens in the user's own browser or is refused.
enum BrowserPolicy {
    static func host(_ host: String, matches allowed: Set<String>) -> Bool {
        let h = host.lowercased()
        return allowed.contains { h == $0 || h.hasSuffix("." + $0) }
    }

    /// - Parameter insecureHosts: hosts for which plain http is acceptable (only ever used by tests on 127.0.0.1).
    static func decide(_ url: URL?, allowedHosts: Set<String>, insecureHosts: Set<String> = []) -> BrowserDecision {
        guard let url, let scheme = url.scheme?.lowercased() else { return .block }
        if scheme == "about" { return url.absoluteString == "about:blank" ? .allow : .block }
        guard let host = url.host else { return .block }
        switch scheme {
        case "https": return host.matchesHost(allowedHosts) ? .allow : .external
        case "http":
            guard host.matchesHost(allowedHosts) else { return .external }
            return insecureHosts.contains(host.lowercased()) ? .allow : .block      // never browse the site over plain http
        default: return .block                              // file:, javascript:, data:, custom schemes
        }
    }

    /// Only video files may be downloaded into the library, and nothing enormous.
    static let maxDownloadBytes: Int64 = 1_500_000_000
    static let downloadExtensions: Set<String> = ["mp4", "mov", "m4v"]

    static func isDownload(_ response: URLResponse) -> Bool {
        if let http = response as? HTTPURLResponse, let disposition = http.value(forHTTPHeaderField: "Content-Disposition")?.lowercased(), disposition.hasPrefix("attachment") { return true }
        return response.mimeType?.lowercased().hasPrefix("video/") == true
    }

    /// A readable title from a wallpaper page address ("…/a-galaxy-within" → "A Galaxy Within").
    static func title(fromSlug slug: String) -> String? {
        let words = slug.split(whereSeparator: { $0 == "-" || $0 == "_" }).filter { !$0.isEmpty }
        guard !words.isEmpty, slug.count <= 120 else { return nil }
        return words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// Resolution tag from a download address like `/dl/4k/10270`.
    static func resolutionTag(from url: URL?) -> String? {
        let parts = url?.pathComponents ?? []
        guard let i = parts.firstIndex(of: "dl"), i + 1 < parts.count else { return nil }
        let tag = parts[i + 1].lowercased()
        return ["4k", "hd", "8k", "2k"].contains(tag) ? tag : nil
    }
}

private extension String {
    func matchesHost(_ allowed: Set<String>) -> Bool { BrowserPolicy.host(self, matches: allowed) }
}

/// A small, locked-down browser for motionbgs.com. The user browses the site as normal; when they press one of its
/// Download buttons the video is captured and added to the library. Nothing is scraped, mirrored or bundled: every
/// file is fetched by the user's own click, from the site's own download link.
final class MotionBGsBrowser: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    static let home = URL(string: "https://motionbgs.com/")!
    static let categories: [(name: String, path: String)] = [
        ("Anime", "tag:anime"), ("Games", "tag:games"), ("Superhero", "tag:superhero"), ("Nature", "tag:nature"), ("Car", "tag:car"),
        ("TV & Movie", "tag:tv"), ("Holiday", "tag:holiday"), ("Animal", "tag:animal"), ("Fantasy", "tag:fantasy"), ("Space", "tag:space"),
        ("Horror", "tag:horror"), ("Technology", "tag:technology"), ("Football", "tag:football"), ("Japan", "tag:japan"), ("4K", "4k"),
    ]

    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var isLoading = false
    @Published private(set) var progress: Double?
    @Published var status: String?

    let allowedHosts: Set<String>
    private let insecureHosts: Set<String>
    private let start: URL
    private weak var library: LibraryModel?
    private let downloadsDir: URL
    private var pageSlugTitle: String?
    private var downloads: [ObjectIdentifier: (destination: URL, title: String?, tags: [String])] = [:]
    private var observers: [NSKeyValueObservation] = []
    private(set) var blockedNavigations = 0

    private(set) lazy var webView: WKWebView = {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()                  // no cookies or history kept between sessions
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        observers = [
            view.observe(\.canGoBack, options: [.initial, .new]) { [weak self] v, _ in self?.canGoBack = v.canGoBack },
            view.observe(\.canGoForward, options: [.initial, .new]) { [weak self] v, _ in self?.canGoForward = v.canGoForward },
            view.observe(\.isLoading, options: [.initial, .new]) { [weak self] v, _ in self?.isLoading = v.isLoading },
        ]
        return view
    }()

    init(library: LibraryModel, allowedHosts: Set<String> = ["motionbgs.com"], insecureHosts: Set<String> = [], start: URL = MotionBGsBrowser.home) {
        self.library = library
        self.allowedHosts = allowedHosts
        self.insecureHosts = insecureHosts
        self.start = start
        downloadsDir = library.storage.downloadsDir
        super.init()
    }

    func loadStart() { webView.load(URLRequest(url: start)) }

    func show(path: String) {
        guard var comps = URLComponents(url: start, resolvingAgainstBaseURL: false) else { return }
        comps.path = "/" + path + "/"
        if let url = comps.url { webView.load(URLRequest(url: url)) }
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { webView.reload() }
    func openInBrowser() { if let url = webView.url ?? URL(string: start.absoluteString) { NSWorkspace.shared.open(url) } }

    func stop() {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        observers = []
    }

    // MARK: Navigation policy

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        switch BrowserPolicy.decide(navigationAction.request.url, allowedHosts: allowedHosts, insecureHosts: insecureHosts) {
        case .allow:
            decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
        case .external:
            if let url = navigationAction.request.url, navigationAction.navigationType == .linkActivated { NSWorkspace.shared.open(url) }
            blockedNavigations += 1
            decisionHandler(.cancel)
        case .block:
            blockedNavigations += 1
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard BrowserPolicy.isDownload(navigationResponse.response) else { decisionHandler(.allow); return }
        if navigationResponse.response.expectedContentLength > BrowserPolicy.maxDownloadBytes {
            status = "That file is larger than 1.5 GB, so it was not downloaded."
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.download)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Remember which wallpaper page the user is on: its address is the best title for what they download from it.
        if let url = webView.url, !url.path.hasPrefix("/dl/"), let slug = url.pathComponents.dropFirst().first, !slug.contains(":") {
            pageSlugTitle = BrowserPolicy.title(fromSlug: slug)
        }
    }

    /// Links that open a new window stay in this view when they are on the site; pop-ups are dropped.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if BrowserPolicy.decide(navigationAction.request.url, allowedHosts: allowedHosts, insecureHosts: insecureHosts) == .allow, navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        } else {
            blockedNavigations += 1
        }
        return nil
    }

    // MARK: Downloads

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { adopt(download, request: navigationAction.request) }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { adopt(download, request: download.originalRequest) }

    private func adopt(_ download: WKDownload, request: URLRequest?) {
        download.delegate = self
        let tag = BrowserPolicy.resolutionTag(from: request?.url)
        downloads[ObjectIdentifier(download)] = (downloadsDir, pageSlugTitle, ["motionbgs", "live"] + (tag.map { [$0] } ?? []))
        progress = 0
        observers.append(download.progress.observe(\.fractionCompleted) { [weak self] p, _ in
            let fraction = p.fractionCompleted
            // Late updates must not resurrect the bar after the download has finished or been cancelled.
            DispatchQueue.main.async { if let self, !self.downloads.isEmpty { self.progress = fraction } }
        })
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let ext = (suggestedFilename as NSString).pathExtension.lowercased()
        let kindOK = BrowserPolicy.downloadExtensions.contains(ext) || response.mimeType?.lowercased().hasPrefix("video/") == true
        guard kindOK else {
            status = "“\(suggestedFilename)” is not a video, so it was ignored."
            downloads[ObjectIdentifier(download)] = nil
            progress = nil
            completionHandler(nil)
            return
        }
        let safeExt = BrowserPolicy.downloadExtensions.contains(ext) ? ext : "mp4"
        let stem = EditorProject.safeAssetName(stem: (suggestedFilename as NSString).deletingPathExtension, ext: safeExt, existing: [])
        let destination = downloadsDir.appendingPathComponent("motionbgs-\(UUID().uuidString.prefix(8))-\(stem)")
        try? FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        if var entry = downloads[ObjectIdentifier(download)] {
            entry.destination = destination
            if entry.title == nil { entry.title = BrowserPolicy.title(fromSlug: (suggestedFilename as NSString).deletingPathExtension) }
            downloads[ObjectIdentifier(download)] = entry
        }
        status = "Downloading “\(suggestedFilename)”…"
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        progress = nil
        guard let entry = downloads.removeValue(forKey: ObjectIdentifier(download)), let library else { return }
        let template = WallpaperRecord(title: entry.title ?? "MotionBGs wallpaper", kind: .video, fileName: "pending.mp4", source: .imported,
                                       category: "MotionBGs", tags: entry.tags, contentHash: "pending")
        Task { @MainActor in
            do {
                let record = try await library.importFile(entry.destination, move: true, template: template)
                self.status = "Added “\(record.title)” to your library."
            } catch {
                try? FileManager.default.removeItem(at: entry.destination)
                self.status = "Could not add the download: \(error.localizedDescription)"
            }
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        progress = nil
        // A download we refused ourselves was already removed (and explained); only report genuine failures.
        guard let entry = downloads.removeValue(forKey: ObjectIdentifier(download)) else { return }
        try? FileManager.default.removeItem(at: entry.destination)
        status = "The download failed: \(error.localizedDescription)"
    }
}
