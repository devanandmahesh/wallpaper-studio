import Foundation

public enum PackageType: String, Codable, Sendable, CaseIterable { case scene, video, image, web }
public enum PackagePermission: String, Codable, Sendable, CaseIterable { case pointer, audio }

/// `manifest.json` at the root of a `.wsp` archive.
public struct PackageManifest: Codable, Equatable, Sendable {
    public static let formatID = "wsp"
    public static let currentFormatVersion = 1

    public var format: String
    public var formatVersion: Int
    public var id: String                  // stable identifier, e.g. "com.example.aurora"
    public var name: String
    public var author: String
    public var version: String             // the wallpaper's own version
    public var type: PackageType
    public var entry: String               // scene.json / index.html / video file / image file
    public var preview: String?            // preview image
    public var permissions: [PackagePermission]
    public var scripts: [String]           // web wallpapers only: extra JavaScript files, run inside the web sandbox
    public var shaders: [String]           // reserved; custom shaders are not supported yet, so this must be empty
    public var config: [String: String]    // free-form values handed to web wallpapers as `studio.config`
    public var minAppVersion: String?

    public init(id: String, name: String, author: String = "", version: String = "1.0", type: PackageType, entry: String,
                preview: String? = nil, permissions: [PackagePermission] = [], scripts: [String] = [], config: [String: String] = [:],
                minAppVersion: String? = nil) {
        format = Self.formatID; formatVersion = Self.currentFormatVersion
        self.id = id; self.name = name; self.author = author; self.version = version; self.type = type; self.entry = entry
        self.preview = preview; self.permissions = permissions; self.scripts = scripts; shaders = []; self.config = config
        self.minAppVersion = minAppVersion
    }

    enum CodingKeys: String, CodingKey {
        case format, formatVersion, id, name, author, version, type, entry, preview, permissions, scripts, shaders, config, minAppVersion
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decode(String.self, forKey: .format)
        formatVersion = try c.decode(Int.self, forKey: .formatVersion)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        author = try c.value(.author, "")
        version = try c.value(.version, "1.0")
        type = try c.decode(PackageType.self, forKey: .type)
        entry = try c.decode(String.self, forKey: .entry)
        preview = try c.decodeIfPresent(String.self, forKey: .preview)
        permissions = try c.value(.permissions, [])
        scripts = try c.value(.scripts, [])
        shaders = try c.value(.shaders, [])
        config = try c.value(.config, [:])
        minAppVersion = try c.decodeIfPresent(String.self, forKey: .minAppVersion)
    }
}

public enum PackageError: Error, Equatable, LocalizedError, Sendable {
    case notAPackage(String)
    case unsupportedVersion(Int)
    case appTooOld(String)
    case unsafePath(String)
    case tooLarge(String)
    case tooManyFiles(Int)
    case forbiddenFile(String)
    case missingFile(String)
    case invalidManifest(String)
    case invalidContent(String)
    case toolFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notAPackage(let m): "Not a wallpaper package: \(m)"
        case .unsupportedVersion(let v): "This package uses format version \(v), which this app does not understand."
        case .appTooOld(let v): "This package needs Wallpaper Studio \(v) or newer."
        case .unsafePath(let p): "The package contains an unsafe path: “\(p)”."
        case .tooLarge(let m): "The package is too large: \(m)."
        case .tooManyFiles(let n): "The package contains too many files (\(n))."
        case .forbiddenFile(let f): "The package contains a file type that is not allowed: “\(f)”."
        case .missingFile(let f): "The package refers to “\(f)”, which is not inside it."
        case .invalidManifest(let m): "The package manifest is invalid: \(m)."
        case .invalidContent(let m): "The package content is invalid: \(m)."
        case .toolFailed(let m): "Could not read the package: \(m)"
        }
    }
}

/// One file or folder in a package archive, as listed before anything is extracted.
public struct PackageEntry: Equatable, Sendable {
    public var path: String
    public var size: Int64
    public var isSymlink: Bool
    public var isDirectory: Bool
    public init(path: String, size: Int64, isSymlink: Bool = false, isDirectory: Bool = false) {
        self.path = path; self.size = size; self.isSymlink = isSymlink; self.isDirectory = isDirectory
    }
}

public enum PackageLimits {
    public static let maxFiles = 2000
    public static let maxFileBytes: Int64 = 256 * 1024 * 1024
    public static let maxTotalBytes: Int64 = 512 * 1024 * 1024
    public static let maxDepth = 6
    public static let maxManifestBytes = 64 * 1024
    public static let maxConfigBytes = 4 * 1024
    public static let maxScriptBytes: Int64 = 1024 * 1024
    public static let mediaExtensions: Set<String> = ["mp4", "mov", "m4v", "jpg", "jpeg", "png", "heic", "gif", "webp", "tif", "tiff", "bmp"]
    public static let webExtensions: Set<String> = ["html", "htm", "css", "js", "json", "svg", "woff", "woff2", "txt"]
    public static let allowedExtensions: Set<String> = mediaExtensions.union(webExtensions)
}

public enum PackageValidator {
    /// A relative path that stays inside the package: no absolute paths, `..`, empty or hidden components, backslashes or control characters.
    public static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, path.count <= 200, !path.hasPrefix("/"), !path.contains("\\") else { return false }
        if path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".") } && parts.count <= PackageLimits.maxDepth
    }

    public static func fileExtension(_ path: String) -> String { (path as NSString).pathExtension.lowercased() }

    /// Dotted-number comparison: "1.10" is newer than "1.9".
    public static func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    /// Checks the archive listing (before extraction) and the manifest against each other.
    /// The returned manifest has passed every structural rule; media decoding and scene contents are checked later,
    /// after extraction, by the app (they need the files).
    @discardableResult
    public static func validate(manifest: PackageManifest, entries: [PackageEntry], appVersion: String) throws -> PackageManifest {
        guard manifest.format == PackageManifest.formatID else { throw PackageError.notAPackage("format “\(manifest.format)”") }
        guard manifest.formatVersion >= 1, manifest.formatVersion <= PackageManifest.currentFormatVersion else {
            throw PackageError.unsupportedVersion(manifest.formatVersion)
        }
        if let min = manifest.minAppVersion, compareVersions(appVersion, min) == .orderedAscending { throw PackageError.appTooOld(min) }
        guard !manifest.id.isEmpty, manifest.id.count <= 100, manifest.id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }) else {
            throw PackageError.invalidManifest("id must be letters, digits, dots, dashes or underscores")
        }
        guard !manifest.name.trimmingCharacters(in: .whitespaces).isEmpty, manifest.name.count <= 100, manifest.author.count <= 100, manifest.version.count <= 30 else {
            throw PackageError.invalidManifest("name, author or version has an invalid length")
        }
        guard manifest.shaders.isEmpty else { throw PackageError.invalidManifest("custom shaders are not supported in format version 1") }
        guard manifest.scripts.isEmpty || manifest.type == .web else { throw PackageError.invalidManifest("scripts are only allowed in web wallpapers") }
        guard manifest.permissions.isEmpty || manifest.type == .web else { throw PackageError.invalidManifest("permissions are only used by web wallpapers") }
        guard Set(manifest.permissions).count == manifest.permissions.count else { throw PackageError.invalidManifest("duplicate permissions") }
        let configBytes = manifest.config.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count }
        guard configBytes <= PackageLimits.maxConfigBytes else { throw PackageError.invalidManifest("config is larger than \(PackageLimits.maxConfigBytes) bytes") }

        // Archive-level rules.
        let files = entries.filter { !$0.isDirectory }
        guard files.count <= PackageLimits.maxFiles else { throw PackageError.tooManyFiles(files.count) }
        var total: Int64 = 0
        var seen = Set<String>()
        for e in entries {
            let path = e.isDirectory ? String(e.path.dropLast()) : e.path
            guard isSafeRelativePath(path) else { throw PackageError.unsafePath(e.path) }
            guard !e.isSymlink else { throw PackageError.unsafePath("\(e.path) (symbolic link)") }
            guard seen.insert(path.lowercased()).inserted else { throw PackageError.invalidManifest("duplicate file “\(path)”") }
            if e.isDirectory { continue }
            guard PackageLimits.allowedExtensions.contains(fileExtension(path)) || path == "manifest.json" else { throw PackageError.forbiddenFile(path) }
            guard e.size <= PackageLimits.maxFileBytes else { throw PackageError.tooLarge("“\(path)” is \(e.size / 1_048_576) MB") }
            total += e.size
        }
        guard total <= PackageLimits.maxTotalBytes else { throw PackageError.tooLarge("\(total / 1_048_576) MB in total") }

        let names = Set(files.map(\.path))
        func requireFile(_ p: String) throws {
            guard isSafeRelativePath(p) else { throw PackageError.unsafePath(p) }
            guard names.contains(p) else { throw PackageError.missingFile(p) }
        }
        guard names.contains("manifest.json") else { throw PackageError.missingFile("manifest.json") }
        try requireFile(manifest.entry)
        let ext = fileExtension(manifest.entry)
        switch manifest.type {
        case .scene: guard ext == "json" else { throw PackageError.invalidManifest("a scene package's entry must be a .json file") }
        case .web: guard ["html", "htm"].contains(ext) else { throw PackageError.invalidManifest("a web package's entry must be an .html file") }
        case .video: guard ["mp4", "mov", "m4v"].contains(ext) else { throw PackageError.invalidManifest("a video package's entry must be .mp4, .mov or .m4v") }
        case .image: guard ["jpg", "jpeg", "png", "heic", "gif", "webp", "tif", "tiff", "bmp"].contains(ext) else { throw PackageError.invalidManifest("an image package's entry must be an image") }
        }
        if let preview = manifest.preview {
            try requireFile(preview)
            guard ["jpg", "jpeg", "png"].contains(fileExtension(preview)) else { throw PackageError.invalidManifest("the preview must be a .jpg or .png") }
        }
        for script in manifest.scripts {
            try requireFile(script)
            guard fileExtension(script) == "js" else { throw PackageError.invalidManifest("script “\(script)” is not a .js file") }
            if let size = files.first(where: { $0.path == script })?.size, size > PackageLimits.maxScriptBytes { throw PackageError.tooLarge("script “\(script)”") }
        }
        return manifest
    }

    /// Scene packages: every asset the scene mentions must be in the archive.
    public static func validateSceneAssets(_ scene: Scene, entries: [PackageEntry]) throws {
        let names = Set(entries.filter { !$0.isDirectory }.map(\.path))
        for asset in scene.referencedAssets {
            guard SafeFileName.isSafe(asset) else { throw PackageError.unsafePath(asset) }
            guard names.contains(asset) else { throw PackageError.missingFile(asset) }
            guard PackageLimits.mediaExtensions.contains(fileExtension(asset)) else { throw PackageError.forbiddenFile(asset) }
        }
    }
}
