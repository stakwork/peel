import SwiftUI

/// A badge: shadcn's `Badge`, a short word or count in a capsule, never
/// cut, so only for the app's own short words and numbers. A sidebar
/// row's unread count, gold when the chat mentions you; "New" on a contact
/// who added you; Payments' "+350"; the day over a chat's messages.
///
/// ```swift
/// Badge(count: 12)                 // the unread count, accent
/// Badge(count: 3, .mention)        // gold: it mentions you
/// Badge("New")
/// Badge("+350", .success)
/// Badge("Today", .outline)         // the day divider
/// ```
struct Badge: View {
    enum Style {
        /// White on the accent: unread, new.
        case `default`
        /// `mentionYouText` on `mentionYouFill`: unread that mentions you.
        case mention
        /// The green of received amounts on a soft green.
        case success
        /// 12 pt regular `secondaryText` inside a `divider` hairline, no
        /// fill: a label on a line (the day divider), not a count.
        case outline
    }

    private let text: String
    private let style: Style

    init(_ text: String, _ style: Style = .default) {
        self.text = text
        self.style = style
    }

    init(count: Int, _ style: Style = .default) {
        self.init(Self.text(count), style)
    }

    /// A count as badges show it, capped at "99+".
    static func text(_ count: Int) -> String { count > 99 ? "99+" : "\(count)" }

    var body: some View {
        // Circular ends: the continuous capsule's stroke draws square stubs
        // past its ends at this height.
        let shape = Capsule(style: .circular)
        let outline = style == .outline
        Text(text)
            // A count's digits keep their width; the day's label is words.
            .font(outline ? Theme.font(12) : Theme.font(11, .bold).monospacedDigit())
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(foreground)
            .padding(.horizontal, outline ? 10 : 6)
            .padding(.vertical, outline ? 2 : 1)
            .background(fill, in: shape)
            .overlay { if outline { shape.strokeBorder(Theme.divider) } }
    }

    private var foreground: Color {
        switch style {
        case .default: Theme.buttonText
        case .mention: Theme.mentionYouText
        case .success: Theme.confirmed
        case .outline: Theme.secondaryText
        }
    }

    private var fill: Color {
        switch style {
        case .default: Theme.accent
        case .mention: Theme.mentionYouFill
        case .success: Theme.confirmed.opacity(0.16)
        case .outline: .clear
        }
    }
}

/// Where a chip sits, which sets its fill and hairline: `.field` in a form
/// or panel (a tag), `.inset` in a chat (a boost), as `Card`'s are.
enum ChipStyle {
    case field
    case inset

    /// Lit is on (a tag) or yours (a boost).
    func fill(lit: Bool) -> Color {
        switch self {
        case .field: lit ? Theme.selection : Theme.fieldFill
        case .inset: lit ? Theme.boostMineFill : Theme.quote
        }
    }

    func edge(lit: Bool) -> Color {
        switch self {
        case .field: lit ? Theme.accent.opacity(0.6) : Theme.inputBorder
        case .inset: lit ? Theme.accent.opacity(0.25) : Theme.divider
        }
    }
}

/// A chip: a label in a capsule, shadcn's `Toggle` when given `selected:`.
/// A tribe's tag, on and off in the edit form and shown in its details; a
/// message's boosts (the bolt, the total and the faces inside). With an
/// action it is a button whose hairline firms under the pointer. The label brings its own padding,
/// as a `Card`'s content does; `Chip("design", selected:)` is the tag.
///
/// ```swift
/// Chip("design", selected: $on)
/// Chip(.inset, lit: mine, action: { showing = true }) { boostLabel }
/// ```
struct Chip<Label: View>: View {
    private let style: ChipStyle
    private let lit: Bool
    private let action: (() -> Void)?
    /// Only a toggle tells VoiceOver it is selected; a lit boost is not.
    private var isToggle = false
    private let label: Label

    @State private var hovering = false

    init(_ style: ChipStyle = .field, lit: Bool = false, action: (() -> Void)? = nil,
         @ViewBuilder label: () -> Label) {
        self.style = style
        self.lit = lit
        self.action = action
        self.label = label()
    }

    var body: some View {
        if let action {
            Button(action: action) { capsule }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .accessibilityAddTraits(isToggle && lit ? [.isSelected] : [])
        } else {
            capsule
        }
    }

    private var capsule: some View {
        // Circular ends: the continuous capsule's stroke draws square stubs
        // past its ends at these heights.
        let shape = Capsule(style: .circular)
        return label
            .background(style.fill(lit: lit), in: shape)
            .overlay(shape.strokeBorder(hovering ? Theme.secondaryText.opacity(0.4) : style.edge(lit: lit)))
            .contentShape(shape)
    }
}

extension Chip where Label == ChipText {
    /// A tag that turns on and off: a tick while on.
    init(_ title: String, selected: Binding<Bool>) {
        self.init(lit: selected.wrappedValue, action: { selected.wrappedValue.toggle() }) {
            ChipText(title: title, on: selected.wrappedValue)
        }
        isToggle = true
    }

    /// A tag that only shows.
    init(_ title: String) {
        self.init { ChipText(title: title, on: false) }
    }
}

/// A text chip's label: 12 medium, 24 tall, a tick while on.
struct ChipText: View {
    let title: String
    let on: Bool

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            if on { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)) }
            Text(title).lineLimit(1).truncationMode(.tail)
        }
        .frame(maxWidth: 200)
        .font(Theme.font(12, .medium))
        .foregroundStyle(on ? Theme.selectionText : Theme.text)
        .padding(.horizontal, 10)
        .frame(height: 24)
    }
}
