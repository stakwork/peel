import SwiftUI

/// Peel's button, shadcn's `Button`: a variant and a size, drawn from `Theme`
/// alone. See docs/design/README.md, "Buttons".
///
///     Button("Save") { … }.buttonStyle(.peel(.primary))
///     Button("Open") { … }.buttonStyle(.peel(.outline, size: .sm))
///     Button("Show in Finder") { … }.buttonStyle(.peel(.link))
///
/// Every variant has a hover, a pressed and a disabled (half opacity) state;
/// focus styling waits for a later batch. The spinner of a running button
/// goes in its label (`buttonProgress`).
struct PeelButton: ButtonStyle {
    enum Variant {
        /// shadcn's default: commits. Filled with `button`, or `fill`.
        case primary
        /// A quiet `hover` fill.
        case secondary
        /// Bordered on `fieldFill`, as the inputs are.
        case outline
        /// Nothing until the pointer is over it.
        case ghost
        /// Filled `destructive`: the second click of an in-place confirm.
        case destructive
        /// Text in `link` at regular weight, underlined under the pointer; no
        /// box, so it sits in a line of text.
        case link
    }

    enum Size {
        /// 28 tall, 12 pt: a chat card, a row.
        case sm
        /// 32 tall, 13 pt, the height of the inputs: panels and forms.
        case md
        /// 40 tall, 14 pt: onboarding.
        case lg

        var height: CGFloat {
            switch self {
            case .sm: 28
            case .md: 32
            case .lg: 40
            }
        }

        var padding: CGFloat {
            switch self {
            case .sm: 10
            case .md: 12
            case .lg: 16
            }
        }

        var fontSize: CGFloat {
            switch self {
            case .sm: 12
            case .md: 13
            case .lg: 14
            }
        }
    }

    var variant: Variant
    var size = Size.md
    /// Replaces a primary's colour: `attention` for a money button waiting
    /// for its second click (`PayButton`).
    var fill: Color?

    func makeBody(configuration: Configuration) -> some View {
        Chrome(configuration: configuration, style: self)
    }

    private struct Chrome: View {
        let configuration: Configuration
        let style: PeelButton
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        private var variant: Variant { style.variant }
        private var filled: Bool { variant == .primary || variant == .destructive }

        private let shape = RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)

        var body: some View {
            label
                .font(Theme.font(style.size.fontSize, variant == .link ? .regular : .medium))
                .brightness(brightness)
                .opacity(isEnabled ? 1 : 0.5)
                .contentShape(shape)
                .onHover { hovering = $0 }
                .environment(\.filledButton, filled)
        }

        @ViewBuilder private var label: some View {
            if variant == .link {
                configuration.label
                    .foregroundStyle(Theme.link)
                    .underline(active)
                    .opacity(configuration.isPressed ? 0.7 : 1)
            } else {
                configuration.label
                    .foregroundStyle(filled ? Theme.buttonText : Theme.text)
                    .lineLimit(1)
                    .padding(.horizontal, style.size.padding)
                    .frame(height: style.size.height)
                    .background(background, in: shape)
                    .overlay {
                        if variant == .outline { shape.strokeBorder(Theme.inputBorder) }
                    }
            }
        }

        private var active: Bool { isEnabled && (hovering || configuration.isPressed) }

        /// A filled button a touch brighter under the pointer, darker pressed.
        private var brightness: Double {
            guard variant != .outline, variant != .ghost, variant != .link, isEnabled else { return 0 }
            return configuration.isPressed ? -0.07 : hovering ? 0.05 : 0
        }

        private var background: Color {
            switch variant {
            case .primary: style.fill ?? Theme.button
            case .destructive: Theme.destructive
            case .secondary: Theme.hover
            case .outline: active ? Theme.hover : Theme.fieldFill
            case .ghost: active ? Theme.hover : .clear
            case .link: .clear
            }
        }
    }
}

extension ButtonStyle where Self == PeelButton {
    /// `fill` is ignored unless the variant is `.primary`.
    static func peel(_ variant: PeelButton.Variant, size: PeelButton.Size = .md, fill: Color? = nil) -> PeelButton {
        PeelButton(variant: variant, size: size, fill: fill)
    }
}

extension EnvironmentValues {
    /// Set by `PeelButton`'s filled variants (primary and destructive):
    /// marks in the label (the copy check, the spinner) take the button's
    /// own text colour, not their usual one.
    @Entry var filledButton = false
}

extension View {
    /// A button's label while its action runs: the spinner takes the label's
    /// place inside the button and the label stays laid out, hidden, so the
    /// button keeps its width and nothing beside it moves. Never a spinner
    /// beside a button. `size` is `.mini` for the small text buttons of a row.
    /// Only in a style SwiftUI draws (`PeelButton`, `.plain`): the system
    /// bordered button may not animate what its label holds.
    ///
    ///     Button { Task { await save() } } label: { Text("Save").buttonProgress(working) }
    func buttonProgress(_ working: Bool, size: ControlSize = .small) -> some View {
        modifier(ButtonProgress(working: working, size: size))
    }
}

private struct ButtonProgress: ViewModifier {
    let working: Bool
    let size: ControlSize
    @Environment(\.filledButton) private var filled
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .opacity(working ? 0 : 1)
            .accessibilityValue(working ? "Working" : "")
            .overlay {
                if working {
                    ProgressView()
                        .controlSize(size)
                        // The system spinner draws in its scheme's grey; on a fill
                        // the other scheme's grey reads like the button's text.
                        .environment(\.colorScheme, filled ? (colorScheme == .dark ? .light : .dark) : colorScheme)
                }
            }
    }
}
