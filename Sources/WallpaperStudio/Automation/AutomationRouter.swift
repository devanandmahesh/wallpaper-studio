import Foundation
import StudioCore

/// What automation is allowed to do to the app. A narrow interface on purpose.
@MainActor
protocol AutomationTarget: AnyObject {
    func nextWallpaper()
    func setPaused(_ paused: Bool)
    var isPaused: Bool { get }
    func setDisplayMode(_ mode: DisplayMode)
    func setPerformanceProfile(_ profile: PerformanceProfile)
    func show(_ section: SidebarSection)
    /// Looks a library item up by title (case-insensitive, ignoring the trash) and plays it. Returns false if there is none.
    func playLibraryItem(titled title: String) async -> Bool
}

/// Carries out `wallpaperstudio://` links.
@MainActor
final class AutomationRouter {
    private weak var target: AutomationTarget?
    private(set) var lastResult = ""

    init(target: AutomationTarget) { self.target = target }

    @discardableResult
    func handle(_ url: URL) async -> Bool {
        guard let command = URLCommand.parse(url), let target else {
            lastResult = "ignored"
            Log.app.notice("Ignored an unrecognised link")
            return false
        }
        switch command {
        case .next: target.nextWallpaper()
        case .pause: target.setPaused(true)
        case .resume: target.setPaused(false)
        case .togglePause: target.setPaused(!target.isPaused)
        case .mode(let m): target.setDisplayMode(m)
        case .profile(let p): target.setPerformanceProfile(p)
        case .open(let s): target.show(s)
        case .set(let title):
            guard await target.playLibraryItem(titled: title) else { lastResult = "no wallpaper titled “\(title)”"; return false }
        }
        lastResult = "ok"
        return true
    }
}
