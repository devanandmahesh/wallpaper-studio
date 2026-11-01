import Foundation

/// Persistent wallpaper library (SQLite). All access is serialised by the actor.
public actor SQLiteLibraryStore {
    private let db: SQLiteDatabase
    public static let schemaVersion = 1

    public init(url: URL) throws {
        db = try SQLiteDatabase(path: url.path)
        try Self.migrate(db)
    }

    // MARK: Schema

    private static func migrate(_ db: SQLiteDatabase) throws {
        let current = try db.query("PRAGMA user_version") { Int($0.int(0)) }.first ?? 0
        if current > schemaVersion {
            throw LibraryError.unsupported("This library was created by a newer version of the app (schema \(current)).")
        }
        try db.transaction {
            if current < 1 {
                try db.execute("""
                CREATE TABLE wallpapers(
                  id TEXT PRIMARY KEY, title TEXT NOT NULL, kind TEXT NOT NULL, file_name TEXT NOT NULL,
                  source TEXT NOT NULL, catalog_id INTEGER, category TEXT, tags TEXT NOT NULL DEFAULT '[]',
                  is_favorite INTEGER NOT NULL DEFAULT 0, date_added REAL NOT NULL, last_played REAL,
                  play_count INTEGER NOT NULL DEFAULT 0, size_bytes INTEGER NOT NULL DEFAULT 0,
                  width INTEGER NOT NULL DEFAULT 0, height INTEGER NOT NULL DEFAULT 0, duration REAL,
                  content_hash TEXT NOT NULL, deleted_at REAL)
                """)
                try db.execute("CREATE UNIQUE INDEX idx_wallpapers_hash ON wallpapers(content_hash)")
                try db.execute("CREATE INDEX idx_wallpapers_catalog ON wallpapers(catalog_id)")
                try db.execute("""
                CREATE TABLE collections(
                  id TEXT PRIMARY KEY, name TEXT NOT NULL UNIQUE COLLATE NOCASE, created REAL NOT NULL)
                """)
                try db.execute("""
                CREATE TABLE collection_items(
                  collection_id TEXT NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
                  wallpaper_id TEXT NOT NULL REFERENCES wallpapers(id) ON DELETE CASCADE,
                  PRIMARY KEY(collection_id, wallpaper_id))
                """)
            }
            try db.execute("PRAGMA user_version = \(schemaVersion)")
        }
    }

    // MARK: Wallpapers

    private static let columns = "id,title,kind,file_name,source,catalog_id,category,tags,is_favorite,date_added,last_played,play_count,size_bytes,width,height,duration,content_hash,deleted_at"

    private static func decode(_ r: SQLRow) throws -> WallpaperRecord {
        guard let kind = WallpaperKind(rawValue: r.text(2)), let source = WallpaperSource(rawValue: r.text(4)) else {
            throw LibraryError.database("Unknown kind or source in row \(r.text(0))")
        }
        let tags = (try? JSONDecoder().decode([String].self, from: Data(r.text(7).utf8))) ?? []
        return WallpaperRecord(
            id: r.text(0), title: r.text(1), kind: kind, fileName: r.text(3), source: source,
            catalogID: r.optInt(5), category: r.optText(6), tags: tags, isFavorite: r.int(8) != 0,
            dateAdded: Date(timeIntervalSince1970: r.double(9)),
            lastPlayed: r.optDouble(10).map(Date.init(timeIntervalSince1970:)),
            playCount: Int(r.int(11)), sizeBytes: r.int(12), width: Int(r.int(13)), height: Int(r.int(14)),
            duration: r.optDouble(15), contentHash: r.text(16),
            deletedAt: r.optDouble(17).map(Date.init(timeIntervalSince1970:)))
    }

    private static func params(_ w: WallpaperRecord) throws -> [SQLValue] {
        guard SafeFileName.isSafe(w.fileName) else { throw LibraryError.unsafeFileName(w.fileName) }
        let tags = String(decoding: (try? JSONEncoder().encode(w.tags)) ?? Data("[]".utf8), as: UTF8.self)
        return [.text(w.id), .text(w.title), .text(w.kind.rawValue), .text(w.fileName), .text(w.source.rawValue),
                SQLValue(w.catalogID), SQLValue(w.category), .text(tags), .int(w.isFavorite ? 1 : 0),
                .double(w.dateAdded.timeIntervalSince1970), SQLValue(w.lastPlayed?.timeIntervalSince1970),
                .int(Int64(w.playCount)), .int(w.sizeBytes), .int(Int64(w.width)), .int(Int64(w.height)),
                SQLValue(w.duration), .text(w.contentHash), SQLValue(w.deletedAt?.timeIntervalSince1970)]
    }

    public func allWallpapers() throws -> [WallpaperRecord] {
        try db.query("SELECT \(Self.columns) FROM wallpapers ORDER BY date_added DESC", [], Self.decode)
    }

    public func wallpaper(hash: String) throws -> WallpaperRecord? {
        try db.query("SELECT \(Self.columns) FROM wallpapers WHERE content_hash = ?", [.text(hash)], Self.decode).first
    }

    public func wallpaper(catalogID: Int) throws -> WallpaperRecord? {
        try db.query("SELECT \(Self.columns) FROM wallpapers WHERE catalog_id = ? LIMIT 1", [.int(Int64(catalogID))], Self.decode).first
    }

    public func insert(_ w: WallpaperRecord) throws {
        try db.execute("INSERT INTO wallpapers(\(Self.columns)) VALUES (\(Array(repeating: "?", count: 18).joined(separator: ",")))", try Self.params(w))
    }

    /// Updates every user-editable column. Throws `.notFound` if the row does not exist.
    public func update(_ w: WallpaperRecord) throws {
        try db.execute("""
        UPDATE wallpapers SET title=?, category=?, tags=?, is_favorite=?, last_played=?, play_count=?, deleted_at=?,
          file_name=?, size_bytes=?, width=?, height=?, duration=? WHERE id=?
        """, [.text(w.title), SQLValue(w.category), .text(String(decoding: (try? JSONEncoder().encode(w.tags)) ?? Data("[]".utf8), as: UTF8.self)),
              .int(w.isFavorite ? 1 : 0), SQLValue(w.lastPlayed?.timeIntervalSince1970), .int(Int64(w.playCount)),
              SQLValue(w.deletedAt?.timeIntervalSince1970), .text(w.fileName), .int(w.sizeBytes),
              .int(Int64(w.width)), .int(Int64(w.height)), SQLValue(w.duration), .text(w.id)])
        if db.changes == 0 { throw LibraryError.notFound }
    }

    public func recordPlay(id: String, at date: Date = Date()) throws {
        try db.execute("UPDATE wallpapers SET last_played=?, play_count=play_count+1 WHERE id=?", [.double(date.timeIntervalSince1970), .text(id)])
    }

    /// Permanently removes the row (and its collection memberships). Deleting the files is the caller's job.
    public func delete(id: String) throws {
        try db.execute("DELETE FROM wallpapers WHERE id=?", [.text(id)])
    }

    // MARK: Collections

    public func collections() throws -> [WallpaperCollection] {
        try db.query("SELECT id, name FROM collections ORDER BY name COLLATE NOCASE") { WallpaperCollection(id: $0.text(0), name: $0.text(1)) }
    }

    public func createCollection(name: String) throws -> WallpaperCollection {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw LibraryError.unsupported("Collection name cannot be empty.") }
        let c = WallpaperCollection(name: clean)
        do {
            try db.execute("INSERT INTO collections(id,name,created) VALUES (?,?,?)", [.text(c.id), .text(c.name), .double(Date().timeIntervalSince1970)])
        } catch LibraryError.database(let m) where m.contains("UNIQUE") {
            throw LibraryError.duplicateName
        }
        return c
    }

    public func deleteCollection(id: String) throws {
        try db.execute("DELETE FROM collections WHERE id=?", [.text(id)])
    }

    public func members(of collectionID: String) throws -> Set<String> {
        Set(try db.query("SELECT wallpaper_id FROM collection_items WHERE collection_id=?", [.text(collectionID)]) { $0.text(0) })
    }

    /// Every (collection id, wallpaper id) pair, for building filters and the detail view.
    public func allMemberships() throws -> [String: Set<String>] {
        var map: [String: Set<String>] = [:]
        for (c, w) in try db.query("SELECT collection_id, wallpaper_id FROM collection_items", [], { ($0.text(0), $0.text(1)) }) {
            map[c, default: []].insert(w)
        }
        return map
    }

    public func setMembership(wallpaper: String, collection: String, included: Bool) throws {
        if included {
            try db.execute("INSERT OR IGNORE INTO collection_items(collection_id, wallpaper_id) VALUES (?,?)", [.text(collection), .text(wallpaper)])
        } else {
            try db.execute("DELETE FROM collection_items WHERE collection_id=? AND wallpaper_id=?", [.text(collection), .text(wallpaper)])
        }
    }

    // MARK: Backup

    /// Writes a consistent copy of the database to `url` (which must not exist).
    public func backup(to url: URL) throws {
        try db.execute("VACUUM INTO ?", [.text(url.path)])
    }
}
