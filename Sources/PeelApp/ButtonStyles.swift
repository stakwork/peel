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

