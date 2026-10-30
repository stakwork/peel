import SwiftUI

// What the phone adds to the Mac's `Theme` (docs/design/iphone.md): the
// Mac's type sizes as Dynamic Type styles, and which grey quiet text takes
// on what surface. Colours are `Theme`'s; there are no phone colours.

/// A Mac size and weight that grows and shrinks with the text style it is
/// tied to: `.phoneFont(.row)`. The sizes are the board's at the default
/// text size (Large).
struct PhoneFont {
    var size: CGFloat
    var weight: Font.Weight = .regular
    var style: Font.TextStyle

    /// The same, at another weight: `.row.weight(.semibold)` for unread.
    func weight(_ weight: Font.Weight) -> PhoneFont {
        var font = self
        font.weight = weight
        return font
    }

    /// 34 bold: a screen's large title when drawn by hand.
    static let largeTitle = PhoneFont(size: 34, weight: .bold, style: .largeTitle)
    /// 22 bold: your name on You.
    static let title = PhoneFont(size: 22, weight: .bold, style: .title2)
    /// 17 semibold: a sheet's or a pushed screen's title.
    static let headline = PhoneFont(size: 17, weight: .semibold, style: .headline)
    /// 16: a chat row's name, a grouped cell, a top row.
    static let row = PhoneFont(size: 16, style: .body)
    /// 15: a message's text (`MessageText(size: PhoneFont.message.size)`).
    static let message = PhoneFont(size: 15, style: .body)
    /// 14 semibold: a sender's name over their run.
    static let name = PhoneFont(size: 14, weight: .semibold, style: .subheadline)
    /// 13: a second line, a note under a title.
    static let secondary = PhoneFont(size: 13, style: .footnote)
    /// 14: the newest reply under a thread row.
    static let reply = PhoneFont(size: 14, style: .subheadline)
    /// 13 semibold: a section's header.
    static let sectionHeader = PhoneFont(size: 13, weight: .semibold, style: .footnote)
    /// 12: a time.
    static let time = PhoneFont(size: 12, style: .caption)
    /// 12 semibold: the digits in a count badge.
    static let badge = PhoneFont(size: 12, weight: .semibold, style: .caption)
}

extension View {
    /// `font` at its Mac size, scaled with Dynamic Type as its text style.
    func phoneFont(_ font: PhoneFont) -> some View {
        modifier(ScaledFont(font: font))
    }
}

private struct ScaledFont: ViewModifier {
    let font: PhoneFont
    @ScaledMetric private var size: CGFloat

    init(font: PhoneFont) {
        self.font = font
        _size = ScaledMetric(wrappedValue: font.size, relativeTo: font.style)
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: font.weight))
    }
}

/// What a view sits on, which decides its quiet grey: `tertiaryText`
/// (`#808D9E`) is over 4.5:1 only on the background and the sheet's panel;
/// on `quote`, `menu` or a tinted row it is `secondaryText` (`#97A3B4`).
enum Surface {
    case background
    /// `quote`, `menu`, a tinted row: set by `PhoneCard` and the panels.
    case raised
}

extension EnvironmentValues {
    @Entry var surface = Surface.background
}

extension Theme {
    /// The grey for a time, a section header or a second line on `surface`.
    static func quietText(on surface: Surface) -> Color {
        surface == .raised ? secondaryText : tertiaryText
    }

    /// A list row's and a screen's side padding on the phone.
    static let phoneGutter: CGFloat = 20
    /// The least a control is tall or wide: the system's touch target.
    static let touchTarget: CGFloat = 44
}

/// A list's kind: rows on the page (Chats), or grouped cells (You).
enum PhoneListKind {
    case plain
    /// Cells on `quote`, a step up from the page.
    case grouped
}

extension View {
    /// On a `List` or `Form`: Peel's page behind it and behind its
    /// navigation bar and large title, never the system's black or grey.
    /// Its rows take `phoneRows` (a `Section` passes it to its rows).
    @ViewBuilder func phoneList(_ kind: PhoneListKind = .plain) -> some View {
        let page = scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .containerBackground(Theme.background, for: .navigation)
        switch kind {
        case .plain: page.listStyle(.plain)
        case .grouped: page.listStyle(.insetGrouped)
        }
    }

    /// On a list's rows or sections: their fill (`background` on a plain
    /// list, `quote` grouped) and `divider` hairlines between them.
    func phoneRows(_ kind: PhoneListKind = .plain) -> some View {
        listRowBackground(kind == .grouped ? Theme.quote : Theme.background)
            .listRowSeparatorTint(Theme.divider)
            .listSectionSeparatorTint(Theme.divider)
    }
}
