import Foundation
import AVFoundation
import StudioCore

/// A package that has been unpacked and checked: everything the renderers need.
struct ResolvedPackage {
    let manifest: PackageManifest
    let directory: URL
    var entryURL: URL { directory.appendingPathComponent(manifest.entry) }
    var previewURL: URL? { manifest.preview.map { directory.appendingPathComponent($0) } }
    let scene: Scene?
}

/// Reads, validates, unpacks and builds `.wsp` packages.
///
/// A `.wsp` is a zip with `manifest.json` at its root. Third-party packages are untrusted, so:
///  * the archive listing is validated **before** anything is extracted (unsafe paths, symlinks, sizes, counts, file types);
///  * extraction goes to a fresh temporary folder through the system `ditto`, never straight into the library;
///  * after extraction the folder is scanned again (symlinks, undeclared files, real sizes) and every medium is decoded;
///  * no native code is ever loaded or run; scripts exist only for web wallpapers and execute inside WebKit's sandbox.
enum PackageService {
    /// The running app's version (from Info.plist), used to honour a package's `minAppVersion`.
    static var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0" }

    // MARK: Running tools

    @discardableResult
    private static func run(_ tool: String, _ args: [String]) throws -> Data {
        do { return try ProcessRunner.run(tool, args) }
        catch let e as ProcessRunnerError { throw PackageError.toolFailed(e.localizedDescription) }
    }

    // MARK: Listing

    /// Archive junk Finder adds when compressing (resource forks, folder metadata). Safe to ignore and delete.
    static func isJunk(_ path: String) -> Bool {
        path.hasPrefix("__MACOSX/") || path == "__MACOSX" || path.hasSuffix(".DS_Store") || path.split(separator: "/").last.map { $0.hasPrefix("._") } == true
    }

    /// Parses `unzip -Z -l` output (permissions, version, OS, size, type, compressed size, method, date, time, name).
    private static let listingPattern = try? NSRegularExpression(pattern: #"^(\S{10})\s+\S+\s+\S+\s+(\d+)\s+\S+\s+\d+\s+\S+\s+\S+\s+\S+\s+(.+)$"#)

    static func parseListing(_ text: String) -> [PackageEntry] {
        guard let pattern = Self.listingPattern else { return [] }
        var entries: [PackageEntry] = []
        for line in text.split(separator: "\n") {
            let s = String(line)
            guard let m = pattern.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), m.numberOfRanges == 4,
                  let perm = Range(m.range(at: 1), in: s), let size = Range(m.range(at: 2), in: s), let name = Range(m.range(at: 3), in: s),
                  let bytes = Int64(s[size]) else { continue }
            let path = String(s[name])
            entries.append(PackageEntry(path: path, size: bytes, isSymlink: s[perm].first == "l", isDirectory: s[perm].first == "d" || path.hasSuffix("/")))
        }
        return entries
    }

    static func listEntries(of zip: URL) throws -> [PackageEntry] {
        let text = String(decoding: try run("/usr/bin/unzip", ["-Z", "-l", zip.path]), as: UTF8.self)
        let entries = parseListing(text)
        guard !entries.isEmpty else { throw PackageError.notAPackage("the archive is empty or unreadable") }
        return entries.filter { !isJunk($0.path) }
    }

    private static func read(_ name: String, from zip: URL, maxBytes: Int) throws -> Data {
        let data = try run("/usr/bin/unzip", ["-p", zip.path, name])
        guard data.count <= maxBytes else { throw PackageError.tooLarge("“\(name)”") }
        return data
    }

    // MARK: Inspect (no extraction)

    struct Inspection {
        let manifest: PackageManifest
        let entries: [PackageEntry]
        let scene: Scene?
    }

    static func inspect(_ zip: URL) throws -> Inspection {
        let entries = try listEntries(of: zip)
        guard let manifestEntry = entries.first(where: { $0.path == "manifest.json" }) else { throw PackageError.missingFile("manifest.json") }
        guard manifestEntry.size <= PackageLimits.maxManifestBytes else { throw PackageError.tooLarge("manifest.json") }
        let manifest: PackageManifest
        do { manifest = try JSONDecoder().decode(PackageManifest.self, from: try read("manifest.json", from: zip, maxBytes: PackageLimits.maxManifestBytes)) }
        catch let e as PackageError { throw e }
        catch { throw PackageError.invalidManifest("cannot be read (\(error.localizedDescription))") }
        try PackageValidator.validate(manifest: manifest, entries: entries, appVersion: appVersion)

        var scene: Scene?
        if manifest.type == .scene {
            // The listing says how big the entry is: refuse before reading anything into memory.
            guard let sceneEntry = entries.first(where: { $0.path == manifest.entry }), sceneEntry.size <= Int64(SceneCodec.maxBytes) else { throw PackageError.tooLarge("“\(manifest.entry)”") }
            let data = try read(manifest.entry, from: zip, maxBytes: SceneCodec.maxBytes)
            do { scene = try SceneCodec.decode(data) } catch { throw PackageError.invalidContent(error.localizedDescription) }
            if let scene { try PackageValidator.validateSceneAssets(scene, entries: entries) }
        }
        return Inspection(manifest: manifest, entries: entries, scene: scene)
    }

    // MARK: Extract

    /// Unpacks into `directory` (which must not exist), then re-checks the result. On any failure nothing is left behind.
    @discardableResult
    static func extract(_ zip: URL, to directory: URL) throws -> ResolvedPackage {
        let inspection = try inspect(zip)
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("wsp-extract-\(UUID().uuidString)")
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }
        // `unzip` (not `ditto`): it extracts exactly the listed files, with the Finder junk excluded, and never interprets AppleDouble data.
        try run("/usr/bin/unzip", ["-q", "-o", "-d", temp.path, zip.path, "-x", "__MACOSX/*", "*.DS_Store", "._*", "*/._*"])

        // Remove Finder junk, then verify the tree exactly matches what the listing promised.
        let junk = fm.enumerator(at: temp, includingPropertiesForKeys: nil)?.allObjects.compactMap { $0 as? URL }.filter { isJunk(relative($0, to: temp)) } ?? []
        junk.forEach { try? fm.removeItem(at: $0) }

        let declared = Set(inspection.entries.filter { !$0.isDirectory }.map(\.path))
        var actual = Set<String>()
        var total: Int64 = 0
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey, .isDirectoryKey]
        let root = temp.resolvingSymlinksInPath().path
        guard let walker = fm.enumerator(at: temp, includingPropertiesForKeys: keys) else { throw PackageError.toolFailed("cannot read the extracted files") }
        for case let url as URL in walker {
            let v = try url.resourceValues(forKeys: Set(keys))
            if v.isSymbolicLink == true { throw PackageError.unsafePath("\(relative(url, to: temp)) (symbolic link)") }
            guard url.resolvingSymlinksInPath().path.hasPrefix(root + "/") else { throw PackageError.unsafePath(relative(url, to: temp)) }
            if v.isDirectory == true { continue }
            guard v.isRegularFile == true else { throw PackageError.forbiddenFile(relative(url, to: temp)) }
            let rel = relative(url, to: temp)
            actual.insert(rel)
            let size = Int64(v.fileSize ?? 0)
            guard size <= PackageLimits.maxFileBytes else { throw PackageError.tooLarge("“\(rel)”") }
            total += size
        }
        guard total <= PackageLimits.maxTotalBytes else { throw PackageError.tooLarge("\(total / 1_048_576) MB in total") }
        guard actual == declared else {
            throw PackageError.invalidContent("the extracted files do not match the archive listing (\(actual.symmetricDifference(declared).sorted().prefix(3).joined(separator: ", ")))")
        }

        try verifyContent(inspection, in: temp)
        try fm.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: temp, to: directory)
        return ResolvedPackage(manifest: inspection.manifest, directory: directory, scene: inspection.scene)
    }

    private static func relative(_ url: URL, to base: URL) -> String {
        let b = base.resolvingSymlinksInPath().path, p = url.resolvingSymlinksInPath().path
        return p.hasPrefix(b + "/") ? String(p.dropFirst(b.count + 1)) : p
    }

    /// Every medium must really decode, so a renamed executable or truncated video is caught at install time.
    private static func verifyContent(_ inspection: Inspection, in dir: URL) throws {
        for entry in inspection.entries where !entry.isDirectory {
            let url = dir.appendingPathComponent(entry.path)
            let ext = PackageValidator.fileExtension(entry.path)
            if ["mp4", "mov", "m4v"].contains(ext) {
                guard MediaInspector.isPlayable(url) else { throw PackageError.invalidContent("“\(entry.path)” is not a playable video") }
            } else if PackageLimits.mediaExtensions.contains(ext) || ["jpg", "jpeg", "png"].contains(ext) {
                guard ImageLoading.source(url).map({ CGImageSourceGetCount($0) > 0 }) == true else { throw PackageError.invalidContent("“\(entry.path)” is not a valid image") }
            }
        }
        if inspection.manifest.type == .web {
            guard (try? Data(contentsOf: dir.appendingPathComponent(inspection.manifest.entry)).count) ?? 0 > 0 else { throw PackageError.invalidContent("the web page is empty") }
        }
    }

    // MARK: Library location

    /// Where the unpacked copy of a package file lives (next to it, so deleting the record removes both).
    static func contentsDirectory(for packageFile: URL) -> URL {
        packageFile.deletingLastPathComponent().appendingPathComponent(packageFile.lastPathComponent + "-contents", isDirectory: true)
    }

    /// The unpacked package for a stored `.wsp` file, unpacking again if the cache was removed.
    static func resolve(_ packageFile: URL) throws -> ResolvedPackage {
        let dir = contentsDirectory(for: packageFile)
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent("manifest.json").path) {
            let data = try Data(contentsOf: dir.appendingPathComponent("manifest.json"))
            let manifest = try JSONDecoder().decode(PackageManifest.self, from: data)
            var scene: Scene?
            if manifest.type == .scene { scene = try SceneCodec.decode(Data(contentsOf: dir.appendingPathComponent(manifest.entry))) }
            return ResolvedPackage(manifest: manifest, directory: dir, scene: scene)
        }
        Log.library.info("Re-extracting package \(packageFile.lastPathComponent)")
        return try extract(packageFile, to: dir)
    }

    // MARK: Building

    /// Creates a package from files on disk. `files` maps the name inside the package to a source file.
    static func build(manifest: PackageManifest, files: [String: URL], preview: Data?, to destination: URL) throws {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("wsp-build-\(UUID().uuidString)")
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }
        var manifest = manifest
        for (name, source) in files {
            guard PackageValidator.isSafeRelativePath(name) else { throw PackageError.unsafePath(name) }
            let target = temp.appendingPathComponent(name)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: target)
        }
        if let preview {
            try preview.write(to: temp.appendingPathComponent("preview.jpg"))
            manifest.preview = "preview.jpg"
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: temp.appendingPathComponent("manifest.json"))
        try? fm.removeItem(at: destination)
        // `zip -X` stores no extra Finder attributes; `-r .` puts the files at the archive root.
        do { try ProcessRunner.run("/usr/bin/zip", ["-X", "-q", "-r", destination.path, "."], currentDirectory: temp) }
        catch let e as ProcessRunnerError { throw PackageError.toolFailed(e.localizedDescription) }
    }
}
