import Foundation

/// Free stock-video sites with an official API that allows apps to search and download (Pexels, Pixabay).
public enum StockProvider: String, CaseIterable, Sendable, Identifiable {
    case pexels, pixabay

    public var id: String { rawValue }
    public var name: String { self == .pexels ? "Pexels" : "Pixabay" }
    public var keyHelpURL: URL { Self.url(self == .pexels ? "https://www.pexels.com/api/" : "https://pixabay.com/api/docs/") }
    public var licenseURL: URL { Self.url(self == .pexels ? "https://www.pexels.com/license/" : "https://pixabay.com/service/license-summary/") }
    public var licenseNote: String {
        self == .pexels ? "Free to use under the Pexels licence. Credit is appreciated, not required."
                        : "Free to use under the Pixabay Content Licence. No credit required."
    }
    public var apiBase: URL { Self.url(self == .pexels ? "https://api.pexels.com" : "https://pixabay.com") }
    public var defaultsKey: String { "stockKey.\(rawValue)" }

    private static func url(_ s: String) -> URL { URL(string: s) ?? URL(fileURLWithPath: "/") }
}

public struct StockFile: Equatable, Hashable, Sendable {
    public let url: URL
    public let width: Int
    public let height: Int
    public init(url: URL, width: Int, height: Int) { self.url = url; self.width = width; self.height = height }
}

public struct StockClip: Identifiable, Equatable, Hashable, Sendable {
    public let provider: StockProvider
    public let providerID: Int
    public var title: String
    public var author: String
    public var pageURL: URL?
    public var thumbURL: URL?
    public var duration: Int
    public var files: [StockFile]

    public init(provider: StockProvider, providerID: Int, title: String, author: String, pageURL: URL?, thumbURL: URL?, duration: Int, files: [StockFile]) {
        self.provider = provider; self.providerID = providerID; self.title = title; self.author = author
        self.pageURL = pageURL; self.thumbURL = thumbURL; self.duration = duration; self.files = files
    }

    public var id: String { "\(provider.rawValue)-\(providerID)" }
    /// The tag the library keeps on an imported clip, so the grid can tell what is already added.
    public var libraryTag: String { "stock:\(id)" }

    /// The best file for a wallpaper: the largest that does not exceed `maxHeight` (default 4K), else the smallest above it.
    /// Landscape files win; a portrait clip is a poor wallpaper.
    public func bestFile(maxHeight: Int = 2160) -> StockFile? {
        let landscape = files.filter { $0.width >= $0.height }
        let pool = landscape.isEmpty ? files : landscape
        let fitting = pool.filter { $0.height <= maxHeight }.sorted { $0.height > $1.height }
        return fitting.first ?? pool.min { $0.height < $1.height }
    }

    public var resolutionLabel: String {
        guard let f = bestFile() else { return "" }
        return f.height >= 2000 ? "4K" : f.height >= 1000 ? "HD" : "\(f.height)p"
    }
}

public struct StockPage: Equatable, Sendable {
    public var clips: [StockClip]
    public var total: Int
    public var hasMore: Bool
    public init(clips: [StockClip], total: Int, hasMore: Bool) { self.clips = clips; self.total = total; self.hasMore = hasMore }
}

public struct StockQuery: Equatable, Sendable {
    public var provider: StockProvider
    public var text: String
    public var page: Int
    public init(provider: StockProvider, text: String = "", page: Int = 1) { self.provider = provider; self.text = text; self.page = page }
}

public enum StockCategories {
    /// One-tap searches that work on both sites (they are search words, not site-specific category ids).
    public static let all: [String] = ["Popular", "Nature", "Space", "Ocean", "City", "Abstract", "Aurora", "Clouds", "Forest", "Rain", "Neon", "Mountains"]
}

public enum StockError: Error, Equatable, LocalizedError, Sendable {
    case missingKey(StockProvider)
    case badKey(StockProvider)
    case rateLimited(StockProvider)
    case server(Int)
    case unreadable

    public var errorDescription: String? {
        switch self {
        case .missingKey(let p): return "Add your free \(p.name) API key to search."
        case .badKey(let p): return "\(p.name) rejected the API key. Check it and try again."
        case .rateLimited(let p): return "\(p.name) is limiting requests. Wait a minute and try again."
        case .server(let code): return "The server answered with an error (\(code))."
        case .unreadable: return "The answer could not be read."
        }
    }
}

public enum StockParser {
    public static let pageSize = 24

    // MARK: Pexels

    private struct PexelsReply: Decodable {
        struct User: Decodable { let name: String? }
        struct File: Decodable { let link: String?; let width: Int?; let height: Int?; let file_type: String? }
        struct Picture: Decodable { let picture: String? }
        struct Video: Decodable {
            let id: Int; let url: String?; let image: String?; let duration: Int?
            let user: User?; let video_files: [File]?; let video_pictures: [Picture]?
        }
        let videos: [Video]?
        let total_results: Int?
        let page: Int?
        let per_page: Int?
    }

    public static func parsePexels(_ data: Data) throws -> StockPage {
        guard let reply = try? JSONDecoder().decode(PexelsReply.self, from: data), let videos = reply.videos else { throw StockError.unreadable }
        let clips: [StockClip] = videos.compactMap { v in
            let files = (v.video_files ?? []).compactMap { f -> StockFile? in
                guard f.file_type?.lowercased() == "video/mp4", let link = f.link, let url = https(link), let w = f.width, let h = f.height, w > 0, h > 0 else { return nil }
                return StockFile(url: url, width: w, height: h)
            }
            guard !files.isEmpty else { return nil }
            let page = v.url.flatMap(https)
            return StockClip(provider: .pexels, providerID: v.id, title: pexelsTitle(page, id: v.id), author: v.user?.name ?? "Pexels",
                             pageURL: page, thumbURL: (v.image ?? v.video_pictures?.first?.picture).flatMap(https),
                             duration: v.duration ?? 0, files: files)
        }
        let total = reply.total_results ?? clips.count
        let seen = (reply.page ?? 1) * (reply.per_page ?? pageSize)
        return StockPage(clips: clips, total: total, hasMore: seen < total)
    }

    /// Pexels gives no title, only a page address such as `.../video/aerial-view-of-a-forest-3571264/`.
    static func pexelsTitle(_ page: URL?, id: Int) -> String {
        let slug = page?.pathComponents.last(where: { $0 != "/" && !$0.isEmpty }) ?? ""
        let words = slug.replacingOccurrences(of: "-\(id)", with: "").split(separator: "-").map(String.init)
        return words.isEmpty ? "Pexels clip \(id)" : words.joined(separator: " ").capitalizedFirst
    }

    // MARK: Pixabay

    private struct PixabayReply: Decodable {
        struct Rendition: Decodable { let url: String?; let width: Int?; let height: Int?; let thumbnail: String? }
        struct Renditions: Decodable { let large: Rendition?; let medium: Rendition?; let small: Rendition?; let tiny: Rendition? }
        struct Hit: Decodable {
            let id: Int; let pageURL: String?; let tags: String?; let duration: Int?; let user: String?; let videos: Renditions?
        }
        let hits: [Hit]?
        let totalHits: Int?
    }

    public static func parsePixabay(_ data: Data, page: Int = 1) throws -> StockPage {
        guard let reply = try? JSONDecoder().decode(PixabayReply.self, from: data), let hits = reply.hits else { throw StockError.unreadable }
        let clips: [StockClip] = hits.compactMap { h in
            let renditions = [h.videos?.large, h.videos?.medium, h.videos?.small, h.videos?.tiny].compactMap { $0 }
            let files = renditions.compactMap { r -> StockFile? in
                // An unavailable size comes back with an empty URL.
                guard let s = r.url, !s.isEmpty, let url = https(s), let w = r.width, let hgt = r.height, w > 0, hgt > 0 else { return nil }
                return StockFile(url: url, width: w, height: hgt)
            }
            guard !files.isEmpty else { return nil }
            let thumb = (h.videos?.medium?.thumbnail ?? h.videos?.small?.thumbnail ?? h.videos?.tiny?.thumbnail).flatMap(https)
            return StockClip(provider: .pixabay, providerID: h.id, title: pixabayTitle(h.tags, id: h.id), author: h.user ?? "Pixabay",
                             pageURL: h.pageURL.flatMap(https), thumbURL: thumb, duration: h.duration ?? 0, files: files)
        }
        let total = reply.totalHits ?? clips.count
        return StockPage(clips: clips, total: total, hasMore: page * pageSize < total)
    }

    static func pixabayTitle(_ tags: String?, id: Int) -> String {
        let words = (tags ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.prefix(3)
        return words.isEmpty ? "Pixabay clip \(id)" : words.joined(separator: ", ").capitalizedFirst
    }

    /// Only https addresses are accepted from a server's answer; anything else is ignored.
    static func https(_ s: String) -> URL? {
        guard let u = URL(string: s), u.scheme?.lowercased() == "https", u.host != nil else { return nil }
        return u
    }

    // MARK: Requests

    /// Builds the request for a query. `base` lets tests point at a local server.
    public static func request(for q: StockQuery, key: String, base: URL? = nil) -> URLRequest? {
        let text = q.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let popular = text.isEmpty || text.caseInsensitiveCompare("Popular") == .orderedSame
        switch q.provider {
        case .pexels:
            var c = components(base ?? StockProvider.pexels.apiBase)
            c?.path = popular ? "/videos/popular" : "/videos/search"
            var items = [URLQueryItem(name: "per_page", value: "\(pageSize)"), URLQueryItem(name: "page", value: "\(max(q.page, 1))"),
                         URLQueryItem(name: "orientation", value: "landscape")]
            if !popular { items.insert(URLQueryItem(name: "query", value: text), at: 0) }
            c?.queryItems = items
            guard let url = c?.url else { return nil }
            var r = URLRequest(url: url)
            r.setValue(key, forHTTPHeaderField: "Authorization")
            return r
        case .pixabay:
            var c = components(base ?? StockProvider.pixabay.apiBase)
            c?.path = "/api/videos/"
            var items = [URLQueryItem(name: "key", value: key), URLQueryItem(name: "per_page", value: "\(pageSize)"),
                         URLQueryItem(name: "page", value: "\(max(q.page, 1))"), URLQueryItem(name: "safesearch", value: "true"),
                         URLQueryItem(name: "min_width", value: "1280"), URLQueryItem(name: "order", value: "popular")]
            if !popular { items.insert(URLQueryItem(name: "q", value: String(text.prefix(100))), at: 1) }
            c?.queryItems = items
            guard let url = c?.url else { return nil }
            return URLRequest(url: url)
        }
    }

    private static func components(_ base: URL) -> URLComponents? { URLComponents(url: base, resolvingAgainstBaseURL: false) }

    public static func parse(_ data: Data, provider: StockProvider, page: Int) throws -> StockPage {
        provider == .pexels ? try parsePexels(data) : try parsePixabay(data, page: page)
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
