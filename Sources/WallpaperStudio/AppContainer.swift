/// Composition root. Built once at launch and handed to the UI, so views never reach for globals.
/// Services are added here as later phases introduce them (display manager, ...).
@MainActor
final class AppContainer {
    let engine: AppDelegate
    let library: LibraryModel
    let downloads: DownloadManager

    init(engine: AppDelegate) {
        self.engine = engine
        let library = LibraryModel()
        self.library = library
        self.downloads = DownloadManager(library: library)
        library.onPlay = { [weak engine] url in engine?.loadSource(url) }
    }
}
