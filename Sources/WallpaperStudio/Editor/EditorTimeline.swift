import SwiftUI
import StudioCore

/// The timeline for the selected layer: a ruler with the playhead, and one row per animated property with draggable keyframes.
struct EditorTimeline: View {
    @ObservedObject var project: EditorProject
    private let labelWidth: CGFloat = 110

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ruler
                    if let layer = project.selectedLayer, !layer.tracks.isEmpty {
                        ForEach(layer.tracks, id: \.property) { track in row(layer: layer, track: track) }
                    } else {
                        Text(project.selectedLayer == nil ? "Select a layer." : "No animation yet. Press ◆ next to a property to add a keyframe at the playhead.")
                            .font(.caption).foregroundColor(.secondary).padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button { project.isPlaying.toggle() } label: { Image(systemName: project.isPlaying ? "pause.fill" : "play.fill") }
                .keyboardShortcut(.space, modifiers: [])
            Button { project.isPlaying = false; project.playhead = 0 } label: { Image(systemName: "backward.end.fill") }
            Text(String(format: "%.2f / %.0f s", project.playhead, project.document.duration)).font(.caption.monospacedDigit())
            Spacer()
            if let ref = project.selectedKeyframe, let key = keyframe(ref) {
                Picker("Easing", selection: Binding(get: { key.easing }, set: { v in project.edit { $0.setEasing(layer: ref.layerID, property: ref.property, index: ref.index, easing: v) } })) {
                    ForEach(Easing.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.frame(width: 160)
                Button("Delete Keyframe") { project.removeKeyframe(ref) }
            }
        }
        .padding(8)
    }

    private func keyframe(_ ref: KeyframeRef) -> Keyframe? {
        project.document.layer(ref.layerID)?.tracks.first { $0.property == ref.property }.flatMap { $0.keyframes.indices.contains(ref.index) ? $0.keyframes[ref.index] : nil }
    }

    private var ruler: some View {
        HStack(spacing: 0) {
            Text("").frame(width: labelWidth)
            GeometryReader { geo in
                let d = project.document.duration
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.secondary.opacity(0.12))
                    ForEach(0...Int(d), id: \.self) { s in
                        if Double(s) <= d, d <= 30 || s % 5 == 0 {
                            Text("\(s)").font(.system(size: 9)).foregroundColor(.secondary).position(x: geo.size.width * CGFloat(Double(s) / d) + 6, y: 10)
                        }
                    }
                    playheadLine(height: 20, width: geo.size.width)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in scrub(g.location.x, width: geo.size.width) })
            }
            .frame(height: 20)
        }
    }

    private func playheadLine(height: CGFloat, width: CGFloat) -> some View {
        Rectangle().fill(Color.accentColor).frame(width: 2, height: height)
            .offset(x: width * CGFloat(project.playhead / project.document.duration) - 1)
    }

    private func scrub(_ x: CGFloat, width: CGFloat) {
        project.isPlaying = false
        project.playhead = min(max(Double(x / max(width, 1)) * project.document.duration, 0), project.document.duration)
    }

    private func row(layer: SceneLayer, track: Track) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text(track.property.label).font(.caption)
                Picker("", selection: Binding(get: { track.loop }, set: { v in project.edit { $0.setLoop(layer: layer.id, property: track.property, loop: v) } })) {
                    ForEach(LoopMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.labelsHidden().controlSize(.mini)
            }
            .frame(width: labelWidth, alignment: .leading).padding(.leading, 6)
            GeometryReader { geo in
                let d = project.document.duration
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.secondary.opacity(0.06))
                    Rectangle().fill(Color.secondary.opacity(0.2)).frame(height: 1)
                    ForEach(Array(track.keyframes.enumerated()), id: \.offset) { i, key in
                        let ref = KeyframeRef(layerID: layer.id, property: track.property, index: i)
                        let selected = project.selectedKeyframe == ref
                        Image(systemName: "diamond.fill").font(.system(size: selected ? 14 : 11))
                            .foregroundColor(selected ? .accentColor : .primary)
                            .position(x: geo.size.width * CGFloat(key.time / d), y: 15)
                            .gesture(DragGesture(minimumDistance: 1).onChanged { g in
                                project.selectedKeyframe = ref
                                project.moveKeyframe(project.selectedKeyframe ?? ref, to: (Double(g.location.x / max(geo.size.width, 1)) * d * 10).rounded() / 10)
                            })
                            .onTapGesture { project.selectedKeyframe = ref; project.playhead = key.time }
                            .help(String(format: "%.2f s → %.2f", key.time, key.value))
                    }
                    playheadLine(height: 30, width: geo.size.width)
                }
                .contentShape(Rectangle())
                .onTapGesture { project.selectedKeyframe = nil }
            }
            .frame(height: 30)
        }
    }
}
