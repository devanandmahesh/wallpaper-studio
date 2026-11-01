import Foundation

public enum WallpaperSource: String, Sendable, Codable {
    case imported   // added by the user
    case catalog    // downloaded from Discover
}

/// One wallpaper in the library. `fileName` is relative to the managed storage folder and never contains a path separator.
public struct WallpaperRecord: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var kind: WallpaperKind
    public var fileName: String
    public var source: WallpaperSource
    public var catalogID: Int?
    public var category: String?
    public var tags: [String]
    public var isFavorite: Bool
    public var dateAdded: Date
    public var lastPlayed: Date?
    public var playCount: Int
    public var sizeBytes: Int64
    public var width: Int
    public var height: Int
    public var duration: Double?
    public var contentHash: String
    public var deletedAt: Date?

    public init(id: String = UUID().uuidString, title: String, kind: WallpaperKind, fileName: String,
                source: WallpaperSource, catalogID: Int? = nil, category: String? = nil, tags: [String] = [],
                isFavorite: Bool = false, dateAdded: Date = Date(), lastPlayed: Date? = nil, playCount: Int = 0,
                sizeBytes: Int64 = 0, width: Int = 0, height: Int = 0, duration: Double? = nil,
                contentHash: String, deletedAt: Date? = nil) {
        self.id = id; self.title = title; self.kind = kind; self.fileName = fileName; self.source = source
        self.catalogID = catalogID; self.category = category; self.tags = tags; self.isFavorite = isFavorite
        self.dateAdded = dateAdded; self.lastPlayed = lastPlayed; self.playCount = playCount
        self.sizeBytes = sizeBytes; self.width = width; self.height = height; self.duration = duration
        self.contentHash = contentHash; self.deletedAt = deletedAt
    }

    public var isTrashed: Bool { deletedAt != nil }
}

public struct WallpaperCollection: Identifiable, Equatable, Sendable {
    public let id: String
    public var name: String
    public init(id: String = UUID().uuidString, name: String) { self.id = id; self.name = name }
}

public enum LibraryError: Error, LocalizedError, Equatable, Sendable {
    case database(String)
    case notFound
    case duplicateName
    case unsafeFileName(String)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .database(let m): "Library database error: \(m)"
        case .notFound: "That item no longer exists."
        case .duplicateName: "A collection with that name already exists."
        case .unsafeFileName(let n): "Refusing to use unsafe file name “\(n)”."
        case .unsupported(let m): m
        }
    }
}

/// Tags are lowercase, trimmed, unique and never contain commas.
public enum TagParser {
    public static func parse(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

/// File names coming from a database or an imported library archive are never trusted as paths.
public enum SafeFileName {
    public static func isSafe(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\") && !name.contains("\0") && name.count < 200
    }
}
