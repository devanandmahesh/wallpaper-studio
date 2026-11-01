import AppKit
import StudioCore
import StudioRender

/// The app's view of the wallpaper library: in-memory snapshot + persistence + file management.
/// Records live in SQLite; media lives in managed storage. All mutations go through here.
@MainActor
final class LibraryModel: ObservableObject {
    let storage: LibraryStorage
    private(set) var store: SQLiteLibraryStore?

    @Published private(set) var records: [WallpaperRecord] = []
    @Published private(set) var collections: [WallpaperCollection] = []
    @Published private(set) var memberships: [String: Set<String>] = [:]
    @Published var query = LibraryQuery()
    @Published var selectedID: String?
    @Published var status: String?
    @Published var busy = false
    @Published private(set) var loadError: String?

    /// Wired by the container: start playing a file on the desktop.
    var onPlay: ((URL) -> Void)?

    private let defaults: UserDefaults
    private let thumbCache = NSCache<NSString, NSImage>()
    static let trashRetention: TimeInterval = 30 * 24 * 3600

    init(storage: LibraryStorage = .standard, defaults: UserDefaults = .standard) {
        self.storage = storage
        self.defaults = defaults
        do {
            try storage.prepare()
            store = try SQLiteLibraryStore(url: storage.databaseURL)
        } catch {
            loadError = error.localizedDescription
            Log.library.error("Library failed to open: \(error.localizedDescription)")
        }
    }

    // MARK: Derived state

    var visible: [WallpaperRecord] {
        var members: Set<String> = []
        if case .collection(let id) = query.scope { members = memberships[id] ?? [] }
        return LibraryFilter.apply(records, query: query, members: members)
    }

    var tagCounts: [(tag: String, count: Int)] { LibraryFilter.tagCounts(records) }
    var trashCount: Int { records.filter(\.isTrashed).count }
    func record(id: String) -> WallpaperRecord? { records.first { $0.id == id } }
    func catalogRecord(_ catalogID: Int) -> WallpaperRecord? { records.first { $0.catalogID == catalogID } }
    func fileURL(_ r: WallpaperRecord) -> URL? { storage.fileURL(r) }
    func collectionIDs(containing wallpaperID: String) -> Set<String> {
        Set(memberships.filter { $0.value.contains(wallpaperID) }.keys)
    }

    // MARK: Loading

    func start() async {
        await reload()
        await purgeOldTrash()
        await migrateLegacyLibrary()
    }

    func reload() async {
        guard let store else { return }
        do {
            records = try await store.allWallpapers()
            collections = try await store.collections()
            memberships = try await store.allMemberships()
        } catch {
            fail(error)
        }
    }

    func fail(_ error: Error) {
        Log.library.error("\(error.localizedDescription)")
        status = error.localizedDescription
    }

    private func requireStore() throws -> SQLiteLibraryStore {
        if let store { return store }
        throw LibraryError.unsupported("The library is unavailable: \(loadError ?? "unknown error").")
    }

    // MARK: Import

    @discardableResult
    func importFile(_ url: URL, move: Bool = false, template: WallpaperRecord? = nil) async throws -> WallpaperRecord {
        let record = try await importOne(url, move: move, template: template)
        await reload()
        return record
    }

    /// Imports files and folders (one pass, up to 500 files) and reports a summary in `status`.
    func importMany(_ urls: [URL]) async {
        busy = true
        defer { busy = false }
        var files: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
                while let item = walker?.nextObject() as? URL, files.count < 500 {
                    if WallpaperKind.detect(pathExtension: item.pathExtension) != nil { files.append(item) }
                }
            } else {
                files.append(url)
            }
        }
        var imported = 0, skipped: [String] = []
        for file in files.prefix(500) {
            do { try await importOne(file, move: false, template: nil); imported += 1 }
            catch { skipped.append("\(file.lastPathComponent): \(error.localizedDescription)") }
        }
        await reload()
        var message = imported == 1 ? "Imported 1 wallpaper." : "Imported \(imported) wallpapers."
        if !skipped.isEmpty { message += " Skipped \(skipped.count): " + skipped.prefix(3).joined(separator: "; ") }
        status = message
    }

    /// Core import: validate, de-duplicate by content hash, copy/move into managed storage, probe, thumbnail, insert.
    @discardableResult
    func importOne(_ url: URL, move: Bool, template: WallpaperRecord?) async throws -> WallpaperRecord {
        let store = try requireStore()
        guard let kind = WallpaperKind.detect(pathExtension: url.pathExtension) else {
            throw LibraryError.unsupported("Unsupported file type “.\(url.pathExtension)”.")
        }
        // Packages are untrusted archives: validate the listing and manifest first, and say exactly what is wrong.
        let manifest: PackageManifest? = kind == .package
            ? try await Task.detached(priority: .utility) {
                do { return try PackageService.inspect(url).manifest } catch { throw LibraryError.unsupported(error.localizedDescription) }
            }.value
            : nil
        let hash: String = try await Task.detached(priority: .utility) {
            guard kind == .package || MediaInspector.canDisplay(url) else { throw LibraryError.unsupported("macOS cannot decode this file.") }
            return try MediaInspector.sha256(url)
        }.value

        if var existing = try await store.wallpaper(hash: hash) {
            if existing.isTrashed { existing.deletedAt = nil; try await store.update(existing) }
            if move { try? FileManager.default.removeItem(at: url) }
            return existing
        }

        let id = UUID().uuidString
        let fileName = "\(id).\(url.pathExtension.lowercased())"
        let destination = storage.filesDir.appendingPathComponent(fileName)
        let thumbURL = storage.thumbURL(id: id)

        let (size, probe): (Int64, MediaInspector.Probe) = try await Task.detached(priority: .utility) {
            if move { try FileManager.default.moveItem(at: url, to: destination) }
            else { try FileManager.default.copyItem(at: url, to: destination) }
            if kind == .package {
                // Unpack once, now, with the full post-extraction checks; a bad package never reaches the library.
                do { try PackageService.extract(destination, to: PackageService.contentsDirectory(for: destination)) }
                catch {
                    try? FileManager.default.removeItem(at: destination)
                    throw LibraryError.unsupported(error.localizedDescription)
                }
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? 0
            if let image = MediaInspector.thumbnail(destination, kind: kind), let jpeg = MediaInspector.jpegData(image) {
                try? jpeg.write(to: thumbURL)
            }
            return (size, await MediaInspector.probe(destination, kind: kind))
        }.value

        var record = template ?? WallpaperRecord(title: manifest?.name ?? url.deletingPathExtension().lastPathComponent, kind: kind,
                                                 fileName: fileName, source: .imported,
                                                 category: manifest == nil ? nil : "Package",
                                                 tags: manifest.map { ["package", $0.type.rawValue] } ?? [], contentHash: hash)
        record.id = id
        record.kind = kind
        record.fileName = fileName
        record.contentHash = hash
        record.sizeBytes = size
        record.width = probe.width
        record.height = probe.height
        record.duration = probe.duration
        if template == nil { record.dateAdded = Date() }
        do {
            try await store.insert(record)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.removeItem(at: PackageService.contentsDirectory(for: destination))
            try? FileManager.default.removeItem(at: thumbURL)
            throw error
        }
        return record
    }

    /// Called when a Discover download finishes: moves the file into the library with its catalog metadata.
    func adopt(download url: URL, item: CatalogItem) async {
        if var existing = catalogRecord(item.id), let store {
            // Re-download of an item that is in the trash: bring it back instead of duplicating.
            if existing.isTrashed { existing.deletedAt = nil; try? await store.update(existing); await reload() }
            try? FileManager.default.removeItem(at: url)
            return
        }
        let template = WallpaperRecord(title: item.title, kind: .video, fileName: "pending.mp4", source: .catalog,
                                       catalogID: item.id, category: item.category,
                                       tags: [item.category.lowercased(), "mixkit", "\(item.quality)p"], contentHash: "pending")
        do { try await importFile(url, move: true, template: template) }
        catch { fail(error); try? FileManager.default.removeItem(at: url) }
    }

    /// Adds a built-in GPU scene to the library (once; re-adding returns the existing item) and returns it.
    @discardableResult
    func installBuiltIn(_ scene: Scene) async -> WallpaperRecord? {
        do {
            let data = try SceneCodec.encode(scene)
            let file = storage.downloadsDir.appendingPathComponent("\(scene.name).\(SceneCodec.fileExtension)")
            try FileManager.default.createDirectory(at: storage.downloadsDir, withIntermediateDirectories: true)
            try data.write(to: file)
            let template = WallpaperRecord(title: scene.name, kind: .scene, fileName: "pending.wsscene", source: .imported,
                                           category: "Generated", tags: ["generated", "gpu"], contentHash: "pending")
            return try await importFile(file, move: true, template: template)
        } catch {
            fail(error)
            return nil
        }
    }

    // MARK: Editing

    private func mutate(_ id: String, _ change: (inout WallpaperRecord) -> Void) async {
        guard var r = record(id: id), let store else { return }
        change(&r)
        do { try await store.update(r); await reload() } catch { fail(error) }
    }

    func toggleFavorite(_ id: String) async { await mutate(id) { $0.isFavorite.toggle() } }
    func rename(_ id: String, to title: String) async {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !clean.isEmpty { await mutate(id) { $0.title = clean } }
    }
    func setTags(_ id: String, text: String) async { await mutate(id) { $0.tags = TagParser.parse(text) } }

    func setMembership(wallpaper: String, collection: String, included: Bool) async {
        guard let store else { return }
        do { try await store.setMembership(wallpaper: wallpaper, collection: collection, included: included); await reload() }
        catch { fail(error) }
    }

    @discardableResult
    func createCollection(named name: String) async -> WallpaperCollection? {
        guard let store else { return nil }
        do {
            let c = try await store.createCollection(name: name)
            await reload()
            return c
        } catch { fail(error); return nil }
    }

    func deleteCollection(_ id: String) async {
        guard let store else { return }
        do {
            try await store.deleteCollection(id: id)
            if query.scope == .collection(id) { query.scope = .all }
            await reload()
        } catch { fail(error) }
    }

    // MARK: Trash

    func trash(_ id: String) async { await mutate(id) { $0.deletedAt = Date() } }
    func restore(_ id: String) async { await mutate(id) { $0.deletedAt = nil } }

    func deleteForever(_ id: String) async {
        guard let r = record(id: id), let store else { return }
        do {
            try await store.delete(id: id)
            if let url = fileURL(r) {
                try? FileManager.default.removeItem(at: url)
                if r.kind == .package { try? FileManager.default.removeItem(at: PackageService.contentsDirectory(for: url)) }
            }
            try? FileManager.default.removeItem(at: storage.thumbURL(id: id))
            thumbCache.removeObject(forKey: id as NSString)
            if selectedID == id { selectedID = nil }
            await reload()
        } catch { fail(error) }
    }

    func emptyTrash() async {
        for r in records where r.isTrashed { await deleteForever(r.id) }
    }

    private func purgeOldTrash() async {
        let cutoff = Date().addingTimeInterval(-Self.trashRetention)
        for r in records where (r.deletedAt ?? .distantFuture) < cutoff { await deleteForever(r.id) }
    }

    // MARK: Playing

    func play(_ r: WallpaperRecord) async {
        guard let url = fileURL(r), FileManager.default.fileExists(atPath: url.path) else {
            status = "The file for “\(r.title)” is missing from the library."
            return
        }
        onPlay?(url)
        try? await store?.recordPlay(id: r.id)
        await reload()
    }

    func isPlaying(_ r: WallpaperRecord, current: URL?) -> Bool {
        guard let current, let url = fileURL(r) else { return false }
        return current.standardizedFileURL.path == url.standardizedFileURL.path
    }

    // MARK: Thumbnails

    /// Drops in-memory thumbnails (they are re-read from disk when needed).
    func trimCaches() { thumbCache.removeAllObjects() }

    func thumbnail(for r: WallpaperRecord) async -> NSImage? {
        if let hit = thumbCache.object(forKey: r.id as NSString) { return hit }
        let thumbURL = storage.thumbURL(id: r.id)
        if let image = NSImage(contentsOf: thumbURL) { thumbCache.setObject(image, forKey: r.id as NSString); return image }
        guard let file = fileURL(r) else { return nil }
        let kind = r.kind
        let image: NSImage? = await Task.detached(priority: .utility) {
            guard let cg = MediaInspector.thumbnail(file, kind: kind) else { return nil }
            if let jpeg = MediaInspector.jpegData(cg) { try? jpeg.write(to: thumbURL) }
            return NSImage(cgImage: cg, size: .zero)
        }.value
        if let image { thumbCache.setObject(image, forKey: r.id as NSString) }
        return image
    }

    // MARK: Migration from the pre-database layout

    private func migrateLegacyLibrary() async {
        guard !defaults.bool(forKey: "libraryMigratedV1") else { return }
        let base = storage.root.deletingLastPathComponent()
        let legacyDir = base.appendingPathComponent("Videos", isDirectory: true)
        var count = 0

        if let files = try? FileManager.default.contentsOfDirectory(at: legacyDir, includingPropertiesForKeys: nil) {
            for file in files where file.lastPathComponent.hasPrefix("mixkit-") && file.pathExtension == "mp4" {
                let idText = file.deletingPathExtension().lastPathComponent.dropFirst("mixkit-".count)
                if let id = Int(idText), let item = Catalog.items.first(where: { $0.id == id }) {
                    await adopt(download: file, item: item)
                    count += 1
                }
            }
        }
        for path in defaults.stringArray(forKey: "userFiles") ?? [] where FileManager.default.fileExists(atPath: path) {
            if (try? await importFile(URL(fileURLWithPath: path))) != nil { count += 1 }
        }
        defaults.removeObject(forKey: "userFiles")
        defaults.set(true, forKey: "libraryMigratedV1")
        if count > 0 { status = "Moved \(count) existing wallpaper(s) into the new library." }
    }
}
