import SwiftUI
import AppKit
import StudioCore

struct EditorInspector: View {
    @ObservedObject var project: EditorProject

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                if let layer = project.selectedLayer {
                    layerSection(layer)
                    contentSection(layer)
                    effectsSection(layer)
                    reactionsSection(layer)
                }
                sceneSection
            }
            .padding(14)
        }
    }

    // MARK: Layer

    @ViewBuilder private func layerSection(_ layer: SceneLayer) -> some View {
        SectionTitle("Layer")
        HStack {
            Text("Name").frame(width: 96, alignment: .leading).font(.callout)
            TextField("", text: Binding(get: { layer.name }, set: { project.rename($0) })).textFieldStyle(.roundedBorder)
        }
        PickerRow(label: "Blend", selection: Binding(get: { layer.blend }, set: { v in project.update { $0.blend = v } }),
                  options: BlendMode.allCases, name: { $0.rawValue.capitalized })
        PropertyRow(project: project, property: .opacity, range: 0...1)
        if layer.content.isMedia || layer.content.kind == .visualizer || layer.content.kind == .particles || true {
            PropertyRow(project: project, property: .positionX, range: -1...1)
            PropertyRow(project: project, property: .positionY, range: -1...1)
            PropertyRow(project: project, property: .scale, range: 0.1...3)
            PropertyRow(project: project, property: .rotation, range: -180...180)
        }
        if layer.content.isMedia {
            PickerRow(label: "Fit", selection: Binding(get: { layer.scaling }, set: { v in project.update { $0.scaling = v } }),
                      options: ScalingMode.allCases, name: { $0.label })
            ValueRow(label: "Parallax depth", value: Binding(get: { layer.parallaxDepth }, set: { v in project.update(key: "parallax") { $0.parallaxDepth = v } }), range: 0...1)
            HStack {
                Button("Replace Media…") { pickMedia { project.replaceMedia(with: $0) } }
                Button(layer.depthAsset == nil ? "Add Depth Map…" : "Change Depth Map…") { pickMedia { project.setDepthMap(from: $0) } }
                if layer.depthAsset != nil { Button("Remove") { project.update { $0.depthAsset = nil } } }
            }
        } else {
            ValueRow(label: "Parallax depth", value: Binding(get: { layer.parallaxDepth }, set: { v in project.update(key: "parallax") { $0.parallaxDepth = v } }), range: 0...1)
        }
    }

    private func pickMedia(_ done: (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Choose an image or video"
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { done(url) }
    }

    // MARK: Content

    @ViewBuilder private func contentSection(_ layer: SceneLayer) -> some View {
        SectionTitle("Content: \(layer.content.kind.rawValue)")
        switch layer.content.kind {
        case .color:
            ColorRow(label: "Colour", color: colorBinding({ layer.content.color }, { c in project.update(key: "c1") { $0.content.color = c } }))
        case .gradient:
            ColorRow(label: "Top", color: colorBinding({ layer.content.color }, { c in project.update(key: "c1") { $0.content.color = c } }))
            ColorRow(label: "Bottom", color: colorBinding({ layer.content.color2 }, { c in project.update(key: "c2") { $0.content.color2 = c } }))
        case .procedural:
            PickerRow(label: "Pattern", selection: Binding(get: { layer.content.procedural ?? .plasma }, set: { v in project.update { $0.content.procedural = v } }),
                      options: ProceduralKind.allCases, name: { $0.rawValue.capitalized })
            ValueRow(label: "Speed", value: Binding(get: { layer.content.speed }, set: { v in project.update(key: "speed") { $0.content.speed = v } }), range: 0...3)
            ValueRow(label: "Scale", value: Binding(get: { layer.content.scale }, set: { v in project.update(key: "pscale") { $0.content.scale = v } }), range: 0.3...3)
            ColorRow(label: "Colour A", color: colorBinding({ layer.content.color }, { c in project.update(key: "c1") { $0.content.color = c } }))
            ColorRow(label: "Colour B", color: colorBinding({ layer.content.color2 }, { c in project.update(key: "c2") { $0.content.color2 = c } }))
        case .image, .video:
            Text(layer.content.asset ?? "").font(.caption).foregroundColor(.secondary)
        case .particles:
            particleEditor(layer)
        case .visualizer:
            visualizerEditor(layer)
        }
    }

    private func particles(_ layer: SceneLayer) -> ParticleSpec { layer.content.particles ?? ParticleSpec() }
    private func editParticles(key: String, _ change: @escaping (inout ParticleSpec) -> Void) {
        project.update(key: key) { var p = $0.content.particles ?? ParticleSpec(); change(&p); $0.content.particles = p }
    }

    @ViewBuilder private func particleEditor(_ layer: SceneLayer) -> some View {
        let p = particles(layer)
        HStack {
            Text("Preset").frame(width: 96, alignment: .leading).font(.callout)
            Menu("Apply…") { ForEach(ParticlePreset.allCases, id: \.self) { preset in Button(preset.label) { project.update { $0.content.particles = preset.spec } } } }
        }
        ValueRow(label: "Count", value: Binding(get: { Double(p.count) }, set: { v in editParticles(key: "count") { $0.count = max(1, Int(v)); $0.burstCount = min($0.burstCount, $0.count); $0.beatBurstCount = min($0.beatBurstCount, $0.count) } }), range: 10...5000)
        ValueRow(label: "Size", value: Binding(get: { p.sizeStart }, set: { v in editParticles(key: "size") { $0.sizeStart = v; $0.sizeEnd = max($0.sizeEnd, 0) } }), range: 0.002...0.06)
        ValueRow(label: "Speed", value: Binding(get: { p.speedMax }, set: { v in editParticles(key: "speed") { $0.speedMax = v; $0.speedMin = min($0.speedMin, v) } }), range: 0...1)
        ValueRow(label: "Gravity", value: Binding(get: { p.gravityY }, set: { v in editParticles(key: "grav") { $0.gravityY = v } }), range: -1...1)
        ValueRow(label: "Drift", value: Binding(get: { p.turbulence }, set: { v in editParticles(key: "turb") { $0.turbulence = v } }), range: 0...0.3)
        ValueRow(label: "Drag", value: Binding(get: { p.drag }, set: { v in editParticles(key: "drag") { $0.drag = v } }), range: 0...3)
        PickerRow(label: "Mouse", selection: Binding(get: { p.pointerMode }, set: { v in editParticles(key: "pm") { $0.pointerMode = v } }), options: PointerMode.allCases, name: { $0.rawValue.capitalized })
        PickerRow(label: "Emitter", selection: Binding(get: { p.shape }, set: { v in editParticles(key: "shape") { $0.shape = v } }), options: EmitterShape.allCases, name: { $0.rawValue.capitalized })
        ValueRow(label: "Click burst", value: Binding(get: { Double(p.burstCount) }, set: { v in editParticles(key: "burst") { $0.burstCount = min(Int(v), $0.count) } }), range: 0...300)
        ValueRow(label: "Beat burst", value: Binding(get: { Double(p.beatBurstCount) }, set: { v in editParticles(key: "bbeat") { $0.beatBurstCount = min(Int(v), $0.count) } }), range: 0...300)
        ValueRow(label: "Bass swell", value: Binding(get: { p.audioSizeGain }, set: { v in editParticles(key: "bass") { $0.audioSizeGain = v } }), range: 0...3)
        ColorRow(label: "Colour start", color: colorBinding({ p.colorStart }, { c in editParticles(key: "cs") { $0.colorStart = c } }))
        ColorRow(label: "Colour end", color: colorBinding({ p.colorEnd }, { c in editParticles(key: "ce") { $0.colorEnd = c } }))
    }

    private func visualizer(_ layer: SceneLayer) -> VisualizerSpec { layer.content.visualizer ?? VisualizerSpec() }
    private func editViz(key: String, _ change: @escaping (inout VisualizerSpec) -> Void) {
        project.update(key: key) { var v = $0.content.visualizer ?? VisualizerSpec(); change(&v); $0.content.visualizer = v }
    }

    @ViewBuilder private func visualizerEditor(_ layer: SceneLayer) -> some View {
        let v = visualizer(layer)
        PickerRow(label: "Style", selection: Binding(get: { v.style }, set: { s in editViz(key: "style") { $0.style = s } }), options: VisualizerStyle.allCases, name: { $0.label })
        ValueRow(label: "Bars", value: Binding(get: { Double(v.bandCount) }, set: { x in editViz(key: "bands") { $0.bandCount = min(max(Int(x), 4), 32) } }), range: 4...32)
        ValueRow(label: "Height", value: Binding(get: { v.amplitude }, set: { x in editViz(key: "amp") { $0.amplitude = x } }), range: 0.05...1)
        ValueRow(label: "Thickness", value: Binding(get: { v.thickness }, set: { x in editViz(key: "thick") { $0.thickness = x } }), range: 0.001...0.1)
        ValueRow(label: "Gap", value: Binding(get: { v.gap }, set: { x in editViz(key: "gap") { $0.gap = x } }), range: 0...0.8)
        ValueRow(label: "Glow", value: Binding(get: { v.glow }, set: { x in editViz(key: "glow") { $0.glow = x } }), range: 0...4)
        ValueRow(label: "Ring size", value: Binding(get: { v.size }, set: { x in editViz(key: "ring") { $0.size = x } }), range: 0.05...0.5)
        ValueRow(label: "Colour drift", value: Binding(get: { v.hueReactivity }, set: { x in editViz(key: "hue") { $0.hueReactivity = x } }), range: -2...2)
        ColorRow(label: "Low colour", color: colorBinding({ v.color }, { c in editViz(key: "c1") { $0.color = c } }))
        ColorRow(label: "High colour", color: colorBinding({ v.color2 }, { c in editViz(key: "c2") { $0.color2 = c } }))
    }

    // MARK: Effects

    @ViewBuilder private func effectsSection(_ layer: SceneLayer) -> some View {
        SectionTitle("Effects")
        PropertyRow(project: project, property: .hueShift, range: -180...180)
        fx(layer, "Colour cycle", 0...0.5, "cycle", { $0.hueCycle }, { $0.hueCycle = $1 })
        PropertyRow(project: project, property: .brightness, range: -0.6...0.6)
        fx(layer, "Contrast", 0.4...2, "contrast", { $0.contrast }, { $0.contrast = $1 })
        PropertyRow(project: project, property: .saturation, range: 0...2)
        PropertyRow(project: project, property: .vignette, range: 0...1)
        PropertyRow(project: project, property: .rippleAmplitude, range: 0...0.03, label: "Ripple")
        PropertyRow(project: project, property: .lightIntensity, range: 0...2)
        PropertyRow(project: project, property: .lightX, range: 0...1)
        PropertyRow(project: project, property: .lightY, range: 0...1)
        PropertyRow(project: project, property: .lightRadius, range: 0.05...1)
        ColorRow(label: "Light colour", color: colorBinding({ layer.effects.lightColor }, { c in project.update(key: "lc") { $0.effects.lightColor = c } }))
        fx(layer, "Flicker", 0...1, "flicker", { $0.lightFlicker }, { $0.lightFlicker = $1 })
    }

    private func fx(_ layer: SceneLayer, _ label: String, _ range: ClosedRange<Double>, _ key: String,
                    _ get: @escaping (LayerEffects) -> Double, _ set: @escaping (inout LayerEffects, Double) -> Void) -> some View {
        ValueRow(label: label, value: Binding(get: { get(layer.effects) }, set: { v in project.update(key: key) { set(&$0.effects, v) } }), range: range)
    }

    // MARK: Reactions

    private static let quickReactions: [(String, InputBinding)] = [
        ("Light follows the mouse (X)", InputBinding(source: .pointerX, target: .lightX, gain: 0.5)),
        ("Light follows the mouse (Y)", InputBinding(source: .pointerY, target: .lightY, gain: -0.5)),
        ("Swell with the bass", InputBinding(source: .audioBass, target: .scale, gain: 0.15)),
        ("Brighten on the beat", InputBinding(source: .audioBeat, target: .brightness, gain: 0.3)),
        ("Hue drifts with loudness", InputBinding(source: .audioLevel, target: .hueShift, gain: 120)),
        ("Flare when you click", InputBinding(source: .clickPulse, target: .lightIntensity, gain: 1)),
        ("Swell while typing", InputBinding(source: .keyPulse, target: .scale, gain: 0.1)),
    ]

    @ViewBuilder private func reactionsSection(_ layer: SceneLayer) -> some View {
        SectionTitle("Reactions (mouse, typing, audio)")
        ForEach(Array(layer.bindings.enumerated()), id: \.offset) { i, b in
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Picker("", selection: Binding(get: { b.source }, set: { v in project.update { $0.bindings[i].source = v } })) {
                        ForEach(InputSource.allCases, id: \.self) { Text($0.label).tag($0) }
                    }.labelsHidden()
                    Image(systemName: "arrow.right").foregroundColor(.secondary)
                    Picker("", selection: Binding(get: { b.target }, set: { v in project.update { $0.bindings[i].target = v } })) {
                        ForEach(AnimatableProperty.allCases, id: \.self) { Text($0.label).tag($0) }
                    }.labelsHidden()
                    Button { project.update { $0.bindings.remove(at: i) } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                }
                ValueRow(label: "Amount", value: Binding(get: { b.gain }, set: { v in project.update(key: "gain\(i)") { $0.bindings[i].gain = v } }), range: -200...200)
            }
        }
        Menu("Add Reaction") {
            ForEach(Array(Self.quickReactions.enumerated()), id: \.offset) { _, entry in
                Button(entry.0) { if let id = project.selection { project.edit { $0.addBinding(layer: id, entry.1) } } }
            }
        }
        .disabled(layer.bindings.count >= 16)
    }

    // MARK: Scene

    private var sceneSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle("Scene")
            HStack {
                Text("Name").frame(width: 96, alignment: .leading).font(.callout)
                TextField("", text: Binding(get: { project.scene.name }, set: { project.setSceneName($0) })).textFieldStyle(.roundedBorder)
            }
            ColorRow(label: "Background", color: colorBinding({ project.scene.background }, { c in project.edit(key: "bg") { $0.scene.background = RGBA(c.r, c.g, c.b, 1) } }))
            ValueRow(label: "Timeline (s)", value: Binding(get: { project.document.duration }, set: { project.setDuration($0.rounded()) }), range: 1...120)
            SectionTitle("Mouse zones")
            ForEach(project.scene.zones) { zone in zoneEditor(zone) }
            Button("Add Zone for Selected Layer") {
                if let id = project.selection { project.edit { _ = $0.addZone(layerID: id) } }
            }
            .disabled(project.selection == nil || project.scene.zones.count >= 32)
            Text("A zone reacts when the mouse hovers or clicks inside the rectangle (fractions of the screen, top-left origin).")
                .font(.caption).foregroundColor(.secondary)
        }
    }

    @ViewBuilder private func zoneEditor(_ zone: InteractionZone) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(zone.id).font(.caption.weight(.semibold))
                Spacer()
                Button { project.edit { $0.removeZone(zone.id) } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
            }
            PickerRow(label: "When", selection: Binding(get: { zone.trigger }, set: { v in project.edit { $0.updateZone(zone.id) { $0.trigger = v } } }),
                      options: InteractionZone.Trigger.allCases, name: { $0 == .hover ? "Mouse hovers" : "Mouse clicks" })
            PickerRow(label: "Layer", selection: Binding(get: { zone.layerID }, set: { v in project.edit { $0.updateZone(zone.id) { $0.layerID = v } } }),
                      options: project.scene.layers.map(\.id), name: { id in project.scene.layers.first { $0.id == id }?.name ?? id })
            PickerRow(label: "Changes", selection: Binding(get: { zone.property }, set: { v in project.edit { $0.updateZone(zone.id) { $0.property = v } } }),
                      options: AnimatableProperty.allCases, name: { $0.label })
            ValueRow(label: "By", value: Binding(get: { zone.amount }, set: { v in project.edit(key: "za-\(zone.id)") { $0.updateZone(zone.id) { $0.amount = v } } }), range: -2...2)
            ValueRow(label: "Left", value: Binding(get: { zone.x }, set: { v in project.edit(key: "zx-\(zone.id)") { $0.updateZone(zone.id) { $0.x = v } } }), range: 0...1)
            ValueRow(label: "Top", value: Binding(get: { zone.y }, set: { v in project.edit(key: "zy-\(zone.id)") { $0.updateZone(zone.id) { $0.y = v } } }), range: 0...1)
            ValueRow(label: "Width", value: Binding(get: { zone.width }, set: { v in project.edit(key: "zw-\(zone.id)") { $0.updateZone(zone.id) { $0.width = v } } }), range: 0.02...1)
            ValueRow(label: "Height", value: Binding(get: { zone.height }, set: { v in project.edit(key: "zh-\(zone.id)") { $0.updateZone(zone.id) { $0.height = v } } }), range: 0.02...1)
        }
        .padding(8).background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }
}
