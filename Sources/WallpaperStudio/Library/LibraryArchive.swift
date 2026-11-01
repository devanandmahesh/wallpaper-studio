import Foundation
import StudioCore

/// Export/import of the whole library as a single zip:
///
///     Wallpaper Studio Library/
///         manifest.json
///         library.sqlite
///         files/<uuid>.<ext>
///
/// Zips are created/extracted with the system `ditto`. Because an archive may come from anywhere, import
/// validates the entry names before extracting, rejects symlinks afterwards, never trusts file names from the
/// database as paths, and re-imports every file through the normal pipeline (decode check, hash, managed copy).
enum LibraryArchive {
    static let rootName = "Wallpaper Studio Library"
    static let formatID = "wallpaper-studio-library"
    static let maxEntries = 100_000

    struct Manifest: Codable { var format: String; var version: Int; var count: Int }

    enum ArchiveError: LocalizedError {
        case toolFailed(String)
        case invalid(String)
        var errorDescription: String? {
            switch self {
            case .toolFailed(let m): "Archive tool failed: \(m)"
            case .invalid(let m): "Not a valid library archive: \(m)"
            }
        }
    }

    /// Entry names that could escape the extraction folder.
    static func unsafeEntries(in names: [String]) -> [String] {
        names.filter { name in
            name.hasPrefix("/") || name.contains("\0") || name.split(separator: "/").contains("..")
        }
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String]) throws -> String {
        do { return String(decoding: try ProcessRunner.run(tool, args), as: UTF8.self) }
        catch let e as ProcessRunnerError { throw ArchiveError.toolFailed(e.localizedDescription) }
    }

    /// Sanity limits on an archive's *declared* contents, checked before extraction: no symbolic links, no absurd counts,
    /// and nothing that cannot fit on the disk. (`freeBytes` is injected so this can be tested.)
    static func checkListing(_ entries: [PackageEntry], freeBytes: Int64) throws {
        guard entries.count <= maxEntries else { throw ArchiveError.invalid("too many entries") }
        if let link = entries.first(where: \.isSymlink) { throw ArchiveError.invalid("contains a symbolic link (“\(link.path)”)") }
        let total = entries.reduce(Int64(0)) { $0 + $1.size }
        guard total <= freeBytes else { throw ArchiveError.invalid("it would need \(total / 1_048_576) MB, more than the free disk space") }
    }

    static func hasSymlink(in directory: URL) -> Bool {
        let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey])
        while let url = walker?.nextObject() as? URL {
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { return true }
        }
        return false
    }
}

extension LibraryModel {
    func exportLibrary(to destination: URL) async {
        guard let store else { return }
        busy = true
        defer { busy = false }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ws-export-\(UUID().uuidString)")
        let root = tmp.appendingPathComponent(LibraryArchive.rootName)
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("files"), withIntermediateDirectories: true)
            try await store.backup(to: root.appendingPathComponent("library.sqlite"))
            let live = records.filter { !$0.isTrashed }
            let sources = live.compactMap { r in fileURL(r).map { ($0, root.appendingPathComponent("files/\(r.fileName)")) } }
            let manifest = LibraryArchive.Manifest(format: LibraryArchive.formatID, version: 1, count: live.count)
            try await Task.detached(priority: .utility) {
                for (from, to) in sources {
                    // Hard links cost no extra disk space; fall back to a copy across volumes.
                    if (try? FileManager.default.linkItem(at: from, to: to)) == nil { try FileManager.default.copyItem(at: from, to: to) }
                }
                try JSONEncoder().encode(manifest).write(to: root.appendingPathComponent("manifest.json"))
                try? FileManager.default.removeItem(at: destination)
                try LibraryArchive.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", root.path, destination.path])
            }.value
            status = "Exported \(live.count) wallpaper(s) to \(destination.lastPathComponent)."
        } catch {
            fail(error)
        }
    }

    func importLibrary(from archive: URL) async {
        guard store != nil else { return }
        busy = true
        defer { busy = false }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ws-import-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            try await Task.detached(priority: .utility) {
                let listing = try LibraryArchive.run("/usr/bin/unzip", ["-Z1", archive.path])
                let names = listing.split(separator: "\n").map(String.init)
                let bad = LibraryArchive.unsafeEntries(in: names)
                guard bad.isEmpty else { throw LibraryArchive.ArchiveError.invalid("unsafe path “\(bad[0])”") }
                let detailed = PackageService.parseListing(try LibraryArchive.run("/usr/bin/unzip", ["-Z", "-l", archive.path]))
                let free = (try? FileManager.default.temporaryDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? Int64.max
                try LibraryArchive.checkListing(detailed, freeBytes: free)
                try LibraryArchive.run("/usr/bin/ditto", ["-x", "-k", archive.path, tmp.path])
                guard !LibraryArchive.hasSymlink(in: tmp) else { throw LibraryArchive.ArchiveError.invalid("contains symbolic links") }
            }.value

            let root = tmp.appendingPathComponent(LibraryArchive.rootName)
            let manifestData = try Data(contentsOf: root.appendingPathComponent("manifest.json"))
            let manifest = try JSONDecoder().decode(LibraryArchive.Manifest.self, from: manifestData)
            guard manifest.format == LibraryArchive.formatID, manifest.version == 1 else {
                throw LibraryArchive.ArchiveError.invalid("unknown format or version")
            }
            let source = try SQLiteLibraryStore(url: root.appendingPathComponent("library.sqlite"))
            let incoming = try await source.allWallpapers().filter { !$0.isTrashed }
            var idMap: [String: String] = [:]
            var skipped = 0
            for r in incoming {
                guard SafeFileName.isSafe(r.fileName) else { skipped += 1; continue }
                let file = root.appendingPathComponent("files/\(r.fileName)")
                guard FileManager.default.fileExists(atPath: file.path) else { skipped += 1; continue }
                do {
                    let new = try await importOne(file, move: true, template: r)
                    idMap[r.id] = new.id
                } catch { skipped += 1 }
            }
            await reload()

            let memberships = try await source.allMemberships()
            for c in try await source.collections() {
                var target = collections.first { $0.name.caseInsensitiveCompare(c.name) == .orderedSame }
                if target == nil { target = await createCollection(named: c.name) }
                guard let target else { continue }
                for old in memberships[c.id] ?? [] {
                    if let new = idMap[old] { try await store?.setMembership(wallpaper: new, collection: target.id, included: true) }
                }
            }
            await reload()
            status = "Imported \(incoming.count - skipped) wallpaper(s) from \(archive.lastPathComponent)" + (skipped > 0 ? " (\(skipped) skipped)." : ".")
        } catch {
            fail(error)
        }
    }
}
