import SwiftUI
import AppKit
import StudioCore

// Note: the Command Line Tools toolchain has no SwiftUI macro plugin, so views use
// ObservableObject/@StateObject instead of @State.

final class NavState: ObservableObject {
    @Published var section: SidebarSection? = .discover
    init() {}
}

final class ThumbLoader: ObservableObject {
    @Published var image: NSImage?
    @MainActor func load(_ record: WallpaperRecord, from library: LibraryModel) {
        Task { self.image = await library.thumbnail(for: record) }
    }
}

/// 16:9 rounded preview frame.
struct Thumb<Content: View>: View {
    let content: Content
    init(@ViewBuilder _ content: () -> Content) { self.content = content() }
    var body: some View {
        Color.secondary.opacity(0.15)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .overlay(content)
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct PageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    let trailing: Trailing
    init(_ title: String, _ subtitle: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title; self.subtitle = subtitle; self.trailing = trailing()
    }
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.largeTitle.weight(.semibold))
                Text(subtitle).foregroundColor(.secondary)
            }
            Spacer()
            trailing
        }
        .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 8)
    }
}

let gridColumns = [GridItem(.adaptive(minimum: 230), spacing: 18)]

// MARK: - Now playing bar

struct ControlsBar: View {
    @ObservedObject var engine: AppDelegate

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Now playing").font(.caption).foregroundColor(.secondary)
                Text(nowPlaying).font(.callout).lineLimit(1)
            }
            Spacer()
            Button { engine.togglePause() } label: {
                Image(systemName: engine.userPaused ? "play.fill" : "pause.fill")
            }
            .help(engine.userPaused ? "Resume" : "Pause").accessibilityLabel(engine.userPaused ? "Resume" : "Pause")
            if engine.playlist.count > 1 {
                Button { engine.nextVideo() } label: { Image(systemName: "forward.fill") }.help("Next video").accessibilityLabel("Next video")
            }
            Button { engine.toggleMute() } label: {
                Image(systemName: engine.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            }
            .help(engine.muted ? "Unmute" : "Mute").accessibilityLabel(engine.muted ? "Unmute" : "Mute")
            Slider(value: Binding(get: { Double(engine.volume) }, set: { engine.setVolume(Float($0)) }), in: 0...1)
                .frame(width: 90)
            Menu {
                ForEach(AppDelegate.speeds, id: \.self) { s in
                    Button(s == 1 ? "Normal" : "\(s)x") { engine.setSpeed(s) }
                }
            } label: { Text(engine.speed == 1 ? "1x" : "\(engine.speed)x") }
                .frame(width: 60)
            Toggle("Fill", isOn: Binding(get: { engine.fill }, set: { _ in engine.toggleFill() }))
                .help("Fill the screen (crop) instead of fitting the whole video")
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
        .background(.bar)
    }

    private var nowPlaying: String {
        guard let url = engine.current else { return "Nothing — pick a wallpaper in Discover or My Library" }
        return engine.playlist.count > 1 ? "\(url.lastPathComponent)  (\(engine.index + 1)/\(engine.playlist.count))" : url.lastPathComponent
    }
}

extension AppDelegate {
    func setVolume(_ v: Float) { volume = v; pushSettings() }
    func setSpeed(_ v: Float) { speed = v; pushSettings() }
    func setInterval(_ seconds: Int) { interval = seconds; scheduleRotation() }
    func play(at i: Int) {
        guard playlist.indices.contains(i) else { return }
        index = i
        startCurrent()
        scheduleRotation()
    }
}
