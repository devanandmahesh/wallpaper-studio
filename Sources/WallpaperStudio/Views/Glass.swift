import SwiftUI
import AppKit

// Liquid Glass (macOS 26+) for the navigation layer only: controls, chips, the now-playing bar. Content (thumbnails, lists, text)
// is never glass. Everything here falls back to a plain material or system style on macOS 14 and 15, so the app still runs there.

extension Animation {
    /// The app's standard motion: smooth, no overshoot. Collapses to a near-instant change when the user turned on Reduce Motion.
    static var fluid: Animation { reduceMotion ? .linear(duration: 0.01) : .smooth(duration: 0.32) }
    /// Quicker, for small state changes (a chip, a button label).
    static var snap: Animation { reduceMotion ? .linear(duration: 0.01) : .snappy(duration: 0.22) }
    private static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

extension AnyTransition {
    /// Switching pages: the old one leaves quickly and the new one arrives just after, so two dense pages are never both clearly visible.
    static var page: AnyTransition {
        let quiet = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        return .asymmetric(
            insertion: .opacity.animation(quiet ? .linear(duration: 0.01) : .easeOut(duration: 0.26).delay(0.1)),
            removal: .opacity.animation(quiet ? .linear(duration: 0.01) : .easeIn(duration: 0.12)))
    }
}

/// Hover feedback for a card: a slight lift. (An observable object, since @State needs the SwiftUI macro plugin that is not installed here.)
private final class HoverState: ObservableObject { @Published var on = false }

private struct HoverLift: ViewModifier {
    @StateObject private var hover = HoverState()
    func body(content: Content) -> some View {
        content
            .scaleEffect(hover.on ? 1.02 : 1)
            .shadow(color: .black.opacity(hover.on ? 0.28 : 0), radius: hover.on ? 12 : 0, y: hover.on ? 6 : 0)
            .animation(.snap, value: hover.on)
            .onHover { hover.on = $0 }
    }
}

extension View {
    func hoverLift() -> some View { modifier(HoverLift()) }

    /// A glass button; `prominent` is for the one primary action in a group.
    @ViewBuilder func glassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26, *) {
            if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
        } else {
            if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
        }
    }

    /// Floating glass behind a control cluster (falls back to a material).
    @ViewBuilder func glassSurface<S: Shape>(in shape: S, tint: Color? = nil) -> some View {
        if #available(macOS 26, *) {
            if let tint { glassEffect(.regular.tint(tint), in: shape) } else { glassEffect(.regular, in: shape) }
        } else {
            background(.regularMaterial, in: shape)
        }
    }

    /// No blurred strip behind the empty window toolbar (the pages draw their own headings).
    @ViewBuilder func clearWindowToolbar() -> some View {
        if #available(macOS 15, *) { toolbarBackgroundVisibility(.hidden, for: .windowToolbar) } else { self }
    }

    /// The page heading sits right under the window toolbar; the toolbar's blur must not smear it.
    @ViewBuilder func clearTopEdge() -> some View {
        if #available(macOS 26, *) { scrollEdgeEffectStyle(.hard, for: .top) } else { self }
    }

    /// Lets content fade softly under a floating glass bar at the bottom edge.
    @ViewBuilder func softBottomEdge() -> some View {
        if #available(macOS 26, *) { scrollEdgeEffectStyle(.soft, for: .bottom) } else { self }
    }
}

/// Glass cannot sample other glass, so neighbouring glass shapes share one container.
struct GlassGroup<Content: View>: View {
    let spacing: CGFloat
    let content: Content
    init(spacing: CGFloat = 12, @ViewBuilder _ content: () -> Content) { self.spacing = spacing; self.content = content() }
    var body: some View {
        if #available(macOS 26, *) { GlassEffectContainer(spacing: spacing) { content } } else { content }
    }
}

/// A selectable pill (categories, tags, weekdays).
struct GlassChip: View {
    let title: String
    let selected: Bool
    var compact = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(compact ? .caption : .body)
                .padding(.horizontal, compact ? 10 : 14).padding(.vertical, compact ? 4 : 6)
                .foregroundColor(selected ? .white : .primary)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .modifier(ChipBackground(selected: selected))
        .animation(.snap, value: selected)
    }
}

private struct ChipBackground: ViewModifier {
    let selected: Bool
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(selected ? .regular.tint(.accentColor).interactive() : .regular.interactive(), in: Capsule())
        } else {
            content.background(Capsule().fill(selected ? Color.accentColor : Color.secondary.opacity(0.18)))
        }
    }
}

/// A horizontally scrolling row of chips sharing one glass container.
struct ChipRow<Item: Hashable>: View {
    let items: [Item]
    let selected: (Item) -> Bool
    var compact = false
    var enabled = true
    let title: (Item) -> String
    let action: (Item) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassGroup(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(items, id: \.self) { item in
                        GlassChip(title: title(item), selected: selected(item), compact: compact) { action(item) }
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .disabled(!enabled)
    }
}

/// A transient message strip (status after an import, a download, an error).
struct StatusBanner: View {
    let text: String
    let dismiss: () -> Void
    var body: some View {
        HStack {
            Text(text).font(.callout)
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .glassSurface(in: RoundedRectangle(cornerRadius: 14, style: .continuous), tint: Color.accentColor.opacity(0.35))
        .padding(.horizontal, 24).padding(.bottom, 6)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
