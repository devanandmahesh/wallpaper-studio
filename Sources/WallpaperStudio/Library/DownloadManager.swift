import Foundation
import StudioCore

/// Downloads Discover wallpapers into the library's downloads folder, then hands them to the library.
@MainActor
final class DownloadManager: ObservableObject {
    @Published private(set) var progress: [Int: Double] = [:]
    @Published private(set) var failed: Set<Int> = []

    private let library: LibraryModel
    private var tasks: [Int: URLSessionDownloadTask] = [:]
    private var observers: [Int: NSKeyValueObservation] = [:]

    init(library: LibraryModel) { self.library = library }

    func isDownloading(_ item: CatalogItem) -> Bool { progress[item.id] != nil }

    func download(_ item: CatalogItem) {
        guard progress[item.id] == nil, library.catalogRecord(item.id)?.isTrashed != false else { return }
        failed.remove(item.id)
        progress[item.id] = 0
        let id = item.id
        let folder = library.storage.downloadsDir
        let dest = folder.appendingPathComponent(item.fileName)
        let task = URLSession.shared.downloadTask(with: item.videoURL) { [weak self] tmp, response, error in
            var ok = false
            if let tmp, error == nil, (response as? HTTPURLResponse)?.statusCode == 200 {
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: dest)
                ok = (try? FileManager.default.moveItem(at: tmp, to: dest)) != nil
            }
            let cancelled = (error as? URLError)?.code == .cancelled
            Task { @MainActor in
                guard let self else { return }
                self.progress[id] = nil
                self.observers[id] = nil
                self.tasks[id] = nil
                if ok { await self.library.adopt(download: dest, item: item) }
                else if !cancelled { self.failed.insert(id); Log.download.error("Download failed for \(item.title)") }
            }
        }
        observers[id] = task.progress.observe(\.fractionCompleted) { [weak self] p, _ in
            let fraction = p.fractionCompleted
            Task { @MainActor in if let self, self.progress[id] != nil { self.progress[id] = fraction } }
        }
        tasks[id] = task
        task.resume()
    }

    func cancel(_ item: CatalogItem) { tasks[item.id]?.cancel() }
}
