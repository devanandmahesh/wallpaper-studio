import SwiftUI
import AppKit
import StudioCore

/// Small reusable controls for the inspector.

func colorBinding(_ get: @escaping () -> RGBA, _ set: @escaping (RGBA) -> Void) -> Binding<Color> {
    Binding(get: { let c = get(); return Color(.sRGB, red: Double(c.r), green: Double(c.g), blue: Double(c.b), opacity: Double(c.a)) },
            set: { color in
                let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
                set(RGBA(Float(ns.redComponent), Float(ns.greenComponent), Float(ns.blueComponent), Float(ns.alphaComponent)))
            })
}

struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).font(.caption.weight(.semibold)).foregroundColor(.secondary).padding(.top, 14).padding(.bottom, 2)
    }
}

/// A slider for any number that is not animated.
struct ValueRow: View {
    let label: String
    let value: Binding<Double>
    let range: ClosedRange<Double>
    var body: some View {
        HStack {
            Text(label).frame(width: 96, alignment: .leading).font(.callout)
            Slider(value: value, in: range)
            Text(String(format: "%.2f", value.wrappedValue)).font(.caption.monospacedDigit()).frame(width: 46, alignment: .trailing).foregroundColor(.secondary)
        }
    }
}

/// A slider for an animatable layer property, with a ◆ button that records a keyframe at the playhead.
struct PropertyRow: View {
    @ObservedObject var project: EditorProject
    let property: AnimatableProperty
    let range: ClosedRange<Double>
    var label: String? = nil

    var body: some View {
        let animated = project.isAnimated(property)
        HStack {
            Text(label ?? property.label).frame(width: 96, alignment: .leading).font(.callout)
            Slider(value: Binding(get: { project.value(property) }, set: { project.setValue(property, $0) }), in: range)
            Text(String(format: "%.2f", project.value(property))).font(.caption.monospacedDigit()).frame(width: 46, alignment: .trailing).foregroundColor(.secondary)
            Button { project.addKeyframe(property) } label: { Image(systemName: animated ? "diamond.fill" : "diamond") }
                .buttonStyle(.plain).foregroundColor(animated ? .accentColor : .secondary)
                .help(animated ? "Animated: edits set a keyframe at the playhead. Click to add one here." : "Click to add a keyframe at the playhead and animate this property.")
        }
    }
}

struct ColorRow: View {
    let label: String
    let color: Binding<Color>
    var body: some View {
        HStack { Text(label).frame(width: 96, alignment: .leading).font(.callout); ColorPicker("", selection: color).labelsHidden(); Spacer() }
    }
}

struct PickerRow<Value: Hashable>: View {
    let label: String
    let selection: Binding<Value>
    let options: [Value]
    let name: (Value) -> String
    var body: some View {
        HStack {
            Text(label).frame(width: 96, alignment: .leading).font(.callout)
            Picker("", selection: selection) { ForEach(options, id: \.self) { Text(name($0)).tag($0) } }.labelsHidden()
        }
    }
}
