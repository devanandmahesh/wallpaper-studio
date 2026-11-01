import SwiftUI
import StudioCore

/// A native grid of free stock videos from Pexels or Pixabay (their official APIs, with the user's own free key).
struct StockView: View {
    @ObservedObject var library: LibraryModel
    @StateObject private var model: StockModel

    init(library: LibraryModel) {
        self.library = library
        _model = StateObject(wrappedValue: StockModel(library: library))
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            if let message = model.message {
                StatusBanner(text: message) { model.dismissMessage() }
            }
            if !model.hasKey {
                KeyPrompt(model: model)
            } else {
                ScrollView {
                    LazyVGrid(columns: gridColumns, spacing: 18) {
                        ForEach(model.clips) { clip in
                            StockCard(clip: clip, model: model)
                                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                                .onAppear { if clip.id == model.clips.last?.id { model.loadMore() } }
                        }
                    }
                    .animation(.fluid, value: model.clips.map(\.id))
                    .padding(24)
                    if model.isLoading { ProgressView().padding() }
                    else if model.hasMore { Button("Load more") { model.loadMore() }.padding(.bottom, 12) }
                    footer
                }
            }
        }
        .animation(.fluid, value: model.message)
        .onAppear { if model.hasKey && model.clips.isEmpty && !model.isLoading { model.search() } }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Picker("", selection: $model.provider) {
                    ForEach(StockProvider.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 200)
                TextField("Search \(model.provider.name) videos", text: $model.text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.search() }
                Button("Search") { model.search() }.glassButton().disabled(!model.hasKey)
            }
            ChipRow(items: StockCategories.all, selected: { model.text.isEmpty && model.category == $0 }, enabled: model.hasKey,
                    title: { $0 }) { model.choose(category: $0) }
        }
        .padding(.horizontal, 24).padding(.vertical, 8)
    }

    private var footer: some View {
        VStack(spacing: 4) {
            Text(model.provider.licenseNote).font(.caption).foregroundColor(.secondary)
            HStack(spacing: 12) {
                Link("\(model.provider.name) licence", destination: model.provider.licenseURL)
                Link("Manage API key", destination: model.provider.keyHelpURL)
            }
            .font(.caption)
        }
        .padding(.bottom, 16)
    }
}

/// The key being typed. (An observable object, since @State needs the SwiftUI macro plugin that is not installed here.)
private final class KeyDraft: ObservableObject { @Published var text = "" }

private struct KeyPrompt: View {
    @ObservedObject var model: StockModel
    @StateObject private var draft = KeyDraft()

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "key.fill").font(.largeTitle).foregroundColor(.secondary)
            Text("Add a free \(model.provider.name) API key").font(.title3.bold())
            Text("\(model.provider.name) lets apps search its videos with a personal key. It is free and takes about a minute. The key stays on this Mac and is only sent to \(model.provider.name).")
                .multilineTextAlignment(.center).foregroundColor(.secondary).frame(maxWidth: 440)
            Link("Get a free key from \(model.provider.name)", destination: model.provider.keyHelpURL)
            HStack {
                SecureField("Paste your \(model.provider.name) API key", text: $draft.text)
                    .textFieldStyle(.roundedBorder).frame(width: 320)
                    .onSubmit(save)
                Button("Save", action: save).glassButton(prominent: true).disabled(draft.text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }

    private func save() {
        model.setKey(draft.text, for: model.provider)
        draft.text = ""
    }
}

private struct StockCard: View {
    let clip: StockClip
    @ObservedObject var model: StockModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Thumb {
                AsyncImage(url: clip.thumbURL, transaction: Transaction(animation: .easeOut(duration: 0.3))) { phase in
                    if let image = phase.image { image.resizable().scaledToFill().transition(.opacity) }
                    else if phase.error != nil { Image(systemName: "photo").foregroundColor(.secondary) }
                    else { ProgressView() }
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if clip.duration > 0 {
                    Text(String(format: "%d:%02d", clip.duration / 60, clip.duration % 60))
                        .font(.caption2.monospacedDigit()).padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.black.opacity(0.6)).foregroundColor(.white).cornerRadius(4).padding(6)
                }
            }
            Text(clip.title).font(.headline).lineLimit(1)
            HStack(spacing: 4) {
                Text("\(clip.author)\(clip.resolutionLabel.isEmpty ? "" : " · \(clip.resolutionLabel)")")
                    .font(.caption).foregroundColor(.secondary).lineLimit(1)
                Spacer()
                if let page = clip.pageURL { Link(destination: page) { Image(systemName: "arrow.up.right.square") }.help("Open on \(clip.provider.name)") }
            }
            action
        }
    }

    @ViewBuilder private var action: some View {
        Group {
            if model.adding.contains(clip.id) {
                HStack { ProgressView().controlSize(.small); Text("Adding…").font(.caption).foregroundColor(.secondary) }
                    .transition(.opacity)
            } else if model.isAdded(clip) {
                Button("Set as Wallpaper") { model.setAsWallpaper(clip) }.glassButton(prominent: true).transition(.opacity)
            } else {
                Button("Add to Library") { model.add(clip) }.glassButton().transition(.opacity)
            }
        }
        .animation(.snap, value: model.adding.contains(clip.id))
        .animation(.snap, value: model.isAdded(clip))
    }
}
