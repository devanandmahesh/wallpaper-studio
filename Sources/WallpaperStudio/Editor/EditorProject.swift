import AppKit
import StudioCore
import StudioRender

/// Identifies one keyframe on the timeline.
struct KeyframeRef: Equatable {
    var layerID: String
    var property: AnimatableProperty
    var index: Int
}

/// What undo restores: the document and which layer was selected.
struct EditorSnapshot: Equatable {
    var document: EditorDocument
    var selection: String?
}

/// An editing session: the document, undo history, selection, playhead, and the project folder on disk.
///
/// The editor never talks to the playback engine: it edits plain `Scene` values, shows them in its own preview renderer,
/// and hands finished work over as a `.wsp` package like any other wallpaper.
final class EditorProject: ObservableObject {
    struct Info: Identifiable {
        let id: String
        let name: String
        let directory: URL
        let modified: Date
    }

    let directory: URL
    @Published private(set) var document: EditorDocument
    @Published var selection: String?
    @Published var playhead = 0.0
    @Published var isPlaying = false
    @Published var simulateAudio = true
    @Published var selectedKeyframe: KeyframeRef?
    @Published var message: String?
    /// Bumps on every change so previews know to refresh.
    @Published private(set) var revision = 0

    private var history = EditorHistory<EditorSnapshot>()
    private var snapshot: EditorSnapshot { EditorSnapshot(document: document, selection: selection) }
    private var saveWork: DispatchWorkItem?

    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }
    var scene: Scene { document.scene }
    var selectedLayer: SceneLayer? { selection.flatMap { document.layer($0) } }

    // MARK: Opening and creating

    static var defaultRoot: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("LiveWallpaper/Editor", isDirectory: true)
    }

    private var quitObserver: NSObjectProtocol?

    init(directory: URL, document: EditorDocument) {
        self.directory = directory
        self.document = document
        selection = document.scene.layers.last?.id
        // Edits are saved a moment after they happen; make sure quitting inside that moment loses nothing.
        quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            try? self?.saveNow()
        }
    }

    deinit { if let quitObserver { NotificationCenter.default.removeObserver(quitObserver) } }

    @discardableResult
    static func create(in root: URL = defaultRoot, from document: EditorDocument) throws -> EditorProject {
        let dir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let project = EditorProject(directory: dir, document: document)
        try project.saveNow()
        return project
    }

    static func open(directory: URL) throws -> EditorProject {
        let scene = try SceneCodec.decode(Data(contentsOf: directory.appendingPathComponent("scene.json")))
        var duration = 10.0
        if let data = try? Data(contentsOf: directory.appendingPathComponent("editor.json")),
           let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let d = meta["duration"] as? Double { duration = d }
        return EditorProject(directory: directory, document: EditorDocument(scene: scene, duration: duration))
    }

    static func list(in root: URL = defaultRoot) -> [Info] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return dirs.compactMap { dir -> Info? in
            let file = dir.appendingPathComponent("scene.json")
            guard let data = try? Data(contentsOf: file), let scene = try? SceneCodec.decode(data) else { return nil }
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return Info(id: dir.lastPathComponent, name: scene.name, directory: dir, modified: date)
        }.sorted { $0.modified > $1.modified }
    }

    // MARK: Saving

    func saveNow() throws {
        saveWork?.cancel()
        try SceneCodec.encode(document.scene).write(to: directory.appendingPathComponent("scene.json"), options: .atomic)
        try JSONSerialization.data(withJSONObject: ["duration": document.duration]).write(to: directory.appendingPathComponent("editor.json"), options: .atomic)
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            do { try self?.saveNow() } catch { Log.library.error("Editor autosave failed: \(error.localizedDescription)") }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    // MARK: Editing

    /// Applies an edit. Edits sharing a `key` that happen within a second (a slider drag) are one undo step.
    func edit(key: String? = nil, _ change: (inout EditorDocument) -> Void) {
        var next = document
        change(&next)
        guard next != document else { return }
        history.willChange(from: snapshot, key: key, at: ProcessInfo.processInfo.systemUptime)
        apply(next)
    }

    private func apply(_ next: EditorDocument) {
        document = next
        revision += 1
        if let s = selection, next.layer(s) == nil { selection = next.scene.layers.last?.id }
        if let k = selectedKeyframe, next.layer(k.layerID)?.tracks.first(where: { $0.property == k.property })?.keyframes.indices.contains(k.index) != true { selectedKeyframe = nil }
        playhead = min(playhead, next.duration)
        scheduleSave()
    }

    func undo() { if let previous = history.undo(current: snapshot) { restore(previous) } }
    func redo() { if let next = history.redo(current: snapshot) { restore(next) } }

    private func restore(_ s: EditorSnapshot) {
        apply(s.document)
        selection = s.selection.flatMap { document.layer($0) != nil ? $0 : nil } ?? document.scene.layers.last?.id
    }

    func addLayer(_ content: LayerContent, name: String? = nil, blend: BlendMode = .normal) {
        var created: String?
        edit { created = $0.addLayer(content, name: name, blend: blend) }
        selection = created
    }

    func removeSelected() { if let id = selection { edit { $0.removeLayer(id) } } }
    func duplicateSelected() {
        guard let id = selection else { return }
        var copy: String?
        edit { copy = $0.duplicateLayer(id) }
        selection = copy ?? selection
    }
    func moveLayer(_ id: String, to index: Int) { edit { $0.moveLayer(id, to: index) } }
    func rename(_ name: String) { if let id = selection { edit(key: "name-\(id)") { $0.update(id) { $0.name = name } } } }
    func setSceneName(_ name: String) { edit(key: "scene-name") { $0.scene.name = name } }
    func update(key: String? = nil, _ change: @escaping (inout SceneLayer) -> Void) {
        guard let id = selection else { return }
        edit(key: key.map { "\(id)-\($0)" }) { $0.update(id, change) }
    }

    // MARK: Animated values

    func isAnimated(_ property: AnimatableProperty) -> Bool { selectedLayer?.tracks.contains { $0.property == property } == true }

    /// The value shown for a property: what the player would show at the playhead.
    func value(_ property: AnimatableProperty) -> Double {
        guard let id = selection else { return 0 }
        return document.value(layer: id, property: property, at: playhead) ?? 0
    }

    /// Edits a property. If it is animated the edit lands on a keyframe at the playhead, otherwise on the base value.
    func setValue(_ property: AnimatableProperty, _ v: Double) {
        guard let id = selection else { return }
        let t = playhead
        edit(key: "\(id)-\(property.rawValue)") { doc in
            if doc.layer(id)?.tracks.contains(where: { $0.property == property }) == true { doc.setKeyframe(layer: id, property: property, time: t, value: v) }
            else { doc.setBase(layer: id, property, v) }
        }
    }

    func addKeyframe(_ property: AnimatableProperty) {
        guard let id = selection else { return }
        let t = playhead, v = value(property)
        edit { $0.setKeyframe(layer: id, property: property, time: t, value: v) }
    }

    func moveKeyframe(_ ref: KeyframeRef, to time: Double) {
        var newIndex: Int?
        edit(key: "kf-\(ref.layerID)-\(ref.property.rawValue)-\(ref.index)") { newIndex = $0.moveKeyframe(layer: ref.layerID, property: ref.property, index: ref.index, to: time) }
        if let newIndex { selectedKeyframe = KeyframeRef(layerID: ref.layerID, property: ref.property, index: newIndex) }
    }

    func removeKeyframe(_ ref: KeyframeRef) { edit { $0.removeKeyframe(layer: ref.layerID, property: ref.property, index: ref.index) } }
    func setDuration(_ seconds: Double) { edit(key: "duration") { $0.setDuration(seconds) } }

    // MARK: Playback of the timeline

    func advance(by dt: Double) {
        guard isPlaying else { return }
        playhead += dt
        if playhead > document.duration { playhead = playhead.truncatingRemainder(dividingBy: document.duration) }
    }

    // MARK: Assets

    /// A file name that is safe inside a scene: letters, digits, dash and underscore, lowercase extension, unique in the project.
    static func safeAssetName(stem: String, ext: String, existing: Set<String>) -> String {
        let cleaned = String(stem.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" || $0 == "_" ? Character($0) : "-" })
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let base = cleaned.isEmpty ? "asset" : String(cleaned.prefix(40))
        let e = ext.lowercased()
        var name = "\(base).\(e)", n = 2
        while existing.contains(name) { name = "\(base)-\(n).\(e)"; n += 1 }
        return name
    }

    /// Copies an image or video into the project and returns the name to use in the scene.
    func importAsset(from url: URL) throws -> String {
        guard let kind = WallpaperKind.detect(pathExtension: url.pathExtension), kind == .image || kind == .video else {
            throw EditorError.invalid(url.pathExtension.lowercased() == "gif" ? "Animated GIFs cannot be used inside scenes. Use a video or a still image." : "Only images and videos can be added as layers.")
        }
        guard MediaInspector.canDisplay(url) else { throw EditorError.invalid("macOS cannot read “\(url.lastPathComponent)”.") }
        let existing = Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
        let name = Self.safeAssetName(stem: url.deletingPathExtension().lastPathComponent, ext: url.pathExtension, existing: existing)
        try FileManager.default.copyItem(at: url, to: directory.appendingPathComponent(name))
        return name
    }

    func addMediaLayer(from url: URL) {
        do {
            let name = try importAsset(from: url)
            let kind = WallpaperKind.detect(pathExtension: url.pathExtension)
            addLayer(kind == .video ? .video(name) : .image(name), name: url.deletingPathExtension().lastPathComponent)
        } catch { message = error.localizedDescription }
    }

    func replaceMedia(with url: URL) {
        guard let layer = selectedLayer, layer.content.isMedia else { return }
        do {
            let name = try importAsset(from: url)
            let isVideo = WallpaperKind.detect(pathExtension: url.pathExtension) == .video
            update { $0.content = isVideo ? .video(name) : .image(name) }
        } catch { message = error.localizedDescription }
    }

    func setDepthMap(from url: URL) {
        do {
            let name = try importAsset(from: url)
            update { $0.depthAsset = name; if $0.parallaxDepth == 0 { $0.parallaxDepth = 0.6 } }
        } catch { message = error.localizedDescription }
    }

    // MARK: Export

    func previewJPEG(width: Int = 960, height: Int = 540) -> Data? {
        guard let context = MetalContext.shared,
              let image = OffscreenRenderer(context: context).image(scene: document.scene, assetBase: directory, width: width, height: height, time: playhead)
        else { return nil }
        return MediaInspector.jpegData(image)
    }

    /// Builds a `.wsp` package from the scene and only the assets it references, then re-reads it as a safety check.
    func exportPackage(to destination: URL) throws {
        try document.validate()
        let sceneFile = FileManager.default.temporaryDirectory.appendingPathComponent("scene-\(UUID().uuidString).json")
        try SceneCodec.encode(document.scene).write(to: sceneFile)
        defer { try? FileManager.default.removeItem(at: sceneFile) }
        var files = ["scene.json": sceneFile]
        for asset in Set(document.scene.referencedAssets) { files[asset] = directory.appendingPathComponent(asset) }
        let slug = String(document.scene.name.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "-" }).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let manifest = PackageManifest(id: "local.\(slug.isEmpty ? "wallpaper" : String(slug.prefix(40))).\(UUID().uuidString.prefix(8).lowercased())",
                                       name: document.scene.name, author: NSFullUserName(), type: .scene, entry: "scene.json")
        try PackageService.build(manifest: manifest, files: files, preview: previewJPEG(), to: destination)
        _ = try PackageService.inspect(destination)
    }
}
