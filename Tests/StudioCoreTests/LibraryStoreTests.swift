import Testing
import Foundation
@testable import StudioCore

private func tempDB() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("lib-\(UUID().uuidString).sqlite")
}

private func record(_ title: String, hash: String? = nil, kind: WallpaperKind = .video, tags: [String] = [], fav: Bool = false) -> WallpaperRecord {
    WallpaperRecord(title: title, kind: kind, fileName: "\(UUID().uuidString).mp4", source: .imported,
                    tags: tags, isFavorite: fav, contentHash: hash ?? UUID().uuidString)
}

@Suite struct LibraryStoreTests {
    @Test func insertAndReadBackEveryField() async throws {
        let store = try SQLiteLibraryStore(url: tempDB())
        let r = WallpaperRecord(title: "Sunset", kind: .image, fileName: "a.png", source: .catalog, catalogID: 42,
                                category: "Nature", tags: ["warm", "sky"], isFavorite: true,
                                dateAdded: Date(timeIntervalSince1970: 1000), lastPlayed: Date(timeIntervalSince1970: 2000),
                                playCount: 3, sizeBytes: 123, width: 1920, height: 1080, duration: 4.5, contentHash: "h1")
        try await store.insert(r)
        let all = try await store.allWallpapers()
        #expect(all == [r])
    }

    @Test func dataSurvivesReopening() async throws {
        let url = tempDB()
        do {
            let store = try SQLiteLibraryStore(url: url)
            try await store.insert(record("Persisted", hash: "p"))
        }
        let reopened = try SQLiteLibraryStore(url: url)
        #expect(try await reopened.allWallpapers().map(\.title) == ["Persisted"])
    }

    @Test func duplicateContentHashIsRejectedAndFindable() async throws {
        let store = try SQLiteLibraryStore(url: tempDB())
        try await store.insert(record("One", hash: "same"))
        await #expect(throws: LibraryError.self) { try await store.insert(record("Two", hash: "same")) }
        #expect(try await store.wallpaper(hash: "same")?.title == "One")
        #expect(try await store.wallpaper(hash: "missing") == nil)
    }

    @Test func updateChangesEditableFieldsAndMissingRowThrows() async throws {
        let store = try SQLiteLibraryStore(url: tempDB())
        var r = record("Old")
        try await store.insert(r)
        r.title = "New"; r.tags = ["a"]; r.isFavorite = true; r.deletedAt = Date(timeIntervalSince1970: 5)
        try await store.update(r)
        let back = try #require(try await store.allWallpapers().first)
        #expect(back.title == "New" && back.tags == ["a"] && back.isFavorite && back.isTrashed)
        r.id = "nope"
        await #expect(throws: LibraryError.notFound) { try await store.update(r) }
    }

    @Test func recordPlayCountsAndStampsTime() async throws {
        let store = try SQLiteLibraryStore(url: tempDB())
        let r = record("Played")
        try await store.insert(r)
        try await store.recordPlay(id: r.id)
        try await store.recordPlay(id: r.id)
        let back = try #require(try await store.allWallpapers().first)
        #expect(back.playCount == 2 && back.lastPlayed != nil)
    }

    @Test func collectionsMembershipAndCascade() async throws {
        let store = try SQLiteLibraryStore(url: tempDB())
        let a = record("A"), b = record("B")
        try await store.insert(a); try await store.insert(b)
        let c = try await store.createCollection(name: "  Chill ")
        #expect(c.name == "Chill")
        try await store.setMembership(wallpaper: a.id, collection: c.id, included: true)
        try await store.setMembership(wallpaper: a.id, collection: c.id, included: true)   // idempotent
        try await store.setMembership(wallpaper: b.id, collection: c.id, included: true)
        #expect(try await store.members(of: c.id) == [a.id, b.id])
        try await store.setMembership(wallpaper: b.id, collection: c.id, included: false)
        #expect(try await store.allMemberships() == [c.id: [a.id]])
        try await store.delete(id: a.id)                       // removing a wallpaper clears its memberships
        #expect(try await store.members(of: c.id).isEmpty)
        try await store.deleteCollection(id: c.id)
        #expect(try await store.collections().isEmpty)
    }

    @Test func collectionNamesAreUniqueIgnoringCaseAndNonEmpty() async throws {
        let store = try SQLiteLibraryStore(url: tempDB())
        _ = try await store.createCollection(name: "Dark")
        await #expect(throws: LibraryError.duplicateName) { try await store.createCollection(name: "dark") }
        await #expect(throws: LibraryError.self) { try await store.createCollection(name: "   ") }
    }

    @Test func pathTraversalFileNamesAreRefused() async throws {
        let store = try SQLiteLibraryStore(url: tempDB())
        var r = record("Evil")
        for name in ["../../etc/passwd", "a/b.mp4", "", ".."] {
            r.fileName = name
            await #expect(throws: LibraryError.self) { try await store.insert(r) }
        }
    }

    @Test func backupProducesAReadableCopy() async throws {
        let store = try SQLiteLibraryStore(url: tempDB())
        try await store.insert(record("Backed up", hash: "b"))
        let copy = tempDB()
        try await store.backup(to: copy)
        let restored = try SQLiteLibraryStore(url: copy)
        #expect(try await restored.allWallpapers().map(\.title) == ["Backed up"])
    }

    @Test func newerSchemaIsRefusedInsteadOfCorrupted() async throws {
        let url = tempDB()
        _ = try SQLiteLibraryStore(url: url)
        let db = try SQLiteDatabase(path: url.path)
        try db.execute("PRAGMA user_version = 99")
        #expect(throws: LibraryError.self) { try SQLiteLibraryStore(url: url) }
    }
}

@Suite struct LibraryFilterTests {
    let now = Date()
    var sample: [WallpaperRecord] {
        [
            WallpaperRecord(title: "Forest Waterfall", kind: .video, fileName: "1.mp4", source: .catalog, category: "Nature", tags: ["water", "green"], isFavorite: true, dateAdded: now, lastPlayed: now, playCount: 5, contentHash: "1"),
            WallpaperRecord(title: "Café Night", kind: .image, fileName: "2.png", source: .imported, category: "City", tags: ["night"], dateAdded: now.addingTimeInterval(-100), contentHash: "2"),
            WallpaperRecord(title: "Neon GIF", kind: .animatedImage, fileName: "3.gif", source: .imported, tags: ["night", "neon"], dateAdded: now.addingTimeInterval(-200), lastPlayed: now.addingTimeInterval(-50), playCount: 9, contentHash: "3"),
            WallpaperRecord(title: "Old", kind: .video, fileName: "4.mp4", source: .imported, dateAdded: now.addingTimeInterval(-300), contentHash: "4", deletedAt: now),
        ]
    }

    @Test func trashIsSeparateFromEverythingElse() {
        var q = LibraryQuery()
        #expect(LibraryFilter.apply(sample, query: q).count == 3)
        q.scope = .trash
        #expect(LibraryFilter.apply(sample, query: q).map(\.title) == ["Old"])
    }

    @Test func searchIgnoresCaseAndAccentsAndMatchesTagsAndCategory() {
        var q = LibraryQuery()
        q.search = "cafe"
        #expect(LibraryFilter.apply(sample, query: q).map(\.title) == ["Café Night"])
        q.search = "NATURE water"
        #expect(LibraryFilter.apply(sample, query: q).map(\.title) == ["Forest Waterfall"])
        q.search = "neon night"
        #expect(LibraryFilter.apply(sample, query: q).map(\.title) == ["Neon GIF"])
        q.search = "zzz"
        #expect(LibraryFilter.apply(sample, query: q).isEmpty)
    }

    @Test func favoritesTagKindAndCollectionScopes() {
        var q = LibraryQuery()
        q.scope = .favorites
        #expect(LibraryFilter.apply(sample, query: q).map(\.title) == ["Forest Waterfall"])
        q = LibraryQuery(); q.tag = "night"
        #expect(Set(LibraryFilter.apply(sample, query: q).map(\.title)) == ["Café Night", "Neon GIF"])
        q = LibraryQuery(); q.kind = .image
        #expect(LibraryFilter.apply(sample, query: q).map(\.title) == ["Café Night"])
        q = LibraryQuery(); q.scope = .collection("c")
        let s = sample
        #expect(LibraryFilter.apply(s, query: q, members: [s[1].id]).map(\.title) == ["Café Night"])
    }

    @Test func recentIsOrderedByLastPlayedAndSkipsNeverPlayed() {
        var q = LibraryQuery(); q.scope = .recent
        #expect(LibraryFilter.apply(sample, query: q).map(\.title) == ["Forest Waterfall", "Neon GIF"])
    }

    @Test func sortingModes() {
        var q = LibraryQuery()
        q.sort = .title
        #expect(LibraryFilter.apply(sample, query: q).map(\.title) == ["Café Night", "Forest Waterfall", "Neon GIF"])
        q.sort = .mostPlayed
        #expect(LibraryFilter.apply(sample, query: q).first?.title == "Neon GIF")
        q.sort = .oldest
        #expect(LibraryFilter.apply(sample, query: q).first?.title == "Neon GIF")
    }

    @Test func tagCountsIgnoreTrashAndSortByUse() {
        let counts = LibraryFilter.tagCounts(sample)
        #expect(counts.first?.tag == "night" && counts.first?.count == 2)
    }

    @Test func tagParserNormalises() {
        #expect(TagParser.parse(" Sky, sky ,, Night\nOcean ") == ["sky", "night", "ocean"])
    }

    @Test func safeFileNames() {
        #expect(SafeFileName.isSafe("abc.mp4"))
        #expect(!SafeFileName.isSafe("../x") && !SafeFileName.isSafe("a/b") && !SafeFileName.isSafe(".."))
    }
}
