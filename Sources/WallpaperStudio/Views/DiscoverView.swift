import SwiftUI
import StudioCore
import StudioRender

enum DiscoverSource: String, CaseIterable { case freeClips = "Free clips & generated", motionBGs = "MotionBGs (browse the web)" }

final class DiscoverState: ObservableObject {
    @Published var category = "All"
    @Published var source = DiscoverSource.freeClips
}

struct DiscoverView: View {
    @ObservedObject var engine: AppDelegate
    @ObservedObject var library: LibraryModel
    @ObservedObject var downloads: DownloadManager
    @StateObject private var state = DiscoverState()

    var body: some View {
        VStack(spacing: 0) {
            PageHeader("Discover", state.source == .freeClips ? "Free wallpapers — download once, play offline" : "Browse motionbgs.com; downloads land in your library") {
                Picker("", selection: $state.source) {
                    ForEach(DiscoverSource.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 360)
            }
            if state.source == .motionBGs {
                MotionBGsView(library: library)
            } else {
                freeClips
            }
        }
    }

    @ViewBuilder private var freeClips: some View {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(Catalog.categories, id: \.self) { name in
                        Button(name) { state.category = name }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 14).padding(.vertical, 6)
                            .background(Capsule().fill(state.category == name ? Color.accentColor : Color.secondary.opacity(0.18)))
                            .foregroundColor(state.category == name ? .white : .primary)
                    }
                }
                .padding(.horizontal, 24).padding(.vertical, 8)
            }
            ScrollView {
                if state.category == "All" || state.category == "Generated" {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Generated on your GPU").font(.headline)
                        Text("No download needed: drawn live, resolution independent, tiny on disk.").font(.caption).foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.top, 8)
                    LazyVGrid(columns: gridColumns, spacing: 18) {
                        ForEach(BuiltInScenes.all, id: \.name) { scene in
                            BuiltInCard(scene: scene, library: library, engine: engine)
                        }
                    }
                    .padding(24)
                }
                if state.category != "Generated" {
                LazyVGrid(columns: gridColumns, spacing: 18) {
                    ForEach(Catalog.items.filter { state.category == "All" || $0.category == state.category }) { item in
                        DiscoverCard(item: item, library: library, downloads: downloads, engine: engine)
                    }
                }
                .padding(24)
                }
                Text("Free stock footage from Mixkit, used under the Mixkit Stock Video Free License.")
                    .font(.caption).foregroundColor(.secondary).padding(.bottom, 16)
            }
    }
}

private struct DiscoverCard: View {
    let item: CatalogItem
    @ObservedObject var library: LibraryModel
    @ObservedObject var downloads: DownloadManager
    @ObservedObject var engine: AppDelegate

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Thumb {
                AsyncImage(url: item.thumbURL) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() }
                    else if phase.error != nil { Image(systemName: "photo").foregroundColor(.secondary) }
                    else { ProgressView() }
                }
            }
            Text(item.title).font(.headline).lineLimit(1)
            Text("\(item.category) · \(item.quality)p · \(item.sizeMB) MB").font(.caption).foregroundColor(.secondary)
            action
        }
    }

    @ViewBuilder private var action: some View {
        let record = library.catalogRecord(item.id)
        if let p = downloads.progress[item.id] {
            HStack {
                ProgressView(value: p)
                Button { downloads.cancel(item) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.plain)
            }
        } else if let record, !record.isTrashed {
            Button("Set as Wallpaper") { Task { await library.play(record) } }
                .buttonStyle(.borderedProminent)
        } else if let record {
            Button("Restore from Trash") { Task { await library.restore(record.id) } }
        } else {
            Button(downloads.failed.contains(item.id) ? "Retry Download" : "Download") { downloads.download(item) }
        }
    }
}

final class BuiltInThumbLoader: ObservableObject {
    @Published var image: NSImage?
    func load(_ scene: StudioCore.Scene) {
        Task.detached(priority: .utility) {
            guard let context = MetalContext.shared,
                  let cg = OffscreenRenderer(context: context).image(scene: scene, assetBase: nil, width: 480, height: 270, time: 2) else { return }
            let image = NSImage(cgImage: cg, size: .zero)
            await MainActor.run { self.image = image }
        }
    }
}

private struct BuiltInCard: View {
    let scene: StudioCore.Scene
    @ObservedObject var library: LibraryModel
    @ObservedObject var engine: AppDelegate
    @StateObject private var loader = BuiltInThumbLoader()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Thumb {
                if let image = loader.image { Image(nsImage: image).resizable().scaledToFill() } else { ProgressView() }
            }
            Text(scene.name).font(.headline)
            Text(scene.reactsToAudio ? "Generated · GPU · reacts to audio" : scene.reactsToPointer ? "Generated · GPU · reacts to the mouse" : "Generated · GPU · live").font(.caption).foregroundColor(.secondary)
            Button("Set as Wallpaper") {
                Task { if let record = await library.installBuiltIn(scene) { await library.play(record) } }
            }
            .buttonStyle(.borderedProminent)
        }
        .onAppear { loader.load(scene) }
    }
}
