import Testing
import AppKit
import SwiftUI
import StudioCore
import StudioRender
@testable import WallpaperStudio

@MainActor
@Suite struct EditorProjectTests {
    init() { PreviewHostView.pacing = .timer }

    func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("editor-\(UUID().uuidString)") }
    func project(_ doc: EditorDocument = .blank(), in r: URL? = nil) throws -> EditorProject { try EditorProject.create(in: r ?? root(), from: doc) }
    func spin(_ s: Double) async {
        let end = Date().addingTimeInterval(s)
        while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)); try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    @Test func assetNamesAreSafeAndUnique() {
        #expect(EditorProject.safeAssetName(stem: "My Photo (1)", ext: "PNG", existing: []) == "My-Photo--1.png")
        #expect(EditorProject.safeAssetName(stem: "../../etc/passwd", ext: "jpg", existing: []) == "etc-passwd.jpg")
        #expect(EditorProject.safeAssetName(stem: "日本語", ext: "png", existing: []) == "asset.png")
        #expect(EditorProject.safeAssetName(stem: "a", ext: "png", existing: ["a.png", "a-2.png"]) == "a-3.png")
        #expect(SafeFileName.isSafe(EditorProject.safeAssetName(stem: String(repeating: "x/", count: 100), ext: "png", existing: [])))
    }

    @Test func projectsPersistAndReopenExactly() throws {
        let r = root()
        let p = try project(in: r)
        p.addLayer(.procedural(.aurora, .black, .white), name: "Sky")
        p.setDuration(20)
        try p.saveNow()
        let reopened = try EditorProject.open(directory: p.directory)
        #expect(reopened.document == p.document && reopened.document.duration == 20)
        let listed = EditorProject.list(in: r)
        #expect(listed.count == 1 && listed[0].name == "Untitled")
        _ = try project(in: r)
        #expect(EditorProject.list(in: r).count == 2)
    }

    @Test func editsAreUndoableAndSliderDragsAreOneStep() throws {
        let p = try project()
        let original = p.document
        p.addLayer(.solid(.white), name: "White")
        let afterAdd = p.document
        for i in 1...10 { p.setValue(.opacity, 1 - Double(i) / 20) }                      // one drag
        #expect(abs(p.value(.opacity) - 0.5) < 1e-9)
        p.undo()
        #expect(p.document == afterAdd)                                                   // the whole drag undone at once
        p.undo()
        #expect(p.document == original && !p.canUndo)
        p.redo(); p.redo()
        #expect(abs(p.value(.opacity) - 0.5) < 1e-9 && !p.canRedo)
    }

    @Test func selectionFollowsLayerChanges() throws {
        let p = try project()
        p.addLayer(.solid(.white), name: "A")
        let a = try #require(p.selection)
        p.addLayer(.solid(.black), name: "B")
        #expect(p.selection != a)
        p.removeSelected()
        #expect(p.selection == p.scene.layers.last?.id)
        p.selection = a
        p.duplicateSelected()
        #expect(p.selection != a && p.selectedLayer?.name == "A copy")
    }

    @Test func animatedPropertiesEditKeyframesAndPlainOnesEditTheBase() throws {
        let p = try project()
        p.addLayer(.solid(.white))
        let id = try #require(p.selection)
        p.setValue(.opacity, 0.4)
        #expect(p.selectedLayer?.opacity == 0.4 && !p.isAnimated(.opacity))
        p.playhead = 0
        p.addKeyframe(.opacity)
        p.playhead = 4
        p.setValue(.opacity, 1)                                                           // now animated: sets a keyframe at 4 s
        #expect(p.isAnimated(.opacity) && p.selectedLayer?.opacity == 0.4)
        #expect(abs((p.document.value(layer: id, property: .opacity, at: 2) ?? -1) - 0.7) < 1e-9)
        p.playhead = 2
        #expect(abs(p.value(.opacity) - 0.7) < 1e-9)
        let ref = KeyframeRef(layerID: id, property: .opacity, index: 1)
        p.moveKeyframe(ref, to: 6)
        #expect(p.selectedKeyframe?.index == 1 && p.selectedLayer?.tracks.first?.keyframes.last?.time == 6)
        p.removeKeyframe(ref)
        p.removeKeyframe(KeyframeRef(layerID: id, property: .opacity, index: 0))
        #expect(!p.isAnimated(.opacity) && p.selectedKeyframe == nil)
    }

    @Test func theTimelinePlaysAndLoops() throws {
        let p = try project()
        p.setDuration(4)
        p.isPlaying = true
        p.advance(by: 3); p.advance(by: 3)
        #expect(abs(p.playhead - 2) < 1e-9)
        p.isPlaying = false
        p.advance(by: 1)
        #expect(abs(p.playhead - 2) < 1e-9)
    }

    @Test func importingAssetsRejectsWhatScenesCannotUse() throws {
        let p = try project()
        let png = Fixtures.png(30, 20)
        let name = try p.importAsset(from: png)
        #expect(name.hasSuffix(".png") && FileManager.default.fileExists(atPath: p.directory.appendingPathComponent(name).path))
        #expect(try p.importAsset(from: png) != name)                                    // second copy gets its own name
        let video = try p.importAsset(from: Fixtures.mp4())
        #expect(video.hasSuffix(".mp4"))
        #expect(throws: EditorError.self) { try p.importAsset(from: Fixtures.gif(frames: 3, delay: 0.1)) }
        let text = Fixtures.dir.appendingPathComponent("t-\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: text)
        #expect(throws: EditorError.self) { try p.importAsset(from: text) }
        let broken = Fixtures.dir.appendingPathComponent("b-\(UUID().uuidString).png")
        try Data("not an image".utf8).write(to: broken)
        #expect(throws: EditorError.self) { try p.importAsset(from: broken) }
    }

    @Test func mediaLayersDepthMapsAndReplacementWork() throws {
        let p = try project()
        p.addMediaLayer(from: Fixtures.png(40, 40))
        let layer = try #require(p.selectedLayer)
        #expect(layer.content.kind == .image && layer.content.asset != nil)
        p.setDepthMap(from: Fixtures.png(10, 10))
        #expect(p.selectedLayer?.depthAsset != nil && (p.selectedLayer?.parallaxDepth ?? 0) > 0)
        p.replaceMedia(with: Fixtures.mp4())
        #expect(p.selectedLayer?.content.kind == .video)
        p.addMediaLayer(from: Fixtures.gif(frames: 2, delay: 0.1))
        #expect(p.message?.contains("GIF") == true)                                      // a clear message, no crash, no layer added
        try p.document.validate()
    }

    @Test func exportingProducesAValidPackageWithOnlyTheAssetsInUse() async throws {
        let p = try project()
        p.addMediaLayer(from: Fixtures.png(64, 36))
        _ = try p.importAsset(from: Fixtures.png(8, 8))                                   // imported but never used
        p.addLayer(.particles(ParticlePreset.fireflies.spec), name: "Flies")
        p.edit { doc in if let id = doc.scene.layers.first?.id { _ = doc.addZone(layerID: id) } }
        p.setSceneName("My Wallpaper")
        let out = Fixtures.dir.appendingPathComponent("export-\(UUID().uuidString).wsp")
        try p.exportPackage(to: out)

        let inspection = try PackageService.inspect(out)
        #expect(inspection.manifest.name == "My Wallpaper" && inspection.manifest.type == .scene && inspection.manifest.preview == "preview.jpg")
        let names = Set(inspection.entries.map(\.path))
        let used = Set(p.scene.referencedAssets)
        #expect(names == used.union(["manifest.json", "scene.json", "preview.jpg"]))
        #expect(inspection.scene?.zones.count == 1)

        // The package installs into the library like any other and renders.
        let name = UUID().uuidString
        let model = LibraryModel(storage: LibraryStorage(root: FileManager.default.temporaryDirectory.appendingPathComponent("ed-\(name)/LiveWallpaper/Library")),
                                 defaults: UserDefaults(suiteName: "ed-\(name)")!)
        let record = try await model.importFile(out)
        #expect(record.kind == .package && record.title == "My Wallpaper")
        #expect(RendererFactory.make(url: try #require(model.fileURL(record)), loops: true, settings: RenderSettings(), maxPixel: 400) is MetalSceneRenderer)
        #expect(await model.thumbnail(for: record) != nil)
    }

    @Test func exportRefusesInvalidScenes() throws {
        let p = try project()
        p.edit { $0.scene.layers[0].content = .image("../escape.png") }
        #expect(throws: SceneError.self) { try p.exportPackage(to: Fixtures.dir.appendingPathComponent("bad-\(UUID().uuidString).wsp")) }
    }

    @Test func thePreviewRendersLiveAndFollowsEdits() async throws {
        guard MetalContext.shared != nil else { return }
        _ = NSApplication.shared
        let p = try project()
        p.addLayer(.visualizer(VisualizerSpec()), name: "Bars", blend: .add)
        let view = PreviewHostView(frame: NSRect(x: 0, y: 0, width: 480, height: 270))
        view.wantsLayer = true
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.attach(p)
        view.viewDidMoveToWindow()
        p.isPlaying = true
        await spin(0.6)
        let first = view.framesDrawn
        #expect(first >= 3, "preview drew \(first) frames")
        #expect(p.playhead > 0.2)                                                         // the timeline advanced with the preview
        p.setValue(.opacity, 0.5)
        view.refresh()
        await spin(0.3)
        #expect(view.framesDrawn > first)
        #expect((view.stats?.frames ?? 0) > 0)
        view.stop(); window.close()
    }

    @Test func theWholeEditorLaysOutWithoutProblems() throws {
        _ = NSApplication.shared
        let r = root()
        let holder = EditorHolder(root: r)
        let name = UUID().uuidString
        let library = LibraryModel(storage: LibraryStorage(root: FileManager.default.temporaryDirectory.appendingPathComponent("ed2-\(name)/LiveWallpaper/Library")),
                                   defaults: UserDefaults(suiteName: "ed2-\(name)")!)
        holder.newProject(from: EditorDocument(scene: BuiltInScenes.pulseRing))
        holder.project.selection = holder.project.scene.layers.last?.id
        let host = NSHostingView(rootView: EditorWorkspace(project: holder.project, holder: holder, library: library))
        host.frame = NSRect(x: 0, y: 0, width: 1500, height: 900)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width > 0)
        // Exercise every layer kind in the inspector.
        for layer in holder.project.scene.layers {
            holder.project.selection = layer.id
            host.layoutSubtreeIfNeeded()
        }
        holder.project.addLayer(.procedural(.waves, .black, .white))
        holder.project.edit { doc in if let id = doc.scene.layers.last?.id { _ = doc.addZone(layerID: id) } }
        host.layoutSubtreeIfNeeded()
        window.close()
    }

    @Test func everyTemplateOpensAsAProject() throws {
        for scene in BuiltInScenes.all {
            let p = try project(EditorDocument(scene: scene))
            try p.document.validate()
            let reopened = try EditorProject.open(directory: p.directory)
            #expect(reopened.scene == scene, "\(scene.name)")
        }
    }
}
