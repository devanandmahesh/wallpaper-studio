import SwiftUI
import Combine
import StudioCore

struct RootView: View {
    let container: AppContainer
    @ObservedObject var engine: AppDelegate
    @ObservedObject var nav: NavState

    /// `nav` is injectable so tests can drive and observe the sidebar.
    init(container: AppContainer, nav: NavState = NavState()) {
        self.container = container
        self.engine = container.engine
        self.nav = nav
    }

    var body: some View {
        NavigationSplitView {
            // The selection type and the row tags must be the same type. Tagging rows with `Optional(section)` while the
            // list selects `SidebarSection` made every click select nothing: the sidebar looked dead.
            List(selection: $nav.section) {
                ForEach(SidebarSection.allCases) { section in
                    Label(section.title, systemImage: section.symbol).tag(section)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            ZStack { page.id(nav.section).transition(.page) }
                .animation(.fluid, value: nav.section)
                .navigationTitle((nav.section ?? .discover).title)
                .toolbar(removing: .sidebarToggle)
                .clearTopEdge()
                .softBottomEdge()
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    GlassGroup {
                        ControlsBar(engine: engine)
                            .padding(.horizontal, 24).padding(.bottom, 14).padding(.top, 6)
                    }
                }
        }
        .clearWindowToolbar()
        .frame(minWidth: 900, minHeight: 600)
        .onReceive(engine.sectionRequests) { nav.section = $0 }
    }

    @ViewBuilder private var page: some View {
        switch nav.section ?? .discover {
        case .discover: DiscoverView(engine: engine, library: container.library, downloads: container.downloads)
        case .library: LibraryView(engine: engine, library: container.library)
        case .editor: EditorView(library: container.library)
        case .playlists: PlaylistsView(engine: engine, library: container.library, schedule: engine.schedule)
        case .displays: DisplaysView(engine: engine, library: container.library)
        case .settings: SettingsView(engine: engine, library: container.library)
        }
    }
}
