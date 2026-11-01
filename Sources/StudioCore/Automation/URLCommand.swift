import Foundation

/// Commands other tools can send through `wallpaperstudio://…` links (Shortcuts "Open URL", Terminal `open`, scripts, web pages).
///
/// Deliberately small and safe: no file paths, no arbitrary text beyond a library title, no way to delete or export
/// anything. Unknown or malformed links are ignored.
public enum URLCommand: Equatable, Sendable {
    case next
    case pause
    case resume
    case togglePause
    case set(title: String)
    case mode(DisplayMode)
    case profile(PerformanceProfile)
    case open(SidebarSection)

    public static let scheme = "wallpaperstudio"
    public static let maxTitleLength = 120

    public static func parse(_ url: URL) -> URLCommand? {
        guard url.scheme?.lowercased() == scheme, let host = url.host?.lowercased() else { return nil }
        let path = url.path
        guard path.isEmpty || path == "/" else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        switch host {
        case "next": return .next
        case "pause": return .pause
        case "resume", "play": return .resume
        case "toggle", "toggle-pause": return .togglePause
        case "set":
            guard let title = value("title")?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty, title.count <= maxTitleLength, !title.unicodeScalars.contains(where: { $0.value < 32 }) else { return nil }
            return .set(title: title)
        case "mode":
            guard let raw = value("value")?.lowercased() else { return nil }
            switch raw {
            case "mirror", "same": return .mode(.mirror)
            case "independent", "different": return .mode(.independent)
            case "span": return .mode(.span)
            default: return nil
            }
        case "profile":
            guard let raw = value("value")?.lowercased() else { return nil }
            switch raw {
            case "battery", "batterysaver", "battery-saver": return .profile(.batterySaver)
            case "balanced": return .profile(.balanced)
            case "performance": return .profile(.performance)
            case "adaptive": return .profile(.adaptive)
            default: return nil
            }
        case "open":
            guard let raw = value("section")?.lowercased(), let section = SidebarSection(rawValue: raw) else { return nil }
            return .open(section)
        default: return nil
        }
    }

    /// The link that triggers this command (used by documentation, tests and the Settings page).
    public var url: URL {
        var c = URLComponents()
        c.scheme = Self.scheme
        switch self {
        case .next: c.host = "next"
        case .pause: c.host = "pause"
        case .resume: c.host = "resume"
        case .togglePause: c.host = "toggle"
        case .set(let title): c.host = "set"; c.queryItems = [URLQueryItem(name: "title", value: title)]
        case .mode(let m): c.host = "mode"; c.queryItems = [URLQueryItem(name: "value", value: m.rawValue)]
        case .profile(let p): c.host = "profile"; c.queryItems = [URLQueryItem(name: "value", value: p.rawValue.lowercased())]
        case .open(let s): c.host = "open"; c.queryItems = [URLQueryItem(name: "section", value: s.rawValue)]
        }
        return c.url ?? URL(fileURLWithPath: "/")
    }
}

/// Online features (accounts, sharing, ratings, sync) are deliberately not built. This is the seam they will plug into;
/// the shipped implementation never touches the network.
public enum CloudStatus: Equatable, Sendable {
    case unavailable(reason: String)
    case signedOut
    case signedIn(user: String)
}

public protocol CloudService: Sendable {
    func status() async -> CloudStatus
}

public struct OfflineCloudService: CloudService {
    public init() {}
    public func status() async -> CloudStatus { .unavailable(reason: "Online features are not part of this version. Everything works offline.") }
}
