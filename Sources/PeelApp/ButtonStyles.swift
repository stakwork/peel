import SwiftUI

/// The quiet bordered button of the account screen; `prominent` for the one
/// that commits (`fill` in place of the button colour, such as orange for a
/// payment waiting for its second click).
struct GhostButtonStyle: ButtonStyle {
    var prominent = false
    var fill: Color?
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.font(13, prominent ? .medium : .regular))
            .foregroundStyle(prominent ? Theme.buttonText : Theme.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(prominent ? fill ?? Theme.button : configuration.isPressed ? Theme.hover : .clear)
            )
            .overlay {
                if !prominent { RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.divider) }
            }
            .opacity(isEnabled ? (configuration.isPressed && prominent ? 0.85 : 1) : 0.45)
            .contentShape(Rectangle())
            .environment(\.filledButton, prominent)
    }
}

extension EnvironmentValues {
    /// Set by the filled button styles (`GhostButtonStyle(prominent:)`,
    /// `PrimaryButtonStyle`): marks in the label (the copy check, the
    /// spinner) take the button's own text colour, not their usual one.
    @Entry var filledButton = false
}

extension View {
    /// A button's label while its action runs: the spinner takes the label's
    /// place inside the button and the label stays laid out, hidden, so the
    /// button keeps its width and nothing beside it moves. Never a spinner
    /// beside a button. `size` is `.mini` for the small text buttons of a row.
    /// Only in a style SwiftUI draws (`GhostButtonStyle`, `PrimaryButtonStyle`,
    /// `.plain`): the system bordered button may not animate what its label holds.
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

struct PrimaryButtonStyle: ButtonStyle {
    var fullWidth = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.font(14, .bold))
            .foregroundStyle(Theme.buttonText)
            .padding(.horizontal, 22)
            .padding(.vertical, 11)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .background(Theme.button, in: RoundedRectangle(cornerRadius: 8))
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.45)
            .environment(\.filledButton, true)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.font(14))
            .foregroundStyle(Theme.text)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity)
            .background(configuration.isPressed ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.divider))
    }
}

