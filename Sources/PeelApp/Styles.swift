import SwiftUI

extension View {
    /// The small dark box behind the sidebar's search and the fields of
    /// Peel's panels.
    func fieldBoxed() -> some View {
        padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Theme.input, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.divider))
    }
}

extension View {
    /// The quiet panel box behind notices, bars and suggestion lists.
    func panelBoxed() -> some View {
        background(Theme.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.divider))
    }

    /// The raised box of menus, suggestion lists and the hover bar.
    func menuBoxed(cornerRadius: CGFloat = 8, shadow: Bool = true) -> some View {
        background(Theme.menu, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Theme.divider))
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
