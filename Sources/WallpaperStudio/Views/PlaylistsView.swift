import SwiftUI

struct PlaylistsView: View {
    @ObservedObject var engine: AppDelegate
    @ObservedObject var library: LibraryModel
    @ObservedObject var schedule: ScheduleController

    var body: some View {
        VStack(spacing: 0) {
            PageHeader("Playlists", "Play every video in a folder, in order or shuffled") {
                HStack {
                    Menu("Play a Collection") {
                        ForEach(library.collections) { c in
                            Button(c.name) {
                                let files = library.records.filter { !$0.isTrashed && (library.memberships[c.id]?.contains($0.id) == true) }.compactMap { library.fileURL($0) }
                                engine.loadPlaylist(files: files)
                            }
                        }
                        if library.collections.isEmpty { Text("Create collections in My Library first") }
                    }
                    Button("Choose Folder…") { engine.chooseFolder() }
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if engine.playlist.count > 1 {
                        HStack(spacing: 16) {
                            Toggle("Shuffle", isOn: Binding(get: { engine.shuffle }, set: { _ in engine.toggleShuffle() }))
                            Picker("Switch every", selection: Binding(get: { engine.interval }, set: { engine.setInterval($0) })) {
                                ForEach(AppDelegate.intervals, id: \.1) { Text($0.0).tag($0.1) }
                            }
                            .frame(width: 220)
                            Spacer()
                            Button("Next") { engine.nextVideo() }
                        }
                        .padding(.horizontal, 24).padding(.vertical, 8)
                        ForEach(Array(engine.playlist.enumerated()), id: \.offset) { i, url in
                            HStack {
                                Image(systemName: i == engine.index ? "play.fill" : "film").frame(width: 20)
                                    .foregroundColor(i == engine.index ? .accentColor : .secondary)
                                Text(url.lastPathComponent)
                                Spacer()
                                if i != engine.index { Button("Play") { engine.play(at: i) } }
                            }
                            .padding(.horizontal, 24).padding(.vertical, 3)
                        }
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "list.and.film").font(.system(size: 40)).foregroundColor(.secondary)
                            Text("No playlist loaded").font(.headline)
                            Text("Choose a folder, or play one of your collections. Images rotate every 30 s unless you pick a different interval.").foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 24)
                    }
                    ScheduleSection(schedule: schedule, library: library)
                }
            }
        }
    }
}
