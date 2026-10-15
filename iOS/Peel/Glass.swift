import SwiftUI

// Liquid Glass on the phone's floating chrome, and only there
// (docs/design/iphone.md, "Liquid Glass"): the system's `.glassEffect`,
// never on rows, messages, cards or panels. Reduce Transparency, Increase
// Contrast and Reduce Motion are the system glass's own.
//
// In a navigation bar the system already draws the glass: put neighbouring
// buttons in one `ToolbarItemGroup` and they share a capsule. These are for
// chrome the bar does not hold: a capsule beside a hand-drawn title, the
// composer's buttons, a close button over a sheet.

/// Neighbouring glass buttons in one capsule, 44 tall, that morphs as a
/// button joins or leaves:
///
///     GlassCapsule {
///         GlassCapsuleButton("phone", label: "Call") { … }
///         GlassCapsuleButton("ellipsis", label: "More") { … }
///     }
struct GlassCapsule<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        GlassEffectContainer {
            HStack(spacing: 0) { content }
                .glassEffect(.regular.interactive(), in: Capsule())
        }
    }
}

/// One button in a `GlassCapsule`: an SF Symbol in a 46 by 44 slot, its
/// label for VoiceOver. `tint` colours the symbol (orange for not
/// connected); otherwise it is `text`.
struct GlassCapsuleButton: View {
    let symbol: GlassSymbol
    let action: () -> Void

    init(_ systemImage: String, label: String, tint: Color? = nil, action: @escaping () -> Void) {
        symbol = GlassSymbol(systemImage: systemImage, label: label, tint: tint)
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            symbol.frame(width: 46, height: Theme.touchTarget).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(symbol.label)
    }
}

/// A round glass button, 44 across: back, close, More beside a hand-drawn
/// header, Attach beside the composer.
struct GlassButton: View {
    let symbol: GlassSymbol
    let action: () -> Void

    init(_ systemImage: String, label: String, tint: Color? = nil, action: @escaping () -> Void) {
        symbol = GlassSymbol(systemImage: systemImage, label: label, tint: tint)
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            symbol.frame(width: Theme.touchTarget, height: Theme.touchTarget).contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .accessibilityLabel(symbol.label)
    }
}

/// The symbol on a glass button: 17 medium, in `tint` or `text`.
struct GlassSymbol: View {
    let systemImage: String
    let label: String
    let tint: Color?

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(tint ?? Theme.text)
    }
}

extension View {
    /// Chrome that floats over a scrolling list at `edge` (the composer, a
    /// bottom bar): the list's content insets clear it, scrolls under it,
    /// and fades under it with the system's scroll-edge effect rather than
    /// a hand-made gradient.
    func floatingBar(_ edge: VerticalEdge, @ViewBuilder content: () -> some View) -> some View {
        safeAreaBar(edge: edge, content: content)
    }

    /// The soft scroll-edge effect at the top and bottom, where the bars
    /// and the tab bar float over the list.
    func scrollEdges() -> some View {
        scrollEdgeEffectStyle(.soft, for: .vertical)
    }
}
