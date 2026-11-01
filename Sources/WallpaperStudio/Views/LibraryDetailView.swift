import SwiftUI
import AVKit
import AppKit
import StudioCore

/// Editable drafts for the detail sheet (plain ObservableObject: no @State macro on this toolchain).
final class DetailDraft: ObservableObject {
    @Published var title: String
    @Published var tags: String
    init(_ r: WallpaperRecord) { title = r.title; tags = r.tags.joined(separator: ", ") }
}

final class PreviewPlayer: ObservableObject {
    let player: AVPlayer?
    private var observer: NSObjectProtocol?

    init(url: URL?, kind: WallpaperKind) {
        guard let url, kind == .video else { player = nil; return }
        let p = AVPlayer(url: url)
        p.isMuted = true
        player = p
        observer = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: p.currentItem, queue: .main) { [weak p] _ in
            p?.seek(to: .zero); p?.play()
        }
    }

    deinit {
        player?.pause()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}

struct LibraryDetailView: View {
    let record: WallpaperRecord
    @ObservedObject var library: LibraryModel
    @ObservedObject var engine: AppDelegate
    @StateObject private var draft: DetailDraft
    @StateObject private var preview: PreviewPlayer
    @StateObject private var loader = ThumbLoader()

    init(record: WallpaperRecord, library: LibraryModel, engine: AppDelegate) {
        self.record = record
        self.library = library
        self.engine = engine
        _draft = StateObject(wrappedValue: DetailDraft(record))
        _preview = StateObject(wrappedValue: PreviewPlayer(url: library.fileURL(record), kind: record.kind))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(spacing: 10) {
                Thumb {
                    if let player = preview.player { VideoPlayer(player: player).onAppear { player.play() } }
                    else if let image = loader.image { Image(nsImage: image).resizable().scaledToFit() }
                    else { ProgressView() }
                }
                .frame(width: 420)
                HStack {
                    Button("Set as Wallpaper") { Task { await library.play(record) } }
                        .buttonStyle(.borderedProminent).disabled(record.isTrashed)
                    Button("Show in Finder") {
                        if let url = library.fileURL(record) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                TextField("Title", text: $draft.title).textFieldStyle(.roundedBorder).font(.title3)
                    .onSubmit { Task { await library.rename(record.id, to: draft.title) } }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Tags (comma separated)").font(.caption).foregroundColor(.secondary)
                    TextField("e.g. calm, blue, ocean", text: $draft.tags).textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await library.setTags(record.id, text: draft.tags) } }
                }
                Toggle("Favorite", isOn: Binding(get: { record.isFavorite }, set: { _ in Task { await library.toggleFavorite(record.id) } }))
                if !library.collections.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Collections").font(.caption).foregroundColor(.secondary)
                        ForEach(library.collections) { c in
                            Toggle(c.name, isOn: Binding(
                                get: { library.memberships[c.id]?.contains(record.id) == true },
                                set: { on in Task { await library.setMembership(wallpaper: record.id, collection: c.id, included: on) } }))
                        }
                    }
                }
                Divider()
                metadata
                Spacer()
                HStack {
                    if record.isTrashed {
                        Button("Restore") { Task { await library.restore(record.id) } }
                        Button("Delete Forever", role: .destructive) { Task { await library.deleteForever(record.id) } }
                    } else {
                        Button("Move to Trash", role: .destructive) {
                            Task { await library.trash(record.id); library.selectedID = nil }
                        }
                    }
                    Spacer()
                    Button("Done") { commit(); library.selectedID = nil }.keyboardShortcut(.defaultAction)
                }
            }
            .frame(width: 320)
        }
        .padding(24)
        .onAppear { loader.load(record, from: library) }
        .onDisappear { commit() }
    }

    private func commit() {
        let title = draft.title, tags = draft.tags
        Task {
            if title != record.title { await library.rename(record.id, to: title) }
            if TagParser.parse(tags) != record.tags { await library.setTags(record.id, text: tags) }
        }
    }

    private var metadata: some View {
        let f = ByteCountFormatter()
        let dateFmt = DateFormatter(); dateFmt.dateStyle = .medium; dateFmt.timeStyle = .short
        return VStack(alignment: .leading, spacing: 4) {
            row("Type", record.kind == .video ? "Video" : record.kind == .image ? "Image" : record.kind == .scene ? "Generated (GPU scene)" : record.kind == .package ? "Wallpaper package" : "Animated GIF")
            if record.width > 0 { row("Size", "\(record.width) × \(record.height)") }
            if let d = record.duration { row("Duration", String(format: "%.1f s", d)) }
            row("File size", f.string(fromByteCount: record.sizeBytes))
            row("Source", record.source == .catalog ? "Discover (Mixkit)" : "Imported")
            row("Added", dateFmt.string(from: record.dateAdded))
            row("Last played", record.lastPlayed.map { dateFmt.string(from: $0) } ?? "Never")
            row("Times played", "\(record.playCount)")
        }
        .font(.callout)
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k).foregroundColor(.secondary).frame(width: 90, alignment: .leading); Text(v) }
    }
}
