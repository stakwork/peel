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
    /// Behind inline code and code blocks: a translucent step darker in
    /// light, lighter in dark, so it still shows on a hovered or tinted row.
    static let codeFill = Color.primary.opacity(0.07)
    /// PrimaryGreen: connected, and a message the server confirmed.
    static let confirmed = Color(light: 0x49C998, dark: 0x49C998)
    /// SphinxOrange: not connected. Also the boost bolt, from phase 4.
    static let attention = Color(light: 0xFFBC58, dark: 0xFFBC58)

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
    init(light: UInt32, dark: UInt32, darkOpacity: CGFloat = 1) {
        #if os(macOS)
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let (r, g, b) = Self.channels(isDark ? dark : light)
            return NSColor(srgbRed: r, green: g, blue: b, alpha: isDark ? darkOpacity : 1)
        })
        #else
        self.init(uiColor: UIColor { traits in
            let isDark = traits.userInterfaceStyle == .dark
            let (r, g, b) = Self.channels(isDark ? dark : light)
            return UIColor(red: r, green: g, blue: b, alpha: isDark ? darkOpacity : 1)
        })
        #endif
    }

    private static func channels(_ rgb: UInt32) -> (CGFloat, CGFloat, CGFloat) {
        (CGFloat((rgb >> 16) & 0xFF) / 255, CGFloat((rgb >> 8) & 0xFF) / 255, CGFloat(rgb & 0xFF) / 255)
    }
}
