import SwiftUI
import PeelCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Sphinx's colours and type; see docs/design/README.md. Every colour follows the
/// system's light or dark appearance.
enum Theme {
    static let sidebar = Color(light: 0xF2F3F5, dark: 0x1A242E)
    static let background = Color(light: 0xFFFFFF, dark: 0x151E27)
    static let panel = Color(light: 0xF7F8F9, dark: 0x1A232D)
    static let input = Color(light: 0xF2F3F5, dark: 0x13181D)
    /// Off-white rather than white on navy: easier on long reads.
    static let text = Color(light: 0x292C33, dark: 0xE3E7EC)
    static let secondaryText = Color(light: 0x646C73, dark: 0x97A3B4)
    /// Quieter still, for what sits beside a time (a sender's local time):
    /// over 4.5:1 on the conversation and the thread panel.
    static let tertiaryText = Color(light: 0x6B737C, dark: 0x808D9E)
    static let divider = Color(light: 0xDCE0E3, dark: 0x2C353D)
    /// Menus, raised a step above the panels they open over.
    static let menu = Color(light: 0xFFFFFF, dark: 0x202B36)
    /// A raised fill on the conversation: quotes, file cards, the reply bar.
    static let quote = Color(light: 0xF2F3F5, dark: 0x1E2934)
    static let hover = Color(light: 0xE8EAED, dark: 0x222E3A)
    static let selection = Color(light: 0xDDE6FF, dark: 0x2D4170)
    static let selectionText = Color(light: 0x1E3D99, dark: 0xFFFFFF)
    static let accent = Color(light: 0x618AFF, dark: 0x618AFF)
    static let button = Color(light: 0x3F68E0, dark: 0x618AFF)
    static let buttonText = Color(light: 0xFFFFFF, dark: 0x0E1620)
    /// PrimaryRed: only for actions that destroy something.
    static let destructive = Color(light: 0xED7474, dark: 0xED7474)
    /// Links in messages.
    static let link = Color(light: 0x3F68E0, dark: 0x8FB0FF)
    /// An @mention: a soft chip.
    static let mentionFill = Color(light: 0xDDE6FF, dark: 0x2A3A5E)
    static let mentionText = Color(light: 0x1E3D99, dark: 0xB4C8FF)
    /// A mention of you, or @all: a gold chip (direction D; in dark, gold
    /// at 22% under light gold text, Tom, 2026-10-08).
    static let mentionYouFill = Color(light: 0xFBE7A6, dark: 0xF2C744, darkOpacity: 0.22)
    static let mentionYouText = Color(light: 0x5C4300, dark: 0xFFE08A)
    /// Text a chat search found (`ChatSearch`): a find highlight, warmer
    /// than a mention of you so the two never read as one.
    static let searchMatch = Color(light: 0xFFD54A, lightOpacity: 0.55, dark: 0xE8A800, darkOpacity: 0.42)
    /// Behind inline code and code blocks: a translucent step darker in
    /// light, lighter in dark, so it still shows on a hovered or tinted row.
    static let codeFill = Color.primary.opacity(0.07)
    /// The call window (board C3): darker than the conversation, so the
    /// tiles (`quote`) stand out; its title bar's rule, the name tags over
    /// tiles and video, and the line between a control and its chevron.
    static let callBackground = Color(light: 0xE9ECEF, dark: 0x0F161D)
    static let callDivider = Color(light: 0xDCE0E3, dark: 0x1E2731)
    static let callTag = Color(light: 0xFFFFFF, dark: 0x0A0E13, darkOpacity: 0.72)
    static let callChevronLine = Color(light: 0xDCE0E3, dark: 0x2F3D4A)
    /// PrimaryGreen: connected, and a message the server confirmed.
    static let confirmed = Color(light: 0x49C998, dark: 0x49C998)
    /// A boost chip with one of yours in it (Tom, 2026-10-08: quiet, as
    /// Slack's reactions): the accent at 12% over the conversation
    /// background, opaque so the boosters' photo rings match it, under its
    /// total in the accent tuned per theme to over 4.5:1 (`link`'s
    /// dark value, `mentionText`'s light one). Someone else's boost sits on
    /// `quote`.
    static let boostMineFill = Color(light: 0xECF1FF, dark: 0x1E2B41)
    static let boostMineText = Color(light: 0x1E3D99, dark: 0x8FB0FF)
    /// SphinxOrange: not connected. Also the money bolt: payment rows, Send
    /// sats and every boost chip (Tom, 2026-10-08). In light a deeper amber
    /// (Tom, 2026-10-08): Sphinx's `#FFBC58` is about 1.5:1 on light fills;
    /// this is over 3:1 on every fill it sits on and 4.5:1 on white, for the
    /// "Expired" text and white text on an armed button.
    static let attention = Color(light: 0xA86400, dark: 0xFFBC58)

    // The form system (shadcn's conventions, `FormKit.swift`): translucent
    // fills, borders and rings over the surfaces above.
    /// Inside a field, and an outline button.
    static let fieldFill = Color(light: 0x141E2D, lightOpacity: 0.05, dark: 0xFFFFFF, darkOpacity: 0.055)
    /// A field's and an outline button's 1 pt border at rest (shadcn's `input`).
    static let inputBorder = Color(light: 0x141E2D, lightOpacity: 0.16, dark: 0xFFFFFF, darkOpacity: 0.15)
    /// The same border under the pointer.
    static let inputBorderHover = Color(light: 0x141E2D, lightOpacity: 0.28, dark: 0xFFFFFF, darkOpacity: 0.26)
    /// The hairline around the popover and its cards.
    static let formEdge = Color(light: 0x141E2D, lightOpacity: 0.08, dark: 0xFFFFFF, darkOpacity: 0.07)
    /// The soft ring outside a focused field.
    static let focusRing = Color(light: 0x3F68E0, lightOpacity: 0.22, dark: 0x618AFF, darkOpacity: 0.28)
    /// The soft ring outside a field with a problem.
    static let problemRing = Color(light: 0xA86400, lightOpacity: 0.16, dark: 0xFFBC58, darkOpacity: 0.2)
    static let switchOff = Color(light: 0x141E2D, lightOpacity: 0.16, dark: 0xFFFFFF, darkOpacity: 0.16)
    static let switchKnob = Color(light: 0xFFFFFF, dark: 0xF4F6F8)
    /// Under the popover: radius 10 and y 4 stay within the 14 pt its
    /// floating window leaves for a shadow (`FloatingWindow.margin`).
    static let popoverShadow = Color(light: 0x141E2D, lightOpacity: 0.18, dark: 0x000000, darkOpacity: 0.5)
    /// Lifts a section off the popover in light; nothing in dark.
    static let sectionShadow = Color(light: 0x141E2D, lightOpacity: 0.04, dark: 0x000000, darkOpacity: 0)

    /// Under a menu, a suggestion list and the jump to newest button: softer
    /// than `popoverShadow` in dark.
    static let menuShadow = Color.black.opacity(0.25)
    /// A paid picture's veil (`PaidAttachmentViews`): soft fields of colour
    /// picked from the message, so locked pictures do not all look alike.
    static let veilTones: [Color] = [
        Color(light: 0x8E969C, dark: 0x3E6189), Color(light: 0xB08B7E, dark: 0x5B4A6E),
        Color(light: 0x7E9A8C, dark: 0x2F5D55), Color(light: 0x9B8BB0, dark: 0x6B5A3E),
    ]

    /// Corner radii: a control (a button, a field, a row's fill), a card (a
    /// box in a form or a chat, a picture), a panel (a popover, a menu).
    /// Chips, badges and pills are capsules.
    enum Radius {
        static let control: CGFloat = 7
        static let card: CGFloat = 9
        static let panel: CGFloat = 12
    }

    /// Padding and the gaps in stacks, on a 4 pt grid. Values off it remain
    /// where a layout was tuned by eye (docs/design/README.md, "Component
    /// library", Tokens).
    enum Space {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
    }

    /// A person's or a tribe's picture: 16 inline in a line of text and in
    /// chips, 20 in a small row, 24 in a panel's list, 32 beside a message
    /// and in a header, 48 at the top of a panel, 64 for your own photo.
    enum AvatarSize {
        static let xs: CGFloat = 16
        static let sm: CGFloat = 20
        static let md: CGFloat = 24
        static let lg: CGFloat = 32
        static let xl: CGFloat = 48
        static let xxl: CGFloat = 64
    }

    /// The system font (SF Pro), Tom's choice for readability on 2026-10-07.
    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        Font.system(size: size, weight: weight)
    }

    /// Code in messages: the system's monospaced face (SF Mono).
    static func code(_ size: CGFloat) -> Font {
        Font.system(size: size, design: .monospaced)
    }
}

/// Direction D (Tom, 2026-10-08): a person's name in their hue, tuned per
/// theme to 4.5:1 on every row, and their initials on a fill that is the
/// same in both themes, under white initials at over 5:1. In `PersonHue`'s
/// order: coral, lime, green, teal, cyan, violet, orchid, pink.
extension PersonHue {
    private static let names: [Color] = [
        Color(light: 0xA83825, dark: 0xFF9079), Color(light: 0x507000, dark: 0xA2C854),
        Color(light: 0x007938, dark: 0x6AD18A), Color(light: 0x00776B, dark: 0x55CEC0),
        Color(light: 0x00718D, dark: 0x57C8E6), Color(light: 0x674EB0, dark: 0xBAA4FF),
        Color(light: 0x874197, dark: 0xE196F3), Color(light: 0xA13567, dark: 0xFF8CBC),
    ]
    private static let fills: [Color] = [
        0xBA4A36, 0x587900, 0x007F3D, 0x007C70, 0x007893, 0x765DC1, 0x9951A9, 0xB44778,
    ].map { Color(light: $0, dark: $0) }

    var name: Color { Self.names[rawValue] }
    var avatarFill: Color { Self.fills[rawValue] }
}

extension Color {
    init(light: UInt32, lightOpacity: CGFloat = 1, dark: UInt32, darkOpacity: CGFloat = 1) {
        #if os(macOS)
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let (r, g, b) = Self.channels(isDark ? dark : light)
            return NSColor(srgbRed: r, green: g, blue: b, alpha: isDark ? darkOpacity : lightOpacity)
        })
        #else
        self.init(uiColor: UIColor { traits in
            let isDark = traits.userInterfaceStyle == .dark
            let (r, g, b) = Self.channels(isDark ? dark : light)
            return UIColor(red: r, green: g, blue: b, alpha: isDark ? darkOpacity : lightOpacity)
        })
        #endif
    }

    private static func channels(_ rgb: UInt32) -> (CGFloat, CGFloat, CGFloat) {
        (CGFloat((rgb >> 16) & 0xFF) / 255, CGFloat((rgb >> 8) & 0xFF) / 255, CGFloat(rgb & 0xFF) / 255)
    }
}
