import Testing
import Foundation
import StudioCore
@testable import WallpaperStudio

/// Each test gets its own storage folder and its own UserDefaults suite.
@MainActor
private func makeModel(name: String = UUID().uuidString) -> (LibraryModel, LibraryStorage) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ws-lib-\(name)/LiveWallpaper/Library")
    let storage = LibraryStorage(root: root)
    let defaults = UserDefaults(suiteName: "ws-test-\(name)")!
    defaults.removePersistentDomain(forName: "ws-test-\(name)")
    return (LibraryModel(storage: storage, defaults: defaults), storage)
}

@MainActor
@Suite struct LibraryModelTests {
    @Test func importCopiesIntoManagedStorageWithThumbnailAndMetadata() async throws {
        let (model, storage) = makeModel()
        let source = Fixtures.png(400, 200)
        let r = try await model.importFile(source)
        #expect(r.kind == .image && r.width == 400 && r.height == 200 && r.sizeBytes > 0)
        #expect(FileManager.default.fileExists(atPath: storage.filesDir.appendingPathComponent(r.fileName).path))
        #expect(FileManager.default.fileExists(atPath: storage.thumbURL(id: r.id).path))
        #expect(FileManager.default.fileExists(atPath: source.path))           // original untouched
        #expect(model.records.map(\.id) == [r.id])
        #expect(await model.thumbnail(for: r) != nil)
    }

    @Test func importingTheSameContentTwiceReturnsTheExistingRecord() async throws {
        let (model, _) = makeModel()
        let a = Fixtures.png(100, 100)
        let b = Fixtures.dir.appendingPathComponent("copy-of-\(UUID().uuidString).png")
        try FileManager.default.copyItem(at: a, to: b)
        let first = try await model.importFile(a)
        let second = try await model.importFile(b)
        #expect(first.id == second.id)
        #expect(model.records.count == 1)
        await model.trash(first.id)
        let third = try await model.importFile(a)      // re-importing something in the trash brings it back
        #expect(third.id == first.id && model.record(id: first.id)?.isTrashed == false)
    }

    @Test func unsupportedAndCorruptFilesAreRejectedWithoutLeavingFiles() async throws {
        let (model, storage) = makeModel()
        let txt = Fixtures.dir.appendingPathComponent("notes.txt")
        try Data("hi".utf8).write(to: txt)
        let broken = Fixtures.dir.appendingPathComponent("broken-\(UUID().uuidString).png")
        try Data("not an image".utf8).write(to: broken)
        await #expect(throws: LibraryError.self) { try await model.importFile(txt) }
        await #expect(throws: LibraryError.self) { try await model.importFile(broken) }
        #expect(model.records.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: storage.filesDir.path).isEmpty)
    }

    @Test func trashRestoreAndDeleteForeverManageFiles() async throws {
        let (model, storage) = makeModel()
        let r = try await model.importFile(Fixtures.png(64, 64))
        let file = storage.filesDir.appendingPathComponent(r.fileName)
        await model.trash(r.id)
        #expect(model.record(id: r.id)?.isTrashed == true && FileManager.default.fileExists(atPath: file.path))
        await model.restore(r.id)
        #expect(model.record(id: r.id)?.isTrashed == false)
        await model.trash(r.id)
        await model.emptyTrash()
        #expect(model.records.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(!FileManager.default.fileExists(atPath: storage.thumbURL(id: r.id).path))
    }

    @Test func importManyWalksFoldersAndReportsSkippedFiles() async throws {
        let (model, _) = makeModel()
        let dir = Fixtures.dir.appendingPathComponent("batch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Fixtures.png(30, 30), to: dir.appendingPathComponent("a.png"))
        try FileManager.default.copyItem(at: Fixtures.gif(frames: 3, delay: 0.1), to: dir.appendingPathComponent("b.gif"))
        try Data("x".utf8).write(to: dir.appendingPathComponent("bad.png"))
        await model.importMany([dir])
        #expect(Set(model.records.map(\.kind)) == [.image, .animatedImage])
        #expect(model.status?.contains("Imported 2") == true && model.status?.contains("Skipped 1") == true)
    }

    @Test func metadataAndCollectionsSurviveRestart() async throws {
        let name = UUID().uuidString
        let (model, storage) = makeModel(name: name)
        let r = try await model.importFile(Fixtures.png(50, 50))
        await model.rename(r.id, to: "  Blue Square ")
        await model.setTags(r.id, text: "Calm, BLUE ,calm")
        await model.toggleFavorite(r.id)
        let c = try #require(await model.createCollection(named: "Focus"))
        await model.setMembership(wallpaper: r.id, collection: c.id, included: true)

        let reopened = LibraryModel(storage: storage, defaults: UserDefaults(suiteName: "ws-test-\(name)")!)
        await reopened.reload()
        let back = try #require(reopened.records.first)
        #expect(back.title == "Blue Square" && back.tags == ["calm", "blue"] && back.isFavorite)
        #expect(reopened.collections.map(\.name) == ["Focus"])
        #expect(reopened.collectionIDs(containing: r.id) == [c.id])
    }

    @Test func playingRecordsTheSessionAndCallsThePlayer() async throws {
        let (model, storage) = makeModel()
        let r = try await model.importFile(Fixtures.png(20, 20))
        var played: URL?
        model.onPlay = { played = $0 }
        await model.play(r)
        #expect(played == storage.filesDir.appendingPathComponent(r.fileName))
        #expect(model.record(id: r.id)?.playCount == 1 && model.record(id: r.id)?.lastPlayed != nil)
        try FileManager.default.removeItem(at: storage.filesDir.appendingPathComponent(r.fileName))
        played = nil
        await model.play(r)
        #expect(played == nil && model.status?.contains("missing") == true)
    }

    @Test func exportThenImportRoundTripsEverything() async throws {
        let (source, _) = makeModel()
        let r1 = try await source.importFile(Fixtures.png(80, 40))
        let r2 = try await source.importFile(Fixtures.gif(frames: 4, delay: 0.1))
        await source.rename(r1.id, to: "Wide")
        await source.setTags(r1.id, text: "one, two")
        await source.toggleFavorite(r2.id)
        let c = try #require(await source.createCollection(named: "Pack"))
        await source.setMembership(wallpaper: r1.id, collection: c.id, included: true)
        let zip = Fixtures.dir.appendingPathComponent("export-\(UUID().uuidString).zip")
        await source.exportLibrary(to: zip)
        #expect(FileManager.default.fileExists(atPath: zip.path), "\(source.status ?? "")")

        let (target, storage) = makeModel()
        await target.importLibrary(from: zip)
        #expect(target.records.count == 2, "\(target.status ?? "")")
        let wide = try #require(target.records.first { $0.title == "Wide" })
        #expect(wide.tags == ["one", "two"] && wide.width == 80)
        #expect(target.records.first { $0.kind == .animatedImage }?.isFavorite == true)
        #expect(target.collections.map(\.name) == ["Pack"])
        #expect(target.memberships[target.collections[0].id] == [wide.id])
        #expect(FileManager.default.fileExists(atPath: storage.filesDir.appendingPathComponent(wide.fileName).path))
        // Importing the same archive again must not duplicate anything.
        await target.importLibrary(from: zip)
        #expect(target.records.count == 2 && target.collections.count == 1)
    }

    @Test func archiveWithPathTraversalIsRefusedBeforeExtraction() async throws {
        let (model, _) = makeModel()
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("evil-\(UUID().uuidString).txt")
        let zip = Fixtures.dir.appendingPathComponent("evil-\(UUID().uuidString).zip")
        try Fixtures.zipWithEmptyEntry(named: "../\(marker.lastPathComponent)").write(to: zip)
        await model.importLibrary(from: zip)
        #expect(model.status?.contains("unsafe") == true, "\(model.status ?? "nil")")
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(model.records.isEmpty)
    }

    @Test func randomZipThatIsNotALibraryIsRefused() async throws {
        let (model, _) = makeModel()
        let zip = Fixtures.dir.appendingPathComponent("plain-\(UUID().uuidString).zip")
        try Fixtures.zipWithEmptyEntry(named: "hello.txt").write(to: zip)
        await model.importLibrary(from: zip)
        #expect(model.status != nil && model.records.isEmpty)
    }

    @Test func legacyDownloadsAreAdoptedOnce() async throws {
        let name = UUID().uuidString
        let (model, storage) = makeModel(name: name)
        let legacy = storage.root.deletingLastPathComponent().appendingPathComponent("Videos")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Fixtures.mp4(), to: legacy.appendingPathComponent("mixkit-2213.mp4"))
        await model.start()
        let r = try #require(model.catalogRecord(2213))
        #expect(r.title == "Forest Waterfall" && r.category == "Nature" && r.tags.contains("mixkit") && r.source == .catalog)
        #expect(r.kind == .video && r.width == 320 && r.height == 180)
        #expect(!FileManager.default.fileExists(atPath: legacy.appendingPathComponent("mixkit-2213.mp4").path))
        await model.start()                       // second run changes nothing
        #expect(model.records.count == 1)
    }
}
