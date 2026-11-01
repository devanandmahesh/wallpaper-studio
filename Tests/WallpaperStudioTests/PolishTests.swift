import Testing
import AppKit
import StudioCore
@testable import WallpaperStudio

@Suite struct ProcessRunnerTests {
    @Test func aToolThatFloodsStandardErrorDoesNotDeadlock() throws {
        // 600 KB on stderr (far beyond a pipe buffer) followed by output: reading one pipe at a time would hang forever.
        let out = try ProcessRunner.run("/bin/sh", ["-c", "head -c 600000 /dev/zero | tr '\\0' 'x' >&2; echo finished"])
        #expect(String(decoding: out, as: UTF8.self).contains("finished"))
    }

    @Test func aToolThatFloodsStandardOutputAlsoCompletes() throws {
        let out = try ProcessRunner.run("/bin/sh", ["-c", "head -c 3000000 /dev/zero"])
        #expect(out.count == 3_000_000)
    }

    @Test func failuresCarryTheToolsMessageAndAreCapped() {
        do {
            _ = try ProcessRunner.run("/bin/sh", ["-c", "echo 'something broke' >&2; exit 3"])
            Issue.record("should have thrown")
        } catch let e as ProcessRunnerError {
            if case .failed(let status, let message) = e { #expect(status == 3 && message == "something broke") }
        } catch { Issue.record("wrong error \(error)") }
        #expect(throws: (any Error).self) { try ProcessRunner.run("/nonexistent/tool", []) }
    }
}

@Suite struct HardeningTests {
    @Test func aSceneEntryThatClaimsToBeHugeIsRefusedBeforeItIsRead() throws {
        let manifest = Fixtures.manifestData(.init())
        let zip = Fixtures.zipFile([Fixtures.ZipItem(name: "manifest.json", data: manifest),
                                    Fixtures.ZipItem(name: "scene.json", data: Data("{}".utf8), declaredSize: 200_000_000)])
        #expect(throws: PackageError.self) { try PackageService.inspect(zip) }
    }

    @Test func libraryArchivesWithLinksOrImpossibleSizesAreRefusedUpFront() throws {
        let entries = [PackageEntry(path: "library.sqlite", size: 10), PackageEntry(path: "files/a.mp4", size: 5_000)]
        #expect(throws: Never.self) { try LibraryArchive.checkListing(entries, freeBytes: 1_000_000) }
        #expect(throws: LibraryArchive.ArchiveError.self) { try LibraryArchive.checkListing(entries, freeBytes: 100) }          // does not fit
        #expect(throws: LibraryArchive.ArchiveError.self) { try LibraryArchive.checkListing(entries + [PackageEntry(path: "x", size: 1, isSymlink: true)], freeBytes: .max) }
        let many = (0...LibraryArchive.maxEntries).map { PackageEntry(path: "f\($0)", size: 1) }
        #expect(throws: LibraryArchive.ArchiveError.self) { try LibraryArchive.checkListing(many, freeBytes: .max) }
    }

    @MainActor
    @Test func aLibraryArchiveWithASymbolicLinkNeverImports() async throws {
        let name = UUID().uuidString
        let model = LibraryModel(storage: LibraryStorage(root: FileManager.default.temporaryDirectory.appendingPathComponent("hard-\(name)/LiveWallpaper/Library")),
                                 defaults: UserDefaults(suiteName: "hard-\(name)")!)
        let zip = Fixtures.zipFile([Fixtures.ZipItem(name: "Wallpaper Studio Library/manifest.json", data: Data("{}".utf8)),
                                    Fixtures.ZipItem(name: "Wallpaper Studio Library/files/evil", data: Data("/etc/passwd".utf8), isSymlink: true)])
        await model.importLibrary(from: zip)
        #expect(model.records.isEmpty && model.status?.contains("symbolic link") == true, "\(model.status ?? "nil")")
    }

    @Test func playabilityChecksUseTheModernLoader() {
        #expect(MediaInspector.isPlayable(Fixtures.mp4()))
        let fake = Fixtures.dir.appendingPathComponent("fake-\(UUID().uuidString).mp4")
        try? Data("not a video".utf8).write(to: fake)
        #expect(!MediaInspector.isPlayable(fake))
        #expect(!MediaInspector.isPlayable(Fixtures.dir.appendingPathComponent("missing-\(UUID().uuidString).mp4")))
    }
}

@MainActor
@Suite struct PollingAndSaveTests {
    func controller(_ sys: FakeSystem) -> PerformanceController {
        let name = "poll-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return PerformanceController(readers: sys.readers, defaults: d)
    }

    @Test func onlyTheAdaptiveProfileWakesTheCPUPeriodically() {
        let c = controller(FakeSystem())
        c.start(interval: 1)
        #expect(!c.isPolling)                       // Balanced: events only
        c.profile = .adaptive
        #expect(c.isPolling)
        c.profile = .batterySaver
        #expect(!c.isPolling)
        c.profile = .adaptive
        c.stop()
        #expect(!c.isPolling)
        c.start(interval: 1)
        #expect(c.isPolling)
        c.stop()
    }

    @Test func eventsStillUpdateTheLimitsWithoutAnyTimer() {
        let sys = FakeSystem()
        let c = controller(sys)
        c.start(interval: 1)
        sys.thermal = .serious
        c.poke()
        #expect(!c.isPolling && c.decision.fpsCap == 15)
        c.stop()
    }

    @Test func quittingRightAfterAnEditLosesNothing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("quit-\(UUID().uuidString)")
        let p = try EditorProject.create(in: root, from: .blank())
        p.setSceneName("Edited just before quitting")                      // autosave is debounced; it has not fired yet
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
        let saved = try SceneCodec.decode(Data(contentsOf: p.directory.appendingPathComponent("scene.json")))
        #expect(saved.name == "Edited just before quitting")
    }
}
