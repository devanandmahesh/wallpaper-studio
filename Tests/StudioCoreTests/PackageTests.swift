import Testing
import Foundation
@testable import StudioCore

@Suite struct PackageValidationTests {
    func entries(_ names: [String], size: Int64 = 100) -> [PackageEntry] { names.map { PackageEntry(path: $0, size: size) } }
    func scene(entry: String = "scene.json") -> PackageManifest { PackageManifest(id: "com.example.test", name: "Test", type: .scene, entry: entry) }
    let ok = ["manifest.json", "scene.json"]
    func validate(_ m: PackageManifest, _ e: [PackageEntry], app: String = "1.0") throws { try PackageValidator.validate(manifest: m, entries: e, appVersion: app) }

    @Test func aMinimalScenePackageIsAccepted() throws {
        try validate(scene(), entries(ok))
    }

    @Test func pathRulesRejectEveryEscapeRoute() {
        for bad in ["/etc/passwd", "../x", "a/../../x", "a//b", "./a", ".hidden", "a/.hidden/b", "a\\b", "a\u{0}b", "", String(repeating: "a", count: 300), "a/b/c/d/e/f/g.png"] {
            #expect(!PackageValidator.isSafeRelativePath(bad), Comment(rawValue: "should reject \(bad.prefix(30))"))
        }
        for good in ["scene.json", "assets/bg.png", "a/b/c.mp4", "My File.png"] { #expect(PackageValidator.isSafeRelativePath(good), Comment(rawValue: good)) }
    }

    @Test func unsafeEntriesInTheArchiveAreRefusedEvenIfUnused() {
        for bad in ["../evil.png", "/abs.png", "a/../../b.png", ".DS_Store"] {
            #expect(throws: PackageError.self) { try validate(scene(), entries(ok + [bad])) }
        }
    }

    @Test func symlinksAreRefused() {
        let e = entries(ok) + [PackageEntry(path: "link.png", size: 5, isSymlink: true)]
        #expect(throws: PackageError.unsafePath("link.png (symbolic link)")) { try validate(scene(), e) }
    }

    @Test func forbiddenFileTypesAreRefused() {
        for bad in ["run.sh", "tool.app", "x.dylib", "evil.exe", "a.html.exe", "noextension", "script.py", "m.metal", "doc.pdf"] {
            #expect(throws: PackageError.forbiddenFile(bad)) { try validate(scene(), entries(ok + [bad])) }
        }
        #expect(throws: Never.self) { try validate(scene(), entries(ok + ["UPPER.PNG", "movie.MP4"])) }          // case-insensitive extensions
    }

    @Test func sizeAndCountLimitsStopZipBombs() {
        #expect(throws: PackageError.self) { try validate(scene(), entries(ok) + [PackageEntry(path: "big.mp4", size: PackageLimits.maxFileBytes + 1)]) }
        let many = (0..<5).map { PackageEntry(path: "v\($0).mp4", size: PackageLimits.maxFileBytes) }
        #expect(throws: PackageError.self) { try validate(scene(), entries(ok) + many) }               // 5 × 256 MB > 512 MB total
        let files = (0...PackageLimits.maxFiles).map { "f\($0).png" }
        #expect(throws: PackageError.self) { try validate(scene(), entries(ok + files)) }
    }

    @Test func caseInsensitiveDuplicatesAreRefused() {
        #expect(throws: PackageError.self) { try validate(scene(), entries(ok + ["a.png", "A.png"])) }
    }

    @Test func theManifestIsChecked() {
        func broken(_ edit: (inout PackageManifest) -> Void) -> PackageManifest { var m = scene(); edit(&m); return m }
        #expect(throws: PackageError.self) { try validate(broken { $0.format = "zip" }, entries(ok)) }
        #expect(throws: PackageError.unsupportedVersion(2)) { try validate(broken { $0.formatVersion = 2 }, entries(ok)) }
        #expect(throws: PackageError.unsupportedVersion(0)) { try validate(broken { $0.formatVersion = 0 }, entries(ok)) }
        #expect(throws: PackageError.self) { try validate(broken { $0.id = "has spaces" }, entries(ok)) }
        #expect(throws: PackageError.self) { try validate(broken { $0.id = "" }, entries(ok)) }
        #expect(throws: PackageError.self) { try validate(broken { $0.name = "   " }, entries(ok)) }
        #expect(throws: PackageError.self) { try validate(broken { $0.shaders = ["custom.metal"] }, entries(ok + ["custom.metal"])) }
        #expect(throws: PackageError.self) { try validate(broken { $0.entry = "../scene.json" }, entries(ok)) }
        #expect(throws: PackageError.missingFile("other.json")) { try validate(broken { $0.entry = "other.json" }, entries(ok)) }
        #expect(throws: PackageError.missingFile("manifest.json")) { try validate(scene(), entries(["scene.json"])) }
        #expect(throws: PackageError.self) { try validate(broken { $0.config = ["k": String(repeating: "x", count: 5000)] }, entries(ok)) }
    }

    @Test func entryTypesMustMatchThePackageType() {
        func m(_ type: PackageType, _ entry: String) -> PackageManifest { PackageManifest(id: "a.b", name: "N", type: type, entry: entry) }
        #expect(throws: PackageError.self) { try validate(m(.scene, "index.html"), entries(["manifest.json", "index.html"])) }
        #expect(throws: PackageError.self) { try validate(m(.web, "scene.json"), entries(ok)) }
        #expect(throws: PackageError.self) { try validate(m(.video, "pic.png"), entries(["manifest.json", "pic.png"])) }
        #expect(throws: PackageError.self) { try validate(m(.image, "clip.mp4"), entries(["manifest.json", "clip.mp4"])) }
        #expect(throws: Never.self) { try validate(m(.web, "index.html"), entries(["manifest.json", "index.html"])) }
        #expect(throws: Never.self) { try validate(m(.video, "clip.mov"), entries(["manifest.json", "clip.mov"])) }
        #expect(throws: Never.self) { try validate(m(.image, "pic.heic"), entries(["manifest.json", "pic.heic"])) }
    }

    @Test func scriptsAndPermissionsBelongToWebPackagesOnly() {
        var web = PackageManifest(id: "a.b", name: "W", type: .web, entry: "index.html", permissions: [.audio, .pointer], scripts: ["main.js"])
        let e = entries(["manifest.json", "index.html", "main.js"])
        #expect(throws: Never.self) { try validate(web, e) }
        web.scripts = ["missing.js"]
        #expect(throws: PackageError.missingFile("missing.js")) { try validate(web, e) }
        web.scripts = ["index.html"]
        #expect(throws: PackageError.self) { try validate(web, e) }              // scripts must be .js
        var scene = scene(); scene.scripts = ["main.js"]
        #expect(throws: PackageError.self) { try validate(scene, entries(ok + ["main.js"])) }
        var perms = self.scene(); perms.permissions = [.audio]
        #expect(throws: PackageError.self) { try validate(perms, entries(ok)) }
        web.scripts = []; web.permissions = [.audio, .audio]
        #expect(throws: PackageError.self) { try validate(web, e) }
    }

    @Test func versionsAreChecked() {
        var m = scene(); m.minAppVersion = "1.10"
        #expect(throws: PackageError.appTooOld("1.10")) { try validate(m, entries(ok), app: "1.9") }
        #expect(throws: Never.self) { try validate(m, entries(ok), app: "1.10") }
        #expect(throws: Never.self) { try validate(m, entries(ok), app: "2.0") }
        #expect(PackageValidator.compareVersions("1.10", "1.9") == .orderedDescending)
        #expect(PackageValidator.compareVersions("1.0", "1") == .orderedSame)
    }

    @Test func sceneAssetsMustBeInsideThePackage() throws {
        let s = Scene(name: "s", layers: [SceneLayer(id: "a", content: .image("bg.png"), depthAsset: "depth.png")])
        let e = entries(ok + ["bg.png"])
        #expect(throws: PackageError.missingFile("depth.png")) { try PackageValidator.validateSceneAssets(s, entries: e) }
        try PackageValidator.validateSceneAssets(s, entries: entries(ok + ["bg.png", "depth.png"]))
        let nested = Scene(name: "s", layers: [SceneLayer(id: "a", content: .image("sub/bg.png"))])
        #expect(throws: PackageError.self) { try PackageValidator.validateSceneAssets(nested, entries: entries(ok + ["sub/bg.png"])) }
    }

    @Test func manifestsRoundTripAndToleratePartialFiles() throws {
        let m = PackageManifest(id: "x.y", name: "N", author: "A", type: .web, entry: "index.html", permissions: [.pointer], scripts: ["a.js"], config: ["k": "v"])
        #expect(try JSONDecoder().decode(PackageManifest.self, from: JSONEncoder().encode(m)) == m)
        let minimal = try JSONDecoder().decode(PackageManifest.self, from: Data(#"{"format":"wsp","formatVersion":1,"id":"a.b","name":"N","type":"video","entry":"c.mp4"}"#.utf8))
        #expect(minimal.permissions.isEmpty && minimal.config.isEmpty && minimal.version == "1.0")
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(PackageManifest.self, from: Data(#"{"format":"wsp"}"#.utf8)) }
    }

    @Test func packagesAreRecognisedByExtension() {
        #expect(WallpaperKind.detect(pathExtension: "wsp") == .package && WallpaperKind.detect(pathExtension: "WSP") == .package)
    }
}
