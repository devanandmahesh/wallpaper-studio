import AppKit
import StudioCore

/// Reads and writes the macOS desktop picture, which is also what the lock screen and login window show.
protocol DesktopImageStore {
    func currentImage(forScreen id: UInt32) -> URL?
    func setImage(_ url: URL, forScreen id: UInt32) throws
}

struct SystemDesktopImageStore: DesktopImageStore {
    private func screen(_ id: UInt32) -> NSScreen? { NSScreen.screens.first { $0.displayID == id } }

    func currentImage(forScreen id: UInt32) -> URL? { screen(id).flatMap { NSWorkspace.shared.desktopImageURL(for: $0) } }

    func setImage(_ url: URL, forScreen id: UInt32) throws {
        guard let screen = screen(id) else { return }
        try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [
            .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
            .allowClipping: true,
        ])
    }
}

/// macOS does not let apps play video on the lock screen or login window. What it does show is the user's desktop
/// picture, so this keeps that picture equal to a still frame of the current wallpaper:
///  * when the wallpaper changes (a moment after, so the first frame exists),
///  * and the moment the screen locks.
/// It is opt-in. Turning it on remembers the pictures that were set before; turning it off puts them back.
final class LockScreenSync: ObservableObject {
    @Published private(set) var isEnabled: Bool
    @Published private(set) var lastSync: Date?
    @Published private(set) var lastError: String?

    private let directory: URL
    private let store: DesktopImageStore
    private let defaults: UserDefaults
    private let snapshot: () -> CGImage?
    private let screens: () -> [UInt32]
    private let debounce: TimeInterval
    private var pending: DispatchWorkItem?

    static let enabledKey = "lockScreenSync"
    static let originalsKey = "lockScreenSyncOriginals"
    static let keepFiles = 2

    init(directory: URL, store: DesktopImageStore = SystemDesktopImageStore(), defaults: UserDefaults = .standard, debounce: TimeInterval = 2,
         screens: @escaping () -> [UInt32] = { NSScreen.screens.compactMap(\.displayID) }, snapshot: @escaping () -> CGImage?) {
        self.directory = directory
        self.store = store
        self.defaults = defaults
        self.debounce = debounce
        self.screens = screens
        self.snapshot = snapshot
        isEnabled = defaults.bool(forKey: Self.enabledKey)
    }

    static func defaultDirectory() -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("LiveWallpaper/LockScreen", isDirectory: true)
    }

    // MARK: Switching

    func setEnabled(_ on: Bool) {
        guard on != isEnabled else { return }
        isEnabled = on
        defaults.set(on, forKey: Self.enabledKey)
        pending?.cancel()
        if on {
            rememberOriginals()
            sync()
        } else {
            restoreOriginals()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// The pictures that were in place before we first replaced them, keyed by display id.
    private var originals: [String: String] {
        get { (defaults.dictionary(forKey: Self.originalsKey) as? [String: String]) ?? [:] }
        set { defaults.set(newValue, forKey: Self.originalsKey) }
    }

    private func isOurs(_ url: URL) -> Bool { url.standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path + "/") }

    private func rememberOriginals() {
        var saved = originals
        for id in screens() {
            // Never record one of our own stills as "the original" (that would make restoring impossible).
            if saved["\(id)"] == nil, let current = store.currentImage(forScreen: id), !isOurs(current) { saved["\(id)"] = current.path }
        }
        originals = saved
    }

    private func restoreOriginals() {
        for id in screens() {
            guard let path = originals["\(id)"], FileManager.default.fileExists(atPath: path) else { continue }
            do { try store.setImage(URL(fileURLWithPath: path), forScreen: id) } catch { lastError = error.localizedDescription }
        }
        originals = [:]
    }

    // MARK: Triggers

    /// Call whenever the wallpaper changed. Waits a moment so a freshly loaded video has a frame to capture.
    func wallpaperChanged() {
        guard isEnabled else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.sync() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    /// Call when the screen locks: capture what is showing right now.
    func screenLocked() {
        guard isEnabled else { return }
        pending?.cancel()
        sync()
    }

    // MARK: Syncing

    /// Writes a still of the current wallpaper and makes it the desktop picture of every display.
    @discardableResult
    func sync() -> URL? {
        guard isEnabled else { return nil }
        guard let image = snapshot(), let data = Self.jpeg(image) else {
            lastError = "There is nothing to capture yet."
            return nil
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("lock-\(Int(Date().timeIntervalSince1970 * 1000)).jpg")
            try data.write(to: file, options: .atomic)
            for id in screens() { try store.setImage(file, forScreen: id) }
            prune(keeping: file)
            lastSync = Date()
            lastError = nil
            return file
        } catch {
            lastError = error.localizedDescription
            Log.app.error("Lock screen sync failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func prune(keeping current: URL) {
        let files = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "jpg" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in files.dropFirst(Self.keepFiles) where old != current { try? FileManager.default.removeItem(at: old) }
    }

    static func jpeg(_ image: CGImage, quality: Double = 0.92) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: quality])
    }
}
