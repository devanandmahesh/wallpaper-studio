import SwiftUI
import AppKit
import UniformTypeIdentifiers
import StudioCore

final class LibraryUIState: ObservableObject {
    @Published var dropTargeted = false
}

struct LibraryView: View {
    @ObservedObject var engine: AppDelegate
    @ObservedObject var library: LibraryModel
    @StateObject private var ui = LibraryUIState()

    private enum Tab: String, CaseIterable { case all = "All", favorites = "Favorites", recent = "Recent", trash = "Trash" }

    private var tab: Tab {
        switch library.query.scope {
        case .all, .collection: .all
        case .favorites: .favorites
        case .recent: .recent
        case .trash: .trash
        }
    }

    private var scopeTitle: String {
        if case .collection(let id) = library.query.scope, let c = library.collections.first(where: { $0.id == id }) { return c.name }
        return tab.rawValue
    }

    var body: some View {
        let items = library.visible
        VStack(spacing: 0) {
            PageHeader("My Library", "\(items.count) in \(scopeTitle)") {
                HStack {
                    Button("Add Wallpaper…") { addWallpapers() }
                    Menu {
                        Button("Export Library…") { exportLibrary() }
                        Button("Import Library…") { importLibrary() }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).frame(width: 36)
                }
            }
            controls
            if let status = library.status {
                HStack {
                    Text(status).font(.callout)
                    Spacer()
                    Button { library.status = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }
                .padding(10).background(Color.accentColor.opacity(0.15)).cornerRadius(8)
                .padding(.horizontal, 24).padding(.bottom, 6)
            }
            if let error = library.loadError {
                Text("The library could not be opened: \(error)").foregroundColor(.red).padding()
            }
            content(items)
        }
        .overlay(dropOverlay)
        .onDrop(of: [.fileURL], isTargeted: Binding(get: { ui.dropTargeted }, set: { ui.dropTargeted = $0 })) { providers in
            loadURLs(from: providers)
            return true
        }
        .sheet(isPresented: Binding(get: { library.selectedID != nil }, set: { if !$0 { library.selectedID = nil } })) {
            if let id = library.selectedID, let record = library.record(id: id) {
                LibraryDetailView(record: record, library: library, engine: engine)
            }
        }
        .task { await library.start() }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                TextField("Search title, tag or category", text: Binding(get: { library.query.search }, set: { library.query.search = $0 }))
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                Picker("", selection: Binding(get: { tab }, set: { setTab($0) })) {
                    ForEach(Tab.allCases, id: \.self) { Text($0 == .trash && library.trashCount > 0 ? "Trash (\(library.trashCount))" : $0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 340)
                collectionsMenu
                Menu {
                    ForEach(LibrarySort.allCases, id: \.self) { s in
                        Button { library.query.sort = s } label: { Label(s.label, systemImage: library.query.sort == s ? "checkmark" : "") }
                    }
                    Divider()
                    Button { library.query.kind = nil } label: { Label("All types", systemImage: library.query.kind == nil ? "checkmark" : "") }
                    ForEach(WallpaperKind.allCases, id: \.self) { k in
                        Button { library.query.kind = k } label: { Label(kindName(k), systemImage: library.query.kind == k ? "checkmark" : "") }
                    }
                } label: { Label("Sort & Filter", systemImage: "line.3.horizontal.decrease.circle") }
                .menuStyle(.borderlessButton).fixedSize()
                Spacer()
                if tab == .trash && library.trashCount > 0 {
                    Button("Empty Trash", role: .destructive) { confirmEmptyTrash() }
                }
            }
            let tags = library.tagCounts.prefix(14)
            if !tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(Array(tags), id: \.tag) { entry in
                            let on = library.query.tag == entry.tag
                            Button("#\(entry.tag) \(entry.count)") { library.query.tag = on ? nil : entry.tag }
                                .buttonStyle(.plain).font(.caption)
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(Capsule().fill(on ? Color.accentColor : Color.secondary.opacity(0.18)))
                                .foregroundColor(on ? .white : .primary)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 24).padding(.bottom, 8)
    }

    private var collectionsMenu: some View {
        Menu {
            Button { library.query.scope = .all } label: { Label("Everything", systemImage: "square.grid.2x2") }
            if !library.collections.isEmpty { Divider() }
            ForEach(library.collections) { c in
                Button { library.query.scope = .collection(c.id) } label: {
                    Label(c.name, systemImage: library.query.scope == .collection(c.id) ? "checkmark" : "rectangle.stack")
                }
            }
            Divider()
            Button("New Collection…") { newCollection() }
            if case .collection(let id) = library.query.scope {
                Button("Delete This Collection", role: .destructive) { Task { await library.deleteCollection(id) } }
            }
        } label: { Label("Collections", systemImage: "rectangle.stack") }
        .menuStyle(.borderlessButton).fixedSize()
    }

    private func setTab(_ t: Tab) {
        switch t {
        case .all: library.query.scope = .all
        case .favorites: library.query.scope = .favorites
        case .recent: library.query.scope = .recent
        case .trash: library.query.scope = .trash
        }
    }

    private func kindName(_ k: WallpaperKind) -> String {
        switch k { case .video: "Videos"; case .image: "Images"; case .animatedImage: "GIFs"; case .scene: "Generated"; case .package: "Packages" }
    }

    // MARK: Content

    @ViewBuilder private func content(_ items: [WallpaperRecord]) -> some View {
        if items.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: tab == .trash ? "trash" : "photo.on.rectangle.angled").font(.system(size: 40)).foregroundColor(.secondary)
                Text(emptyTitle).font(.headline)
                Text(emptyHint).foregroundColor(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: gridColumns, spacing: 18) {
                    ForEach(items) { r in
                        LibraryCard(record: r, library: library, engine: engine)
                    }
                }
                .padding(24)
            }
        }
    }

    private var emptyTitle: String {
        if !library.query.search.isEmpty || library.query.tag != nil || library.query.kind != nil { return "No matches" }
        switch library.query.scope {
        case .favorites: return "No favorites yet"
        case .recent: return "Nothing played yet"
        case .trash: return "Trash is empty"
        case .collection: return "This collection is empty"
        case .all: return "Nothing here yet"
        }
    }

    private var emptyHint: String {
        library.query.scope == .all && library.query.search.isEmpty
            ? "Download wallpapers from Discover, or drop videos, images and GIFs here."
            : "Try a different search, filter or tab."
    }

    @ViewBuilder private var dropOverlay: some View {
        if ui.dropTargeted {
            RoundedRectangle(cornerRadius: 14).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                .background(Color.accentColor.opacity(0.08)).padding(8).allowsHitTesting(false)
        }
    }

    // MARK: Actions

    private func addWallpapers() {
        let panel = NSOpenPanel()
        panel.title = "Add wallpapers (videos, images, GIFs or folders)"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        if panel.runModal() == .OK { Task { await library.importMany(panel.urls) } }
    }

    private func loadURLs(from providers: [NSItemProvider]) {
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()
        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    lock.lock(); urls.append(url); lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { Task { await library.importMany(urls) } }
    }

    private func newCollection() {
        guard let name = promptForText(title: "New Collection", message: "Name for the collection:") else { return }
        Task {
            if let c = await library.createCollection(named: name) { library.query.scope = .collection(c.id) }
        }
    }

    private func confirmEmptyTrash() {
        let alert = NSAlert()
        alert.messageText = "Permanently delete \(library.trashCount) item(s)?"
        alert.informativeText = "This removes the files from disk and cannot be undone."
        alert.addButton(withTitle: "Delete Forever")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn { Task { await library.emptyTrash() } }
    }

    private func exportLibrary() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Wallpaper Studio Library.zip"
        panel.allowedContentTypes = [.zip]
        if panel.runModal() == .OK, let url = panel.url { Task { await library.exportLibrary(to: url) } }
    }

    private func importLibrary() {
        let panel = NSOpenPanel()
        panel.title = "Choose an exported library (.zip)"
        panel.allowedContentTypes = [.zip]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { Task { await library.importLibrary(from: url) } }
    }
}

/// Shared helper: a one-line text prompt.
func promptForText(title: String, message: String, initial: String = "") -> String? {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
    field.stringValue = initial
    alert.accessoryView = field
    alert.addButton(withTitle: "OK")
    alert.addButton(withTitle: "Cancel")
    alert.window.initialFirstResponder = field
    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
}

// MARK: - Card

private struct LibraryCard: View {
    let record: WallpaperRecord
    @ObservedObject var library: LibraryModel
    @ObservedObject var engine: AppDelegate
    @StateObject private var loader = ThumbLoader()

    private var active: Bool { library.isPlaying(record, current: engine.current) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Thumb {
                if let image = loader.image { Image(nsImage: image).resizable().scaledToFill() }
                else { ProgressView() }
            }
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor, lineWidth: active ? 3 : 0))
            .overlay(alignment: .topTrailing) {
                if !record.isTrashed {
                    Button { Task { await library.toggleFavorite(record.id) } } label: {
                        Image(systemName: record.isFavorite ? "heart.fill" : "heart")
                            .foregroundColor(record.isFavorite ? .pink : .white)
                            .padding(6).background(Circle().fill(.black.opacity(0.45)))
                    }
                    .buttonStyle(.plain).padding(8).help(record.isFavorite ? "Remove from favorites" : "Add to favorites").accessibilityLabel(record.isFavorite ? "Remove from favorites" : "Add to favorites")
                }
            }
            .overlay(alignment: .bottomLeading) {
                Text(badge).font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(.black.opacity(0.55))).foregroundColor(.white).padding(8)
            }
            .contentShape(Rectangle())
            .onTapGesture { library.selectedID = record.id }
            Text(record.title).font(.headline).lineLimit(1)
            actions
        }
        .onAppear { loader.load(record, from: library) }
        .contextMenu { menu }
    }

    private var badge: String {
        var parts = [record.kind == .video ? "VIDEO" : record.kind == .image ? "IMAGE" : record.kind == .scene ? "GPU" : record.kind == .package ? "PKG" : "GIF"]
        if record.width > 0 && record.kind != .scene { parts.append("\(record.width)×\(record.height)") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var actions: some View {
        if record.isTrashed {
            HStack {
                Button("Restore") { Task { await library.restore(record.id) } }
                Button("Delete Forever", role: .destructive) { Task { await library.deleteForever(record.id) } }
            }
        } else {
            HStack {
                Button(active ? "Playing" : "Set as Wallpaper") { Task { await library.play(record) } }
                    .buttonStyle(.borderedProminent).disabled(active)
                Spacer()
                Button { library.selectedID = record.id } label: { Image(systemName: "info.circle") }.buttonStyle(.plain).help("Details").accessibilityLabel("Details")
            }
        }
    }

    @ViewBuilder private var menu: some View {
        if record.isTrashed {
            Button("Restore") { Task { await library.restore(record.id) } }
            Button("Delete Forever", role: .destructive) { Task { await library.deleteForever(record.id) } }
        } else {
            Button("Set as Wallpaper") { Task { await library.play(record) } }
            Button(record.isFavorite ? "Remove from Favorites" : "Add to Favorites") { Task { await library.toggleFavorite(record.id) } }
            Menu("Add to Collection") {
                ForEach(library.collections) { c in
                    let inside = library.memberships[c.id]?.contains(record.id) == true
                    Button { Task { await library.setMembership(wallpaper: record.id, collection: c.id, included: !inside) } } label: {
                        Label(c.name, systemImage: inside ? "checkmark" : "")
                    }
                }
            }
            Button("Show in Finder") {
                if let url = library.fileURL(record) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            Divider()
            Button("Move to Trash", role: .destructive) { Task { await library.trash(record.id) } }
        }
    }
}
