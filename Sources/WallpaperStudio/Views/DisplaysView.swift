import SwiftUI
import AppKit
import StudioCore

struct DisplaysView: View {
    @ObservedObject var engine: AppDelegate
    @ObservedObject var library: LibraryModel
    @ObservedObject var layout: DisplayLayoutController
    @StateObject private var displays = DisplayManager()

    init(engine: AppDelegate, library: LibraryModel) {
        self.engine = engine
        self.library = library
        self.layout = engine.layout
    }

    private var mode: DisplayMode { layout.mode(for: displays.displays) }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader("Displays", "\(displays.displays.count) connected") {
                Picker("", selection: Binding(get: { mode }, set: { layout.setMode($0, for: displays.displays) })) {
                    ForEach(DisplayMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 420)
            }
            Text(mode.summary).font(.callout).foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.bottom, 8)
            ScrollView {
                VStack(spacing: 14) {
                    ForEach(displays.displays) { display in
                        DisplayCard(display: display, mode: mode, engine: engine, library: library, layout: layout)
                    }
                    remembered
                }
                .padding(24)
            }
        }
    }

    /// Displays that were connected before but are not now; their settings return automatically when they reconnect.
    @ViewBuilder private var remembered: some View {
        let connected = Set(displays.displays.map(\.uuid))
        let offline = layout.state.knownNames.filter { !connected.contains($0.key) }.sorted { $0.value < $1.value }
        if !offline.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Remembered displays").font(.headline)
                Text("Their settings come back automatically when they reconnect.").font(.caption).foregroundColor(.secondary)
                ForEach(offline, id: \.key) { uuid, name in
                    HStack {
                        Image(systemName: "display").foregroundColor(.secondary)
                        Text(name)
                        Spacer()
                        Button("Forget") { layout.forget(uuid: uuid) }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
                }
            }
            .padding(.top, 8)
        }
    }
}

private struct DisplayCard: View {
    let display: DisplayDescriptor
    let mode: DisplayMode
    @ObservedObject var engine: AppDelegate
    @ObservedObject var library: LibraryModel
    @ObservedObject var layout: DisplayLayoutController

    private var config: DisplayConfig? { layout.config(for: display.uuid) }
    private var defaults: DisplayConfig {
        DisplayConfig(scaling: engine.fill ? .fill : .fit, speed: engine.speed, volume: engine.volume, muted: engine.muted)
    }
    private func edit(_ change: @escaping (inout DisplayConfig) -> Void) { layout.update(display, defaults: defaults, change) }

    private var effectivePath: String? { config?.wallpaperPath ?? engine.current?.path }
    private var effectiveKind: WallpaperKind? {
        effectivePath.flatMap { WallpaperKind.detect(pathExtension: URL(fileURLWithPath: $0).pathExtension) }
    }
    /// Frame limits only mean something for content that moves.
    private var canLimitFrames: Bool { effectiveKind == .animatedImage || effectiveKind == .video || effectiveKind == .scene }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Image(systemName: "display").font(.system(size: 28)).frame(width: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(display.name + (display.isMain ? "  · main" : "")).font(.headline)
                    Text("\(Int(display.width)) × \(Int(display.height)) pt  ·  \(Int(display.scale))x  ·  up to \(display.maxFPS) Hz")
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Button("Identify") { DisplayIdentifier.flash(display) }
                    .help("Show a number on this display for two seconds")
            }
            if mode == .independent { controls } else {
                Text(mode == .span ? "Showing its part of the spanned wallpaper." : "Showing the main wallpaper.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.12)))
    }

    @ViewBuilder private var controls: some View {
        Divider()
        HStack {
            Text("Wallpaper").frame(width: 90, alignment: .leading)
            Menu(wallpaperTitle) {
                Button("Use main wallpaper") { edit { $0.wallpaperPath = nil } }
                Divider()
                ForEach(library.records.filter { !$0.isTrashed }.prefix(40)) { r in
                    Button(r.title) { if let url = library.fileURL(r) { edit { $0.wallpaperPath = url.path } } }
                }
                Divider()
                Button("Choose File…") { chooseFile() }
            }
            .frame(maxWidth: 260)
            Spacer()
            Toggle("Paused", isOn: Binding(get: { config?.paused ?? false }, set: { v in edit { $0.paused = v } }))
        }
        HStack {
            Text("Scaling").frame(width: 90, alignment: .leading)
            Picker("", selection: Binding(get: { config?.scaling ?? defaults.scaling }, set: { v in edit { $0.scaling = v } })) {
                ForEach(ScalingMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }.labelsHidden().frame(width: 170)
            Text("Rotation").padding(.leading, 12)
            Picker("", selection: Binding(get: { config?.rotation ?? .r0 }, set: { v in edit { $0.rotation = v } })) {
                ForEach(Rotation.allCases, id: \.self) { Text($0.label).tag($0) }
            }.labelsHidden().frame(width: 150)
        }
        HStack {
            Text("Playback").frame(width: 90, alignment: .leading)
            Picker("", selection: Binding(get: { config?.speed ?? defaults.speed }, set: { v in edit { $0.speed = v } })) {
                ForEach(AppDelegate.speeds, id: \.self) { Text($0 == 1 ? "Normal" : "\($0)x").tag($0) }
            }.labelsHidden().frame(width: 100)
            Button { edit { $0.muted.toggle() } } label: {
                Image(systemName: (config?.muted ?? defaults.muted) ? "speaker.slash.fill" : "speaker.wave.2.fill")
            }
            Slider(value: Binding(get: { Double(config?.volume ?? defaults.volume) }, set: { v in edit { $0.volume = Float(v) } }), in: 0...1)
                .frame(width: 100)
            Text("Frame limit").padding(.leading, 12)
            Picker("", selection: Binding(get: { config?.maxFPS ?? 0 }, set: { v in edit { $0.maxFPS = v == 0 ? nil : v } })) {
                Text("None").tag(0)
                ForEach([10, 15, 24, 30, 60], id: \.self) { Text("\($0) fps").tag($0) }
            }.labelsHidden().frame(width: 100).disabled(!canLimitFrames)
        }
        HStack {
            Text("Effects").frame(width: 90, alignment: .leading)
            Picker("", selection: Binding(get: { config?.effect ?? .none }, set: { v in edit { $0.effect = v } })) {
                ForEach(EffectPreset.allCases, id: \.self) { Text($0.label).tag($0) }
            }.labelsHidden().frame(width: 150).disabled(effectiveKind == .animatedImage || effectiveKind == .scene)
            Text("Resolution").padding(.leading, 12)
            Picker("", selection: Binding(get: { config?.resolutionScale ?? 1 }, set: { v in edit { $0.resolutionScale = v } })) {
                ForEach(RenderQuality.resolutionChoices, id: \.self) { Text("\(Int($0 * 100))%").tag($0) }
            }.labelsHidden().frame(width: 90)
        }
        Text("Effects, resolution and frame limits are drawn by the GPU renderer (not available for GIFs; GIF frame limits are applied to the animation itself).")
            .font(.caption).foregroundColor(.secondary)
    }

    private var wallpaperTitle: String {
        guard let path = config?.wallpaperPath else { return "Main wallpaper" }
        return library.records.first { library.fileURL($0)?.path == path }?.title ?? URL(fileURLWithPath: path).lastPathComponent
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose a wallpaper for \(display.name)"
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard MediaInspector.canDisplay(url) else {
            let alert = NSAlert()
            alert.messageText = "Can't display \(url.lastPathComponent)"
            alert.informativeText = "Supported: videos (.mp4 .mov .m4v), images and animated .gif."
            alert.runModal()
            return
        }
        edit { $0.wallpaperPath = url.path }
    }
}

/// Briefly shows the display's number so users can tell which physical screen a card belongs to.
enum DisplayIdentifier {
    static func flash(_ display: DisplayDescriptor) {
        guard let screen = NSScreen.screens.first(where: { $0.displayID == display.id }) else { return }
        let size: CGFloat = 220
        let frame = CGRect(x: screen.frame.midX - size / 2, y: screen.frame.midY - size / 2, width: size, height: size)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .statusBar
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        let index = (NSScreen.screens.firstIndex(where: { $0.displayID == display.id }) ?? 0) + 1
        let label = NSTextField(labelWithString: "\(index)")
        label.font = .systemFont(ofSize: 120, weight: .bold)
        label.textColor = .white
        label.alignment = .center
        label.frame = CGRect(x: 0, y: (size - 140) / 2, width: size, height: 140)
        let box = NSView(frame: CGRect(origin: .zero, size: CGSize(width: size, height: size)))
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.7).cgColor
        box.layer?.cornerRadius = 28
        box.addSubview(label)
        window.contentView = box
        window.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { window.orderOut(nil) }
    }
}
