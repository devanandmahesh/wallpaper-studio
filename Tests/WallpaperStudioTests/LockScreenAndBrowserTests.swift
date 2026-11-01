import Testing
import AppKit
import Network
import WebKit
import StudioCore
@testable import WallpaperStudio

// MARK: - Lock screen

final class FakeDesktopStore: DesktopImageStore {
    var images: [UInt32: URL] = [:]
    var failing = false
    private(set) var sets: [(URL, UInt32)] = []
    func currentImage(forScreen id: UInt32) -> URL? { images[id] }
    func setImage(_ url: URL, forScreen id: UInt32) throws {
        if failing { throw NSError(domain: "fake", code: 1, userInfo: [NSLocalizedDescriptionKey: "no permission"]) }
        images[id] = url
        sets.append((url, id))
    }
}

private func solidImage(_ w: Int = 64, _ h: Int = 36) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
    ctx.setFillColor(NSColor.systemPurple.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage()!
}

@MainActor
@Suite struct LockScreenSyncTests {
    func make(store: FakeDesktopStore, screens: [UInt32] = [1], image: CGImage? = solidImage(), debounce: TimeInterval = 0.05) -> (LockScreenSync, URL, UserDefaults) {
        let name = "lock-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        return (LockScreenSync(directory: dir, store: store, defaults: defaults, debounce: debounce, screens: { screens }, snapshot: { image }), dir, defaults)
    }

    func spin(_ s: Double) async {
        let end = Date().addingTimeInterval(s)
        while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)); try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    @Test func offByDefaultAndDoesNothingUntilEnabled() async {
        let store = FakeDesktopStore()
        let (sync, _, _) = make(store: store)
        #expect(!sync.isEnabled)
        sync.wallpaperChanged(); sync.screenLocked()
        await spin(0.2)
        #expect(store.sets.isEmpty && sync.sync() == nil)
    }

    @Test func enablingRemembersTheOriginalPictureAndSetsAStill() throws {
        let store = FakeDesktopStore()
        let original = URL(fileURLWithPath: "/System/Library/Desktop Pictures/original.heic")
        store.images[1] = original
        let (sync, dir, defaults) = make(store: store)
        sync.setEnabled(true)
        let applied = try #require(store.images[1])
        #expect(applied != original && applied.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL && applied.pathExtension == "jpg")
        let stillSize = try Data(contentsOf: applied).count
        #expect(FileManager.default.fileExists(atPath: applied.path) && stillSize > 100)
        #expect(sync.lastSync != nil && sync.lastError == nil)
        #expect((defaults.dictionary(forKey: LockScreenSync.originalsKey) as? [String: String])?["1"] == original.path)
    }

    @Test func disablingPutsThePreviousPictureBackAndCleansUp() throws {
        let store = FakeDesktopStore()
        let original = FileManager.default.temporaryDirectory.appendingPathComponent("orig-\(UUID().uuidString).jpg")
        try Data([1, 2, 3]).write(to: original)
        store.images[1] = original; store.images[2] = original
        let (sync, dir, _) = make(store: store, screens: [1, 2])
        sync.setEnabled(true)
        #expect(store.images[1] != original && store.images[2] != original)
        sync.setEnabled(false)
        #expect(store.images[1] == original && store.images[2] == original)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
        #expect(!sync.isEnabled)
    }

    @Test func enablingTwiceNeverTreatsItsOwnStillAsTheOriginal() throws {
        let store = FakeDesktopStore()
        let original = FileManager.default.temporaryDirectory.appendingPathComponent("o2-\(UUID().uuidString).jpg")
        try Data([9]).write(to: original)
        store.images[1] = original
        let (sync, _, defaults) = make(store: store)
        sync.setEnabled(true); sync.setEnabled(false); sync.setEnabled(true)
        sync.setEnabled(true)                                                     // already on: no-op
        #expect((defaults.dictionary(forKey: LockScreenSync.originalsKey) as? [String: String])?["1"] == original.path)
        sync.setEnabled(false)
        #expect(store.images[1] == original)
    }

    @Test func aWallpaperChangeSyncsOnceAfterTheDebounce() async {
        let store = FakeDesktopStore()
        let (sync, _, _) = make(store: store, debounce: 0.1)
        sync.setEnabled(true)
        let initial = store.sets.count
        for _ in 0..<5 { sync.wallpaperChanged() }                                // a burst of changes
        await spin(0.05)
        #expect(store.sets.count == initial)                                      // still waiting
        await spin(0.3)
        #expect(store.sets.count == initial + 1)
    }

    @Test func lockingTheScreenSyncsImmediately() {
        let store = FakeDesktopStore()
        let (sync, _, _) = make(store: store)
        sync.setEnabled(true)
        let before = store.sets.count
        sync.screenLocked()
        #expect(store.sets.count == before + 1)
    }

    @Test func everyDisplayGetsTheStillAndOldFilesArePruned() async throws {
        let store = FakeDesktopStore()
        let (sync, dir, _) = make(store: store, screens: [1, 2, 3])
        sync.setEnabled(true)
        for _ in 0..<5 { sync.screenLocked(); try await Task.sleep(nanoseconds: 3_000_000) }
        #expect(Set(store.sets.map(\.1)) == [1, 2, 3])
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".jpg") }
        #expect(files.count <= LockScreenSync.keepFiles && files.contains(store.images[1]!.lastPathComponent))
    }

    @Test func missingSnapshotsAndFailingStoresReportInsteadOfCrashing() {
        let store = FakeDesktopStore()
        let (empty, _, _) = make(store: store, image: nil)
        empty.setEnabled(true)
        #expect(empty.lastError != nil && store.sets.isEmpty)
        let failing = FakeDesktopStore(); failing.failing = true
        let (broken, _, _) = make(store: failing)
        broken.setEnabled(true)
        #expect(broken.lastError == "no permission" && broken.lastSync == nil)
    }

    @Test func theSettingSurvivesARestart() {
        let store = FakeDesktopStore()
        let (sync, dir, defaults) = make(store: store)
        sync.setEnabled(true)
        let again = LockScreenSync(directory: dir, store: store, defaults: defaults, screens: { [1] }, snapshot: { solidImage() })
        #expect(again.isEnabled)
    }
}

// MARK: - Browser policy

@Suite struct BrowserPolicyTests {
    let hosts: Set<String> = ["motionbgs.com"]
    func decide(_ s: String, insecure: Set<String> = []) -> BrowserDecision { BrowserPolicy.decide(URL(string: s), allowedHosts: hosts, insecureHosts: insecure) }

    @Test func onlyTheSiteItselfIsShownInsideTheApp() {
        #expect(decide("https://motionbgs.com/a-galaxy-within") == .allow)
        #expect(decide("https://www.motionbgs.com/tag:anime/") == .allow && decide("https://cdn.motionbgs.com/x.mp4") == .allow)
        #expect(decide("https://motionbgs.com.evil.example/") == .external)               // look-alike hosts do not match
        #expect(decide("https://evilmotionbgs.com/") == .external)
        #expect(decide("https://example.com/") == .external)
    }

    @Test func plainHTTPAndOddSchemesAreNeverBrowsed() {
        #expect(decide("http://motionbgs.com/") == .block)
        #expect(decide("http://example.com/") == .external)
        #expect(decide("file:///etc/passwd") == .block && decide("javascript:alert(1)") == .block && decide("data:text/html,hi") == .block)
        #expect(decide("ftp://motionbgs.com/") == .block && decide("wallpaperstudio://delete") == .block)
        #expect(decide("about:blank") == .allow && decide("about:config") == .block)
        #expect(BrowserPolicy.decide(nil, allowedHosts: hosts) == .block)
        #expect(decide("http://127.0.0.1:80/", insecure: ["127.0.0.1"]) == .external)       // not an allowed host
    }

    @Test func downloadsMustBeVideos() {
        let url = URL(string: "https://motionbgs.com/dl/hd/1/")!
        func response(mime: String?, disposition: String? = nil) -> URLResponse {
            HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [
                "Content-Type": mime ?? "text/html", "Content-Disposition": disposition ?? ""].filter { !$0.value.isEmpty })!
        }
        #expect(BrowserPolicy.isDownload(response(mime: "video/mp4")))
        #expect(BrowserPolicy.isDownload(response(mime: "application/octet-stream", disposition: "attachment; filename=\"x.mp4\"")))
        #expect(!BrowserPolicy.isDownload(response(mime: "text/html")))
        #expect(BrowserPolicy.downloadExtensions == ["mp4", "mov", "m4v"])
    }

    @Test func titlesAndTagsComeFromAddresses() {
        #expect(BrowserPolicy.title(fromSlug: "a-galaxy-within") == "A Galaxy Within")
        #expect(BrowserPolicy.title(fromSlug: "star-guardian-janna") == "Star Guardian Janna")
        #expect(BrowserPolicy.title(fromSlug: "---") == nil && BrowserPolicy.title(fromSlug: "") == nil)
        #expect(BrowserPolicy.resolutionTag(from: URL(string: "https://motionbgs.com/dl/4k/10270")) == "4k")
        #expect(BrowserPolicy.resolutionTag(from: URL(string: "https://motionbgs.com/dl/hd/10270/")) == "hd")
        #expect(BrowserPolicy.resolutionTag(from: URL(string: "https://motionbgs.com/dl/zip/1")) == nil && BrowserPolicy.resolutionTag(from: nil) == nil)
        #expect(MotionBGsBrowser.categories.count >= 14 && MotionBGsBrowser.categories.allSatisfy { !$0.path.contains(" ") && !$0.path.hasPrefix("/") })
    }
}

// MARK: - Browser downloads against a local web server

/// A minimal HTTP server standing in for the website.
final class MiniWebServer {
    struct Reply { var status = 200; var headers: [String: String] = [:]; var body = Data() }
    private let listener: NWListener
    private(set) var port: UInt16 = 0
    private(set) var requests: [String] = []
    var routes: [String: Reply] = [:]
    /// Answers for any path that starts with the key (for addresses that carry a query string).
    var prefixRoutes: [String: Reply] = [:]
    private(set) var rawRequests: [String] = []
    private let lock = NSLock()

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [weak self] c in self?.handle(c) }
        listener.start(queue: .global())
        _ = ready.wait(timeout: .now() + 3)
        port = listener.port?.rawValue ?? 0
    }
    deinit { listener.cancel() }

    var requestedPaths: [String] { lock.lock(); defer { lock.unlock() }; return requests }
    var rawRequestTexts: [String] { lock.lock(); defer { lock.unlock() }; return rawRequests }

    private func handle(_ c: NWConnection) {
        c.start(queue: .global())
        c.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self, let data, let text = String(data: data, encoding: .utf8), let line = text.split(separator: "\r\n").first else { c.cancel(); return }
            let path = String(line.split(separator: " ").dropFirst().first ?? "/")
            self.lock.lock(); self.requests.append(path); self.rawRequests.append(text)
            let reply = self.routes[path] ?? self.prefixRoutes.first(where: { path.hasPrefix($0.key) })?.value ?? Reply(status: 404, body: Data("missing".utf8)); self.lock.unlock()
            var head = "HTTP/1.1 \(reply.status) OK\r\nConnection: close\r\n"
            for (k, v) in reply.headers { head += "\(k): \(v)\r\n" }
            if reply.headers["Content-Length"] == nil { head += "Content-Length: \(reply.body.count)\r\n" }
            c.send(content: Data(head.utf8) + Data("\r\n".utf8) + reply.body, completion: .contentProcessed { _ in c.cancel() })
        }
    }
}

@MainActor
@Suite struct MotionBGsBrowserTests {
    func spin(_ s: Double) async {
        let end = Date().addingTimeInterval(s)
        while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)); try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    func library() -> LibraryModel {
        let name = "bgs-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return LibraryModel(storage: LibraryStorage(root: FileManager.default.temporaryDirectory.appendingPathComponent("\(name)/LiveWallpaper/Library")), defaults: defaults)
    }

    func eval(_ web: WKWebView, _ js: String) async {
        await withCheckedContinuation { c in web.evaluateJavaScript(js) { _, _ in c.resume() } }
    }

    func waitUntil(_ seconds: Double = 15, _ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while !condition() && Date() < end { await spin(0.1) }
    }

    func setUp() throws -> (MiniWebServer, MotionBGsBrowser, LibraryModel, NSWindow) {
        _ = NSApplication.shared
        let server = try MiniWebServer()
        let video = try Data(contentsOf: Fixtures.mp4())
        let page = "<html><head><title>x</title></head><body><a id='hd' href='/dl/hd/1/'>HD</a><a id='bad' href='/dl/hd/2/'>BAD</a><a id='big' href='/dl/hd/3/'>BIG</a><a id='local' href='file:///etc/hosts'>F</a></body></html>"
        server.routes["/a-galaxy-within"] = .init(headers: ["Content-Type": "text/html"], body: Data(page.utf8))
        server.routes["/dl/hd/1/"] = .init(headers: ["Content-Type": "video/mp4", "Content-Disposition": "attachment; filename=\"a-galaxy-within-hd.mp4\""], body: video)
        server.routes["/dl/hd/2/"] = .init(headers: ["Content-Type": "application/octet-stream", "Content-Disposition": "attachment; filename=\"evil.exe\""], body: Data("MZ".utf8))
        server.routes["/dl/hd/3/"] = .init(headers: ["Content-Type": "video/mp4", "Content-Length": "2000000000", "Content-Disposition": "attachment; filename=\"huge.mp4\""], body: Data())
        let lib = library()
        let browser = MotionBGsBrowser(library: lib, allowedHosts: ["127.0.0.1"], insecureHosts: ["127.0.0.1"],
                                       start: URL(string: "http://127.0.0.1:\(server.port)/a-galaxy-within")!)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = browser.webView
        browser.loadStart()
        return (server, browser, lib, window)
    }

    @Test func pressingDownloadAddsTheVideoToTheLibraryWithAGoodTitle() async throws {
        let (server, browser, lib, window) = try setUp()
        await waitUntil { !browser.webView.isLoading && browser.webView.url != nil && server.requestedPaths.contains("/a-galaxy-within") }
        await spin(0.5)
        await eval(browser.webView, "document.getElementById('hd').click()")
        await waitUntil { lib.records.count == 1 && browser.status?.contains("Added") == true }
        let r = try #require(lib.records.first, "the download was not imported; status: \(browser.status ?? "nil")")
        #expect(r.title == "A Galaxy Within" && r.category == "MotionBGs" && r.kind == .video)
        #expect(r.tags.contains("motionbgs") && r.tags.contains("hd"))
        #expect(r.width == 320 && r.height == 180)
        #expect(await lib.thumbnail(for: r) != nil)
        #expect(browser.status?.contains("Added") == true && browser.progress == nil)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: lib.storage.downloadsDir.path)) ?? []
        #expect(leftovers.isEmpty, "temporary download left behind: \(leftovers)")
        browser.stop(); window.close()
    }

    @Test func nonVideoDownloadsAreIgnored() async throws {
        let (server, browser, lib, window) = try setUp()
        await waitUntil { server.requestedPaths.contains("/a-galaxy-within") }
        await spin(0.8)
        await eval(browser.webView, "document.getElementById('bad').click()")
        await waitUntil(8) { browser.status?.contains("not a video") == true }
        #expect(browser.status?.contains("not a video") == true && lib.records.isEmpty)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: lib.storage.downloadsDir.path)) ?? []
        #expect(leftovers.isEmpty)
        browser.stop(); window.close()
    }

    @Test func enormousDownloadsAreRefusedBeforeTheyStart() async throws {
        let (server, browser, lib, window) = try setUp()
        await waitUntil { server.requestedPaths.contains("/a-galaxy-within") }
        await spin(0.8)
        await eval(browser.webView, "document.getElementById('big').click()")
        await waitUntil(8) { browser.status?.contains("larger than") == true }
        #expect(browser.status?.contains("1.5 GB") == true && lib.records.isEmpty)
        browser.stop(); window.close()
    }

    @Test func newWindowLinksOnTheSiteStayInThisViewAndOthersAreDropped() async throws {
        let (server, browser, _, window) = try setUp()
        server.routes["/a-galaxy-within"] = .init(headers: ["Content-Type": "text/html"], body: Data("""
            <html><body><a id='same' target='_blank' href='/tag:anime/'>same site</a><a id='odd' target='_blank' href='ftp://127.0.0.1/x'>odd</a></body></html>
            """.utf8))
        server.routes["/tag:anime/"] = .init(headers: ["Content-Type": "text/html"], body: Data("<html>anime</html>".utf8))
        await waitUntil { server.requestedPaths.contains("/a-galaxy-within") }
        await spin(0.8)
        let before = browser.blockedNavigations
        await eval(browser.webView, "document.getElementById('odd').click()")
        await waitUntil(5) { browser.blockedNavigations > before }
        #expect(browser.blockedNavigations > before)
        await eval(browser.webView, "document.getElementById('same').click()")
        await waitUntil(8) { server.requestedPaths.contains("/tag:anime/") }
        #expect(server.requestedPaths.contains("/tag:anime/"))                              // opened in this same view, no new window
        browser.stop(); window.close()
    }

    @Test func theCategoryMenuBuildsSiteAddresses() async throws {
        let (server, browser, _, window) = try setUp()
        await waitUntil { server.requestedPaths.contains("/a-galaxy-within") }
        server.routes["/tag:anime/"] = .init(headers: ["Content-Type": "text/html"], body: Data("<html>anime</html>".utf8))
        browser.show(path: "tag:anime")
        await waitUntil { server.requestedPaths.contains("/tag:anime/") }
        #expect(server.requestedPaths.contains("/tag:anime/"))
        browser.stop(); window.close()
    }

    /// Opt-in: `WS_LIVE_TESTS=1 ./test.sh --filter liveSite` loads one real wallpaper page (no file is downloaded).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WS_LIVE_TESTS"] != nil)) func liveSiteWallpaperPageShowsDownloadLinks() async throws {
        _ = NSApplication.shared
        let lib = library()
        let browser = MotionBGsBrowser(library: lib, start: URL(string: "https://motionbgs.com/a-galaxy-within")!)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = browser.webView
        browser.loadStart()
        var links: [String] = []
        await waitUntil(25) {
            return !browser.webView.isLoading && browser.webView.url != nil
        }
        await spin(2)
        links = await withCheckedContinuation { c in
            browser.webView.evaluateJavaScript("Array.from(document.querySelectorAll('a[href*=\"/dl/\"]')).map(a => a.getAttribute('href'))") { v, _ in c.resume(returning: (v as? [String]) ?? []) }
        }
        print("LIVE links:", links, "blocked:", browser.blockedNavigations)
        #expect(links.contains { $0.contains("/dl/hd/") } && links.contains { $0.contains("/dl/4k/") })
        browser.stop(); window.close()
    }
}

// MARK: - Pexels / Pixabay grid

@MainActor
@Suite struct StockModelTests {
    func spin(_ s: Double) async {
        let end = Date().addingTimeInterval(s)
        while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)); try? await Task.sleep(nanoseconds: 5_000_000) }
    }
    func waitUntil(_ seconds: Double = 15, _ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while !condition() && Date() < end { await spin(0.05) }
    }

    func make(server: MiniWebServer, key: String? = "KEY") -> (StockModel, LibraryModel, UserDefaults) {
        let name = "stock-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        if let key { defaults.set(key, forKey: StockProvider.pexels.defaultsKey); defaults.set(key, forKey: StockProvider.pixabay.defaultsKey) }
        let lib = LibraryModel(storage: LibraryStorage(root: FileManager.default.temporaryDirectory.appendingPathComponent("\(name)/LiveWallpaper/Library")), defaults: defaults)
        let base = URL(string: "http://127.0.0.1:\(server.port)")!
        let model = StockModel(library: lib, defaults: defaults, session: URLSession(configuration: .ephemeral), bases: [.pexels: base, .pixabay: base])
        return (model, lib, defaults)
    }

    func pexelsBody(_ port: UInt16, ids: [Int], total: Int = 2) -> Data {
        let items = ids.map { id in
            "{\"id\":\(id),\"url\":\"https://www.pexels.com/video/calm-sea-\(id)/\",\"duration\":5,\"user\":{\"name\":\"Ada\"},\"video_files\":[{\"link\":\"https://127.0.0.1:\(port)/never.mp4\",\"width\":1920,\"height\":1080,\"file_type\":\"video/mp4\"}]}"
        }.joined(separator: ",")
        return Data("{\"page\":1,\"per_page\":24,\"total_results\":\(total),\"videos\":[\(items)]}".utf8)
    }

    @Test func searchSendsTheKeyInTheHeaderAndShowsTheClips() async throws {
        let server = try MiniWebServer()
        server.prefixRoutes["/videos/search"] = .init(headers: ["Content-Type": "application/json"], body: pexelsBody(server.port, ids: [11, 22]))
        let (model, _, _) = make(server: server)
        model.provider = .pexels
        model.text = "sea"
        model.search()
        await waitUntil { !model.clips.isEmpty }
        #expect(model.clips.map(\.providerID) == [11, 22])
        #expect(model.clips[0].title == "Calm sea")
        let raw = try #require(server.rawRequestTexts.first(where: { $0.contains("/videos/search") }))
        #expect(raw.contains("query=sea"))
        #expect(raw.lowercased().contains("authorization: key"))
        #expect(!(raw.split(separator: "\r\n").first ?? "").contains("KEY"))   // the key is not in the address
    }

    @Test func withoutAKeyNothingIsRequested() async throws {
        let server = try MiniWebServer()
        let (model, _, _) = make(server: server, key: nil)
        model.search()
        await spin(0.3)
        #expect(!model.hasKey && model.clips.isEmpty && server.requestedPaths.isEmpty)
    }

    @Test func aRejectedKeyAndRateLimitingAreExplained() async throws {
        let server = try MiniWebServer()
        server.prefixRoutes["/videos/popular"] = .init(status: 401, body: Data("no".utf8))
        let (model, _, _) = make(server: server)
        model.provider = .pexels
        model.search()
        await waitUntil { model.message != nil }
        #expect(model.message?.contains("rejected the API key") == true && model.clips.isEmpty && !model.isLoading)

        server.prefixRoutes["/videos/popular"] = .init(status: 429, body: Data("slow".utf8))
        model.search()
        await waitUntil { model.message?.contains("limiting") == true }
        #expect(model.message?.contains("limiting") == true)
    }

    @Test func noResultsSaysSo() async throws {
        let server = try MiniWebServer()
        server.prefixRoutes["/videos/popular"] = .init(headers: ["Content-Type": "application/json"], body: pexelsBody(server.port, ids: [], total: 0))
        let (model, _, _) = make(server: server)
        model.provider = .pexels
        model.search()
        await waitUntil { model.message != nil }
        #expect(model.message?.contains("No results") == true && !model.hasMore)
    }

    @Test func loadMoreAppendsTheNextPageWithoutDuplicates() async throws {
        let server = try MiniWebServer()
        server.routes["/videos/popular?per_page=24&page=1&orientation=landscape"] = .init(headers: ["Content-Type": "application/json"], body: pexelsBody(server.port, ids: [1, 2], total: 100))
        server.routes["/videos/popular?per_page=24&page=2&orientation=landscape"] = .init(headers: ["Content-Type": "application/json"], body: pexelsBody(server.port, ids: [2, 3], total: 100))
        let (model, _, _) = make(server: server)
        model.provider = .pexels
        model.search()
        await waitUntil { model.clips.count == 2 }
        #expect(model.hasMore)
        model.loadMore()
        await waitUntil { model.clips.count == 3 }
        #expect(model.clips.map(\.providerID) == [1, 2, 3])
    }

    @Test func aSlowOldSearchCannotOverwriteANewerOne() async throws {
        let server = try MiniWebServer()
        server.prefixRoutes["/videos/search?query=first"] = .init(headers: ["Content-Type": "application/json"], body: pexelsBody(server.port, ids: [1]))
        server.prefixRoutes["/videos/search?query=second"] = .init(headers: ["Content-Type": "application/json"], body: pexelsBody(server.port, ids: [2]))
        let (model, _, _) = make(server: server)
        model.provider = .pexels
        model.text = "first"; model.search()
        model.text = "second"; model.search()
        await waitUntil { !model.clips.isEmpty }
        await spin(0.3)
        #expect(model.clips.map(\.providerID) == [2])
    }

    @Test func addingDownloadsTheBestFileIntoTheLibraryAndMarksItAdded() async throws {
        let server = try MiniWebServer()
        let video = try Data(contentsOf: Fixtures.mp4())
        server.routes["/files/best.mp4"] = .init(headers: ["Content-Type": "video/mp4"], body: video)
        let (model, lib, _) = make(server: server)
        let clip = StockClip(provider: .pixabay, providerID: 77, title: "Calm sea", author: "Ada", pageURL: nil, thumbURL: nil, duration: 5,
                             files: [StockFile(url: URL(string: "http://127.0.0.1:\(server.port)/files/best.mp4")!, width: 320, height: 180)])
        #expect(!model.isAdded(clip))
        model.add(clip)
        await waitUntil { model.isAdded(clip) && model.adding.isEmpty }
        let record = try #require(model.record(for: clip))
        #expect(record.title == "Calm sea" && record.category == "Pixabay" && record.kind == .video)
        #expect(record.tags.contains("stock:pixabay-77") && record.tags.contains("pixabay"))
        #expect(lib.records.count == 1 && model.adding.isEmpty)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: lib.storage.downloadsDir.path)) ?? []
        #expect(leftovers.isEmpty, "temporary download left behind: \(leftovers)")

        model.add(clip)                        // already added: no second download
        await spin(0.3)
        #expect(server.requestedPaths.filter { $0 == "/files/best.mp4" }.count == 1)
    }

    @Test func aFailedDownloadIsReportedAndLeavesNothingBehind() async throws {
        let server = try MiniWebServer()                       // /missing.mp4 is a 404
        let (model, lib, _) = make(server: server)
        let clip = StockClip(provider: .pexels, providerID: 5, title: "Gone", author: "x", pageURL: nil, thumbURL: nil, duration: 1,
                             files: [StockFile(url: URL(string: "http://127.0.0.1:\(server.port)/missing.mp4")!, width: 1920, height: 1080)])
        model.add(clip)
        await waitUntil { model.message?.contains("Could not add") == true }
        #expect(model.message?.contains("Could not add “Gone”") == true && !model.isAdded(clip) && lib.records.isEmpty && model.adding.isEmpty)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: lib.storage.downloadsDir.path)) ?? []
        #expect(leftovers.isEmpty)
    }

    @Test func keysAreSavedTrimmedAndRemovable() throws {
        let server = try MiniWebServer()
        let (model, _, defaults) = make(server: server, key: nil)
        model.setKey("  abc  \n", for: .pexels)
        #expect(model.key(for: .pexels) == "abc" && defaults.string(forKey: StockProvider.pexels.defaultsKey) == "abc")
        model.provider = .pexels
        #expect(model.hasKey)
        model.setKey("", for: .pexels)
        #expect(!model.hasKey && defaults.string(forKey: StockProvider.pexels.defaultsKey) == nil)
    }
}
