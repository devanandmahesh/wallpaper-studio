/// Top-level dashboard destinations, in display order.
public enum SidebarSection: String, CaseIterable, Identifiable, Sendable {
    case discover, library, editor, playlists, displays, settings

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .discover: "Discover"
        case .library: "My Library"
        case .editor: "Editor"
        case .playlists: "Playlists"
        case .displays: "Displays"
        case .settings: "Settings"
        }
    }

    public var symbol: String {
        switch self {
        case .discover: "sparkles.rectangle.stack"
        case .library: "photo.on.rectangle.angled"
        case .editor: "slider.horizontal.3"
        case .playlists: "list.and.film"
        case .displays: "display.2"
        case .settings: "gearshape"
        }
    }
}
