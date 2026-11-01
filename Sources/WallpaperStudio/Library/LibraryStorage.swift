import Foundation
import StudioCore

/// Where the library lives on disk. Everything the app owns sits under one folder:
///
///     ~/Library/Application Support/LiveWallpaper/Library/
///         library.sqlite      metadata
///         files/<uuid>.<ext>  the wallpapers themselves (copied/moved in, never referenced in place)
///         thumbs/<uuid>.jpg   regenerable previews
///         downloads/          in-flight downloads
struct LibraryStorage {
    let root: URL

    static var standard: LibraryStorage {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return LibraryStorage(root: base.appendingPathComponent("LiveWallpaper/Library", isDirectory: true))
    }

    var filesDir: URL { root.appendingPathComponent("files", isDirectory: true) }
    var thumbsDir: URL { root.appendingPathComponent("thumbs", isDirectory: true) }
    var downloadsDir: URL { root.appendingPathComponent("downloads", isDirectory: true) }
    var databaseURL: URL { root.appendingPathComponent("library.sqlite") }

    func prepare() throws {
        for dir in [filesDir, thumbsDir, downloadsDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// nil if the stored file name is not a plain file name (defence against a tampered database).
    func fileURL(_ record: WallpaperRecord) -> URL? {
        SafeFileName.isSafe(record.fileName) ? filesDir.appendingPathComponent(record.fileName) : nil
    }

    func thumbURL(id: String) -> URL { thumbsDir.appendingPathComponent("\(id).jpg") }
}
