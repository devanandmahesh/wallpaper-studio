import Testing
import AppKit
import StudioCore
@testable import WallpaperStudio

typealias Z = Fixtures.ZipItem

func png(_ r: UInt8 = 255) -> Data { try! Data(contentsOf: Fixtures.png(8, 8)) }

func sceneJSON(asset: String? = "bg.png") -> Data {
    let layers: [SceneLayer] = asset.map { [SceneLayer(id: "bg", content: .image($0))] } ?? [SceneLayer(id: "c", content: .solid(.white))]
    return try! SceneCodec.encode(Scene(name: "Pkg", layers: layers))
}

func goodScenePackage(extra: [Z] = []) -> URL {
    let m = Fixtures.PackageManifestLike(extra: ["preview": "preview.png"])
    return Fixtures.zipFile([Z(name: "manifest.json", data: Fixtures.manifestData(m)), Z(name: "scene.json", data: sceneJSON()),
                             Z(name: "bg.png", data: png()), Z(name: "preview.png", data: png())] + extra)
}

@Suite struct PackageServiceTests {
    func tempDir() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("wsp-test-\(UUID().uuidString)") }

    @Test func aWellFormedScenePackageIsInspectedAndExtracted() throws {
        let zip = goodScenePackage()
        let inspection = try PackageService.inspect(zip)
        #expect(inspection.manifest.name == "Test Package" && inspection.scene?.layers.count == 1)
        let dest = tempDir()
        let resolved = try PackageService.extract(zip, to: dest)
        #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("bg.png").path))
        #expect(resolved.previewURL != nil && resolved.scene != nil)
    }

    @Test func buildThenInstallRoundTripsEveryPackageType() throws {
        let png = Fixtures.png(32, 32), gif = Fixtures.gif(frames: 3, delay: 0.1), mp4 = Fixtures.mp4()
        let html = Fixtures.dir.appendingPathComponent("index-\(UUID().uuidString).html")
        try Data("<html><body>hi</body></html>".utf8).write(to: html)
        let sceneFile = Fixtures.dir.appendingPathComponent("s-\(UUID().uuidString).json")
        try sceneJSON(asset: "bg.png").write(to: sceneFile)
        let cases: [(PackageManifest, [String: URL])] = [
            (PackageManifest(id: "a.scene", name: "S", type: .scene, entry: "scene.json"), ["scene.json": sceneFile, "bg.png": png]),
            (PackageManifest(id: "a.video", name: "V", type: .video, entry: "clip.mp4"), ["clip.mp4": mp4]),
            (PackageManifest(id: "a.image", name: "I", type: .image, entry: "pic.gif"), ["pic.gif": gif]),
            (PackageManifest(id: "a.web", name: "W", type: .web, entry: "index.html", config: ["k": "v"]), ["index.html": html]),
        ]
        for (manifest, files) in cases {
            let out = Fixtures.dir.appendingPathComponent("built-\(manifest.type.rawValue)-\(UUID().uuidString).wsp")
            try PackageService.build(manifest: manifest, files: files, preview: nil, to: out)
            let resolved = try PackageService.extract(out, to: tempDir())
            #expect(resolved.manifest.type == manifest.type && resolved.manifest.name == manifest.name, "\(manifest.type)")
            #expect(FileManager.default.fileExists(atPath: resolved.entryURL.path))
        }
    }

    @Test func finderJunkIsIgnoredAndRemoved() throws {
        let zip = goodScenePackage(extra: [Z(name: "__MACOSX/._bg.png", data: Data([1, 2, 3])), Z(name: ".DS_Store", data: Data([0])), Z(name: "._scene.json", data: Data([9]))])
        let dest = tempDir()
        try PackageService.extract(zip, to: dest)
        let names = (FileManager.default.enumerator(atPath: dest.path)?.allObjects as? [String]) ?? []
        #expect(!names.contains { $0.contains("__MACOSX") || $0.contains(".DS_Store") || $0.hasPrefix("._") })
    }

    @Test func hostilePackagesAreRefusedBeforeAnythingIsWritten() throws {
        let manifest = Fixtures.manifestData(Fixtures.PackageManifestLike())
        let base = [Z(name: "manifest.json", data: manifest), Z(name: "scene.json", data: sceneJSON(asset: nil))]
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("wsp-evil-\(UUID().uuidString).png")
        let attacks: [(String, [Z])] = [
            ("path traversal", base + [Z(name: "../\(marker.lastPathComponent)", data: png())]),
            ("absolute path", base + [Z(name: "/tmp/\(marker.lastPathComponent)", data: png())]),
            ("nested traversal", base + [Z(name: "a/../../\(marker.lastPathComponent)", data: png())]),
            ("hidden file", base + [Z(name: ".secret.png", data: png())]),
            ("symlink", base + [Z(name: "link.png", data: Data("/etc/passwd".utf8), isSymlink: true)]),
            ("executable", base + [Z(name: "run.sh", data: Data("#!/bin/sh\necho hi".utf8))]),
            ("app bundle file", base + [Z(name: "Evil.dylib", data: Data([0xCF, 0xFA]))]),
            ("zip bomb header", base + [Z(name: "huge.png", data: png(), declaredSize: 900_000_000)]),
        ]
        for (label, items) in attacks {
            let zip = Fixtures.zipFile(items)
            let dest = tempDir()
            #expect(throws: PackageError.self, "\(label)") { try PackageService.extract(zip, to: dest) }
            #expect(!FileManager.default.fileExists(atPath: dest.path), "\(label): destination must not exist")
            #expect(!FileManager.default.fileExists(atPath: marker.path), "\(label): nothing may be written outside")
        }
    }

    @Test func brokenManifestsAndContentAreRefused() throws {
        func zip(_ m: Fixtures.PackageManifestLike, _ items: [Z]) -> URL { Fixtures.zipFile([Z(name: "manifest.json", data: Fixtures.manifestData(m))] + items) }
        let ok = Z(name: "scene.json", data: sceneJSON(asset: nil))
        #expect(throws: PackageError.self) { try PackageService.inspect(Fixtures.zipFile([ok])) }                                              // no manifest
        #expect(throws: PackageError.unsupportedVersion(7)) { try PackageService.inspect(zip(.init(formatVersion: 7), [ok])) }
        #expect(throws: PackageError.self) { try PackageService.inspect(zip(.init(format: "other"), [ok])) }
        #expect(throws: PackageError.self) { try PackageService.inspect(zip(.init(extra: ["shaders": ["x.metal"]]), [ok, Z(name: "x.png", data: png())])) }
        #expect(throws: PackageError.appTooOld("99.0")) { try PackageService.inspect(zip(.init(extra: ["minAppVersion": "99.0"]), [ok])) }
        #expect(throws: PackageError.self) { try PackageService.inspect(zip(.init(), [Z(name: "scene.json", data: Data("{ not json".utf8))])) }       // bad scene
        #expect(throws: PackageError.missingFile("bg.png")) { try PackageService.inspect(zip(.init(), [Z(name: "scene.json", data: sceneJSON())])) } // missing asset
        #expect(throws: PackageError.self) { try PackageService.inspect(Fixtures.zipFile([Z(name: "manifest.json", data: Data("nope".utf8))])) }
        let garbage = Fixtures.dir.appendingPathComponent("garbage-\(UUID().uuidString).wsp")
        try Data("this is not a zip".utf8).write(to: garbage)
        #expect(throws: PackageError.self) { try PackageService.inspect(garbage) }
        // Content that is not what its extension says is caught after extraction, leaving nothing behind.
        let fake = zip(.init(), [Z(name: "scene.json", data: sceneJSON()), Z(name: "bg.png", data: Data("MZ not an image".utf8))])
        let dest = tempDir()
        #expect(throws: PackageError.self) { try PackageService.extract(fake, to: dest) }
        #expect(!FileManager.default.fileExists(atPath: dest.path))
    }

    @Test func webPackagesMayCarryScriptsButOtherTypesMayNot() throws {
        let html = Z(name: "index.html", data: Data("<html></html>".utf8)), js = Z(name: "main.js", data: Data("var a=1;".utf8))
        let web = Fixtures.PackageManifestLike(type: "web", entry: "index.html", extra: ["scripts": ["main.js"], "permissions": ["audio"]])
        let ok = Fixtures.zipFile([Z(name: "manifest.json", data: Fixtures.manifestData(web)), html, js])
        #expect(try PackageService.inspect(ok).manifest.scripts == ["main.js"])
        let scene = Fixtures.PackageManifestLike(extra: ["scripts": ["main.js"]])
        let bad = Fixtures.zipFile([Z(name: "manifest.json", data: Fixtures.manifestData(scene)), Z(name: "scene.json", data: sceneJSON(asset: nil)), js])
        #expect(throws: PackageError.self) { try PackageService.inspect(bad) }
    }

    @Test func listingParserHandlesNamesWithSpacesAndFlagsSymlinksAndDirectories() {
        let text = """
        Archive:  x.zip
        Zip file size: 1000 bytes, number of entries: 3
        -rw-r--r--  2.1 unx      123 tx      80 defN 24-Oct-31 04:44 my file.png
        lrwxr-xr-x  2.1 unx       11 tx      11 stor 24-Oct-31 04:44 link
        drwxr-xr-x  2.1 unx        0 bx       0 stor 24-Oct-31 04:44 folder/
        3 files, 134 bytes uncompressed, 91 bytes compressed:  32.1%
        """
        let entries = PackageService.parseListing(text)
        #expect(entries.count == 3)
        #expect(entries[0] == PackageEntry(path: "my file.png", size: 123))
        #expect(entries[1].isSymlink && entries[2].isDirectory)
    }
}

@MainActor
@Suite struct PackageLibraryTests {
    func makeModel() -> LibraryModel {
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: "ws-pkg-\(name)")!
        defaults.removePersistentDomain(forName: "ws-pkg-\(name)")
        return LibraryModel(storage: LibraryStorage(root: FileManager.default.temporaryDirectory.appendingPathComponent("ws-pkg-\(name)/LiveWallpaper/Library")), defaults: defaults)
    }

    @Test func importingAPackageUnpacksItAndNamesItFromTheManifest() async throws {
        let model = makeModel()
        let r = try await model.importFile(goodScenePackage())
        #expect(r.kind == .package && r.title == "Test Package" && r.tags.contains("scene") && r.category == "Package")
        let file = try #require(model.fileURL(r))
        #expect(FileManager.default.fileExists(atPath: PackageService.contentsDirectory(for: file).appendingPathComponent("scene.json").path))
        #expect(await model.thumbnail(for: r) != nil)
        let resolved = try PackageService.resolve(file)
        #expect(resolved.manifest.id == "com.test.pkg")
        await model.trash(r.id)
        await model.deleteForever(r.id)
        #expect(!FileManager.default.fileExists(atPath: PackageService.contentsDirectory(for: file).path) && !FileManager.default.fileExists(atPath: file.path))
    }

    @Test func aHostilePackageNeverEntersTheLibrary() async throws {
        let model = makeModel()
        let manifest = Fixtures.manifestData(Fixtures.PackageManifestLike())
        let evil = Fixtures.zipFile([Z(name: "manifest.json", data: manifest), Z(name: "scene.json", data: sceneJSON(asset: nil)), Z(name: "../x.png", data: png())])
        await #expect(throws: LibraryError.self) { try await model.importFile(evil) }
        #expect(model.records.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: model.storage.filesDir.path).isEmpty)
    }

    @Test func missingUnpackedFilesAreRestoredFromTheStoredArchive() async throws {
        let model = makeModel()
        let r = try await model.importFile(goodScenePackage())
        let file = try #require(model.fileURL(r))
        try FileManager.default.removeItem(at: PackageService.contentsDirectory(for: file))
        let resolved = try PackageService.resolve(file)
        #expect(FileManager.default.fileExists(atPath: resolved.entryURL.path))
    }

    @Test func packagesSurviveLibraryExportAndImport() async throws {
        let source = makeModel()
        _ = try await source.importFile(goodScenePackage())
        let zip = Fixtures.dir.appendingPathComponent("lib-\(UUID().uuidString).zip")
        await source.exportLibrary(to: zip)
        let target = makeModel()
        await target.importLibrary(from: zip)
        let r = try #require(target.records.first)
        #expect(r.kind == .package)
        let file = try #require(target.fileURL(r))
        #expect(FileManager.default.fileExists(atPath: PackageService.contentsDirectory(for: file).appendingPathComponent("manifest.json").path))
    }

    @Test func thePlayerBuildsRenderersFromPackages() async throws {
        let model = makeModel()
        let scenePkg = try await model.importFile(goodScenePackage())
        let url = try #require(model.fileURL(scenePkg))
        #expect(RendererFactory.make(url: url, loops: true, settings: RenderSettings(), maxPixel: 400) is MetalSceneRenderer)
        let mp4 = Fixtures.mp4()
        let videoOut = Fixtures.dir.appendingPathComponent("v-\(UUID().uuidString).wsp")
        try PackageService.build(manifest: PackageManifest(id: "a.v", name: "V", type: .video, entry: "clip.mp4"), files: ["clip.mp4": mp4], preview: nil, to: videoOut)
        let videoPkg = try await model.importFile(videoOut)
        #expect(RendererFactory.make(url: try #require(model.fileURL(videoPkg)), loops: true, settings: RenderSettings(), maxPixel: 400) is VideoWallpaperRenderer)
    }
}
