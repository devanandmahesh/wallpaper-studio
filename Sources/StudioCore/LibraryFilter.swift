import Foundation

public enum LibraryScope: Equatable, Sendable {
    case all, favorites, recent, trash
    case collection(String)
}

public enum LibrarySort: String, CaseIterable, Sendable {
    case newest, oldest, title, mostPlayed

    public var label: String {
        switch self {
        case .newest: "Newest"
        case .oldest: "Oldest"
        case .title: "Title"
        case .mostPlayed: "Most played"
        }
    }
}

public struct LibraryQuery: Equatable, Sendable {
    public var scope: LibraryScope = .all
    public var search: String = ""
    public var tag: String?
    public var kind: WallpaperKind?
    public var sort: LibrarySort = .newest
    public init() {}
}

public enum LibraryFilter {
    public static let recentLimit = 30

    /// `members` is the wallpaper-id set of the selected collection (ignored for other scopes).
    public static func apply(_ records: [WallpaperRecord], query: LibraryQuery, members: Set<String> = []) -> [WallpaperRecord] {
        var items = records.filter { r in
            switch query.scope {
            case .trash: return r.isTrashed
            case .all: return !r.isTrashed
            case .favorites: return !r.isTrashed && r.isFavorite
            case .recent: return !r.isTrashed && r.lastPlayed != nil
            case .collection: return !r.isTrashed && members.contains(r.id)
            }
        }
        if let tag = query.tag { items = items.filter { $0.tags.contains(tag) } }
        if let kind = query.kind { items = items.filter { $0.kind == kind } }

        let terms = fold(query.search).split(separator: " ").map(String.init)
        if !terms.isEmpty {
            items = items.filter { r in
                let haystack = fold(([r.title, r.category ?? "", r.kind.rawValue] + r.tags).joined(separator: " "))
                return terms.allSatisfy { haystack.contains($0) }
            }
        }

        if query.scope == .recent {
            return Array(items.sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }.prefix(recentLimit))
        }
        switch query.sort {
        case .newest: items.sort { $0.dateAdded > $1.dateAdded }
        case .oldest: items.sort { $0.dateAdded < $1.dateAdded }
        case .title: items.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .mostPlayed: items.sort { ($0.playCount, $0.dateAdded) > ($1.playCount, $1.dateAdded) }
        }
        return items
    }

    /// Tags of non-trashed wallpapers with their counts, most used first.
    public static func tagCounts(_ records: [WallpaperRecord]) -> [(tag: String, count: Int)] {
        var counts: [String: Int] = [:]
        for r in records where !r.isTrashed { for t in r.tags { counts[t, default: 0] += 1 } }
        return counts.map { (tag: $0.key, count: $0.value) }.sorted { ($0.count, $1.tag) > ($1.count, $0.tag) }
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
