import SwiftUI

// Fields are `FormKit`'s (`FormTextField`, `FormNumberField`, `FieldChrome`).

extension View {
    /// The raised box of menus, suggestion lists and the hover bar.
    /// `.circular` for a box whose radius is half its height or more: the
    /// continuous stroke draws square stubs there.
    func menuBoxed(
        cornerRadius: CGFloat = 8, style: RoundedCornerStyle = .continuous, shadow: Bool = true
    ) -> some View {
        background(Theme.menu, in: RoundedRectangle(cornerRadius: cornerRadius, style: style))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: style).strokeBorder(Theme.divider))
            .shadow(color: .black.opacity(shadow ? 0.25 : 0), radius: 10, y: 4)
    }
}

extension View {
    /// A dropdown's box: `PeelDropdown`, and buttons that open a panel to choose in.
    func dropdownBoxed(hovering: Bool) -> some View {
        padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(hovering ? Theme.hover : Theme.input, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.divider))
            .contentShape(Rectangle())
    }
}
