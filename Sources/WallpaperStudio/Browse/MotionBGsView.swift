import SwiftUI
import WebKit

private struct BrowserWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

/// motionbgs.com inside the app. Browse, press **HD** or **4K** on a wallpaper page, and the video is added to My Library.
struct MotionBGsView: View {
    @ObservedObject var library: LibraryModel
    @StateObject private var browser: MotionBGsBrowser

    init(library: LibraryModel) {
        self.library = library
        _browser = StateObject(wrappedValue: MotionBGsBrowser(library: library))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { browser.goBack() } label: { Image(systemName: "chevron.left") }.disabled(!browser.canGoBack).help("Back").accessibilityLabel("Back")
                Button { browser.goForward() } label: { Image(systemName: "chevron.right") }.disabled(!browser.canGoForward).help("Forward").accessibilityLabel("Forward")
                Button { browser.reload() } label: { Image(systemName: "arrow.clockwise") }.help("Reload").accessibilityLabel("Reload")
                Button("Home") { browser.loadStart() }
                Menu("Categories") {
                    ForEach(MotionBGsBrowser.categories, id: \.path) { c in Button(c.name) { browser.show(path: c.path) } }
                }
                .fixedSize()
                if browser.isLoading { ProgressView().controlSize(.small) }
                Spacer()
                Button("Open in Browser") { browser.openInBrowser() }
            }
            .padding(.horizontal, 24).padding(.vertical, 8)
            if let progress = browser.progress { ProgressView(value: progress).padding(.horizontal, 24) }
            if let status = browser.status { StatusBanner(text: status) { browser.status = nil } }
            BrowserWebView(webView: browser.webView)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 24)
            Text("Wallpapers on motionbgs.com belong to their creators and are offered for personal use. Open a wallpaper page and press HD or 4K Download; the video is added to your library. Other links open in your own browser.")
                .font(.caption).foregroundColor(.secondary).padding(.horizontal, 24).padding(.vertical, 8)
        }
        .animation(.fluid, value: browser.status)
        .onAppear { if browser.webView.url == nil { browser.loadStart() } }
        .onDisappear { browser.webView.stopLoading() }
    }
}
