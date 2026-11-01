import Testing
import AppKit
import SwiftUI
import StudioCore
@testable import WallpaperStudio

@MainActor
@Suite struct SidebarTests {
    func spin(_ s: Double) async {
        let end = Date().addingTimeInterval(s)
        while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)); try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    func findTable(in view: NSView) -> NSTableView? {
        if let t = view as? NSTableView { return t }
        for sub in view.subviews { if let t = findTable(in: sub) { return t } }
        return nil
    }

    func host(nav: NavState) throws -> (NSHostingView<RootView>, NSWindow) {
        _ = NSApplication.shared
        let engine = AppDelegate()
        let container = AppContainer(engine: engine)
        let host = NSHostingView(rootView: RootView(container: container, nav: nav))
        host.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return (host, window)
    }

    @Test func clickingEverySidebarRowSwitchesThePage() async throws {
        let nav = NavState()
        let (host, window) = try host(nav: nav)
        await spin(0.4)
        let table = try #require(findTable(in: host), "the sidebar list was not found")
        #expect(table.numberOfRows == SidebarSection.allCases.count)
        for (i, section) in SidebarSection.allCases.enumerated().reversed() {
            table.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
            await spin(0.25)
            #expect(nav.section == section, "selecting row \(i) should open \(section.title) but the page is \(String(describing: nav.section))")
        }
        window.close()
    }

    @Test func theSidebarHighlightFollowsProgrammaticNavigation() async throws {
        let nav = NavState()
        let (host, window) = try host(nav: nav)
        await spin(0.3)
        let table = try #require(findTable(in: host))
        nav.section = .settings                                              // e.g. a wallpaperstudio://open?section=settings link
        await spin(0.3)
        #expect(table.selectedRow == SidebarSection.allCases.firstIndex(of: .settings))
        window.close()
    }

    @Test func linksAndMenusCanRequestAPage() async throws {
        let nav = NavState()
        let engine = AppDelegate()
        let container = AppContainer(engine: engine)
        let host = NSHostingView(rootView: RootView(container: container, nav: nav))
        host.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        await spin(0.2)
        engine.sectionRequests.send(.displays)
        await spin(0.2)
        #expect(nav.section == .displays)
        window.close()
    }
}
