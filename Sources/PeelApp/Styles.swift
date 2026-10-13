import SwiftUI

// Fields are `FormKit`'s (`FormTextField`, `FormNumberField`, `FieldChrome`).

extension View {
    /// The raised box of menus, suggestion lists and the hover bar, in a
    /// rounded rectangle of `cornerRadius` (`.circular` for one whose
    /// radius is half its height or more: the continuous stroke draws
    /// square stubs there).
    func menuBoxed(
        cornerRadius: CGFloat = Theme.Radius.card, style: RoundedCornerStyle = .continuous, shadow: Bool = true
    ) -> some View {
        menuBoxed(in: RoundedRectangle(cornerRadius: cornerRadius, style: style), shadow: shadow)
    }

    /// The same box in any shape: a capsule (the "Copied" pill), a circle
    /// (the jump to newest button).
    func menuBoxed(in shape: some InsettableShape, shadow: Bool = true) -> some View {
        background(Theme.menu, in: shape)
            .overlay(shape.strokeBorder(Theme.divider))
            .shadow(color: shadow ? Theme.menuShadow : .clear, radius: 10, y: 4)
    }

    /// A muted line under or beside what it explains: 12 pt `secondaryText`,
    /// wrapping (shadcn's `text-muted-foreground text-sm`).
    func muted() -> some View {
        font(Theme.font(12))
            .foregroundStyle(Theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension View {
    /// A dropdown's box: `PeelDropdown`, and buttons that open a panel to choose in.
    func dropdownBoxed(hovering: Bool) -> some View {
        padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(hovering ? Theme.hover : Theme.input, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(Theme.divider))
            .contentShape(Rectangle())
    }
}
