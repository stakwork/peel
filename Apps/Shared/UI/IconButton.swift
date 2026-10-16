import SwiftUI
import PeelUI

/// Peel's icon button, shadcn's `<Button variant="ghost" size="icon">`: an
/// SF Symbol, or any label, in a square that lights under the pointer. It
/// always carries its tooltip and accessibility label (`help`). See
/// docs/design/README.md, "Icon buttons".
///
///     IconButton("xmark", help: "Close", action: close)
///     IconButton("ellipsis", help: "More", lit: menuOpen) { … }
///     IconButton("phone", help: "Start a call", working: starting) { … }
///     IconButton(help: title, action: copy) { CopyLabel(…) }   // any label
///
/// The icon is `secondaryText` at rest and `text` under the pointer, pressed
/// or `lit`; a label that sets its own colour keeps it. Disabled is half
/// opacity with no hover, as `PeelButton`.
struct IconButton<Label: View>: View {
    enum Variant {
        /// Nothing until the pointer is over it: headers, bars, the hover bar.
        case ghost
        /// Bordered on `fieldFill`, as `PeelButton`'s outline: beside an
        /// outline button (the call bar's microphone).
        case outline
    }

    enum Size {
        /// 24 square: a small control beside a name (the connection bolt).
        case sm
        /// 28 square, the height of a `.sm` `PeelButton`.
        case md

        var side: CGFloat {
            switch self {
            case .sm: 24
            case .md: PeelButton.Size.sm.height
            }
        }
    }

    let help: String
    var variant = Variant.ghost
    var size = Size.md
    /// What it opened is open (its menu, its panel, the search): drawn as
    /// under the pointer.
    var lit = false
    /// Its action is running: the spinner takes the icon's place.
    var working = false
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button(action: action) {
            label().buttonProgress(working)
        }
        .buttonStyle(Style(variant: variant, side: size.side, lit: lit))
        .help(help)
        .accessibilityLabel(help)
    }

    private struct Style: ButtonStyle {
        let variant: Variant
        let side: CGFloat
        let lit: Bool

        func makeBody(configuration: Configuration) -> some View {
            Chrome(configuration: configuration, style: self)
        }
    }

    private struct Chrome: View {
        let configuration: ButtonStyleConfiguration
        let style: Style
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        private let shape = RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)

        var body: some View {
            let on = isEnabled && (style.lit || hovering || configuration.isPressed)
            configuration.label
                .font(.system(size: 13))
                .foregroundStyle(on ? Theme.text : Theme.secondaryText)
                .frame(width: style.side, height: style.side)
                .background(on ? Theme.hover : style.variant == .outline ? Theme.fieldFill : .clear, in: shape)
                .overlay {
                    if style.variant == .outline { shape.strokeBorder(Theme.inputBorder) }
                }
                .opacity(isEnabled ? 1 : 0.5)
                .contentShape(shape)
                .onHover { hovering = $0 }
                // A disabled button may never hear the pointer leave.
                .onChange(of: isEnabled) { if !isEnabled { hovering = false } }
        }
    }
}

extension IconButton where Label == Image {
    init(
        _ systemImage: String, help: String, variant: Variant = .ghost, size: Size = .md, lit: Bool = false,
        working: Bool = false, action: @escaping () -> Void
    ) {
        self.init(help: help, variant: variant, size: size, lit: lit, working: working, action: action) {
            Image(systemName: systemImage)
        }
    }
}
