import SwiftUI
import AppKit
import StudioCore

/// Holds whichever project is open; switching projects swaps this object.
final class EditorHolder: ObservableObject {
    @Published var project: EditorProject
    private let root: URL

    init(root: URL = EditorProject.defaultRoot) {
        self.root = root
        if let recent = EditorProject.list(in: root).first, let opened = try? EditorProject.open(directory: recent.directory) {
            project = opened
        } else {
            project = (try? EditorProject.create(in: root, from: .blank())) ?? EditorProject(directory: root, document: .blank())
        }
    }

    func open(_ project: EditorProject) { try? self.project.saveNow(); self.project = project }
    func newProject(from document: EditorDocument) {
        if let p = try? EditorProject.create(in: root, from: document) { open(p) }
    }
    func openExisting(_ info: EditorProject.Info) { if let p = try? EditorProject.open(directory: info.directory) { open(p) } }
    func projects() -> [EditorProject.Info] { EditorProject.list(in: root) }
}

struct EditorView: View {
    @StateObject private var holder = EditorHolder()
    @ObservedObject var library: LibraryModel

    var body: some View {
        EditorWorkspace(project: holder.project, holder: holder, library: library)
            .id(holder.project.directory)
    }
}

struct EditorWorkspace: View {
    @ObservedObject var project: EditorProject
    @ObservedObject var holder: EditorHolder
    @ObservedObject var library: LibraryModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                layersPanel.frame(width: 210)
                Divider()
                VStack(spacing: 0) {
                    EditorPreview(project: project)
                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
                        .overlay(zoneOverlay)
                        .background(Color.black)
                        .frame(maxWidth: .infinity)
                    Divider()
                    EditorTimeline(project: project).frame(minHeight: 150, maxHeight: 220)
                }
                Divider()
                EditorInspector(project: project).frame(width: 340)
            }
            if let message = project.message {
                HStack {
                    Text(message).font(.callout)
                    Spacer()
                    Button { project.message = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }
                .padding(8).background(Color.accentColor.opacity(0.15))
            }
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Menu {
                Button("New Blank Wallpaper") { holder.newProject(from: .blank()) }
                Menu("New from Template") {
                    ForEach(BuiltInScenes.all, id: \.name) { scene in Button(scene.name) { holder.newProject(from: EditorDocument(scene: scene)) } }
                }
                let projects = holder.projects()
                if !projects.isEmpty {
                    Divider()
                    ForEach(projects) { info in Button(info.name) { holder.openExisting(info) } }
                }
            } label: { Label(project.scene.name, systemImage: "folder") }
            .menuStyle(.borderlessButton).fixedSize()

            Button { project.undo() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(!project.canUndo).keyboardShortcut("z", modifiers: .command).help("Undo").accessibilityLabel("Undo")
            Button { project.redo() } label: { Image(systemName: "arrow.uturn.forward") }.disabled(!project.canRedo).keyboardShortcut("z", modifiers: [.command, .shift]).help("Redo").accessibilityLabel("Redo")
            Toggle("Simulate audio", isOn: $project.simulateAudio).toggleStyle(.checkbox).help("Preview audio-reactive layers with a built-in test signal")
            Spacer()
            Button("Export Package…") { exportPackage() }
            Button("Add to Library") { Task { await addToLibrary(play: false) } }
            Button("Set as Wallpaper") { Task { await addToLibrary(play: true) } }.glassButton(prominent: true)
        }
        .padding(8)
    }

    // MARK: Layers

    private var layersPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Layers").font(.headline)
                Spacer()
                Menu {
                    Button("Solid Colour") { project.addLayer(.solid(RGBA(0.2, 0.3, 0.8)), name: "Colour") }
                    Button("Gradient") { project.addLayer(.gradient(top: RGBA(0.1, 0.1, 0.4), bottom: RGBA(0.02, 0.02, 0.1)), name: "Gradient") }
                    Button("Image or Video…") { chooseMedia() }
                    Menu("Pattern") { ForEach(ProceduralKind.allCases, id: \.self) { k in
                        Button(k.rawValue.capitalized) { project.addLayer(.procedural(k, RGBA(0.1, 0.1, 0.5), RGBA(0.9, 0.3, 0.6)), name: k.rawValue.capitalized) } } }
                    Menu("Particles") { ForEach(ParticlePreset.allCases, id: \.self) { p in
                        Button(p.label) { project.addLayer(.particles(p.spec), name: p.label, blend: .add) } } }
                    Menu("Audio Visualiser") { ForEach(VisualizerStyle.allCases, id: \.self) { s in
                        Button(s.label) { var v = VisualizerSpec(); v.style = s; project.addLayer(.visualizer(v), name: s.label, blend: .add) } } }
                    Button("Light") {
                        var e = LayerEffects(); e.lightIntensity = 0.8; e.lightRadius = 0.4
                        project.addLayer(.solid(RGBA(0, 0, 0, 0)), name: "Light", blend: .add)
                        project.update { $0.effects = e }
                    }
                } label: { Image(systemName: "plus") }
                .menuStyle(.borderlessButton).fixedSize()
                Button { project.duplicateSelected() } label: { Image(systemName: "plus.square.on.square") }.buttonStyle(.plain).help("Duplicate").accessibilityLabel("Duplicate").disabled(project.selection == nil)
                Button { project.removeSelected() } label: { Image(systemName: "trash") }.buttonStyle(.plain).help("Delete").accessibilityLabel("Delete").disabled(project.selection == nil)
            }
            .padding(8)
            Divider()
            let layers = Array(project.scene.layers.reversed())
            List(selection: Binding(get: { project.selection }, set: { project.selection = $0 })) {
                ForEach(layers) { layer in
                    Label(layer.name, systemImage: icon(layer)).tag(Optional(layer.id))
                }
                .onMove { from, to in
                    guard let i = from.first else { return }
                    let dest = to > i ? to - 1 : to
                    project.moveLayer(layers[i].id, to: layers.count - 1 - dest)
                }
            }
        }
    }

    private func icon(_ layer: SceneLayer) -> String {
        switch layer.content.kind {
        case .color: "square.fill"
        case .gradient: "square.tophalf.filled"
        case .image: "photo"
        case .video: "film"
        case .procedural: "waveform.path"
        case .particles: "sparkles"
        case .visualizer: "chart.bar.fill"
        }
    }

    /// The mouse zones, drawn over the preview so they can be located at a glance.
    private var zoneOverlay: some View {
        GeometryReader { geo in
            ForEach(project.scene.zones) { zone in
                RoundedRectangle(cornerRadius: 4).strokeBorder(Color.yellow.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                    .frame(width: geo.size.width * zone.width, height: geo.size.height * zone.height)
                    .overlay(Text(zone.id).font(.caption2).foregroundColor(.yellow).padding(2), alignment: .topLeading)
                    .position(x: geo.size.width * (zone.x + zone.width / 2), y: geo.size.height * (zone.y + zone.height / 2))
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: Actions

    private func chooseMedia() {
        let panel = NSOpenPanel()
        panel.title = "Choose an image or video"
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { project.addMediaLayer(from: url) }
    }

    private func exportPackage() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(project.scene.name).wsp"
        panel.title = "Export wallpaper package"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try project.exportPackage(to: url); project.message = "Exported \(url.lastPathComponent)." }
        catch { project.message = error.localizedDescription }
    }

    @MainActor
    private func addToLibrary(play: Bool) async {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("\(project.scene.name)-\(UUID().uuidString.prefix(6)).wsp")
        do {
            try project.exportPackage(to: tmp)
            let record = try await library.importFile(tmp, move: true)
            project.message = play ? "Set “\(record.title)” as your wallpaper." : "Added “\(record.title)” to your library."
            if play { await library.play(record) }
        } catch { project.message = error.localizedDescription }
    }
}
