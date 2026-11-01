import Foundation
import StudioCore

/// Search and download for the Pexels / Pixabay grid. The sites' own APIs are used with the user's free key;
/// a clip is downloaded only when its Add button is pressed.
@MainActor
final class StockModel: ObservableObject {
    @Published var provider: StockProvider { didSet { if provider != oldValue { defaults.set(provider.rawValue, forKey: "stockProvider"); search() } } }
    @Published var text = ""
    @Published var category = "Popular"
    @Published private(set) var clips: [StockClip] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasMore = false
    @Published private(set) var message: String?
    @Published private(set) var adding: Set<String> = []
    @Published private(set) var keyVersion = 0

    private let library: LibraryModel
    private let defaults: UserDefaults
    private let session: URLSession
    private let bases: [StockProvider: URL]
    private var page = 1
    private var generation = 0

    init(library: LibraryModel, defaults: UserDefaults = .standard, session: URLSession = .shared, bases: [StockProvider: URL] = [:]) {
        self.library = library; self.defaults = defaults; self.session = session; self.bases = bases
        provider = StockProvider(rawValue: defaults.string(forKey: "stockProvider") ?? "") ?? .pexels
    }

    // MARK: Keys

    func key(for p: StockProvider) -> String { (defaults.string(forKey: p.defaultsKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    var hasKey: Bool { !key(for: provider).isEmpty }

    func setKey(_ value: String, for p: StockProvider) {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty { defaults.removeObject(forKey: p.defaultsKey) } else { defaults.set(clean, forKey: p.defaultsKey) }
        keyVersion += 1
        if p == provider { search() }
    }

    func dismissMessage() { message = nil }

    // MARK: Searching

    private var effectiveText: String { text.trimmingCharacters(in: .whitespaces).isEmpty ? category : text }

    func choose(category name: String) { category = name; text = ""; search() }

    func search() {
        generation += 1
        page = 1
        clips = []; hasMore = false; message = nil
        guard hasKey else { isLoading = false; return }
        fetch(generation)
    }

    func loadMore() {
        guard hasMore, !isLoading else { return }
        page += 1
        fetch(generation)
    }

    private func fetch(_ mine: Int) {
        let p = provider
        guard let request = StockParser.request(for: StockQuery(provider: p, text: effectiveText, page: page), key: key(for: p), base: bases[p]) else { return }
        isLoading = true
        let wanted = page
        Task {
            do {
                let (data, response) = try await session.data(for: request)
                guard mine == generation else { return }
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if code == 401 || code == 403 || (p == .pixabay && code == 400) { throw StockError.badKey(p) }
                if code == 429 { throw StockError.rateLimited(p) }
                guard code == 200 else { throw StockError.server(code) }
                let result = try StockParser.parse(data, provider: p, page: wanted)
                let known = Set(clips.map(\.id))
                clips += result.clips.filter { !known.contains($0.id) }
                hasMore = result.hasMore
                if clips.isEmpty { message = "No results. Try another search." }
            } catch {
                guard mine == generation else { return }
                if wanted > 1 { page -= 1 }
                message = (error as? StockError)?.errorDescription ?? "Could not reach \(p.name): \(error.localizedDescription)"
            }
            if mine == generation { isLoading = false }
        }
    }

    // MARK: Adding to the library

    func isAdded(_ clip: StockClip) -> Bool { record(for: clip) != nil }
    func record(for clip: StockClip) -> WallpaperRecord? {
        library.records.first { !$0.isTrashed && $0.tags.contains(clip.libraryTag) }
    }

    func add(_ clip: StockClip) {
        guard !adding.contains(clip.id), !isAdded(clip), let file = clip.bestFile() else { return }
        adding.insert(clip.id)
        message = nil
        let folder = library.storage.downloadsDir
        Task {
            defer { adding.remove(clip.id) }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let (tmp, response) = try await session.download(from: file.url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    try? FileManager.default.removeItem(at: tmp)
                    throw StockError.server((response as? HTTPURLResponse)?.statusCode ?? 0)
                }
                let dest = folder.appendingPathComponent("\(clip.id).mp4")
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: tmp, to: dest)
                let tags = [clip.provider.rawValue, "stock", clip.libraryTag, clip.resolutionLabel.lowercased()].filter { !$0.isEmpty }
                let template = WallpaperRecord(title: clip.title, kind: .video, fileName: "pending.mp4", source: .imported,
                                               category: clip.provider.name, tags: tags, contentHash: "pending")
                let record = try await library.importFile(dest, move: true, template: template)
                message = "Added “\(record.title)” to your library."
            } catch {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent("\(clip.id).mp4"))
                message = "Could not add “\(clip.title)”: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
            }
        }
    }

    func setAsWallpaper(_ clip: StockClip) {
        guard let record = record(for: clip) else { return }
        Task { await library.play(record) }
    }
}
